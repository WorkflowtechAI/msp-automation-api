#Requires -Version 7.0
<#
.SYNOPSIS
    In-place upgrade of Windows 10 to Windows 11, by the Installation Assistant or by Windows Update.
.DESCRIPTION
    -Method InstallationAssistant
        Clears the Windows Update download cache and any stale $WINDOWS.~BT / $WINDOWS.~WS staging
        folders, downloads Microsoft's Windows 11 Installation Assistant, verifies its Authenticode
        signature, launches it, and copies its logs to -LogDestination.
        Refuses to clear staging while an upgrade appears to be running (SetupHost or the
        Assistant itself).
    -Method WindowsUpdate
        Uses the PSWindowsUpdate module (must already be installed) to pin the target release with
        Set-WUSettings -TargetReleaseVersion and then installs through Microsoft Update.
        No KB number is hard-coded; pass -KBArticleID only to install a specific update.

    -SkipCompatCheck passes /skipcompatcheck to the Installation Assistant. That bypasses the
    hardware compatibility check and leaves the machine on UNSUPPORTED hardware: it may not
    receive updates and Microsoft does not support it. Default is off. It applies to the
    InstallationAssistant method only and is rejected with WindowsUpdate.

    The Assistant switches come from the author's field notes and have not been re-verified
    against the current Assistant build.

    Requires an elevated pwsh 7 session. A -WhatIf preview does not need elevation and changes
    nothing. Exit code 0 on success, 1 on any failure.
.PARAMETER Method
    InstallationAssistant or WindowsUpdate.
.PARAMETER TargetReleaseVersion
    Feature release to pin, for example 24H2. Required for -Method WindowsUpdate.
.PARAMETER ProductVersion
    Product to pin. Default: Windows 11.
.PARAMETER SkipCompatCheck
    Opt in to /skipcompatcheck (InstallationAssistant only). See the warning above.
.PARAMETER Wait
    InstallationAssistant only: wait for the Assistant to exit, fail on a non-zero exit code,
    then copy logs. Without it the Assistant is launched and logs are copied at once.
.PARAMETER KBArticleID
    WindowsUpdate only: install only these updates.
.PARAMETER AssistantUrl
    Download for the Installation Assistant. Default: Microsoft's public fwlink.
.PARAMETER LogDestination
    Where Assistant logs are copied. Default: C:\UA_Logs.
.PARAMETER LogPath
    Folder for the MSPLogger log file.
.EXAMPLE
    .\Invoke-Windows11Upgrade.ps1 -Method InstallationAssistant -WhatIf
.EXAMPLE
    .\Invoke-Windows11Upgrade.ps1 -Method WindowsUpdate -TargetReleaseVersion 24H2 -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('InstallationAssistant', 'WindowsUpdate')]
    [string]$Method,

    [ValidatePattern('^\d{2}[Hh][12]$')]
    [string]$TargetReleaseVersion,

    [ValidateSet('Windows 11')]
    [string]$ProductVersion = 'Windows 11',

    [switch]$SkipCompatCheck,

    [switch]$Wait,

    [string[]]$KBArticleID,

    [string]$AssistantUrl = 'https://go.microsoft.com/fwlink/?linkid=2171764',

    [string]$LogDestination = 'C:\UA_Logs',

    [string]$LogPath = 'C:\Logs\MSP'
)

