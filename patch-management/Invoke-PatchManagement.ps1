#Requires -Modules Microsoft.PowerShell.Management, PSWindowsUpdate
<#
.SYNOPSIS
    Comprehensive patch management for Windows systems with approval workflow and reporting.
.DESCRIPTION
    Advanced Windows Update management with scheduling, approval gates, reboot control,
    and compliance reporting. Requires PSWindowsUpdate module.
.PARAMETER ComputerName
    One or more target computers
.PARAMETER ScanOnly
    Only scan for available updates without installing
.PARAMETER InstallUpdates
    Install available updates
.PARAMETER RebootIfNeeded
    Automatically reboot if required by updates
.PARAMETER ApprovalGroup
    Require approval from this group before installing (e.g., "IT-Admins")
.PARAM ExcludeUpdates
    Array of update KBs to exclude
.PARAMETER UpdateCategories
    Categories to include (Critical, Important, Moderate, Low, Definition)
.PARAMETER MaxRebootDelay
    Maximum minutes to delay reboot if required
.PARAMETER ConfigPath
    Path to MSP configuration file
.PARAMETER ExportCSV
    Path to export patch results
.EXAMPLE
    .\Invoke-PatchManagement.ps1 -ComputerName PC01,PC02 -ScanOnly -ExportCSV "C:\Reports\patch-scan.csv"
.EXAMPLE
    .\Invoke-PatchManagement.ps1 -ComputerName SRV01 -InstallUpdates -RebootIfNeeded -ApprovalGroup "IT-Admins"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    
    [switch]$ScanOnly,
    
    [switch]$InstallUpdates,
    
    [switch]$RebootIfNeeded,
    
    [string]$ApprovalGroup,
    
    [string[]]$ExcludeUpdates = @(),
    
    [ValidateSet("Critical", "Important", "Moderate", "Low", "Definition")]
    [string[]]$UpdateCategories = @("Critical", "Important"),
    
    [int]$MaxRebootDelay = 60,
    
    [string]$ConfigPath = ".\config\MSPConfig.psd1",
    
    [string]$ExportCSV
)

# Import logging framework
$LoggerScriptPath = Join-Path $PSScriptRoot "..\framework\MSPLogger.ps1"
. $LoggerScriptPath

$logger = Get-MSPLogger -LogName "PatchManagement" -Level "Info"

$logger.StartOperation("Patch Management")

