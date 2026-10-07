#Requires -Version 7.0
<#
.SYNOPSIS
    Enable the Exchange Online mailbox for an on-prem user in a hybrid deployment, then read it back.
.DESCRIPTION
    Thin wrapper around Enable-RemoteMailbox. It builds the alias and the remote routing address
    from parameters (no tenant or domain is baked in), runs the cmdlet through ShouldProcess, and
    verifies by reading the remote mailbox back and checking the routing address is present.

    Run it in the on-prem Exchange Management Shell (or a remote session to it) so that
    Enable-RemoteMailbox and Get-RemoteMailbox exist. It does not assign licenses.

    If the user already has a remote mailbox and it has an address in -RoutingDomain, the script
    reports it and exits 0 without changes. If it has none, the script exits 1: the mailbox is
    routed to a different tenant domain than the one you gave, and this script will not change it.
    Exit code 1 on any failure, including a read-back that does not show the routing address.
.PARAMETER Identity
    The on-prem user: UserPrincipalName, SamAccountName or primary SMTP address.
.PARAMETER RoutingDomain
    The tenant routing domain, for example contoso.mail.onmicrosoft.com. The routing address
    becomes <alias>@<RoutingDomain>.
.PARAMETER Alias
    Mailbox alias. Default: the part of -Identity before the @.
.PARAMETER Archive
    Also create the online archive.
.PARAMETER LogPath
    Folder for the MSPLogger log file.
.EXAMPLE
    .\Enable-HybridRemoteMailbox.ps1 -Identity jane.doe@contoso.com -RoutingDomain contoso.mail.onmicrosoft.com -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Identity,

    [Parameter(Mandatory)]
    [ValidatePattern('^(?=.{4,253}$)([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$')]
    [string]$RoutingDomain,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Alias,

    [switch]$Archive,

    [string]$LogPath = 'C:\Logs\MSP'
)

function New-RemoteRoutingAddress {
    <# Pure: <alias>@<routing domain>. #>
    param(
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$RoutingDomain
    )
    "$($Alias.Trim())@$($RoutingDomain.Trim().TrimStart('@'))"
}

function Test-HasRoutingDomainAddress {
    <# Pure: does any address in the list end in @<routing domain>? #>
    param([string[]]$Address, [Parameter(Mandatory)][string]$RoutingDomain)
    $suffix = '@' + $RoutingDomain.Trim().TrimStart('@')
    [bool](@($Address) | Where-Object { $_ -and $_.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) })
}

function Get-DefaultAlias {
    <# Pure: the local part of an address, or the whole identity when it has no @. #>
    param([Parameter(Mandatory)][string]$Identity)
    ($Identity -split '@')[0]
}

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot '..' 'framework' 'MSPLogger.ps1')
    $logger = Get-MSPLogger -LogName 'EnableHybridRemoteMailbox' -LogPath $LogPath -Level 'Info'
} catch {
    # Write-Host, not Write-Error: with ErrorActionPreference Stop, Write-Error would throw past the exit.
    Write-Host "[ERROR] Cannot start logging; framework/MSPLogger.ps1 must exist next to this script's folder: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$logger.StartOperation('Enable remote mailbox')

$exitCode = 0
try {
    foreach ($cmd in 'Enable-RemoteMailbox', 'Get-RemoteMailbox') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "$cmd not found. Run this in the on-prem Exchange Management Shell."
        }
    }
    if (-not $Alias) { $Alias = Get-DefaultAlias -Identity $Identity }
    $routing = New-RemoteRoutingAddress -Alias $Alias -RoutingDomain $RoutingDomain

    $existing = Get-RemoteMailbox -Identity $Identity -ErrorAction SilentlyContinue
    if ($existing) {
        if (-not (Test-HasRoutingDomainAddress -Address @($existing.EmailAddresses | ForEach-Object { "$_" }) -RoutingDomain $RoutingDomain)) {
            throw "$Identity already has a remote mailbox with no address in $RoutingDomain (it has: $(@($existing.EmailAddresses) -join ', ')). Not changing it; check the tenant routing domain."
        }
        $logger.Info("$Identity already has a remote mailbox routed through $RoutingDomain; nothing to do.")
    } elseif ($PSCmdlet.ShouldProcess($Identity, "Enable remote mailbox (alias $Alias, routing $routing)")) {
        $enable = @{ Identity = $Identity; Alias = $Alias; RemoteRoutingAddress = $routing }
        if ($Archive) { $enable.Archive = $true }
        Enable-RemoteMailbox @enable -ErrorAction Stop | Out-Null

        $mailbox = Get-RemoteMailbox -Identity $Identity -ErrorAction Stop
        $addresses = @($mailbox.EmailAddresses | ForEach-Object { "$_" })
        Write-Host "Remote mailbox for ${Identity}:" -ForegroundColor Cyan
        $addresses | ForEach-Object { Write-Host "  $_" }
        if (-not ($addresses | Where-Object { $_ -ieq "smtp:$routing" })) {
            throw "Read-back does not list the routing address smtp:$routing."
        }
        $logger.Info("Enabled remote mailbox for $Identity with routing address $routing")
        [pscustomobject]@{
            Identity             = $Identity
            Alias                = $mailbox.Alias
            RemoteRoutingAddress = $routing
            EmailAddresses       = $addresses
        }
    } else {
        $logger.Info('WhatIf/declined: nothing changed.')
    }
} catch {
    $logger.Error("Enable remote mailbox failed: $($_.Exception.Message)")
    $exitCode = 1
} finally {
    $logger.EndOperation('Enable remote mailbox')
}
exit $exitCode
