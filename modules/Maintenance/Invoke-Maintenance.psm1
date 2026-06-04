# Maintenance Module
# API-ready maintenance operations

Import-Module (Join-Path $PSScriptRoot "..\MSPAutomation.Core.psm1") -Force

<#
.SYNOPSIS
    Get service health report for critical services.
.PARAMETER ComputerName
    Array of computer names to check
.PARAMETER CriticalServices
    Array of service names that must be running
.PARAMETER RestartStopped
    Attempt to restart stopped critical services
.EXAMPLE
    Get-ServiceHealthReport -ComputerName @("SRV01", "SRV02") -RestartStopped
.OUTPUTS
    ApiResponse object with service health data
#>
function Get-ServiceHealthReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [string[]]$CriticalServices = @(
            "wuauserv", "WinDefend", "EventLog", "RpcSs", "Dnscache",
            "Dhcp", "LanmanWorkstation", "W32Time", "MpsSvc", "BITS", "CryptSvc"
        ),

        [switch]$RestartStopped
    )

    return Invoke-AutomationOperation -OperationName "Get-ServiceHealthReport" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName     = $p.ComputerName
        $CriticalServices = $p.CriticalServices
        $RestartStopped   = $p.RestartStopped

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($computer in $ComputerName) {
            try {
                $services = Invoke-Command -ComputerName $computer -ErrorAction Stop -ScriptBlock {
                    $serviceResults = @()
                    foreach ($serviceName in $using:CriticalServices) {
                        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                        if ($svc) {
                            $currentStatus = $svc.Status.ToString()
                            $restartResult = $null

                            if ($using:RestartStopped -and $svc.Status -ne "Running") {
                                try {
                                    $svc.Start()
                                    $svc.WaitForStatus("Running", [TimeSpan]::FromSeconds(15))
                                    $svc.Refresh()
                                    $currentStatus = $svc.Status.ToString()
                                    $restartResult = if ($svc.Status -eq "Running") { "Success" } else { "Started but not Running" }
                                } catch {
                                    $restartResult = "Failed: $($_.Exception.Message)"
                                }
                            }

                            $serviceResults += @{
                                ServiceName   = $serviceName
                                DisplayName   = $svc.DisplayName
                                Status        = $currentStatus
                                StartType     = $svc.StartType.ToString()
                                RestartResult = $restartResult
                            }
                        } else {
                            $serviceResults += @{
                                ServiceName   = $serviceName
                                DisplayName   = "Not Found"
                                Status        = "NotFound"
                                StartType     = "Unknown"
                                RestartResult = $null
                            }
                        }
                    }
                    return $serviceResults
                }

                foreach ($service in $services) {
                    $results.Add([PSCustomObject]@{
                        Computer      = $computer
                        ServiceName   = $service.ServiceName
                        DisplayName   = $service.DisplayName
                        Status        = $service.Status
                        StartType     = $service.StartType
                        IsRunning     = ($service.Status -eq "Running")
                        IsCritical    = $true
                        RestartResult = $service.RestartResult
                        CheckTime     = (Get-Date).ToString("o")
                    })
                }

            } catch {
                $results.Add([PSCustomObject]@{
                    Computer  = $computer
                    Error     = $_.Exception.Message
                    CheckTime = (Get-Date).ToString("o")
                })
            }
        }

        $runningCount = ($results | Where-Object { $_.IsRunning -eq $true }).Count
        $stoppedCount = ($results | Where-Object { $_.IsRunning -eq $false -and -not $_.Error }).Count

        return New-SuccessResponse -Message "Service health check completed" -Data @{
            TotalComputers   = $ComputerName.Count
            TotalServices    = $results.Count
            RunningServices  = $runningCount
            StoppedServices  = $stoppedCount
            ServiceData      = $results
        }
    } -Parameters @{
        ComputerName     = $ComputerName
        CriticalServices = $CriticalServices
        RestartStopped   = [bool]$RestartStopped
    } -EnableObservability
}

<#
.SYNOPSIS
    Get stale user profiles for cleanup review.
.PARAMETER ComputerName
    Array of computer names to check
.PARAMETER DaysInactive
    Number of days of inactivity to consider stale (default: 90)
.EXAMPLE
    Get-StaleUserProfiles -ComputerName @("PC01", "PC02") -DaysInactive 120
.OUTPUTS
    ApiResponse object with stale profile data
