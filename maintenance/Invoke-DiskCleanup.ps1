#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Targeted disk cleanup: temp files, Windows Update cache, old logs, browser caches, recycle bin.
    Shows space recovered. Safer than CleanMgr for scripted/remote use.
.PARAMETER ComputerName   Default: localhost
.PARAMETER IncludeBrowser Also clear Chrome/Edge/Firefox caches for all users
.PARAMETER WhatIf         Show what would be deleted without deleting
.EXAMPLE
    .\Invoke-DiskCleanup.ps1
    .\Invoke-DiskCleanup.ps1 -ComputerName PC01 -IncludeBrowser
    .\Invoke-DiskCleanup.ps1 -WhatIf
#>
param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [switch]$IncludeBrowser,
    [switch]$WhatIf
)

$action = if ($WhatIf) { "WhatIf" } else { "Delete" }
Write-Host "`n=== Disk Cleanup: $ComputerName $(if($WhatIf){ '[WHATIF MODE]' }) ===" -ForegroundColor Cyan

$script = {
    param($includeBrowser, $whatIf)

    function Remove-SafePath {
        param([string]$Path, [string]$Label)
        if (-not (Test-Path $Path)) { return 0 }
        $size = (Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $sizeMB = [math]::Round($size / 1MB, 1)
        if ($whatIf) {
            Write-Host "  [WHATIF] $Label : $sizeMB MB" -ForegroundColor Yellow
        } else {
            Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [CLEANED] $Label : $sizeMB MB freed" -ForegroundColor Green
        }
        return $size
    }

    $total = 0

    # System temp
    $total += Remove-SafePath $env:TEMP "User Temp ($env:USERNAME)"
    $total += Remove-SafePath "C:\Windows\Temp" "Windows Temp"

    # Windows Update cache
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    $total += Remove-SafePath "C:\Windows\SoftwareDistribution\Download" "Windows Update Downloads"
    Start-Service -Name wuauserv -ErrorAction SilentlyContinue

    # CBS logs
    $total += Remove-SafePath "C:\Windows\Logs\CBS" "CBS Logs"

    # Old prefetch
    $total += Remove-SafePath "C:\Windows\Prefetch" "Prefetch"

    # IIS logs (if present)
    $total += Remove-SafePath "C:\inetpub\logs\LogFiles" "IIS Logs"

    # Dump files
    Get-ChildItem "C:\" -Recurse -Include "*.dmp" -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $size = $_.Length
        if ($whatIf) { Write-Host "  [WHATIF] Dump file: $($_.FullName)" -ForegroundColor Yellow }
        else { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; Write-Host "  [CLEANED] Dump: $($_.Name)" -ForegroundColor Green }
        $total += $size
    }

    # Browser caches
    if ($includeBrowser) {
        $users = Get-ChildItem "C:\Users" -Directory
        foreach ($u in $users) {
            $cachePaths = @{
                "Chrome Cache"    = "$($u.FullName)\AppData\Local\Google\Chrome\User Data\Default\Cache"
                "Edge Cache"      = "$($u.FullName)\AppData\Local\Microsoft\Edge\User Data\Default\Cache"
                "Firefox Cache"   = "$($u.FullName)\AppData\Local\Mozilla\Firefox\Profiles"
            }
            foreach ($key in $cachePaths.Keys) {
                $total += Remove-SafePath $cachePaths[$key] "$key ($($u.Name))"
            }
        }
    }

    # Recycle Bin
    if (-not $whatIf) {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Host "  [CLEANED] Recycle Bin" -ForegroundColor Green
    }

    Write-Host "`nTotal space $(if($whatIf){'recoverable'}else{'recovered'}): $([math]::Round($total/1GB,2)) GB" -ForegroundColor Cyan
}

if ($ComputerName -eq $env:COMPUTERNAME) {
    & $script $IncludeBrowser.IsPresent $WhatIf.IsPresent
} else {
    Invoke-Command -ComputerName $ComputerName -ScriptBlock $script -ArgumentList $IncludeBrowser.IsPresent, $WhatIf.IsPresent
}
