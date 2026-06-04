<#
.SYNOPSIS
    Comprehensive connectivity test: DNS, gateway, internet, key services.
    Run on a client machine to diagnose network issues fast.
.PARAMETER Target     Custom target to test (default: tests a standard set)
.EXAMPLE
    .\Test-NetworkConnectivity.ps1
    .\Test-NetworkConnectivity.ps1 -Target "clientserver.domain.com"
#>
param([string]$Target)

function Test-Port {
    param([string]$Host, [int]$Port, [int]$Timeout = 2000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $task = $tcp.ConnectAsync($Host, $Port)
        if ($task.Wait($Timeout)) { $tcp.Close(); return $true }
        $tcp.Close(); return $false
    } catch { return $false }
}

function Show-Result {
    param([string]$Label, [bool]$Pass, [string]$Detail = "")
    $icon  = if ($Pass) { "[OK]  " } else { "[FAIL]" }
    $color = if ($Pass) { "Green" } else { "Red" }
    Write-Host ("  {0} {1,-35} {2}" -f $icon, $Label, $Detail) -ForegroundColor $color
}

Write-Host "`n=== Network Connectivity Diagnostic ===" -ForegroundColor Cyan
Write-Host "Machine  : $env:COMPUTERNAME"
Write-Host "Time     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"

# --- Adapter Info ---
Write-Host "--- Active Adapters ---" -ForegroundColor Yellow
Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | ForEach-Object {
    Write-Host "  $($_.InterfaceAlias): $($_.IPv4Address.IPAddress) | GW: $($_.IPv4DefaultGateway.NextHop) | DNS: $(($_.DNSServer.ServerAddresses) -join ', ')"
}

Write-Host "`n--- Connectivity Tests ---" -ForegroundColor Yellow

# Gateway ping
$gw = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4DefaultGateway.NextHop
$gwPing = Test-Connection -ComputerName $gw -Count 1 -TimeoutSeconds 2 -ErrorAction SilentlyContinue
Show-Result "Default Gateway ($gw)" ($null -ne $gwPing) $(if ($gwPing) { "$($gwPing.Latency)ms" })

# DNS resolution
$dnsTest = try { [System.Net.Dns]::GetHostEntry("google.com"); $true } catch { $false }
Show-Result "DNS Resolution (google.com)" $dnsTest

# Internet ping
$internet = Test-Connection -ComputerName "8.8.8.8" -Count 1 -TimeoutSeconds 2 -ErrorAction SilentlyContinue
Show-Result "Internet Ping (8.8.8.8)" ($null -ne $internet) $(if ($internet) { "$($internet.Latency)ms" })

# HTTPS
$https = Test-Port "google.com" 443
Show-Result "HTTPS Port 443 (google.com)" $https

# HTTP
$http = Test-Port "google.com" 80
Show-Result "HTTP Port 80 (google.com)" $http

# M365 endpoints
$m365DNS = try { [System.Net.Dns]::GetHostEntry("outlook.office365.com"); $true } catch { $false }
Show-Result "M365 DNS (outlook.office365.com)" $m365DNS

$m365Port = Test-Port "outlook.office365.com" 443
Show-Result "M365 HTTPS (outlook.office365.com:443)" $m365Port

# Custom target
if ($Target) {
    Write-Host "`n--- Custom Target: $Target ---" -ForegroundColor Yellow
    $customPing = Test-Connection -ComputerName $Target -Count 2 -ErrorAction SilentlyContinue
    Show-Result "Ping $Target" ($null -ne $customPing) $(if ($customPing) { "$([math]::Round(($customPing.Latency | Measure-Object -Average).Average))ms avg" })
    Show-Result "Port 443 $Target" (Test-Port $Target 443)
    Show-Result "Port 80 $Target" (Test-Port $Target 80)
    Show-Result "Port 3389 (RDP) $Target" (Test-Port $Target 3389)
}

# Check for captive portal / proxy
Write-Host "`n--- Proxy / Captive Portal Check ---" -ForegroundColor Yellow
$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$proxyUri = $proxy.GetProxy("http://www.google.com")
if ($proxyUri.Host -ne "www.google.com") {
    Write-Host "  [INFO] Proxy detected: $proxyUri" -ForegroundColor Yellow
} else {
    Write-Host "  [OK]  No proxy detected (direct connection)" -ForegroundColor Green
}

Write-Host ""
