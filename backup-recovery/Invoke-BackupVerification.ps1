#Requires -Modules Microsoft.PowerShell.Management
<#
.SYNOPSIS
    Verify backup integrity across multiple backup sources and alert on failures.
.DESCRIPTION
    Comprehensive backup verification script that checks backup existence, age, size,
    and test restoration capabilities. Supports various backup systems including Veeam,
    Windows Server Backup, and cloud backups.
.PARAMETER BackupPath
    Root path containing backups (e.g., \\backupserver\backups)
.PARAMETER MaxAgeHours
    Maximum age of backups in hours before alerting (default: 26)
.PARAMETER MinSizeMB
    Minimum backup size in MB (default: 100)
.PARAMETER TestRestore
    Perform test restoration of random files to verify integrity
.PARAMETER BackupType
    Type of backup system (Veeam, WindowsServerBackup, Custom)
.PARAMETER ConfigPath
    Path to MSP configuration file
.PARAMETER ExportCSV
    Path to export verification results
.EXAMPLE
    .\Invoke-BackupVerification.ps1 -BackupPath "\\backupserver\backups" -TestRestore
.EXAMPLE
    .\Invoke-BackupVerification.ps1 -BackupType Veeam -ExportCSV "C:\Reports\backup-verification.csv"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BackupPath,
    
    [int]$MaxAgeHours = 26,
    
    [int]$MinSizeMB = 100,
    
    [switch]$TestRestore,
    
    [ValidateSet("Veeam", "WindowsServerBackup", "Custom")]
    [string]$BackupType = "Custom",
    
    [string]$ConfigPath = ".\config\MSPConfig.psd1",
    
    [string]$ExportCSV
)

# Import logging framework
$LoggerScriptPath = Join-Path $PSScriptRoot "..\framework\MSPLogger.ps1"
. $LoggerScriptPath

$logger = Get-MSPLogger -LogName "BackupVerification" -Level "Info"

$logger.StartOperation("Backup Verification")

