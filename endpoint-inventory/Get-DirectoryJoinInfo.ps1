#Requires -Version 7.0
<#
.SYNOPSIS
    Report how this machine is joined (workgroup, local AD, Azure AD, hybrid), which DC holds
    the PDC emulator role, and whether an Azure AD Connect sync server exists.
.DESCRIPTION
    Read-only. Runs on the machine being asked about and returns one structured object, plus a
    one-paragraph summary on the console. Nothing is guessed: a fact that cannot be detected is
    reported as empty and explained in Notes, never filled in with an assumption.

    Detection:
      Join type       Win32_ComputerSystem.PartOfDomain plus `dsregcmd /status` (AzureAdJoined).
      Primary DC      PDC emulator of the domain, from the ActiveDirectory module when present,
                      otherwise from System.DirectoryServices.
      AD Connect      The ADSync service or install folders on this machine, and the Azure AD
                      Connect service connection point in the directory when the ActiveDirectory
                      module is present.

    The ActiveDirectory module is optional. Without it the script still reports join type and
    falls back for the PDC.
.PARAMETER ExportJson
    Write the result object to this path as JSON.
.EXAMPLE
    .\Get-DirectoryJoinInfo.ps1
.EXAMPLE
    $info = .\Get-DirectoryJoinInfo.ps1 -ExportJson C:\Reports\join-info.json
    $info.JoinType
#>
[CmdletBinding()]
param(
    [string]$ExportJson
)

function Resolve-JoinType {
    <# Pure decision: domain membership plus Azure AD join gives the join type. #>
    param(
        [Parameter(Mandatory)][bool]$PartOfDomain,
        [Parameter(Mandatory)][bool]$AzureAdJoined
    )
    if ($PartOfDomain -and $AzureAdJoined) { return 'Hybrid' }
    if ($PartOfDomain)                     { return 'LocalAD' }
    if ($AzureAdJoined)                    { return 'AzureAD' }
    return 'Workgroup'
}

function ConvertFrom-DsregStatus {
    <# Parse the text of `dsregcmd /status` into the two flags this script needs. #>
    param([string[]]$Text)
    $state = [ordered]@{ AzureAdJoined = $false; DomainJoined = $false }
    foreach ($line in $Text) {
        if ($line -match '^\s*AzureAdJoined\s*:\s*(YES|NO)\s*$') { $state.AzureAdJoined = ($Matches[1] -eq 'YES') }
        if ($line -match '^\s*DomainJoined\s*:\s*(YES|NO)\s*$')  { $state.DomainJoined  = ($Matches[1] -eq 'YES') }
    }
    [pscustomobject]$state
}

function Get-JoinSummary {
    <# Pure: one human-readable paragraph from the result object. #>
    param([Parameter(Mandatory)]$Info)
    $lines = switch ($Info.JoinType) {
        'Hybrid'    { "Hybrid joined (domain $($Info.DomainName) and Azure AD)." }
        'LocalAD'   { "Joined to the local AD domain $($Info.DomainName) only." }
        'AzureAD'   { 'Azure AD joined only.' }
        'Workgroup' { 'Not joined to any directory (workgroup).' }
        default     { 'Join type could not be determined.' }
    }
    $lines = @($lines)
    if ($Info.JoinType -in 'Hybrid', 'LocalAD') {
        $lines += if ($Info.PrimaryDC) { "Primary DC (PDC emulator): $($Info.PrimaryDC)." } else { 'Primary DC: not detected.' }
        if ($Info.AdSyncServer) {
            $where = if ($Info.AdSyncIsLocal) { 'this machine' } else { $Info.AdSyncServer }
            $lines += "Azure AD Connect sync server: $where (found by $($Info.AdSyncDetectedBy -join ', '))."
        } elseif ($Info.AdSyncIsLocal) {
            $lines += "Azure AD Connect is present on this machine (found by $($Info.AdSyncDetectedBy -join ', '))."
        } else {
            $lines += 'Azure AD Connect sync server: not detected.'
        }
    }
    $lines -join ' '
}

function Get-PrimaryDomainController {
    $name = $null; $source = $null
    if (Get-Command Get-ADDomain -ErrorAction SilentlyContinue) {
        try { $name = (Get-ADDomain -ErrorAction Stop).PDCEmulator; $source = 'ActiveDirectory module' } catch { }
    }
    if (-not $name) {
        try {
            $name   = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
            $source = 'System.DirectoryServices'
        } catch { }
    }
    [pscustomobject]@{ Name = $name; Source = $source }
}

