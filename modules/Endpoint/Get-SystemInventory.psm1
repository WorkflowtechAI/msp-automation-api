# System Inventory Module
# API-ready endpoint for system inventory operations

# No -Force here on purpose. -Force removes an already-loaded MSPAutomation.Core
# and re-imports it into THIS module's scope, so a caller who imported Core first
# silently loses New-SuccessResponse and friends. That is the exact sequence the
# README's quick start documents. Plain Import-Module is a no-op when the module
# is already loaded and loads it when it is not, which is what we want.
Import-Module (Join-Path $PSScriptRoot "..\MSPAutomation.Core.psm1")

<#
.SYNOPSIS
    Get system inventory for one or more computers in JSON format for API consumption.
.PARAMETER ComputerName
    Array of computer names to inventory
.PARAMETER IncludeDiskSpace
    Include detailed disk space information
.PARAMETER IncludeNetworkInfo
    Include detailed network configuration
.PARAMETER IncludeInstalledSoftware
    Include installed software inventory (reads registry, not Win32_Product)
.PARAMETER TimeoutSeconds
    Operation timeout in seconds per computer
.PARAMETER EnableIdempotency
    Enable idempotency checking
.PARAMETER StateStorePath
    Path for idempotency state storage
.EXAMPLE
    Get-SystemInventory -ComputerName @("PC01", "PC02") -IncludeDiskSpace -EnableIdempotency
.OUTPUTS
    ApiResponse object with JSON serialization support
#>
function Get-SystemInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [switch]$IncludeDiskSpace,
        [switch]$IncludeNetworkInfo,
        [switch]$IncludeInstalledSoftware,

        [ValidateRange(30, 3600)]
        [int]$TimeoutSeconds = 300,

        [switch]$EnableIdempotency,

        [string]$StateStorePath = "C:\AutomationState"
    )

    return Invoke-AutomationOperation -OperationName "Get-SystemInventory" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName            = $p.ComputerName
        $IncludeDiskSpace        = $p.IncludeDiskSpace
        $IncludeNetworkInfo      = $p.IncludeNetworkInfo
        $IncludeInstalledSoftware = $p.IncludeInstalledSoftware
        $TimeoutSeconds          = $p.TimeoutSeconds

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $errors  = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($computer in $ComputerName) {
            try {
                $job = Invoke-Command -ComputerName $computer -AsJob -ErrorAction Stop -ScriptBlock {
                    $os   = Get-CimInstance Win32_OperatingSystem
                    $cs   = Get-CimInstance Win32_ComputerSystem
                    $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
                    $bios = Get-CimInstance Win32_BIOS

                    $diskInfo = @()
                    if ($using:IncludeDiskSpace) {
                        $diskInfo = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
                            @{
                                Drive       = $_.DeviceID
                                SizeGB      = [math]::Round($_.Size / 1GB, 2)
                                FreeGB      = [math]::Round($_.FreeSpace / 1GB, 2)
                                UsedPercent = if ($_.Size -gt 0) {
                                    [math]::Round((($_.Size - $_.FreeSpace) / $_.Size) * 100, 2)
                                } else { 0 }
                            }
                        }
                    }

                    $networkInfo = @()
                    if ($using:IncludeNetworkInfo) {
                        $networkInfo = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" | ForEach-Object {
                            @{
                                Description = $_.Description
                                IPAddress   = $_.IPAddress -join ", "
                                MACAddress  = $_.MACAddress
                                DNS         = $_.DNSServerSearchOrder -join ", "
                                DHCPEnabled = $_.DHCPEnabled
                            }
                        }
                    }

                    # Use registry instead of Win32_Product to avoid MSI reconfiguration trigger
                    $softwareInfo = @()
                    if ($using:IncludeInstalledSoftware) {
                        $regPaths = @(
                            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
                        )
                        $softwareInfo = foreach ($path in $regPaths) {
                            if (Test-Path $path) {
                                Get-ItemProperty $path -ErrorAction SilentlyContinue |
                                    Where-Object { $_.DisplayName } |
                                    Select-Object -First 50 |
                                    ForEach-Object {
                                        @{
                                            Name        = $_.DisplayName
                                            Version     = $_.DisplayVersion
                                            Vendor      = $_.Publisher
                                            InstallDate = $_.InstallDate
                                        }
                                    }
                            }
                        }
                    }

                    @{
                        Hostname     = $env:COMPUTERNAME
                        Manufacturer = $cs.Manufacturer
                        Model        = $cs.Model
                        SerialNumber = $bios.SerialNumber
                        CPU          = $cpu.Name
                        CPUCores     = $cpu.NumberOfCores
                        CPULogical   = $cpu.NumberOfLogicalProcessors
                        RAM_GB       = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
                        OS           = $os.Caption
                        OSBuild      = $os.BuildNumber
                        OSVersion    = $os.Version
                        LastBoot     = $os.LastBootUpTime.ToString("o")
                        UptimeDays   = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
                        Domain       = $cs.Domain
                        CurrentUser  = $cs.UserName
                        BIOSVersion  = $bios.SMBIOSBIOSVersion
                        Disks        = @($diskInfo)
                        Network      = @($networkInfo)
                        Software     = @($softwareInfo)
                        ScanTime     = (Get-Date).ToString("o")
                    }
                }

                $null = $job | Wait-Job -Timeout $TimeoutSeconds
                if ($job.State -eq 'Running') {
                    Stop-Job $job
                    throw "Remote command timed out after $TimeoutSeconds seconds"
                }

                $result = Receive-Job -Job $job -ErrorAction Stop
                Remove-Job -Job $job -Force

                $results.Add([PSCustomObject]$result)

            } catch {
                # Ensure job cleanup even on error
                if ($job -and $job.State -ne 'Completed') {
                    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                }
                $errors.Add([PSCustomObject]@{
                    Computer  = $computer
                    Error     = $_.Exception.Message
                    ErrorType = $_.Exception.GetType().Name
                })
            }
        }

        $response = @{
            TotalComputers = $ComputerName.Count
            Successful     = $results.Count
            Failed         = $errors.Count
            Inventory      = $results
            Errors         = $errors
        }

        if ($errors.Count -gt 0 -and $results.Count -eq 0) {
            return New-ErrorResponse -Message "Inventory failed for all computers" -ErrorCode "PARTIAL_SUCCESS" -Data $response
        } elseif ($errors.Count -gt 0) {
            return New-ErrorResponse -Message "Inventory completed with errors" -ErrorCode "PARTIAL_SUCCESS" -Data $response
        } else {
            return New-SuccessResponse -Message "Inventory completed successfully" -Data $response
        }

    } -Parameters @{
        ComputerName             = $ComputerName
        IncludeDiskSpace         = [bool]$IncludeDiskSpace
        IncludeNetworkInfo       = [bool]$IncludeNetworkInfo
        IncludeInstalledSoftware = [bool]$IncludeInstalledSoftware
        TimeoutSeconds           = $TimeoutSeconds
    } -EnableIdempotency:$EnableIdempotency -StateStorePath $StateStorePath -EnableObservability
}

