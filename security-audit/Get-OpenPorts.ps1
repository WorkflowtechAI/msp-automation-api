<#
.SYNOPSIS
    List all active listening ports with process name and owner. Quick local firewall audit.
.PARAMETER ExportCSV
.EXAMPLE
    .\Get-OpenPorts.ps1
    .\Get-OpenPorts.ps1 -ExportCSV "C:\Reports\ports.csv"
#>
param([string]$ExportCSV)

Write-Host "`n=== Open Listening Ports ===" -ForegroundColor Cyan

$listeners = Get-NetTCPConnection -State Listen | Sort-Object LocalPort |
    Select-Object LocalAddress, LocalPort,
        @{N="PID";E={$_.OwningProcess}},
        @{N="ProcessName";E={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Name}},
        @{N="ProcessPath";E={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Path}}

$udpListeners = Get-NetUDPEndpoint | Sort-Object LocalPort |
    Select-Object LocalAddress, LocalPort,
        @{N="PID";E={$_.OwningProcess}},
        @{N="ProcessName";E={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Name}}

Write-Host "`n--- TCP Listeners ---" -ForegroundColor Yellow
$listeners | Format-Table LocalAddress, LocalPort, ProcessName, PID, ProcessPath -AutoSize

Write-Host "`n--- UDP Endpoints ---" -ForegroundColor Yellow
$udpListeners | Format-Table LocalAddress, LocalPort, ProcessName, PID -AutoSize

# Flag anything unusual on well-known dangerous ports
$dangerousPorts = @(23,69,135,137,138,139,445,3389,5985,5986,4444,31337,1337)
$flagged = $listeners | Where-Object { $_.LocalPort -in $dangerousPorts }
if ($flagged) {
    Write-Host "`n=== FLAGGED PORTS (review these) ===" -ForegroundColor Red
    $flagged | Format-Table LocalAddress, LocalPort, ProcessName, ProcessPath -AutoSize
}

if ($ExportCSV) {
    $listeners | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "`n[OK] Exported to $ExportCSV" -ForegroundColor Green
}
