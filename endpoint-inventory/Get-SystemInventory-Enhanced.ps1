#Requires -Modules Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility
<#
.SYNOPSIS
    Enhanced hardware/software inventory snapshot with parallel execution, structured logging, and config support.
.DESCRIPTION
    Modernized version of Get-SystemInventory with parallel processing, configuration management,
    structured logging, and improved error handling. Compatible with PowerShell 7+.
.PARAMETER ComputerName
    One or more hostnames (default: localhost)
.PARAMETER ConfigPath
    Path to MSP configuration file (default: .\config\MSPConfig.psd1)
.PARAMETER ExportCSV
    Path to export results
.PARAMETER ExportJSON
    Path to export results as JSON
.PARAMETER Parallel
    Enable parallel execution for multiple computers
.PARAMETER ThrottleLimit
    Maximum number of parallel operations (default: 10)
.EXAMPLE
    .\Get-SystemInventory-Enhanced.ps1 -ComputerName PC01,PC02,PC03 -Parallel -ExportCSV "C:\Reports\inventory.csv"
.EXAMPLE
    .\Get-SystemInventory-Enhanced.ps1 -ConfigPath "C:\Scripts\msp-admin-scripts\config\MSPConfig.psd1" -ExportJSON "C:\Reports\inventory.json"
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$ConfigPath = ".\config\MSPConfig.psd1",
    [string]$ExportCSV,
    [string]$ExportJSON,
    [switch]$Parallel,
    [int]$ThrottleLimit = 10
)

# Import logging framework
$LoggerScriptPath = Join-Path $PSScriptRoot "..\framework\MSPLogger.ps1"
. $LoggerScriptPath

$logger = Get-MSPLogger -LogName "SystemInventory" -Level "Info"

$logger.StartOperation("System Inventory Scan")