<#
.SYNOPSIS
    Get quick system health status for monitoring dashboards.
.PARAMETER ComputerName
    Computer name to check
.EXAMPLE
    Get-SystemHealth -ComputerName "PC01"
.OUTPUTS
    ApiResponse object with health status
#>
function Get-SystemHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName
    )

    return Invoke-AutomationOperation -OperationName "Get-SystemHealth" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName = $p.ComputerName

        try {
            $health = Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
                $os     = Get-CimInstance Win32_OperatingSystem
                $cs     = Get-CimInstance Win32_ComputerSystem
                $cpu    = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
                $memory = Get-CimInstance Win32_OperatingSystem
                $disk   = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"

                $cpuUsage    = if ($cpu.Average)  { [math]::Round($cpu.Average, 2) } else { 0 }
                $memoryUsage = [math]::Round(
                    (($memory.TotalVisibleMemorySize - $memory.FreePhysicalMemory) / $memory.TotalVisibleMemorySize) * 100, 2)
                $diskUsage   = if ($disk -and $disk.Size -gt 0) {
                    [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 2)
                } else { 0 }

                $criticalServices = @("wuauserv", "WinDefend", "EventLog", "RpcSs", "Dnscache")
                $services         = Get-Service -Name $criticalServices -ErrorAction SilentlyContinue
                $stoppedServices  = @($services | Where-Object { $_.Status -ne "Running" })

                $overallStatus = if ($stoppedServices.Count -eq 0 -and
                                     $cpuUsage    -lt 90 -and
                                     $memoryUsage -lt 90 -and
                                     $diskUsage   -lt 90) { "Healthy" } else { "Warning" }

                @{
                    ComputerName     = $env:COMPUTERNAME
                    Online           = $true
                    CPUPercent       = $cpuUsage
                    MemoryPercent    = $memoryUsage
                    DiskPercent      = $diskUsage
                    UptimeDays       = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
                    StoppedServices  = @($stoppedServices | ForEach-Object { $_.Name })
                    OverallStatus    = $overallStatus
                    CheckTime        = (Get-Date).ToString("o")
                }
            }

            return New-SuccessResponse -Message "Health check completed" -Data $health

        } catch {
            return New-ErrorResponse -Message "Computer offline or inaccessible: $($_.Exception.Message)" `
                -ErrorCode "CONNECTION_ERROR" -Data @{
                    ComputerName = $ComputerName
                    Online       = $false
                    CheckTime    = (Get-Date).ToString("o")
                }
        }
    } -Parameters @{ ComputerName = $ComputerName } -EnableObservability
}

Export-ModuleMember -Function @(
    'Get-SystemInventory',
    'Get-SystemHealth'
)
