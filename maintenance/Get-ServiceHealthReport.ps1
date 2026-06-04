<#
.SYNOPSIS
    Check status of critical services on one or more machines. Alerts on stopped services that should be running.
.PARAMETER ComputerName
.PARAMETER CriticalServices  Services that must be running (defaults to common MSP-critical list)
.PARAMETER RestartStopped     Attempt to restart stopped critical services
.PARAMETER ExportCSV
.EXAMPLE
    .\Get-ServiceHealthReport.ps1 -ComputerName SRV01,SRV02
    .\Get-ServiceHealthReport.ps1 -ComputerName PC01 -RestartStopped
#>
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string[]]$CriticalServices = @(
        "wuauserv",       # Windows Update
        "WinDefend",      # Windows Defender
        "EventLog",       # Event Log
        "RpcSs",          # RPC
        "Dnscache",       # DNS Client
        "Dhcp",           # DHCP Client
        "LanmanWorkstation", # Workstation
        "W32Time",        # Windows Time
        "MpsSvc",         # Windows Firewall
        "BITS",           # Background Intelligent Transfer
        "CryptSvc",       # Cryptographic Services
        "TrustedInstaller" # Windows Modules Installer
    ),
    [switch]$RestartStopped,
    [string]$ExportCSV
)

$results = @()

Write-Host "`n=== Service Health Report ===" -ForegroundColor Cyan

foreach ($computer in $ComputerName) {
    Write-Host "`n$computer" -ForegroundColor Yellow
    try {
        $services = Get-Service -ComputerName $computer -Name $CriticalServices -ErrorAction SilentlyContinue

        foreach ($svc in $services) {
            $running  = $svc.Status -eq "Running"
            $color    = if ($running) { "Green" } else { "Red" }
            $status   = $svc.Status.ToString()
            Write-Host ("  {0,-40} {1}" -f $svc.DisplayName, $status) -ForegroundColor $color

            if (-not $running -and $RestartStopped) {
                try {
                    $svc.Start()
                    $svc.WaitForStatus("Running", [TimeSpan]::FromSeconds(10))
                    Write-Host "    [RESTARTED]" -ForegroundColor Yellow
                    $status = "Restarted"
                } catch {
                    Write-Host "    [FAILED TO RESTART] $_" -ForegroundColor Red
                    $status = "RestartFailed"
                }
            }

            $results += [PSCustomObject]@{
                Computer    = $computer
                ServiceName = $svc.ServiceName
                DisplayName = $svc.DisplayName
                Status      = $status
                StartType   = $svc.StartType
                Alert       = (-not $running)
            }
        }

        # Also check for any services in Error state
        $errored = Get-Service -ComputerName $computer -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq "StopPending" -or $_.Status -eq "StartPending" }
        if ($errored) {
            Write-Host "`n  [WARN] Services stuck in transition:" -ForegroundColor Yellow
            $errored | ForEach-Object { Write-Host "    $($_.DisplayName): $($_.Status)" -ForegroundColor Yellow }
        }
    } catch {
        Write-Host "  [ERROR] $computer : $_" -ForegroundColor Red
    }
}

$alerts = $results | Where-Object { $_.Alert }
if ($alerts.Count -gt 0) {
    Write-Host "`n=== STOPPED CRITICAL SERVICES ===" -ForegroundColor Red
    $alerts | Format-Table Computer, DisplayName, Status, StartType -AutoSize
} else {
    Write-Host "`nAll critical services are running." -ForegroundColor Green
}

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "[OK] Exported to $ExportCSV" -ForegroundColor Green
}
