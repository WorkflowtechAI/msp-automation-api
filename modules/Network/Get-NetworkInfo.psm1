# Network Module
# API-ready network operations and diagnostics

Import-Module (Join-Path $PSScriptRoot "..\MSPAutomation.Core.psm1") -Force

<#
.SYNOPSIS
    Get DNS configuration and report for one or more computers.
.PARAMETER ComputerName
    Array of computer names to check
.PARAMETER IncludeDNSSuffixes
    Include DNS suffix search list
.EXAMPLE
    Get-DNSReport -ComputerName @("PC01", "PC02") -IncludeDNSSuffixes
.OUTPUTS
    ApiResponse object with DNS configuration data
#>
function Get-DNSReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [switch]$IncludeDNSSuffixes
    )

    return Invoke-AutomationOperation -OperationName "Get-DNSReport" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName      = $p.ComputerName
        $IncludeDNSSuffixes = $p.IncludeDNSSuffixes

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($computer in $ComputerName) {
            try {
                $dnsData = Invoke-Command -ComputerName $computer -ErrorAction Stop -ScriptBlock {
                    $adapters = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True"

                    $suffixList = @()
                    if ($using:IncludeDNSSuffixes) {
                        $suffixList = (Get-DnsClientGlobalSetting -ErrorAction SilentlyContinue).SuffixSearchList
                    }

                    $adapters | ForEach-Object {
                        @{
                            Description                    = $_.Description
                            Index                          = $_.Index
                            DNSServerSearchOrder           = $_.DNSServerSearchOrder -join ", "
                            DNSDomain                      = $_.DNSDomain
                            DNSDomainSuffixSearchOrder     = if ($using:IncludeDNSSuffixes) { $suffixList -join ", " } else { $null }
                            DHCPEnabled                    = $_.DHCPEnabled
                            DHCPServer                     = $_.DHCPServer
                            FullDNSRegistrationEnabled     = $_.FullDNSRegistrationEnabled
                            WINSPrimaryServer              = $_.WINSPrimaryServer
                            WINSSecondaryServer            = $_.WINSSecondaryServer
                        }
                    }
                }

                foreach ($adapter in $dnsData) {
                    $results.Add([PSCustomObject]@{
                        Computer                       = $computer
                        Description                    = $adapter.Description
                        Index                          = $adapter.Index
                        DNSServerSearchOrder           = $adapter.DNSServerSearchOrder
                        DNSDomain                      = $adapter.DNSDomain
                        DNSDomainSuffixSearchOrder     = $adapter.DNSDomainSuffixSearchOrder
                        DHCPEnabled                    = $adapter.DHCPEnabled
                        DHCPServer                     = $adapter.DHCPServer
                        FullDNSRegistrationEnabled     = $adapter.FullDNSRegistrationEnabled
                        WINSPrimaryServer              = $adapter.WINSPrimaryServer
                        WINSSecondaryServer            = $adapter.WINSSecondaryServer
                        ScanTime                       = (Get-Date).ToString("o")
                    })
                }

            } catch {
                $results.Add([PSCustomObject]@{
                    Computer  = $computer
                    Error     = $_.Exception.Message
                    ScanTime  = (Get-Date).ToString("o")
                })
            }
        }

        return New-SuccessResponse -Message "DNS report completed" -Data @{
            TotalComputers = $ComputerName.Count
            TotalAdapters  = $results.Count
            DNSData        = $results
        }
    } -Parameters @{
        ComputerName       = $ComputerName
        IncludeDNSSuffixes = [bool]$IncludeDNSSuffixes
    } -EnableObservability
}

<#
.SYNOPSIS
    Perform ping sweep across a network range (max /24 subnet).
.PARAMETER NetworkRange
    Network range in CIDR notation. Maximum supported prefix length is /23 (510 hosts).
.PARAMETER TimeoutMilliseconds
    Timeout for each ping in milliseconds (default: 1000). Compatible with PS5 and PS7.
.PARAMETER MaxConcurrent
    Maximum concurrent ping jobs (default: 50).
.EXAMPLE
    Invoke-PingSweep -NetworkRange "192.168.1.0/24" -TimeoutMilliseconds 500
.OUTPUTS
    ApiResponse object with ping sweep results
