<#
.SYNOPSIS
    Check DNS resolution for a list of hostnames/domains from one or more machines.
    Useful for validating DNS after changes or diagnosing split-brain DNS issues.
.PARAMETER Targets      Hostnames or domains to resolve
.PARAMETER DNSServers   Specific DNS servers to query (default: system DNS)
.PARAMETER ComputerName Run checks from remote machines
.EXAMPLE
    .\Get-DNSReport.ps1 -Targets "google.com","outlook.com","internalserver"
    .\Get-DNSReport.ps1 -Targets "domain.local" -DNSServers "8.8.8.8","1.1.1.1"
#>
param(
    [string[]]$Targets = @("google.com", "outlook.office365.com", "login.microsoftonline.com"),
    [string[]]$DNSServers = @(),
    [string[]]$ComputerName = @($env:COMPUTERNAME)
)

Write-Host "`n=== DNS Resolution Report ===" -ForegroundColor Cyan

foreach ($computer in $ComputerName) {
    Write-Host "`nFrom: $computer" -ForegroundColor Yellow
    foreach ($target in $Targets) {
        try {
            if ($DNSServers.Count -gt 0) {
                # Use Resolve-DnsName with specific server
                $resolved = Invoke-Command -ComputerName $computer -ArgumentList $target, $DNSServers[0] -ScriptBlock {
                    param($t, $dns)
                    Resolve-DnsName -Name $t -Server $dns -ErrorAction Stop |
                        Select-Object -ExpandProperty IPAddress -ErrorAction SilentlyContinue
                }
            } else {
                $resolved = Invoke-Command -ComputerName $computer -ArgumentList $target -ScriptBlock {
                    param($t)
                    [System.Net.Dns]::GetHostAddresses($t) | Select-Object -ExpandProperty IPAddressToString
                }
            }
            $ips = ($resolved | Where-Object { $_ }) -join ", "
            Write-Host ("  [OK]  {0,-40} -> {1}" -f $target, $ips) -ForegroundColor Green
        } catch {
            Write-Host ("  [FAIL]{0,-40} -> FAILED: {1}" -f $target, $_) -ForegroundColor Red
        }
    }
}