#>
function Get-StaleUserProfiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [ValidateRange(30, 730)]
        [int]$DaysInactive = 90
    )

    return Invoke-AutomationOperation -OperationName "Get-StaleUserProfiles" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName = $p.ComputerName
        $DaysInactive = $p.DaysInactive

        $results    = [System.Collections.Generic.List[PSCustomObject]]::new()
        $cutoffDate = (Get-Date).AddDays(-$DaysInactive)

        foreach ($computer in $ComputerName) {
            try {
                $profiles = Invoke-Command -ComputerName $computer -ErrorAction Stop -ScriptBlock {
                    Get-CimInstance Win32_UserProfile |
                        Where-Object {
                            $_.LastUseTime -and
                            $_.LastUseTime -lt $using:cutoffDate -and
                            $_.Special -eq $false -and
                            $_.Loaded -eq $false
                        } |
                        ForEach-Object {
                            $profilePath = $_.LocalPath
                            $sizeBytes   = 0
                            if ($profilePath -and (Test-Path $profilePath)) {
                                $measure = Get-ChildItem $profilePath -Recurse -ErrorAction SilentlyContinue |
                                    Measure-Object -Property Length -Sum
                                $sizeBytes = if ($measure.Sum) { $measure.Sum } else { 0 }
                            }

                            @{
                                LocalPath         = $profilePath
                                LastUseTime       = $_.LastUseTime.ToString("o")
                                SID               = $_.SID
                                RoamingConfigured = $_.RoamingConfigured
                                SizeBytes         = $sizeBytes
                            }
                        }
                }

                foreach ($profile in $profiles) {
                    $lastUse      = [DateTime]::Parse($profile.LastUseTime)
                    $daysInactive = [math]::Round(((Get-Date) - $lastUse).TotalDays, 0)

                    $results.Add([PSCustomObject]@{
                        Computer          = $computer
                        LocalPath         = $profile.LocalPath
                        LastUseTime       = $profile.LastUseTime
                        SID               = $profile.SID
                        RoamingConfigured = $profile.RoamingConfigured
                        SizeMB            = [math]::Round($profile.SizeBytes / 1MB, 2)
                        DaysInactive      = $daysInactive
                        ScanTime          = (Get-Date).ToString("o")
                    })
                }

            } catch {
                $results.Add([PSCustomObject]@{
                    Computer  = $computer
                    Error     = $_.Exception.Message
                    ScanTime  = (Get-Date).ToString("o")
                })
            }
        }

        return New-SuccessResponse -Message "Stale profile scan completed" -Data @{
            TotalComputers       = $ComputerName.Count
            DaysInactiveThreshold = $DaysInactive
            TotalStaleProfiles   = $results.Count
            TotalSizeMB          = [math]::Round(($results | Where-Object { $_.SizeMB } |
                                        Measure-Object -Property SizeMB -Sum).Sum, 2)
            ProfileData          = $results
        }
    } -Parameters @{
        ComputerName = $ComputerName
        DaysInactive = $DaysInactive
    } -EnableObservability
}

<#
.SYNOPSIS
    Invoke disk cleanup operations on one or more computers.
.PARAMETER ComputerName
    Array of computer names to clean
.PARAMETER CleanupTempFiles
    Clean user and system temporary files
.PARAMETER CleanupRecycleBin
    Empty recycle bin
.PARAMETER CleanupWindowsUpdateCache
    Clean Windows Update download cache (stops/restarts wuauserv)
.PARAMETER MinFreeSpaceGB
    Skip cleanup if C: free space is already at or above this threshold (0 = always clean)
.EXAMPLE
    Invoke-DiskCleanup -ComputerName @("PC01", "PC02") -CleanupTempFiles -CleanupRecycleBin -MinFreeSpaceGB 10
.OUTPUTS
    ApiResponse object with cleanup results