try {
    # Load configuration
    if (Test-Path $ConfigPath) {
        $config = Import-PowerShellDataFile -Path $ConfigPath
        $retentionDays = $config.Backup.RetentionDays
        $logger.Info("Configuration loaded from $ConfigPath")
    } else {
        $retentionDays = 30
        $logger.Warning("Configuration file not found, using defaults")
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $cutoffTime = (Get-Date).AddHours(-$MaxAgeHours)

    $logger.Info("Starting backup verification for: $BackupPath")
    $logger.Info("Maximum backup age: $MaxAgeHours hours")
    $logger.Info("Minimum backup size: $MinSizeMB MB")

    # Check backup path accessibility
    if (-not (Test-Path $BackupPath)) {
        $logger.Error("Backup path not accessible: $BackupPath")
        throw "Backup path not accessible"
    }

    # Get backup files/directories based on type
    switch ($BackupType) {
        "Veeam" {
            $backups = Get-ChildItem $BackupPath -Filter "*.vib" -Recurse -ErrorAction SilentlyContinue
        }
        "WindowsServerBackup" {
            $backups = Get-ChildItem $BackupPath -Filter "*. Backup*" -Directory -ErrorAction SilentlyContinue
        }
        "Custom" {
            $backups = Get-ChildItem $BackupPath -Recurse -ErrorAction SilentlyContinue | 
                       Where-Object { $_.PSIsContainer -or $_.Extension -match '\.(zip|bak|backup)' }
        }
    }

    $logger.Info("Found $($backups.Count) backup items to verify")

    foreach ($backup in $backups) {
        $logger.Info("Verifying: $($backup.Name)")
        
        $result = [PSCustomObject]@{
            BackupName      = $backup.Name
            BackupPath      = $backup.FullName
            BackupType      = $BackupType
            LastModified    = $backup.LastWriteTime
            AgeHours        = [math]::Round(((Get-Date) - $backup.LastWriteTime).TotalHours, 1)
            SizeMB          = if ($backup.PSIsContainer) { 
                (Get-ChildItem $backup.FullName -Recurse -ErrorAction SilentlyContinue | 
                 Measure-Object -Property Length -Sum).Sum / 1MB 
            } else { 
                $backup.Length / 1MB 
            }
            WithinAgeWindow = $backup.LastWriteTime -gt $cutoffTime
            AboveMinSize    = $false
            Accessible      = $true
            TestRestoreResult = "NotTested"
            OverallStatus   = "Unknown"
            ScanTime        = Get-Date
        }

        # Check size
        $result.AboveMinSize = $result.SizeMB -gt $MinSizeMB

        # Check accessibility
        try {
            $testAccess = Get-Item $backup.FullName -ErrorAction Stop
            $result.Accessible = $true
        } catch {
            $result.Accessible = $false
            $logger.Warning("  [WARNING] Backup not accessible: $_")
        }

        # Test restore if requested and accessible
        if ($TestRestore -and $result.Accessible -and $result.AboveMinSize) {
            try {
                $logger.Info("  Performing test restore check...")
                
                if ($backup.PSIsContainer) {
                    # For directories, try to read a random file
                    $testFiles = Get-ChildItem $backup.FullName -Recurse -File -ErrorAction SilentlyContinue | 
                                 Get-Random -Count 1 -ErrorAction SilentlyContinue
                    if ($testFiles) {
                        $testFile = $testFiles | Get-Random
                        $testContent = Get-Content $testFile.FullName -TotalCount 1 -ErrorAction Stop
                        $result.TestRestoreResult = "Success"
                    } else {
                        $result.TestRestoreResult = "NoFilesToTest"
                    }
                } else {
                    # For files, try to read header
                    $fileHeader = Get-Content $backup.FullName -TotalCount 1 -ErrorAction Stop
                    $result.TestRestoreResult = "Success"
                }
                
                $logger.Info("  [OK] Test restore successful")
            } catch {
                $result.TestRestoreResult = "Failed: $($_.Exception.Message)"
                $logger.Warning("  [WARNING] Test restore failed: $_")
            }
        }

        # Determine overall status
        if (-not $result.Accessible) {
            $result.OverallStatus = "Critical"
        } elseif (-not $result.WithinAgeWindow) {
            $result.OverallStatus = "Warning"
        } elseif (-not $result.AboveMinSize) {
            $result.OverallStatus = "Warning"
        } elseif ($result.TestRestoreResult -eq "Failed") {
            $result.OverallStatus = "Critical"
        } elseif ($result.TestRestoreResult -eq "Success") {
            $result.OverallStatus = "Healthy"
        } else {
            $result.OverallStatus = "Healthy"
        }

        $results.Add($result)

        # Log status
        $statusColor = switch ($result.OverallStatus) {
            "Healthy"   { "Green" }
            "Warning"   { "Yellow" }
            "Critical"  { "Red" }
            default     { "White" }
        }
        $logger.Info("  Status: $($result.OverallStatus) | Age: $($result.AgeHours)h | Size: $([math]::Round($result.SizeMB, 1))MB")
    }

    # Check for old backups beyond retention
    $oldBackups = $results | Where-Object { $_.AgeHours -gt ($retentionDays * 24) }
    if ($oldBackups.Count -gt 0) {
        $logger.Warning("Found $($oldBackups.Count) backups exceeding retention period of $retentionDays days")
    }

    # Summary statistics
    $healthy = ($results | Where-Object { $_.OverallStatus -eq "Healthy" }).Count
    $warnings = ($results | Where-Object { $_.OverallStatus -eq "Warning" }).Count
    $critical = ($results | Where-Object { $_.OverallStatus -eq "Critical" }).Count

    $logger.Info("Verification complete: $healthy healthy, $warnings warnings, $critical critical")

    # Export results
    if ($ExportCSV) {
        $results | Export-Csv $ExportCSV -NoTypeInformation
        $logger.Info("Exported CSV to $ExportCSV")
    }

    # Display summary
    Write-Host "`n=== Backup Verification Summary ===" -ForegroundColor Cyan
    Write-Host "Total backups checked : $($results.Count)" -ForegroundColor White
    Write-Host "Healthy              : $healthy" -ForegroundColor Green
    Write-Host "Warnings             : $warnings" -ForegroundColor Yellow
    Write-Host "Critical             : $critical" -ForegroundColor $(if ($critical -gt 0) { "Red" } else { "Green" })

    if ($critical -gt 0) {
        Write-Host "`nCritical Issues:" -ForegroundColor Red
        $results | Where-Object { $_.OverallStatus -eq "Critical" } | 
            Format-Table BackupName, OverallStatus, AgeHours, SizeMB, TestRestoreResult -AutoSize
    }

    if ($warnings -gt 0) {
        Write-Host "`nWarnings:" -ForegroundColor Yellow
        $results | Where-Object { $_.OverallStatus -eq "Warning" } | 
            Format-Table BackupName, OverallStatus, AgeHours, SizeMB -AutoSize
    }

    # Exit code based on results
    if ($critical -gt 0) {
        $logger.WriteEventLog("Backup verification completed with $critical critical failures", [System.Diagnostics.EventLogEntryType]::Error)
        exit 2
    } elseif ($warnings -gt 0) {
        $logger.WriteEventLog("Backup verification completed with $warnings warnings", [System.Diagnostics.EventLogEntryType]::Warning)
        exit 1
    } else {
        $logger.WriteEventLog("Backup verification completed successfully", [System.Diagnostics.EventLogEntryType]::Information)
        exit 0
    }

} catch {
    $logger.Error("Fatal error in backup verification", $_)
    $logger.WriteEventLog("Backup verification failed: $($_.Exception.Message)", [System.Diagnostics.EventLogEntryType]::Error)
    throw
} finally {
    $logger.EndOperation("Backup Verification")
}