try {
    # Load configuration
    if (Test-Path $ConfigPath) {
        $config = Import-PowerShellDataFile -Path $ConfigPath
        $logger.Info("Configuration loaded from $ConfigPath")
    } else {
        $logger.Warning("Configuration file not found at $ConfigPath, using defaults")
        $config = @{}
    }

    $results = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

    $inventoryBlock = {
        param($computer, $config)

        try {
            $data = Invoke-Command -ComputerName $computer -ScriptBlock {
                $os   = Get-CimInstance Win32_OperatingSystem
                $cs   = Get-CimInstance Win32_ComputerSystem
                $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
                $bios = Get-CimInstance Win32_BIOS
                $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
                         ForEach-Object { 
                             [PSCustomObject]@{
                                 Drive = $_.DeviceID
                                 SizeGB = [math]::Round($_.Size/1GB,1)
                                 FreeGB = [math]::Round($_.FreeSpace/1GB,1)
                                 UsedPercent = [math]::Round((($_.Size - $_.FreeSpace) / $_.Size) * 100, 1)
                             }
                         }
                $nics  = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" |
                         ForEach-Object { 
                             [PSCustomObject]@{
                                 Description = $_.Description
                                 IPAddress = ($_.IPAddress -join ', ')
                                 MACAddress = $_.MACAddress
                                 DNS = ($_.DNSServerSearchOrder -join ', ')
                             }
                         }
                $hotfixes = Get-CimInstance Win32_QuickFixEngineering | 
                            Select-Object -First 10 | 
                            ForEach-Object { $_.HotFixID }

                [PSCustomObject]@{
                    Hostname        = $env:COMPUTERNAME
                    Manufacturer    = $cs.Manufacturer
                    Model           = $cs.Model
                    SerialNumber    = $bios.SerialNumber
                    CPU             = $cpu.Name
                    CPUCores        = $cpu.NumberOfCores
                    CPULogical      = $cpu.NumberOfLogicalProcessors
                    RAM_GB          = [math]::Round($cs.TotalPhysicalMemory/1GB, 1)
                    OS              = $os.Caption
                    OSBuild         = $os.BuildNumber
                    OSVersion       = $os.Version
                    LastBoot        = $os.LastBootUpTime
                    UptimeDays      = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
                    Disks           = $disks
                    NICs            = $nics
                    Domain          = $cs.Domain
                    Workgroup       = $cs.Workgroup
                    CurrentUser     = $cs.UserName
                    BIOSVersion     = $bios.SMBIOSBIOSVersion
                    BIOSReleaseDate = $bios.ReleaseDate
                    RecentHotfixes  = $hotfixes -join ", "
                    ScanTime        = Get-Date
                }
            } -ErrorAction Stop

            return @{
                Success = $true
                Computer = $computer
                Data = $data
            }
        } catch {
            return @{
                Success = $false
                Computer = $computer
                Error = $_.Exception.Message
            }
        }
    }

    $logger.Info("Starting inventory of $($ComputerName.Count) computer(s)")

    if ($Parallel -and $ComputerName.Count -gt 1) {
        $logger.Info("Using parallel execution with throttle limit: $ThrottleLimit")
        $ComputerName | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $result = & $using:inventoryBlock -computer $_ -config $using:config
            $using:results.Add($result)
        }
    } else {
        foreach ($computer in $ComputerName) {
            $logger.Info("Inventorying $computer...")
            $result = & $inventoryBlock -computer $computer -config $config
            
            if ($result.Success) {
                $results.Add([PSCustomObject]$result.Data)
                $logger.Info("  [OK] $($result.Data.Hostname) - $($result.Data.OS)")
            } else {
                $logger.Error("  [ERROR] $computer - $($result.Error)")
                $results.Add([PSCustomObject]@{
                    Hostname = $computer
                    Error = $result.Error
                    ScanTime = Get-Date
                })
            }
        }
    }

    # Process results
    $successful = $results | Where-Object { $_.Error -eq $null }
    $failed = $results | Where-Object { $_.Error -ne $null }

    $logger.Info("Inventory complete: $($successful.Count) successful, $($failed.Count) failed")

    # Check for alerts
    $thresholds = $config.Thresholds
    if ($thresholds) {
        $alerts = @()
        
        foreach ($item in $successful) {
            foreach ($disk in $item.Disks) {
                if ($disk.UsedPercent -gt $thresholds.DiskSpacePercent) {
                    $alerts += "ALERT: $($item.Hostname) disk $($disk.Drive) at $($disk.UsedPercent)% capacity"
                }
            }
            
            if ($item.UptimeDays -gt $thresholds.UptimeDays) {
                $alerts += "ALERT: $($item.Hostname) uptime $($item.UptimeDays) days exceeds threshold"
            }
        }
        
        if ($alerts.Count -gt 0) {
            $logger.Warning("Found $($alerts.Count) alert condition(s):")
            foreach ($alert in $alerts) {
                $logger.Warning("  $alert")
            }
        }
    }

    # Export results
    if ($ExportCSV) {
        $successful | Export-Csv $ExportCSV -NoTypeInformation
        $logger.Info("Exported CSV to $ExportCSV")
    }

    if ($ExportJSON) {
        $successful | ConvertTo-Json -Depth 10 | Out-File $ExportJSON
        $logger.Info("Exported JSON to $ExportJSON")
    }

    # Display summary
    Write-Host "`n=== Inventory Summary ===" -ForegroundColor Cyan
    Write-Host "Total computers: $($ComputerName.Count)" -ForegroundColor White
    Write-Host "Successful: $($successful.Count)" -ForegroundColor Green
    Write-Host "Failed: $($failed.Count)" -ForegroundColor $(if ($failed.Count -gt 0) { "Red" } else { "Green" })

    if ($failed.Count -gt 0) {
        Write-Host "`nFailed computers:" -ForegroundColor Red
        $failed | ForEach-Object { Write-Host "  $($_.Hostname): $($_.Error)" -ForegroundColor Red }
    }

    return $successful

} catch {
    $logger.Error("Fatal error in inventory operation", $_)
    throw
} finally {
    $logger.EndOperation("System Inventory Scan")
}