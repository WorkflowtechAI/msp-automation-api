# Disk Space Module
# API-ready disk space monitoring, software inventory, and Windows Update status

Import-Module (Join-Path $PSScriptRoot "..\MSPAutomation.Core.psm1") -Force

<#
.SYNOPSIS
    Get disk space information and alert on threshold violations.
.PARAMETER ComputerName
    Array of computer names to check
.PARAMETER AlertThresholdPercent
    Disk usage percentage threshold for alerts (default: 90)
.PARAMETER IncludeRemovable
    Include removable drives (DriveType=2) in addition to fixed drives
.EXAMPLE
    Get-DiskSpaceAlert -ComputerName @("PC01", "PC02") -AlertThresholdPercent 85
.OUTPUTS
    ApiResponse object with disk space data and alerts
#>
function Get-DiskSpaceAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [ValidateRange(1, 100)]
        [int]$AlertThresholdPercent = 90,

        [switch]$IncludeRemovable
    )

    return Invoke-AutomationOperation -OperationName "Get-DiskSpaceAlert" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName          = $p.ComputerName
        $AlertThresholdPercent = $p.AlertThresholdPercent
        $IncludeRemovable      = $p.IncludeRemovable

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $alerts  = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($computer in $ComputerName) {
            try {
                $diskData = Invoke-Command -ComputerName $computer -ErrorAction Stop -ScriptBlock {
                    # DriveType 3 = Fixed, 2 = Removable
                    $filter = if ($using:IncludeRemovable) {
                        "DriveType=3 OR DriveType=2"
                    } else {
                        "DriveType=3"
                    }

                    Get-CimInstance Win32_LogicalDisk -Filter $filter | ForEach-Object {
                        $usedPercent = if ($_.Size -gt 0) {
                            [math]::Round((($_.Size - $_.FreeSpace) / $_.Size) * 100, 2)
                        } else { 0 }

                        @{
                            Drive       = $_.DeviceID
                            DriveType   = $_.DriveType
                            VolumeName  = $_.VolumeName
                            SizeGB      = [math]::Round($_.Size / 1GB, 2)
                            FreeGB      = [math]::Round($_.FreeSpace / 1GB, 2)
                            UsedPercent = $usedPercent
                            IsAlert     = $usedPercent -ge $using:AlertThresholdPercent
                        }
                    }
                }

                foreach ($disk in $diskData) {
                    $diskInfo = [PSCustomObject]@{
                        Computer    = $computer
                        Drive       = $disk.Drive
                        VolumeName  = $disk.VolumeName
                        SizeGB      = $disk.SizeGB
                        FreeGB      = $disk.FreeGB
                        UsedPercent = $disk.UsedPercent
                        IsAlert     = $disk.IsAlert
                        CheckTime   = (Get-Date).ToString("o")
                    }
                    $results.Add($diskInfo)

                    if ($disk.IsAlert) {
                        $alerts.Add([PSCustomObject]@{
                            Computer    = $computer
                            Drive       = $disk.Drive
                            UsedPercent = $disk.UsedPercent
                            Threshold   = $AlertThresholdPercent
                            FreeGB      = $disk.FreeGB
                            Severity    = if ($disk.UsedPercent -ge 98) { "Critical" }
                                          elseif ($disk.UsedPercent -ge 95) { "High" }
                                          else { "Medium" }
                        })
                    }
                }

            } catch {
                $results.Add([PSCustomObject]@{
                    Computer  = $computer
                    Error     = $_.Exception.Message
                    CheckTime = (Get-Date).ToString("o")
                })
            }
        }

        return New-SuccessResponse -Message "Disk space check completed" -Data @{
            TotalDrives = $results.Count
            AlertCount  = $alerts.Count
            Threshold   = $AlertThresholdPercent
            DiskData    = $results
            Alerts      = $alerts
        }
    } -Parameters @{
        ComputerName          = $ComputerName
        AlertThresholdPercent = $AlertThresholdPercent
        IncludeRemovable      = [bool]$IncludeRemovable
    } -EnableObservability
}

<#
.SYNOPSIS
    Get installed software inventory for one or more computers via the registry.
    Uses registry keys instead of Win32_Product to avoid triggering MSI reconfiguration.
.PARAMETER ComputerName
    Array of computer names to query
.PARAMETER IncludeUpdates
    Include Windows hotfix/update history
.PARAMETER MaxResults
    Maximum number of software items to return per computer (default: 200)
.EXAMPLE
    Get-InstalledSoftware -ComputerName @("PC01", "PC02") -MaxResults 50
.OUTPUTS
    ApiResponse object with software inventory
