#Requires -Version 7.0
<#
.SYNOPSIS
    Find a deleted Active Directory user and restore it to a chosen OU, after confirmation.
.DESCRIPTION
    Searches deleted objects (IncludeDeletedObjects) by SamAccountName or display name. The
    search value is LDAP-escaped, so wildcard or filter characters in it are matched literally.

    Exactly one match is required. Zero matches or several matches stop the run with exit code 1
    and nothing is restored; several matches are listed so the search can be narrowed.

    The match is shown, then restored to -TargetOU through ShouldProcess (-WhatIf previews,
    -Confirm prompts). The result is read back and printed.

    Notes: the AD Recycle Bin must be enabled for recycled objects to keep their attributes and
    group memberships. A restored account may still need to be re-enabled and have its password
    reset; this script does neither.

    Uses the on-prem ActiveDirectory module (RSAT). Run from a domain-joined host with rights to
    restore objects.
.PARAMETER SamAccountName
    Exact SamAccountName of the deleted user.
.PARAMETER DisplayName
    Exact display name of the deleted user.
.PARAMETER TargetOU
    Distinguished name of the OU to restore into, for example OU=Staff,DC=contoso,DC=com.
.PARAMETER Server
    Domain controller to talk to. Default: whichever the module picks.
.PARAMETER LogPath
    Folder for the MSPLogger log file.
.EXAMPLE
    .\Restore-DeletedADUser.ps1 -SamAccountName jdoe -TargetOU 'OU=Staff,DC=contoso,DC=com' -WhatIf
.EXAMPLE
    .\Restore-DeletedADUser.ps1 -DisplayName 'Jane Doe' -TargetOU 'OU=Staff,DC=contoso,DC=com'
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'BySam')]
param(
    [Parameter(Mandatory, ParameterSetName = 'BySam')]
    [ValidateNotNullOrEmpty()]
    [string]$SamAccountName,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [string]$DisplayName,

    [Parameter(Mandatory)]
    [ValidatePattern('^(OU|CN)=.+,DC=.+$')]
    [string]$TargetOU,

    [string]$Server,

    [string]$LogPath = 'C:\Logs\MSP'
)

function ConvertTo-LdapFilterValue {
    <# RFC 4515 escaping so a value is matched literally inside an LDAP filter. #>
    param([Parameter(Mandatory)][string]$Value)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '\'     { [void]$sb.Append('\5c') }
            '*'     { [void]$sb.Append('\2a') }
            '('     { [void]$sb.Append('\28') }
            ')'     { [void]$sb.Append('\29') }
            "`0"    { [void]$sb.Append('\00') }
            default { [void]$sb.Append($ch) }
        }
    }
    $sb.ToString()
}

function New-DeletedUserLdapFilter {
    <# Pure: filter for deleted user objects by SamAccountName or display name. #>
    param([string]$SamAccountName, [string]$DisplayName)
    if ($SamAccountName) { $clause = "(sAMAccountName=$(ConvertTo-LdapFilterValue $SamAccountName))" }
    elseif ($DisplayName) { $clause = "(displayName=$(ConvertTo-LdapFilterValue $DisplayName))" }
    else { throw 'Give a SamAccountName or a DisplayName.' }
    "(&(objectClass=user)(isDeleted=TRUE)$clause)"
}

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'framework' 'MSPLogger.ps1')
$logger = Get-MSPLogger -LogName 'RestoreDeletedADUser' -LogPath $LogPath -Level 'Info'
$logger.StartOperation('Restore deleted AD user')

$exitCode = 0
try {
    foreach ($cmd in 'Get-ADObject', 'Restore-ADObject') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "$cmd not found. Install RSAT (ActiveDirectory module) on this host."
        }
    }
    $adArgs = @{}
    if ($Server) { $adArgs.Server = $Server }

    $filter  = New-DeletedUserLdapFilter -SamAccountName $SamAccountName -DisplayName $DisplayName
    $logger.Info("Searching deleted objects with $filter")
    $found = @(Get-ADObject -LDAPFilter $filter -IncludeDeletedObjects @adArgs `
        -Properties sAMAccountName, displayName, lastKnownParent, whenChanged)

    if ($found.Count -eq 0) { throw 'No deleted user matched.' }
    if ($found.Count -gt 1) {
        $found | Format-Table Name, sAMAccountName, lastKnownParent, whenChanged -AutoSize | Out-String | Write-Host
        throw "$($found.Count) deleted users matched. Narrow the search (use SamAccountName); nothing was restored."
    }

    $target = $found[0]
    Write-Host "Found deleted user:" -ForegroundColor Cyan
    $target | Format-List Name, sAMAccountName, displayName, lastKnownParent, whenChanged, DistinguishedName | Out-String | Write-Host

    if ($PSCmdlet.ShouldProcess($target.DistinguishedName, "Restore to $TargetOU")) {
        Restore-ADObject -Identity $target.ObjectGUID -TargetPath $TargetOU @adArgs -ErrorAction Stop
        $restored = Get-ADObject -Identity $target.ObjectGUID @adArgs -Properties sAMAccountName -ErrorAction Stop
        if (-not $restored -or -not $restored.DistinguishedName.EndsWith($TargetOU, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Restore reported success but the object is not under $TargetOU."
        }
        $logger.Info("Restored $($restored.sAMAccountName) to $($restored.DistinguishedName)")
        [pscustomobject]@{
            SamAccountName    = $restored.sAMAccountName
            DistinguishedName = $restored.DistinguishedName
            ObjectGuid        = $target.ObjectGUID
        }
    } else {
        $logger.Info('WhatIf/declined: nothing restored.')
    }
} catch {
    $logger.Error("Restore failed: $($_.Exception.Message)")
    $exitCode = 1
} finally {
    $logger.EndOperation('Restore deleted AD user')
}
exit $exitCode
