#Requires -RunAsAdministrator
#Requires -Modules Microsoft.PowerShell.Management
<#
.SYNOPSIS
    Enhanced BitLocker encryption status with compliance checking and remediation support.
.DESCRIPTION
    Modernized BitLocker auditing with configuration-driven compliance checking,
    structured logging, and optional remediation actions.
.PARAMETER ComputerName
    One or more hostnames (default: localhost)
.PARAMETER ConfigPath
    Path to MSP configuration file
.PARAMETER ExportCSV
    Path to export results
.PARAMETER ExportJSON
    Path to export results as JSON
.PARAMETER Remediate
    Attempt to enable BitLocker on unprotected drives
.PARAMETER Parallel
    Enable parallel execution
.EXAMPLE
    .\Get-BitLockerStatus-Enhanced.ps1 -ComputerName PC01,PC02,PC03 -ExportCSV "C:\Reports\bitlocker.csv"
.EXAMPLE
    .\Get-BitLockerStatus-Enhanced.ps1 -Remediate -Parallel
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$ConfigPath = ".\config\MSPConfig.psd1",
    [string]$ExportCSV,
    [string]$ExportJSON,
    [switch]$Remediate,
    [switch]$Parallel,
    [int]$ThrottleLimit = 10
)

# Import logging framework
$LoggerScriptPath = Join-Path $PSScriptRoot "..\framework\MSPLogger.ps1"
. $LoggerScriptPath

$logger = Get-MSPLogger -LogName "BitLockerAudit" -Level "Info"

$logger.StartOperation("BitLocker Compliance Audit")

