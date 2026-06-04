<#
.SYNOPSIS
    Report pending Windows Updates and last install date on one or more machines.
.PARAMETER ComputerName
.PARAMETER ExportCSV
.EXAMPLE
    .\Get-WindowsUpdateStatus.ps1 -ComputerName PC01,PC02
#>
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$ExportCSV
)

$results = @()

Write-Host "`n=== Windows Update Status ===" -ForegroundColor Cyan

foreach ($computer in $ComputerName) {
    Write-Host "`n$computer..." -ForegroundColor Yellow
    try {
        $info = Invoke-Command -ComputerName $computer -ScriptBlock {
            # Last successful update install
            $wu = New-Object -ComObject Microsoft.Update.Session
            $searcher = $wu.CreateUpdateSearcher()
            $histCount = $searcher.GetTotalHistoryCount()
            $lastInstall = if ($histCount -gt 0) {
                ($searcher.QueryHistory(0, [Math]::Min($histCount, 50)) |
                    Where-Object { $_.ResultCode -eq 2 } |
                    Sort-Object Date -Descending |
                    Select-Object -First 1).Date
            } else { $null }

            # Pending updates
            $pending = $searcher.Search("IsInstalled=0 and IsHidden=0")
            $criticalCount = ($pending.Updates | Where-Object { $_.MsrcSeverity -eq "Critical" }).Count

            [PSCustomObject]@{
                Hostname         = $env:COMPUTERNAME
                PendingUpdates   = $pending.Updates.Count
                CriticalPending  = $criticalCount
                LastInstallDate  = $lastInstall
                DaysSinceUpdate  = if ($lastInstall) { (New-TimeSpan -Start $lastInstall -End (Get-Date)).Days } else { "Unknown" }
                PendingTitles    = ($pending.Updates | Select-Object -First 5 -ExpandProperty Title) -join " | "
            }
        } -ErrorAction Stop

        $color = if ($info.CriticalPending -gt 0) { "Red" } elseif ($info.PendingUpdates -gt 0) { "Yellow" } else { "Green" }
        Write-Host "  Pending: $($info.PendingUpdates) ($($info.CriticalPending) critical)  Last install: $($info.LastInstallDate)" -ForegroundColor $color
        if ($info.PendingTitles) { Write-Host "  Top pending: $($info.PendingTitles)" -ForegroundColor Gray }

        $results += $info
    } catch {
        Write-Host "  [ERROR] $computer : $_" -ForegroundColor Red
        $results += [PSCustomObject]@{ Hostname = $computer; PendingUpdates = "ERROR"; Error = $_ }
    }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$results | Format-Table Hostname, PendingUpdates, CriticalPending, LastInstallDate, DaysSinceUpdate -AutoSize

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "[OK] Exported to $ExportCSV" -ForegroundColor Green
}
