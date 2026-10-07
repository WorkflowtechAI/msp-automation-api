#Requires -Version 7.0
<#
.SYNOPSIS
    Change a user's primary SMTP address in proxyAddresses and keep the old one as an alias.
.DESCRIPTION
    proxyAddresses marks the primary address with an upper-case SMTP: prefix and aliases with a
    lower-case smtp: prefix. This script makes -NewPrimarySmtp the only SMTP: entry, demotes the
    previous primary to smtp:, keeps every other entry (X500, SIP and so on), and removes
    duplicates ignoring case.

    Writes to on-prem Active Directory (Set-ADUser). That is the right place for users synced
    from AD: Entra ID / Exchange Online receive the change at the next sync. It replaces the
    retired AzureAD / MSOnline cmdlets the original snippet used.

    Microsoft Graph is used for verification only (-VerifyInGraph): per Microsoft's user resource
    documentation proxyAddresses is read-only in Graph, so Graph cannot apply this change. That
    has not been tested here. Cloud-only mailboxes need Exchange Online instead (Set-Mailbox).

    If an Exchange email address policy is enabled for the user it can overwrite the result.
    Disable the policy for the user first (Set-RemoteMailbox -EmailAddressPolicyEnabled $false).

    -WhatIf previews; the before and after lists are always printed. The change is read back from
    AD and the run fails (exit 1) if it did not take.
.PARAMETER Identity
    UserPrincipalName or SamAccountName of the user.
.PARAMETER NewPrimarySmtp
    The address to make primary, for example jane.doe@contoso.com.
.PARAMETER UpdateMailAttribute
    Also set the user's mail attribute to the new primary.
.PARAMETER VerifyInGraph
    After the AD change, read proxyAddresses from Microsoft Graph and report whether it already
    shows the new primary. Requires the Microsoft.Graph.Users module and an existing
    Connect-MgGraph session (User.Read.All). A cloud copy that has not synced yet is reported,
    not treated as failure.
.PARAMETER Server
    Domain controller to talk to.
.PARAMETER LogPath
    Folder for the MSPLogger log file.
.EXAMPLE
    .\Set-UserPrimarySmtpAddress.ps1 -Identity jdoe@contoso.com -NewPrimarySmtp jane.doe@contoso.com -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Identity,

    [Parameter(Mandatory)]
    [ValidatePattern('^[^@\s:]+@[^@\s:]+\.[^@\s:]+$')]
    [string]$NewPrimarySmtp,

    [switch]$UpdateMailAttribute,

    [switch]$VerifyInGraph,

    [string]$Server,

    [string]$LogPath = 'C:\Logs\MSP'
)

function Get-UpdatedProxyAddresses {
    <#
        Pure transformation. Returns the list with $NewPrimary as the single SMTP: entry and the
        old primary kept as smtp:. Non-SMTP entries are untouched.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$ProxyAddresses,
        [Parameter(Mandatory)][string]$NewPrimary
    )
    $new = $NewPrimary.Trim()
    $result = [System.Collections.Generic.List[string]]::new()
    $seen   = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    [void]$seen.Add($new)
    $result.Add("SMTP:$new")

    foreach ($entry in @($ProxyAddresses)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($entry -match '^smtp:(.+)$') {
            # Case-insensitive prefix: SMTP: (old primary) becomes smtp:, smtp: stays smtp:.
            $address = $Matches[1].Trim()
            if ($seen.Add($address)) { $result.Add("smtp:$address") }
        } else {
            if ($seen.Add($entry)) { $result.Add($entry) }
        }
    }
    , $result.ToArray()
}

function ConvertTo-LdapFilterValue {
    param([Parameter(Mandatory)][string]$Value)
    $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace("`0", '\00')
}

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot '..' 'framework' 'MSPLogger.ps1')
    $logger = Get-MSPLogger -LogName 'SetPrimarySmtp' -LogPath $LogPath -Level 'Info'
} catch {
    # Write-Host, not Write-Error: with ErrorActionPreference Stop, Write-Error would throw past the exit.
    Write-Host "[ERROR] Cannot start logging; framework/MSPLogger.ps1 must exist next to this script's folder: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$logger.StartOperation('Set primary SMTP')

$exitCode = 0
try {
    foreach ($cmd in 'Get-ADUser', 'Set-ADUser') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "$cmd not found. Install RSAT (ActiveDirectory module) on this host."
        }
    }
    $adArgs = @{}
    if ($Server) { $adArgs.Server = $Server }

    $escaped = ConvertTo-LdapFilterValue $Identity
    $users = @(Get-ADUser -LDAPFilter "(|(userPrincipalName=$escaped)(sAMAccountName=$escaped))" @adArgs `
        -Properties proxyAddresses, mail)
    if ($users.Count -eq 0) { throw "No AD user matches '$Identity'." }
    if ($users.Count -gt 1) { throw "$($users.Count) AD users match '$Identity'. Use the UserPrincipalName." }
    $user = $users[0]

    $before = @($user.proxyAddresses)
    $after  = Get-UpdatedProxyAddresses -ProxyAddresses $before -NewPrimary $NewPrimarySmtp

    Write-Host "proxyAddresses before:" -ForegroundColor Cyan
    $before | ForEach-Object { Write-Host "  $_" }
    Write-Host "proxyAddresses after:" -ForegroundColor Cyan
    $after | ForEach-Object { Write-Host "  $_" }

    $unchanged = (($before | Sort-Object -CaseSensitive) -join '|') -ceq (($after | Sort-Object -CaseSensitive) -join '|')
    if ($unchanged -and -not $UpdateMailAttribute) {
        $logger.Info('Already the primary address; nothing to change.')
    } elseif ($PSCmdlet.ShouldProcess($user.DistinguishedName, "Set primary SMTP to $NewPrimarySmtp")) {
        $replace = @{ proxyAddresses = [string[]]$after }
        if ($UpdateMailAttribute) { $replace.mail = $NewPrimarySmtp }
        Set-ADUser -Identity $user.ObjectGUID -Replace $replace @adArgs

        $check = Get-ADUser -Identity $user.ObjectGUID -Properties proxyAddresses @adArgs
        $primary = @($check.proxyAddresses) | Where-Object { $_ -cmatch '^SMTP:' }
        if (@($primary).Count -ne 1 -or $primary -ine "SMTP:$NewPrimarySmtp") {
            throw "Read-back shows primary '$primary', expected 'SMTP:$NewPrimarySmtp'. An email address policy may have rewritten it."
        }
        $logger.Info("Primary SMTP for $($user.SamAccountName) is now $NewPrimarySmtp; old primary kept as an alias.")

        if ($VerifyInGraph) {
            if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue) -or -not (Get-MgContext)) {
                $logger.Warning('-VerifyInGraph skipped: no Microsoft Graph session (Connect-MgGraph first).')
            } else {
                $cloud = Get-MgUser -UserId $user.UserPrincipalName -Property proxyAddresses
                if (@($cloud.ProxyAddresses) -ccontains "SMTP:$NewPrimarySmtp") {
                    $logger.Info('Graph already shows the new primary.')
                } else {
                    $logger.Warning('Graph does not show the new primary yet; it appears after the next directory sync.')
                }
            }
        }
    } else {
        $logger.Info('WhatIf/declined: nothing changed.')
    }
} catch {
    $logger.Error("Set primary SMTP failed: $($_.Exception.Message)")
    $exitCode = 1
} finally {
    $logger.EndOperation('Set primary SMTP')
}
exit $exitCode