try {
    # Check for PSWindowsUpdate module
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        $logger.Error("PSWindowsUpdate module is required but not installed")
        throw "PSWindowsUpdate module required. Install with: Install-Module PSWindowsUpdate"
    }

    # Load configuration
    if (Test-Path $ConfigPath) {
        $config = Import-PowerShellDataFile -Path $ConfigPath
        $logger.Info("Configuration loaded from $ConfigPath")
    } else {
        $logger.Warning("Configuration file not found, using defaults")
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Approval workflow
    if ($InstallUpdates -and $ApprovalGroup) {
        $logger.Info("Approval required from group: $ApprovalGroup")
        
        # Check if current user is in approval group
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $isApproved = $false
        
        try {
            $groupMembers = Get-ADGroupMember -Identity $ApprovalGroup -ErrorAction SilentlyContinue
            if ($groupMembers) {
                $isApproved = $groupMembers | Where-Object { 
                    $_.SamAccountName -eq $currentUser.Split('\')[-1] 
                }
            }
        } catch {
            $logger.Warning("Could not verify approval group membership: $_")
        }

        if (-not $isApproved) {
            $logger.Error("User $currentUser is not authorized to approve updates. Required group: $ApprovalGroup")
            throw "Authorization required for update installation"
        }

        $logger.Info("Approval verified for user: $currentUser")
    }

    foreach ($computer in $ComputerName) {
        $logger.Info("Processing $computer...")
        
        $result = [PSCustomObject]@{
            Computer           = $computer
            ScanTime           = Get-Date
            AvailableUpdates   = 0
            InstalledUpdates   = 0
            FailedUpdates      = 0
            PendingReboot      = $false
            RebootRequired     = $false
            LastBootTime       = $null
            UpdateDetails      = @()
            Status             = "Unknown"
            ErrorMessage       = $null
        }

        try {
            # Test connectivity
            if (-not (Test-Connection -ComputerName $computer -Count 1 -Quiet)) {
                throw "Computer not reachable"
            }

            # Invoke update operations remotely
            $updateScript = {
                param($scanOnly, $categories, $excludeUpdates)
                
                Import-Module PSWindowsUpdate
                
                if ($scanOnly) {
                    $updates = Get-WindowsUpdate -WindowsUpdate -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
                    return @{
                        Mode = "Scan"
                        Updates = $updates
                        PendingReboot = (Test-WURebootRequired)
                    }
                } else {
                    $updates = Get-WindowsUpdate -WindowsUpdate -AcceptAll -Install -IgnoreReboot -ErrorAction SilentlyContinue
                    return @{
                        Mode = "Install"
                        Updates = $updates
                        PendingReboot = (Test-WURebootRequired)
                    }
                }
            }

            $updateResult = Invoke-Command -ComputerName $computer -ScriptBlock $updateScript -ArgumentList $ScanOnly, $UpdateCategories, $ExcludeUpdates -ErrorAction Stop

            # Process update results
            $result.AvailableUpdates = $updateResult.Updates.Count
            $result.PendingReboot = $updateResult.PendingReboot

            if ($ScanOnly) {
                $result.Status = "Scanned"
                $logger.Info("  Found $($result.AvailableUpdates) available updates")
            } else {
                $installed = ($updateResult.Updates | Where-Object { $_.Result -eq "Installed" }).Count
                $failed = ($updateResult.Updates | Where-Object { $_.Result -ne "Installed" -and $_.Result -ne "Succeeded" }).Count
                
                $result.InstalledUpdates = $installed
                $result.FailedUpdates = $failed
                $result.RebootRequired = $updateResult.PendingReboot

                if ($failed -eq 0) {
                    $result.Status = "Success"
                    $logger.Info("  Installed $installed updates successfully")
                } else {
                    $result.Status = "PartialSuccess"
                    $logger.Warning("  Installed $installed updates, $failed failed")
                }

                # Store update details
                $result.UpdateDetails = $updateResult.Updates | Select-Object KB, Title, Result, Size
            }

            # Get last boot time
            $lastBoot = Invoke-Command -ComputerName $computer -ScriptBlock { 
                (Get-CimInstance Win32_OperatingSystem).LastBootUpTime 
            } -ErrorAction SilentlyContinue
            $result.LastBootTime = $lastBoot

            # Handle reboot if needed
            if ($result.RebootRequired -and $RebootIfNeeded -and -not $ScanOnly) {
                $logger.Info("  Reboot required. Scheduling reboot within $MaxRebootDelay minutes...")
                
                try {
                    $rebootTime = (Get-Date).AddMinutes(Get-Random -Minimum 1 -Maximum $MaxRebootDelay)
                    shutdown /r /m \\$computer /t $([math]::Round(($rebootTime - (Get-Date)).TotalSeconds)) /c "Patch management reboot" /f
                    $logger.Info("  Reboot scheduled for $rebootTime")
                } catch {
                    $logger.Warning("  Could not schedule reboot: $_")
                }
            }

        } catch {
            $result.Status = "Error"
            $result.ErrorMessage = $_.Exception.Message
            $logger.Error("  Error processing $computer : $($_.Exception.Message)")
        }

        $results.Add($result)
    }

    # Summary statistics
    $totalComputers = $results.Count
    $successful = ($results | Where-Object { $_.Status -eq "Success" }).Count
    $partialSuccess = ($results | Where-Object { $_.Status -eq "PartialSuccess" }).Count
    $errors = ($results | Where-Object { $_.Status -eq "Error" }).Count
    $totalUpdates = ($results | Measure-Object -Property AvailableUpdates -Sum).Sum
    $totalInstalled = ($results | Measure-Object -Property InstalledUpdates -Sum).Sum
    $rebootsPending = ($results | Where-Object { $_.RebootRequired -or $_.PendingReboot }).Count

    $logger.Info("Patch management complete: $successful successful, $partialSuccess partial, $errors errors")
    $logger.Info("Total updates: $totalUpdates, Installed: $totalInstalled, Reboots pending: $rebootsPending")

    # Export results
    if ($ExportCSV) {
        $results | Export-Csv $ExportCSV -NoTypeInformation
        $logger.Info("Exported CSV to $ExportCSV")
    }

    # Display summary
    Write-Host "`n=== Patch Management Summary ===" -ForegroundColor Cyan
    Write-Host "Total computers     : $totalComputers" -ForegroundColor White
    Write-Host "Successful          : $successful" -ForegroundColor Green
    Write-Host "Partial Success     : $partialSuccess" -ForegroundColor Yellow
    Write-Host "Errors              : $errors" -ForegroundColor $(if ($errors -gt 0) { "Red" } else { "Green" })
    Write-Host "Total Updates       : $totalUpdates" -ForegroundColor White
    Write-Host "Installed           : $totalInstalled" -ForegroundColor Green
    Write-Host "Reboots Pending     : $rebootsPending" -ForegroundColor $(if ($rebootsPending -gt 0) { "Yellow" } else { "Green" })

    if ($errors -gt 0) {
        Write-Host "`nErrors:" -ForegroundColor Red
        $results | Where-Object { $_.Status -eq "Error" } | 
            Format-Table Computer, Status, ErrorMessage -AutoSize
    }

    if ($rebootsPending -gt 0) {
        Write-Host "`nPending Reboots:" -ForegroundColor Yellow
        $results | Where-Object { $_.RebootRequired -or $_.PendingReboot } | 
            Format-Table Computer, RebootRequired, LastBootTime -AutoSize
    }

    # Exit code
    if ($errors -gt 0) {
        exit 2
    } elseif ($partialSuccess -gt 0 -or $rebootsPending -gt 0) {
        exit 1
    } else {
        exit 0
    }

} catch {
    $logger.Error("Fatal error in patch management", $_)
    throw
} finally {
    $logger.EndOperation("Patch Management")
}