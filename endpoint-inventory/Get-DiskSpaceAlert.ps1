<#
.SYNOPSIS
    Check disk space across machines and alert on drives below threshold.
.PARAMETER ComputerName
.PARAMETER ThresholdPct   Alert if free space is below this percentage (default: 20)
.PARAMETER ExportCSV
.EXAMPLE
    .\Get-DiskSpaceAlert.ps1 -ComputerName PC01,PC02,SRV01 -ThresholdPct 15
#>
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [int]$ThresholdPct = 20,
    [string]$ExportCSV
)

$results = @()

Write-Host "`n=== Disk Space Report (Alert threshold: <$ThresholdPct% free) ===" -ForegroundColor Cyan

foreach ($computer in $ComputerName) {
    try {
        $disks = Get-CimInstance -ComputerName $computer Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
        foreach ($disk in $disks) {
            $totalGB = [math]::Round($disk.Size / 1GB, 1)
            $freeGB  = [math]::Round($disk.FreeSpace / 1GB, 1)
            $usedGB  = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 1)
            $freePct = if ($disk.Size -gt 0) { [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1) } else { 0 }
            $alert   = $freePct -lt $ThresholdPct

            $color = if ($freePct -lt 10) { "Red" } elseif ($freePct -lt $ThresholdPct) { "Yellow" } else { "Green" }
            Write-Host ("  {0,-15} {1}  {2,6}GB total  {3,6}GB used  {4,6}GB free  ({5}%){6}" -f `
                $computer, $disk.DeviceID, $totalGB, $usedGB, $freeGB, $freePct,
                $(if ($alert) { " <<< LOW" } else { "" })) -ForegroundColor $color

            $results += [PSCustomObject]@{
                Computer   = $computer
                Drive      = $disk.DeviceID
                Label      = $disk.VolumeName
                TotalGB    = $totalGB
                UsedGB     = $usedGB
                FreeGB     = $freeGB
                FreePct    = $freePct
                Alert      = $alert
            }
        }
    } catch {
        Write-Host "  [ERROR] $computer : $_" -ForegroundColor Red
    }
}

$alerts = $results | Where-Object { $_.Alert }
if ($alerts.Count -gt 0) {
    Write-Host "`n=== LOW DISK SPACE ALERTS ===" -ForegroundColor Red
    $alerts | Format-Table Computer, Drive, Label, TotalGB, FreeGB, FreePct -AutoSize
} else {
    Write-Host "`nAll drives are above threshold." -ForegroundColor Green
}

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "[OK] Exported to $ExportCSV" -ForegroundColor Green
}
