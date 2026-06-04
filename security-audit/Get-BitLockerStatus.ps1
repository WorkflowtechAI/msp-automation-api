#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Report BitLocker encryption status across all fixed drives on local or remote machines.
.PARAMETER ComputerName   One or more hostnames (default: localhost)
.PARAMETER ExportCSV      Path to export results
.EXAMPLE
    .\Get-BitLockerStatus.ps1
    .\Get-BitLockerStatus.ps1 -ComputerName PC01,PC02,PC03 -ExportCSV "C:\Reports\bitlocker.csv"
#>
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$ExportCSV
)

$results = @()

foreach ($computer in $ComputerName) {
    Write-Host "`nChecking $computer..." -ForegroundColor Cyan
    try {
        $volumes = Invoke-Command -ComputerName $computer -ScriptBlock {
            Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, EncryptionPercentage,
                ProtectionStatus, LockStatus, EncryptionMethod,
                @{N="KeyProtectors";E={($_.KeyProtector | Select-Object -ExpandProperty KeyProtectorType) -join ", "}}
        } -ErrorAction Stop

        foreach ($v in $volumes) {
            $status = if ($v.ProtectionStatus -eq "On") { "PROTECTED" } else { "UNPROTECTED" }
            $color  = if ($status -eq "PROTECTED") { "Green" } else { "Red" }
            Write-Host "  $($v.MountPoint)  $status  $($v.EncryptionPercentage)%  $($v.KeyProtectors)" -ForegroundColor $color

            $results += [PSCustomObject]@{
                Computer           = $computer
                Drive              = $v.MountPoint
                Status             = $status
                VolumeStatus       = $v.VolumeStatus
                EncryptionPct      = $v.EncryptionPercentage
                ProtectionStatus   = $v.ProtectionStatus
                LockStatus         = $v.LockStatus
                EncryptionMethod   = $v.EncryptionMethod
                KeyProtectors      = $v.KeyProtectors
            }
        }
    } catch {
        Write-Host "  [ERROR] Could not query $computer : $_" -ForegroundColor Red
        $results += [PSCustomObject]@{
            Computer = $computer; Drive = "N/A"; Status = "ERROR"; VolumeStatus = $_
        }
    }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$unprotected = $results | Where-Object { $_.Status -eq "UNPROTECTED" }
Write-Host "Total drives checked : $($results.Count)"
Write-Host "Unprotected drives   : $($unprotected.Count)" -ForegroundColor $(if ($unprotected.Count -gt 0) { "Red" } else { "Green" })

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "`n[OK] Exported to $ExportCSV" -ForegroundColor Green
}