function Get-AdSyncInfo {
    <# Looks on this machine and, when possible, in the directory. #>
    $detectedBy = [System.Collections.Generic.List[string]]::new()
    $isLocal    = $false
    $server     = $null

    if (Get-Service -Name ADSync -ErrorAction SilentlyContinue) {
        $isLocal = $true; $detectedBy.Add('local ADSync service')
    } else {
        $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
        foreach ($root in $roots) {
            foreach ($folder in 'Microsoft Azure AD Sync', 'Microsoft Azure Active Directory Connect') {
                if (Test-Path -LiteralPath (Join-Path $root $folder)) { $isLocal = $true; $detectedBy.Add("local install folder '$folder'") }
            }
        }
    }

    if ((Get-Command Get-ADObject -ErrorAction SilentlyContinue) -and (Get-Command Get-ADRootDSE -ErrorAction SilentlyContinue)) {
        try {
            $configNc = (Get-ADRootDSE -ErrorAction Stop).configurationNamingContext
            $scp = Get-ADObject -SearchBase $configNc -ErrorAction Stop `
                -LDAPFilter '(&(objectClass=serviceConnectionPoint)(keywords=azureDirectorySynchronizationService))' `
                -Properties ServerReferenceBL | Select-Object -First 1
            if ($scp -and $scp.ServerReferenceBL) {
                $computer = Get-ADObject -Identity ($scp.ServerReferenceBL | Select-Object -First 1) -Properties DNSHostName -ErrorAction Stop
                if ($computer.DNSHostName) { $server = [string]$computer.DNSHostName; $detectedBy.Add('directory service connection point') }
            }
        } catch { }
    }

    if (-not $server -and $isLocal) { $server = $env:COMPUTERNAME }
    if ($server -and -not $isLocal -and ($server.Split('.')[0] -ieq $env:COMPUTERNAME)) { $isLocal = $true }

    [pscustomobject]@{ Server = $server; IsLocal = $isLocal; DetectedBy = @($detectedBy) }
}

# Main. Functions above are defined without side effects so tests can load them alone.
$notes = [System.Collections.Generic.List[string]]::new()

$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$dsreg = $null
try {
    $dsreg = ConvertFrom-DsregStatus -Text (dsregcmd /status)
} catch {
    $notes.Add("dsregcmd /status could not be read ($($_.Exception.Message)); Azure AD join assumed absent.")
}
$azureJoined = [bool]($dsreg -and $dsreg.AzureAdJoined)
$joinType    = Resolve-JoinType -PartOfDomain ([bool]$cs.PartOfDomain) -AzureAdJoined $azureJoined

$pdc  = $null
$sync = [pscustomobject]@{ Server = $null; IsLocal = $false; DetectedBy = @() }
if ($joinType -in 'Hybrid', 'LocalAD') {
    $pdc  = Get-PrimaryDomainController
    if (-not $pdc.Name) { $notes.Add('PDC emulator could not be determined (no ActiveDirectory module and no domain reachable).') }
    $sync = Get-AdSyncInfo
    if (-not (Get-Command Get-ADObject -ErrorAction SilentlyContinue)) {
        $notes.Add('ActiveDirectory module not installed: the directory was not searched for an Azure AD Connect server.')
    }
}

$info = [pscustomobject]@{
    ComputerName     = $env:COMPUTERNAME
    JoinType         = $joinType
    DomainName       = if ($cs.PartOfDomain) { $cs.Domain } else { $null }
    AzureAdJoined    = $azureJoined
    PrimaryDC        = if ($pdc) { $pdc.Name } else { $null }
    PrimaryDCSource  = if ($pdc) { $pdc.Source } else { $null }
    AdSyncServer     = $sync.Server
    AdSyncIsLocal    = $sync.IsLocal
    AdSyncDetectedBy = $sync.DetectedBy
    Notes            = @($notes)
}

Write-Host (Get-JoinSummary -Info $info) -ForegroundColor Cyan
foreach ($n in $notes) { Write-Warning $n }

if ($ExportJson) {
    $info | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ExportJson -Encoding utf8
    Write-Host "[OK] Exported to $ExportJson" -ForegroundColor Green
}

$info