#>
function Invoke-DiskCleanup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [switch]$CleanupTempFiles,
        [switch]$CleanupRecycleBin,
        [switch]$CleanupWindowsUpdateCache,

        [ValidateRange(0, 1000)]
        [int]$MinFreeSpaceGB = 0
    )

    return Invoke-AutomationOperation -OperationName "Invoke-DiskCleanup" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName             = $p.ComputerName
        $CleanupTempFiles         = $p.CleanupTempFiles
        $CleanupRecycleBin        = $p.CleanupRecycleBin
        $CleanupWindowsUpdateCache = $p.CleanupWindowsUpdateCache
        $MinFreeSpaceGB           = $p.MinFreeSpaceGB

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($computer in $ComputerName) {
            try {
                $cleanupResult = Invoke-Command -ComputerName $computer -ErrorAction Stop -ScriptBlock {
                    $cleanupActions = @{}
                    $spaceFreed     = [long]0

                    # Check free space threshold first
                    if ($using:MinFreeSpaceGB -gt 0) {
                        $cDrive      = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
                        $freeSpaceGB = if ($cDrive) { [math]::Round($cDrive.FreeSpace / 1GB, 2) } else { 0 }
                        if ($freeSpaceGB -ge $using:MinFreeSpaceGB) {
                            return @{
                                Skipped    = $true
                                Reason     = "Sufficient free space ($freeSpaceGB GB >= threshold $($using:MinFreeSpaceGB) GB)"
                                SpaceFreedMB = 0
                                Actions    = @{}
                            }
                        }
                    }

                    # Helper: measure directory size safely
                    function Get-DirSize($path) {
                        if (-not (Test-Path $path)) { return [long]0 }
                        $m = Get-ChildItem $path -Recurse -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum
                        if ($m.Sum) { return [long]$m.Sum } else { return [long]0 }
                    }

                    # Cleanup temp files
                    if ($using:CleanupTempFiles) {
                        try {
                            $tempPaths = @("$env:TEMP", "C:\Windows\Temp", "C:\Windows\Prefetch")
                            foreach ($path in $tempPaths) {
                                $before      = Get-DirSize $path
                                Remove-Item "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
                                $after       = Get-DirSize $path
                                $spaceFreed += ($before - $after)
                            }
                            $cleanupActions["TempFiles"] = "Success"
                        } catch {
                            $cleanupActions["TempFiles"] = "Failed: $($_.Exception.Message)"
                        }
                    }

                    # Cleanup recycle bin
                    if ($using:CleanupRecycleBin) {
                        try {
                            Clear-RecycleBin -Force -ErrorAction Stop
                            $cleanupActions["RecycleBin"] = "Success"
                        } catch {
                            $cleanupActions["RecycleBin"] = "Failed: $($_.Exception.Message)"
                        }
                    }

                    # Cleanup Windows Update cache
                    if ($using:CleanupWindowsUpdateCache) {
                        $wuStarted = $false
                        try {
                            Stop-Service -Name wuauserv -Force -ErrorAction Stop
                            $updateCache = "C:\Windows\SoftwareDistribution\Download"
                            $before      = Get-DirSize $updateCache
                            Remove-Item "$updateCache\*" -Recurse -Force -ErrorAction SilentlyContinue
                            $after       = Get-DirSize $updateCache
                            $spaceFreed += ($before - $after)
                            Start-Service -Name wuauserv -ErrorAction Stop
                            $wuStarted = $true
                            $cleanupActions["WindowsUpdateCache"] = "Success"
                        } catch {
                            # Always attempt to restart wuauserv on failure
                            if (-not $wuStarted) {
                                Start-Service -Name wuauserv -ErrorAction SilentlyContinue
                            }
                            $cleanupActions["WindowsUpdateCache"] = "Failed: $($_.Exception.Message)"
                        }
                    }

                    @{
                        Skipped      = $false
                        Reason       = $null
                        Actions      = $cleanupActions
                        SpaceFreedMB = [math]::Round($spaceFreed / 1MB, 2)
                    }
                }

                $results.Add([PSCustomObject]@{
                    Computer     = $computer
                    Skipped      = $cleanupResult.Skipped
                    SkipReason   = $cleanupResult.Reason
                    Actions      = $cleanupResult.Actions
                    SpaceFreedMB = $cleanupResult.SpaceFreedMB
                    CleanupTime  = (Get-Date).ToString("o")
                })

            } catch {
                $results.Add([PSCustomObject]@{
                    Computer    = $computer
                    Error       = $_.Exception.Message
                    CleanupTime = (Get-Date).ToString("o")
                })
            }
        }

        $totalFreed = [math]::Round(
            ($results | Where-Object { $_.SpaceFreedMB } | Measure-Object -Property SpaceFreedMB -Sum).Sum, 2)

        return New-SuccessResponse -Message "Disk cleanup completed" -Data @{
            TotalComputers  = $ComputerName.Count
            TotalSpaceFreedMB = if ($totalFreed) { $totalFreed } else { 0 }
            CleanupData     = $results
        }
    } -Parameters @{
        ComputerName              = $ComputerName
        CleanupTempFiles          = [bool]$CleanupTempFiles
        CleanupRecycleBin         = [bool]$CleanupRecycleBin
        CleanupWindowsUpdateCache = [bool]$CleanupWindowsUpdateCache
        MinFreeSpaceGB            = $MinFreeSpaceGB
    } -EnableObservability
}

Export-ModuleMember -Function @(
    'Get-ServiceHealthReport',
    'Get-StaleUserProfiles',
    'Invoke-DiskCleanup'
)
