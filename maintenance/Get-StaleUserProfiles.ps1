#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Find and optionally remove stale user profiles on workstations.
    Essential for reclaiming disk space on shared or multi-user machines.
.PARAMETER ComputerName
.PARAMETER DaysOld        Profiles not used in this many days (default: 90)
.PARAMETER Remove         Actually delete the stale profiles
.PARAMETER ExcludeUsers   Usernames to always skip (e.g. service accounts)
.EXAMPLE
    .\Get-StaleUserProfiles.ps1 -ComputerName PC01,PC02 -DaysOld 90
    .\Get-StaleUserProfiles.ps1 -ComputerName PC01 -DaysOld 60 -Remove -ExcludeUsers "svc-backup","admin"
#>
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [int]$DaysOld = 90,
    [switch]$Remove,
    [string[]]$ExcludeUsers = @("Administrator", "Default", "Public", "All Users")
)

$cutoff = (Get-Date).AddDays(-$DaysOld)
$results = @()

foreach ($computer in $ComputerName) {
    Write-Host "`nChecking profiles on $computer..." -ForegroundColor Cyan
    try {
        $profiles = Get-CimInstance -ComputerName $computer Win32_UserProfile |
            Where-Object {
                -not $_.Special -and
                $_.LocalPath -notlike "*$($ExcludeUsers -join '*' -replace ',','*')*" -and
                ($_.LastUseTime -lt $cutoff -or $_.LastUseTime -eq $null)
            }

        foreach ($p in $profiles) {
            $username   = Split-Path $p.LocalPath -Leaf
            $lastUse    = if ($p.LastUseTime) { $p.LastUseTime.ToString('yyyy-MM-dd') } else { "Never" }
            $sizeGB     = try {
                $size = (Invoke-Command -ComputerName $computer -ArgumentList $p.LocalPath -ScriptBlock {
                    param($path)
                    (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                } -ErrorAction SilentlyContinue)
                [math]::Round($size / 1GB, 2)
            } catch { "?" }

            $color = if ($Remove) { "Red" } else { "Yellow" }
            Write-Host ("  {0,-20} Last used: {1,-12} Size: {2} GB  Path: {3}" -f $username, $lastUse, $sizeGB, $p.LocalPath) -ForegroundColor $color

            if ($Remove -and $username -notin $ExcludeUsers) {
                try {
                    $p | Remove-CimInstance
                    Write-Host "    [REMOVED] $($p.LocalPath)" -ForegroundColor Red
                } catch {
                    Write-Host "    [ERROR] Could not remove $($p.LocalPath): $_" -ForegroundColor Red
                }
            }

            $results += [PSCustomObject]@{
                Computer  = $computer
                Username  = $username
                Path      = $p.LocalPath
                LastUsed  = $lastUse
                SizeGB    = $sizeGB
                Removed   = $Remove
            }
        }

        if ($profiles.Count -eq 0) {
            Write-Host "  No stale profiles found." -ForegroundColor Green
        }
    } catch {
        Write-Host "  [ERROR] $computer : $_" -ForegroundColor Red
    }
}

Write-Host "`nTotal stale profiles found: $($results.Count)" -ForegroundColor Yellow