#>
function Get-InstalledSoftware {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [switch]$IncludeUpdates,

        [ValidateRange(1, 2000)]
        [int]$MaxResults = 200
    )

    return Invoke-AutomationOperation -OperationName "Get-InstalledSoftware" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName  = $p.ComputerName
        $IncludeUpdates = $p.IncludeUpdates
        $MaxResults    = $p.MaxResults

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($computer in $ComputerName) {
            try {
                $software = Invoke-Command -ComputerName $computer -ErrorAction Stop -ScriptBlock {
                    # Registry-based enumeration - does NOT trigger MSI reconfiguration
                    $regPaths = @(
                        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
                    )

                    $softwareList = foreach ($path in $regPaths) {
                        if (Test-Path $path) {
                            Get-ItemProperty $path -ErrorAction SilentlyContinue |
                                Where-Object { $_.DisplayName } |
                                ForEach-Object {
                                    @{
                                        Name        = $_.DisplayName
                                        Version     = $_.DisplayVersion
                                        Vendor      = $_.Publisher
                                        InstallDate = $_.InstallDate
                                        InstallSource = $_.InstallSource
                                        PackageCode = $_.PSChildName
                                        IsUpdate    = $false
                                    }
                                }
                        }
                    }

                    # Deduplicate by name+version; take first $MaxResults
                    $seen = @{}
                    $deduped = foreach ($app in $softwareList) {
                        $key = "$($app.Name)|$($app.Version)"
                        if (-not $seen[$key]) {
                            $seen[$key] = $true
                            $app
                        }
                    }
                    $finalList = @($deduped | Select-Object -First $using:MaxResults)

                    if ($using:IncludeUpdates) {
                        $updates = Get-CimInstance Win32_QuickFixEngineering |
                            Select-Object -First 50 |
                            ForEach-Object {
                                @{
                                    Name          = $_.HotFixID
                                    Version       = $_.FixComments
                                    Vendor        = "Microsoft"
                                    InstallDate   = if ($_.InstalledOn) { $_.InstalledOn.ToString("o") } else { $null }
                                    InstallSource = "Windows Update"
                                    PackageCode   = $_.HotFixID
                                    IsUpdate      = $true
                                }
                            }
                        $finalList += $updates
                    }

                    return $finalList
                }

                foreach ($app in $software) {
                    $results.Add([PSCustomObject]@{
                        Computer      = $computer
                        Name          = $app.Name
                        Version       = $app.Version
                        Vendor        = $app.Vendor
                        InstallDate   = $app.InstallDate
                        InstallSource = $app.InstallSource
                        PackageCode   = $app.PackageCode
                        IsUpdate      = [bool]$app.IsUpdate
                        ScanTime      = (Get-Date).ToString("o")
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

        return New-SuccessResponse -Message "Software inventory completed" -Data @{
            TotalComputers = $ComputerName.Count
            TotalSoftware  = $results.Count
            SoftwareData   = $results
        }
    } -Parameters @{
        ComputerName   = $ComputerName
        IncludeUpdates = [bool]$IncludeUpdates
        MaxResults     = $MaxResults
    } -EnableObservability
}

<#
.SYNOPSIS
    Get Windows Update status for one or more computers.
.PARAMETER ComputerName
    Array of computer names to check
.PARAMETER IncludePendingUpdates
    Include detailed pending update information via Windows Update Agent COM API
.EXAMPLE
    Get-WindowsUpdateStatus -ComputerName @("PC01", "PC02") -IncludePendingUpdates
.OUTPUTS
    ApiResponse object with Windows Update status
#>
function Get-WindowsUpdateStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [switch]$IncludePendingUpdates
    )

    return Invoke-AutomationOperation -OperationName "Get-WindowsUpdateStatus" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName        = $p.ComputerName
        $IncludePendingUpdates = $p.IncludePendingUpdates

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($computer in $ComputerName) {
            try {
                $updateStatus = Invoke-Command -ComputerName $computer -ErrorAction Stop -ScriptBlock {
                    $wuService  = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
                    $lastUpdate = Get-CimInstance Win32_QuickFixEngineering |
                        Sort-Object InstalledOn -Descending |
                        Select-Object -First 1

                    $pendingUpdates = @()
                    $pendingError   = $null
                    if ($using:IncludePendingUpdates) {
                        try {
                            $session  = New-Object -ComObject Microsoft.Update.Session
                            $searcher = $session.CreateUpdateSearcher()
                            $search   = $searcher.Search("IsInstalled=0")
                            $pendingUpdates = @($search.Updates | Select-Object -First 20 | ForEach-Object {
                                @{
                                    Title        = $_.Title
                                    KB           = if ($_.KBArticleIDs.Count -gt 0) { $_.KBArticleIDs[0] } else { "N/A" }
                                    IsMandatory  = $_.IsMandatory
                                    IsDownloaded = $_.IsDownloaded
                                }
                            })
                        } catch {
                            $pendingError = $_.Exception.Message
                        }
                    }

                    @{
                        ServiceRunning     = ($wuService -and $wuService.Status -eq "Running")
                        ServiceStartType   = if ($wuService) { $wuService.StartType.ToString() } else { "Unknown" }
                        LastUpdateDate     = if ($lastUpdate.InstalledOn) { $lastUpdate.InstalledOn.ToString("o") } else { $null }
                        LastUpdateKB       = $lastUpdate.HotFixID
                        PendingUpdates     = $pendingUpdates
                        PendingUpdateCount = $pendingUpdates.Count
                        PendingUpdateError = $pendingError
                    }
                }

                $results.Add([PSCustomObject]@{
                    Computer           = $computer
                    ServiceRunning     = $updateStatus.ServiceRunning
                    ServiceStartType   = $updateStatus.ServiceStartType
                    LastUpdateDate     = $updateStatus.LastUpdateDate
                    LastUpdateKB       = $updateStatus.LastUpdateKB
                    PendingUpdateCount = $updateStatus.PendingUpdateCount
                    PendingUpdates     = $updateStatus.PendingUpdates
                    PendingUpdateError = $updateStatus.PendingUpdateError
                    CheckTime          = (Get-Date).ToString("o")
                })

            } catch {
                $results.Add([PSCustomObject]@{
                    Computer  = $computer
                    Error     = $_.Exception.Message
                    CheckTime = (Get-Date).ToString("o")
                })
            }
        }

        return New-SuccessResponse -Message "Windows Update status check completed" -Data @{
            TotalComputers = $ComputerName.Count
            UpdateData     = $results
        }
    } -Parameters @{
        ComputerName         = $ComputerName
        IncludePendingUpdates = [bool]$IncludePendingUpdates
    } -EnableObservability
}

Export-ModuleMember -Function @(
    'Get-DiskSpaceAlert',
    'Get-InstalledSoftware',
    'Get-WindowsUpdateStatus'
)