#>
function Invoke-PingSweep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$')]
        [string]$NetworkRange,

        [ValidateRange(100, 10000)]
        [int]$TimeoutMilliseconds = 1000,

        [ValidateRange(1, 100)]
        [int]$MaxConcurrent = 50
    )

    return Invoke-AutomationOperation -OperationName "Invoke-PingSweep" -ScriptBlock {
        param([hashtable]$p)

        $NetworkRange        = $p.NetworkRange
        $TimeoutMilliseconds = $p.TimeoutMilliseconds
        $MaxConcurrent       = $p.MaxConcurrent

        $cidrParts    = $NetworkRange.Split('/')
        $networkAddr  = $cidrParts[0]
        $prefixLength = [int]$cidrParts[1]

        if ($prefixLength -lt 23) {
            return New-ErrorResponse -Message "Network range too large. Minimum prefix length is /23." `
                -ErrorCode "VALIDATION_ERROR" -Data @{
                    NetworkRange    = $NetworkRange
                    MaxSupportedBits = 23
                }
        }

        $baseIP    = [System.Net.IPAddress]::Parse($networkAddr)
        $hostBits  = 32 - $prefixLength
        $numHosts  = [Math]::Pow(2, $hostBits)

        # Convert base IP to integer (big-endian)
        $ipBytes = $baseIP.GetAddressBytes()
        [Array]::Reverse($ipBytes)
        $baseInt = [BitConverter]::ToUInt32($ipBytes, 0)

        # Build IP list (skip network and broadcast addresses)
        $ips = for ($i = 1; $i -lt ($numHosts - 1); $i++) {
            $newInt   = $baseInt + $i
            $newBytes = [BitConverter]::GetBytes([uint32]$newInt)
            [Array]::Reverse($newBytes)
            [System.Net.IPAddress]::new($newBytes).IPAddressToString
        }

        $results    = [System.Collections.Generic.List[PSCustomObject]]::new()
        $onlineHosts = 0

        # Throttled parallel ping using runspaces for compatibility with PS5+
        $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $MaxConcurrent)
        $runspacePool.Open()
        $jobs = [System.Collections.Generic.List[hashtable]]::new()

        $pingScript = {
            param($ip, $timeoutMs)
            $ping   = New-Object System.Net.NetworkInformation.Ping
            $reply  = $ping.Send($ip, $timeoutMs)
            $ping.Dispose()
            @{
                IPAddress      = $ip
                Online         = ($reply.Status -eq "Success")
                ResponseTimeMS = if ($reply.Status -eq "Success") { $reply.RoundtripTime } else { $null }
            }
        }

        foreach ($ip in $ips) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            $null = $ps.AddScript($pingScript).AddArgument($ip).AddArgument($TimeoutMilliseconds)
            $jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }

        foreach ($job in $jobs) {
            try {
                $result = $job.PS.EndInvoke($job.Handle)
                if ($result.Online) { $onlineHosts++ }
                $results.Add([PSCustomObject]@{
                    IPAddress      = $result.IPAddress
                    Online         = $result.Online
                    ResponseTimeMS = $result.ResponseTimeMS
                    ScanTime       = (Get-Date).ToString("o")
                })
            } catch {
                $results.Add([PSCustomObject]@{
                    IPAddress = "Unknown"
                    Online    = $false
                    Error     = $_.Exception.Message
                    ScanTime  = (Get-Date).ToString("o")
                })
            } finally {
                $job.PS.Dispose()
            }
        }

        $runspacePool.Close()
        $runspacePool.Dispose()

        return New-SuccessResponse -Message "Ping sweep completed" -Data @{
            NetworkRange  = $NetworkRange
            TotalHosts    = $ips.Count
            OnlineHosts   = $onlineHosts
            OfflineHosts  = $ips.Count - $onlineHosts
            SweepResults  = ($results | Sort-Object IPAddress)
        }
    } -Parameters @{
        NetworkRange        = $NetworkRange
        TimeoutMilliseconds = $TimeoutMilliseconds
        MaxConcurrent       = $MaxConcurrent
    } -EnableObservability
}

<#
.SYNOPSIS
    Test network connectivity (ping, DNS, TCP ports) from a computer to multiple endpoints.
.PARAMETER ComputerName
    Source computer to test from
.PARAMETER TargetEndpoints
    Array of target endpoints (IP addresses or hostnames)
.PARAMETER TestPorts
    Array of TCP ports to test connectivity
.PARAMETER PortTimeoutSeconds
    Timeout for port connection tests (default: 2)
.EXAMPLE
    Test-NetworkConnectivity -ComputerName "PC01" -TargetEndpoints @("google.com", "8.8.8.8") -TestPorts @(443, 53)
.OUTPUTS
    ApiResponse object with connectivity test results
#>
function Test-NetworkConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [string[]]$TargetEndpoints,

        [int[]]$TestPorts = @(),

        [ValidateRange(1, 30)]
        [int]$PortTimeoutSeconds = 2
    )

    return Invoke-AutomationOperation -OperationName "Test-NetworkConnectivity" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName      = $p.ComputerName
        $TargetEndpoints   = $p.TargetEndpoints
        $TestPorts         = $p.TestPorts
        $PortTimeoutSeconds = $p.PortTimeoutSeconds

        try {
            $connectivityResults = Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
                $results = @()

                foreach ($endpoint in $using:TargetEndpoints) {
                    # Ping test
                    $pingResult = Test-Connection -ComputerName $endpoint -Count 1 -Quiet -ErrorAction SilentlyContinue

                    # DNS resolution
                    $dnsResolved = $false
                    $dnsAddress  = $null
                    try {
                        $entry = [System.Net.Dns]::GetHostEntry($endpoint)
                        $dnsResolved = $true
                        $dnsAddress  = $entry.AddressList[0].IPAddressToString
                    } catch { }

                    # TCP port tests
                    $portResults = @()
                    foreach ($port in $using:TestPorts) {
                        $tcpClient = $null
                        try {
                            $tcpClient   = New-Object System.Net.Sockets.TcpClient
                            $connectTask = $tcpClient.ConnectAsync($endpoint, $port)
                            $completed   = $connectTask.Wait(
                                [TimeSpan]::FromSeconds($using:PortTimeoutSeconds))

                            if ($completed -and $tcpClient.Connected) {
                                $portResults += @{ Port = $port; Open = $true;  Error = $null }
                            } else {
                                $portResults += @{ Port = $port; Open = $false; Error = "Timeout" }
                            }
                        } catch {
                            $portResults += @{ Port = $port; Open = $false; Error = $_.Exception.InnerException.Message }
                        } finally {
                            if ($tcpClient) { $tcpClient.Dispose() }
                        }
                    }

                    $results += @{
                        Endpoint    = $endpoint
                        PingSuccess = $pingResult
                        DNSResolved = $dnsResolved
                        DNSAddress  = $dnsAddress
                        PortTests   = $portResults
                    }
                }

                return $results
            }

            $formattedResults = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($result in $connectivityResults) {
                $formattedResults.Add([PSCustomObject]@{
                    Computer  = $ComputerName
                    Endpoint  = $result.Endpoint
                    TestType  = "Ping"
                    Port      = $null
                    Success   = $result.PingSuccess
                    Error     = $null
                    TestTime  = (Get-Date).ToString("o")
                })

                $formattedResults.Add([PSCustomObject]@{
                    Computer         = $ComputerName
                    Endpoint         = $result.Endpoint
                    TestType         = "DNS"
                    Port             = $null
                    Success          = $result.DNSResolved
                    ResolvedAddress  = $result.DNSAddress
                    Error            = if (-not $result.DNSResolved) { "DNS resolution failed" } else { $null }
                    TestTime         = (Get-Date).ToString("o")
                })

                foreach ($portTest in $result.PortTests) {
                    $formattedResults.Add([PSCustomObject]@{
                        Computer = $ComputerName
                        Endpoint = $result.Endpoint
                        TestType = "Port"
                        Port     = $portTest.Port
                        Success  = $portTest.Open
                        Error    = $portTest.Error
                        TestTime = (Get-Date).ToString("o")
                    })
                }
            }

            return New-SuccessResponse -Message "Network connectivity test completed" -Data @{
                SourceComputer  = $ComputerName
                TotalEndpoints  = $TargetEndpoints.Count
                TotalTests      = $formattedResults.Count
                SuccessfulTests = ($formattedResults | Where-Object { $_.Success }).Count
                ConnectivityData = $formattedResults
            }

        } catch {
            return New-ErrorResponse -Message "Connectivity test failed: $($_.Exception.Message)" `
                -ErrorCode "CONNECTION_ERROR"
        }
    } -Parameters @{
        ComputerName       = $ComputerName
        TargetEndpoints    = $TargetEndpoints
        TestPorts          = $TestPorts
        PortTimeoutSeconds = $PortTimeoutSeconds
    } -EnableObservability
}

Export-ModuleMember -Function @(
    'Get-DNSReport',
    'Invoke-PingSweep',
    'Test-NetworkConnectivity'
)
