#Requires -Version 7.0
<#
.SYNOPSIS
    Replace the installed Sysmon with the latest Sysinternals release and reinstall it with a given config.
.DESCRIPTION
    Order of operations, each step checked; the first failure stops the run with exit code 1:
      1. Refuse to run unless elevated (a -WhatIf preview does not need elevation).
      2. Download Sysmon.zip from Sysinternals into a private temp folder and extract it.
      3. Verify the extracted binary has a valid Authenticode signature from Microsoft Corporation.
         The existing install is not touched until this passes.
      4. Uninstall the current Sysmon (if installed), copy the new binary into place and install
         it with -ConfigPath.
      5. Confirm the Sysmon service is running and print old and new versions.
    The temp folder is always removed.

    Failure after step 4 begins can leave the machine without Sysmon. The script says so in its
    error output; rerun it or install manually with the config.

    The config is mandatory and has no default: it is specific to whoever owns the detection
    content (for example an MDR vendor). Pass the path to the config on the target machine.
.PARAMETER ConfigPath
    Path to the Sysmon configuration XML to install with. Must exist.
.PARAMETER InstallDirectory
    Folder that holds the installed Sysmon binary. Default: the Windows folder, where Sysmon
    installs itself.
.PARAMETER DownloadUrl
    Sysmon download. Default: the public Sysinternals URL.
.PARAMETER LogPath
    Folder for the MSPLogger log file.
.EXAMPLE
    .\Update-Sysmon.ps1 -ConfigPath 'C:\ProgramData\SecurityTools\sysmon-config.xml' -WhatIf
.EXAMPLE
    .\Update-Sysmon.ps1 -ConfigPath 'C:\ProgramData\SecurityTools\sysmon-config.xml' -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [string]$InstallDirectory = $(if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }),

    [ValidatePattern('^https://')]
    [string]$DownloadUrl = 'https://download.sysinternals.com/files/Sysmon.zip',

    [string]$LogPath = 'C:\Logs\MSP'
)

function Test-IsElevated {
    if (-not $IsWindows) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-MicrosoftSignature {
    <# Pure check on the object Get-AuthenticodeSignature returns: valid AND signed by Microsoft. #>
    param($Signature)
    if (-not $Signature) { return $false }
    if ("$($Signature.Status)" -ne 'Valid') { return $false }
    if (-not $Signature.SignerCertificate) { return $false }
    $Signature.SignerCertificate.Subject -match '(^|,\s*)CN=Microsoft Corporation(,|$)'
}

function Get-SysmonBinaryName {
    if ([Environment]::Is64BitOperatingSystem) { 'Sysmon64.exe' } else { 'Sysmon.exe' }
}

function Invoke-Native {
    <# Runs a native command; a non-zero exit code throws with the command's own output. #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    $output = & $FilePath @ArgumentList 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($FilePath)) $($ArgumentList -join ' ') failed with exit code $LASTEXITCODE. $($output.Trim())" }
    $output
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

try {
    . (Join-Path $PSScriptRoot '..' 'framework' 'MSPLogger.ps1')
    $logger = Get-MSPLogger -LogName 'UpdateSysmon' -LogPath $LogPath -Level 'Info'
} catch {
    # Write-Host, not Write-Error: with ErrorActionPreference Stop, Write-Error would throw past the exit.
    Write-Host "[ERROR] Cannot start logging; framework/MSPLogger.ps1 must exist next to this script's folder: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$logger.StartOperation('Update Sysmon')

if (-not $WhatIfPreference -and -not (Test-IsElevated)) {
    $logger.Error('Must run elevated on Windows. Re-run from an elevated pwsh session.')
    exit 1
}

$binaryName = Get-SysmonBinaryName
$installed  = [System.IO.Path]::Combine($InstallDirectory, $binaryName)
$oldVersion = if ([System.IO.File]::Exists($installed)) { (Get-Item -LiteralPath $installed).VersionInfo.FileVersion } else { $null }
$logger.Info("Current Sysmon: $(if ($oldVersion) { $oldVersion } else { 'not installed' })")

if (-not $PSCmdlet.ShouldProcess([Environment]::MachineName, "Download latest Sysmon, replace $installed, reinstall with config $ConfigPath")) {
    $logger.Info('WhatIf/declined: nothing changed.')
    exit 0
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("sysmon-update-" + [guid]::NewGuid().ToString('N'))
$exitCode = 0
$replaceStarted = $false
try {
    New-Item -ItemType Directory -Path $work | Out-Null
    $zip = Join-Path $work 'Sysmon.zip'
    $logger.Info("Downloading $DownloadUrl")
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $work -Force

    $fresh = Join-Path $work $binaryName
    if (-not (Test-Path -LiteralPath $fresh)) { throw "$binaryName not found in the downloaded archive." }

    $sig = Get-AuthenticodeSignature -FilePath $fresh
    if (-not (Test-MicrosoftSignature -Signature $sig)) {
        throw "Signature check failed for the downloaded $binaryName (status: $($sig.Status)). The existing install was not touched."
    }
    $newVersion = (Get-Item -LiteralPath $fresh).VersionInfo.FileVersion
    $logger.Info("Downloaded $binaryName $newVersion, signature valid, signed by Microsoft Corporation.")

    $replaceStarted = $true
    if ($oldVersion) {
        $logger.Info('Uninstalling current Sysmon.')
        Invoke-Native -FilePath $installed -ArgumentList '-u' | Out-Null
    }
    Copy-Item -LiteralPath $fresh -Destination $installed -Force
    $logger.Info("Installing with config $ConfigPath")
    Invoke-Native -FilePath $installed -ArgumentList '-accepteula', '-i', $ConfigPath | Out-Null

    $service = Get-Service -Name 'Sysmon64', 'Sysmon' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running'
    if (-not $service) { throw 'Install command succeeded but no Sysmon service is running.' }

    $installedNow = (Get-Item -LiteralPath $installed).VersionInfo.FileVersion
    $logger.Info("Sysmon version: $(if ($oldVersion) { $oldVersion } else { 'none' }) -> $installedNow")
} catch {
    $logger.Error("Update failed: $($_.Exception.Message)")
    if ($replaceStarted) {
        $logger.Error('The replace step had started: Sysmon may now be uninstalled. Verify the service and reinstall with the config if needed.')
    }
    $exitCode = 1
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    $logger.EndOperation('Update Sysmon')
}
exit $exitCode