try {
    # Load configuration
    if (Test-Path $ConfigPath) {
        $config = Import-PowerShellDataFile -Path $ConfigPath
        $bitLockerRequired = $config.Security.BitLockerRequired
        $logger.Info("Configuration loaded from $ConfigPath")
    } else {
        $bitLockerRequired = $true
        $logger.Warning("Configuration file not found, using defaults")
    }

    $results = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

    $bitLockerBlock = {
        param($computer, $remediate)

        try {
            $volumes = Invoke-Command -ComputerName $computer -ScriptBlock {
                Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, EncryptionPercentage,
                    ProtectionStatus, LockStatus, EncryptionMethod, CapacityGB,
                    @{N="KeyProtectors";E={($_.KeyProtector | Select-Object -ExpandProperty KeyProtectorType) -join ", "}},
                    @{N="AutoUnlock";E={(Get-BitLockerVolume -MountPoint $_.MountPoint).AutoUnlockEnabled}}
            } -ErrorAction Stop

            $volumeResults = @()
            foreach ($v in $volumes) {
                $status = if ($v.ProtectionStatus -eq "On") { "PROTECTED" } else { "UNPROTECTED" }
                $compliant = $status -eq "PROTECTED"
                
                $volumeResult = [PSCustomObject]@{
                    Computer           = $computer
                    Drive              = $v.MountPoint
                    Status             = $status
                    Compliant          = $compliant
                    VolumeStatus       = $v.VolumeStatus
                    EncryptionPct      = $v.EncryptionPercentage
                    ProtectionStatus   = $v.ProtectionStatus
                    LockStatus         = $v.LockStatus
                    EncryptionMethod   = $v.EncryptionMethod
                    CapacityGB         = $v.CapacityGB
                    KeyProtectors      = $v.KeyProtectors
                    AutoUnlock         = $v.AutoUnlock
                    ScanTime           = Get-Date
                }

                # Attempt remediation if requested and not compliant
                if ($remediate -and -not $compliant -and $v.VolumeStatus -eq "FullyDecrypted") {
                    try {
                        $enableResult = Invoke-Command -ComputerName $computer -ScriptBlock {
                            param($mountPoint)
                            Enable-BitLocker -MountPoint $mountPoint -UsedSpaceOnly -SkipHardwareTest -RecoveryPasswordProtector
                        } -ArgumentList $v.MountPoint -ErrorAction Stop
                        
                        $volumeResult.RemediationAttempted = $true
                        $volumeResult.RemediationResult = "Success"
                        $volumeResult.RemediationMessage = "BitLocker enablement initiated"
                    } catch {
                        $volumeResult.RemediationAttempted = $true
                        $volumeResult.RemediationResult = "Failed"
                        $volumeResult.RemediationMessage = $_.Exception.Message
                    }
                } else {
                    $volumeResult.RemediationAttempted = $false
                }

                $volumeResults += $volumeResult
            }

            return @{
                Success = $true
                Computer = $computer
                Data = $volumeResults
            }
        } catch {
            return @{
                Success = $false
                Computer = $computer
                Error = $_.Exception.Message
            }
        }
    }

    $logger.Info("Starting BitLocker audit of $($ComputerName.Count) computer(s)")

    if ($Parallel -and $ComputerName.Count -gt 1) {
        $logger.Info("Using parallel execution with throttle limit: $ThrottleLimit")
        $ComputerName | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $result = & $using:bitLockerBlock -computer $_ -remediate $using:Remediate
            foreach ($item in $result.Data) {
                $using:results.Add($item)
            }
        }
    } else {
        foreach ($computer in $ComputerName) {
            $logger.Info("Checking $computer...")
            $result = & $bitLockerBlock -computer $computer -remediate $Remediate
            
            if ($result.Success) {
                foreach ($item in $result.Data) {
                    $results.Add($item)
                    
                    $color = if ($item.Status -eq "PROTECTED") { "Green" } else { "Red" }
                    $logger.Info("  $($item.Drive)  $($item.Status)  $($item.EncryptionPct)%  $($item.KeyProtectors)")
                    
                    if ($item.RemediationAttempted) {
                        if ($item.RemediationResult -eq "Success") {
                            $logger.Info("    [REMEDIATED] $($item.RemediationMessage)")
                        } else {
                            $logger.Warning("    [REMEDIATION FAILED] $($item.RemediationMessage)")
                        }
                    }
                }
            } else {
                $logger.Error("  [ERROR] $computer - $($result.Error)")
                $results.Add([PSCustomObject]@{
                    Computer = $computer
                    Drive = "N/A"
                    Status = "ERROR"
                    Compliant = $false
                    Error = $result.Error
                    ScanTime = Get-Date
                })
            }
        }
    }

    # Process results
    $totalDrives = $results.Count
    $protectedDrives = ($results | Where-Object { $_.Status -eq "PROTECTED" }).Count
    $unprotectedDrives = ($results | Where-Object { $_.Status -eq "UNPROTECTED" }).Count
    $nonCompliant = $results | Where-Object { $_.Compliant -eq $false -and $_.Status -ne "ERROR" }

    $logger.Info("Audit complete: $totalDrives drives checked, $protectedDrives protected, $unprotectedDrives unprotected")

    # Compliance check
    if ($bitLockerRequired) {
        $complianceRate = if ($totalDrives -gt 0) { [math]::Round(($protectedDrives / $totalDrives) * 100, 1) } else { 0 }
        $logger.Info("Compliance rate: $complianceRate%")
        
        if ($complianceRate -lt 100) {
            $logger.Warning("Compliance requirement not met (target: 100%, actual: $complianceRate%)")
        }
    }

    # Export results
    if ($ExportCSV) {
        $results | Export-Csv $ExportCSV -NoTypeInformation
        $logger.Info("Exported CSV to $ExportCSV")
    }

    if ($ExportJSON) {
        $results | ConvertTo-Json -Depth 10 | Out-File $ExportJSON
        $logger.Info("Exported JSON to $ExportJSON")
    }

    # Display summary
    Write-Host "`n=== BitLocker Status Summary ===" -ForegroundColor Cyan
    Write-Host "Total drives checked   : $totalDrives" -ForegroundColor White
    Write-Host "Protected drives       : $protectedDrives" -ForegroundColor Green
    Write-Host "Unprotected drives     : $unprotectedDrives" -ForegroundColor $(if ($unprotectedDrives -gt 0) { "Red" } else { "Green" })

    if ($nonCompliant.Count -gt 0) {
        Write-Host "`nNon-compliant drives:" -ForegroundColor Red
        $nonCompliant | Format-Table Computer, Drive, Status, EncryptionPct, KeyProtectors -AutoSize
    }

    if ($Remediate) {
        $remediationResults = $results | Where-Object { $_.RemediationAttempted }
        if ($remediationResults.Count -gt 0) {
            Write-Host "`nRemediation Summary:" -ForegroundColor Yellow
            $remediationResults | Format-Table Computer, Drive, RemediationResult, RemediationMessage -AutoSize
        }
    }

    return $results

} catch {
    $logger.Error("Fatal error in BitLocker audit", $_)
    throw
} finally {
    $logger.EndOperation("BitLocker Compliance Audit")
}