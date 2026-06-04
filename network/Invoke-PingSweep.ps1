<#
.SYNOPSIS
    Sweep a subnet and return all responding hosts with hostname and response time.
.PARAMETER Subnet        Base subnet e.g. "192.168.1" (sweeps .1-.254)
.PARAMETER StartIP       Start of range (default 1)
.PARAMETER EndIP         End of range (default 254)
.PARAMETER Throttle      Parallel jobs (default 50)
.PARAMETER ExportCSV
.EXAMPLE
    .\Invoke-PingSweep.ps1 -Subnet "192.168.1"
    .\Invoke-PingSweep.ps1 -Subnet "10.0.0" -StartIP 1 -EndIP 100
#>
param(
    [Parameter(Mandatory)][string]$Subnet,
    [int]$StartIP  = 1,
    [int]$EndIP    = 254,
    [int]$Throttle = 50,
    [string]$ExportCSV
)

Write-Host "`n=== Ping Sweep: $Subnet.$StartIP - $Subnet.$EndIP ===" -ForegroundColor Cyan
$startTime = Get-Date

$results = $StartIP..$EndIP | ForEach-Object -ThrottleLimit $Throttle -Parallel {
    $ip = "$using:Subnet.$_"
    $ping = Test-Connection -ComputerName $ip -Count 1 -TimeoutSeconds 1 -ErrorAction SilentlyContinue
    if ($ping) {
        $hostname = try { [System.Net.Dns]::GetHostEntry($ip).HostName } catch { "N/A" }
        [PSCustomObject]@{
            IP           = $ip
            Hostname     = $hostname
            ResponseTime = $ping.Latency
            Status       = "UP"
        }
    }
} | Sort-Object { [version]$_.IP }

$elapsed = (Get-Date) - $startTime

Write-Host "`nHosts responding: $($results.Count) of $($EndIP - $StartIP + 1) addresses" -ForegroundColor Green
Write-Host "Scan time: $([math]::Round($elapsed.TotalSeconds, 1))s`n"
$results | Format-Table IP, Hostname, ResponseTime, Status -AutoSize

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "[OK] Exported to $ExportCSV" -ForegroundColor Green
}