function Test-IsElevated {
    if (-not $IsWindows) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-MicrosoftSignature {
    param($Signature)
    if (-not $Signature) { return $false }
    if ("$($Signature.Status)" -ne 'Valid') { return $false }
    if (-not $Signature.SignerCertificate) { return $false }
    $Signature.SignerCertificate.Subject -match '(^|,\s*)CN=Microsoft Corporation(,|$)'
}

function Get-InstallationAssistantArguments {
    <# Pure: the Assistant command line. /skipcompatcheck is added only on explicit opt-in. #>
    param([switch]$SkipCompatCheck)
    $list = @('/quietinstall', '/skipeula', '/auto', 'upgrade', '/reusecatalog', '/norestartui')
    if ($SkipCompatCheck) { $list += '/skipcompatcheck' }
    $list
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

. (Join-Path $PSScriptRoot '..' 'framework' 'MSPLogger.ps1')
$logger = Get-MSPLogger -LogName 'Windows11Upgrade' -LogPath $LogPath -Level 'Info'
$logger.StartOperation("Windows 11 upgrade ($Method)")

# Argument checks come before anything else, so a bad call fails the same way with or without -WhatIf.
if ($Method -eq 'WindowsUpdate' -and -not $TargetReleaseVersion) {
    $logger.Error('-TargetReleaseVersion is required for -Method WindowsUpdate (for example 24H2).')
    exit 1
}
if ($Method -eq 'WindowsUpdate' -and $SkipCompatCheck) {
    $logger.Error('-SkipCompatCheck applies only to -Method InstallationAssistant.')
    exit 1
}
if ($Method -eq 'InstallationAssistant' -and ($TargetReleaseVersion -or $KBArticleID)) {
    $logger.Error('-TargetReleaseVersion and -KBArticleID apply only to -Method WindowsUpdate.')
    exit 1
}

if ($SkipCompatCheck) {
    $logger.Warning('SkipCompatCheck is ON: the hardware compatibility check is bypassed and the machine will be on unsupported hardware.')
}

if (-not $WhatIfPreference -and -not (Test-IsElevated)) {
    $logger.Error('Must run elevated on Windows. Re-run from an elevated pwsh session.')
    exit 1
}

if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Windows 11 upgrade via $Method")) {
    $logger.Info('WhatIf/declined: nothing changed.')
    exit 0
}

$exitCode = 0
$servicesStopped = $false
try {
    if ($Method -eq 'InstallationAssistant') {
        $busy = Get-Process -Name SetupHost, Windows10UpgraderApp, Windows11InstallationAssistant -ErrorAction SilentlyContinue
        if ($busy) { throw "An upgrade appears to be running ($(@($busy.ProcessName | Sort-Object -Unique) -join ', ')). Not clearing its staging folders." }

        $logger.Info('Clearing the Windows Update download cache.')
        $servicesStopped = $true
        Stop-Service -Name wuauserv, bits -Force
        $cache = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
        if (Test-Path -LiteralPath $cache) {
            Get-ChildItem -LiteralPath $cache -Force | Remove-Item -Recurse -Force
        }
        Start-Service -Name wuauserv, bits
        $servicesStopped = $false

        foreach ($name in '$WINDOWS.~BT', '$WINDOWS.~WS') {
            $stale = Join-Path "$env:SystemDrive\" $name
            if (Test-Path -LiteralPath $stale) {
                $logger.Info("Removing stale staging folder $stale")
                Remove-Item -LiteralPath $stale -Recurse -Force
            }
        }

        $assistant = Join-Path ([IO.Path]::GetTempPath()) 'Windows11InstallationAssistant.exe'
        $logger.Info("Downloading the Installation Assistant from $AssistantUrl")
        Invoke-WebRequest -Uri $AssistantUrl -OutFile $assistant -UseBasicParsing
        if (-not (Test-Path -LiteralPath $assistant) -or (Get-Item -LiteralPath $assistant).Length -eq 0) {
            throw 'Download produced no file.'
        }
        $sig = Get-AuthenticodeSignature -FilePath $assistant
        if (-not (Test-MicrosoftSignature -Signature $sig)) {
            Remove-Item -LiteralPath $assistant -Force -ErrorAction SilentlyContinue
            throw "Signature check failed for the downloaded Assistant (status: $($sig.Status)). Not launching it."
        }

        $assistantArgs = Get-InstallationAssistantArguments -SkipCompatCheck:$SkipCompatCheck
        $logger.Info("Launching the Assistant: $($assistantArgs -join ' ')")
        $proc = Start-Process -FilePath $assistant -ArgumentList $assistantArgs -PassThru
        if ($Wait) {
            $proc.WaitForExit()
            if ($proc.ExitCode -ne 0) { throw "The Assistant exited with code $($proc.ExitCode)." }
        }

        $logSource = Join-Path $env:ProgramData 'Microsoft\Windows\UpdateAssistant'
        if (Test-Path -LiteralPath $logSource) {
            New-Item -ItemType Directory -Path $LogDestination -Force | Out-Null
            Copy-Item -Path (Join-Path $logSource '*') -Destination $LogDestination -Recurse -Force
            $logger.Info("Assistant logs copied to $LogDestination")
        } else {
            $logger.Warning("No Assistant logs found at $logSource yet.")
        }
    } else {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            throw 'PSWindowsUpdate module is required. Install it with: Install-Module PSWindowsUpdate'
        }
        Import-Module PSWindowsUpdate
        $logger.Info("Pinning target release $ProductVersion $TargetReleaseVersion")
        Set-WUSettings -TargetReleaseVersion -TargetReleaseVersionInfo $TargetReleaseVersion -ProductVersion $ProductVersion -Confirm:$false
        $install = @{ MicrosoftUpdate = $true; AcceptAll = $true; Install = $true; IgnoreReboot = $true }
        if ($KBArticleID) { $install.KBArticleID = $KBArticleID }
        $logger.Info('Installing through Microsoft Update (reboot is not forced).')
        Get-WindowsUpdate @install | Out-Null
        if (Get-Command Get-WURebootStatus -ErrorAction SilentlyContinue) {
            $pending = Get-WURebootStatus -Silent
            $logger.Info("Reboot required: $pending")
        }
    }
} catch {
    $logger.Error("Upgrade failed: $($_.Exception.Message)")
    $exitCode = 1
} finally {
    if ($servicesStopped) {
        # Never leave Windows Update stopped because the cache clear failed halfway.
        Start-Service -Name wuauserv, bits -ErrorAction SilentlyContinue
    }
    $logger.EndOperation("Windows 11 upgrade ($Method)")
}
exit $exitCode
