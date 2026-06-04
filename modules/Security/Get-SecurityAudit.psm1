# Security Audit Module
# API-ready security operations and compliance checks

Import-Module (Join-Path $PSScriptRoot "..\MSPAutomation.Core.psm1") -Force

<#
.SYNOPSIS
    Get failed login attempts for security auditing.
.PARAMETER ComputerName
    Array of computer names to check
.PARAMETER HoursBack
    Number of hours back to search for failed logins (default: 24)
.PARAMETER MaxResults
    Maximum number of failed login attempts to return per computer (default: 50)
.EXAMPLE
    Get-FailedLogins -ComputerName @("DC01", "DC02") -HoursBack 48
.OUTPUTS
    ApiResponse object with failed login data
#>
function Get-FailedLogins {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [ValidateRange(1, 720)]
        [int]$HoursBack = 24,

        [ValidateRange(1, 1000)]
        [int]$MaxResults = 50
    )

    return Invoke-AutomationOperation -OperationName "Get-FailedLogins" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName = $p.ComputerName
        $HoursBack    = $p.HoursBack
        $MaxResults   = $p.MaxResults

        $results    = [System.Collections.Generic.List[PSCustomObject]]::new()
        $cutoffTime = (Get-Date).AddHours(-$HoursBack)

        foreach ($computer in $ComputerName) {
            try {
                $failedLogins = Invoke-Command -ComputerName $computer -ErrorAction Stop -ScriptBlock {
                    $events = Get-WinEvent -FilterHashtable @{
                        LogName   = 'Security'
                        Id        = 4625
                        StartTime = $using:cutoffTime
                    } -MaxEvents $using:MaxResults -ErrorAction SilentlyContinue

                    if ($events) {
                        $events | ForEach-Object {
                            @{
                                TimeStamp     = $_.TimeCreated.ToString("o")
                                UserName      = $_.Properties[5].Value
                                Domain        = $_.Properties[6].Value
                                Workstation   = $_.Properties[13].Value
                                IPAddress     = $_.Properties[19].Value
                                Status        = $_.Properties[8].Value
                                FailureReason = $_.Properties[10].Value
                            }
                        }
                    } else { @() }
                }

                foreach ($login in $failedLogins) {
                    $results.Add([PSCustomObject]@{
                        Computer      = $computer
                        TimeStamp     = $login.TimeStamp
                        UserName      = $login.UserName
                        Domain        = $login.Domain
                        Workstation   = $login.Workstation
                        IPAddress     = $login.IPAddress
                        Status        = $login.Status
                        FailureReason = $login.FailureReason
                    })
                }

            } catch {
                $results.Add([PSCustomObject]@{
                    Computer  = $computer
                    Error     = $_.Exception.Message
                    CheckTime = (Get-Date).ToString("o")
                })
            }
        }

        # Group by username to surface brute-force candidates
        $attackSummary = $results |
            Where-Object { $_.UserName } |
            Group-Object UserName |
            Where-Object { $_.Count -ge 5 } |
            ForEach-Object { [PSCustomObject]@{ UserName = $_.Name; AttemptCount = $_.Count } } |
            Sort-Object AttemptCount -Descending

        return New-SuccessResponse -Message "Failed login audit completed" -Data @{
            TotalComputers    = $ComputerName.Count
            HoursSearched     = $HoursBack
            TotalFailedLogins = $results.Count
            SuspectedBruteForce = $attackSummary
            FailedLoginData   = $results
        }
    } -Parameters @{
        ComputerName = $ComputerName
        HoursBack    = $HoursBack
        MaxResults   = $MaxResults
    } -EnableObservability
}

<#
.SYNOPSIS
    Get local administrator group membership for security auditing.
.PARAMETER ComputerName
    Array of computer names to check
.PARAMETER IncludeDomainAdmins
    Include domain admin group membership check
.EXAMPLE
    Get-LocalAdminAudit -ComputerName @("PC01", "PC02") -IncludeDomainAdmins
.OUTPUTS
    ApiResponse object with local admin audit data
#>
function Get-LocalAdminAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [switch]$IncludeDomainAdmins
    )

    return Invoke-AutomationOperation -OperationName "Get-LocalAdminAudit" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName       = $p.ComputerName
        $IncludeDomainAdmins = $p.IncludeDomainAdmins

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($computer in $ComputerName) {
            try {
                $adminData = Invoke-Command -ComputerName $computer -ErrorAction Stop -ScriptBlock {
                    $localAdmins = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue |
                        ForEach-Object {
                            @{
                                Name            = $_.Name
                                PrincipalSource = $_.PrincipalSource.ToString()
                                SID             = $_.SID.Value
                            }
                        }

                    $domainAdminNames = @()
                    if ($using:IncludeDomainAdmins) {
                        try {
                            $domainAdmins     = Get-ADGroupMember "Domain Admins" -ErrorAction Stop
                            $domainAdminNames = @($domainAdmins | ForEach-Object { $_.SamAccountName })
                        } catch {
                            $domainAdminNames = @("Error: $($_.Exception.Message)")
                        }
                    }

                    @{
                        LocalAdmins      = $localAdmins
                        DomainAdminNames = $domainAdminNames
                    }
                }

                foreach ($admin in $adminData.LocalAdmins) {
                    # Extract the SAM account name from "DOMAIN\Username" format
                    $samName    = ($admin.Name -split '\\' | Select-Object -Last 1)
                    $isDomainAdmin = if ($IncludeDomainAdmins -and $adminData.DomainAdminNames.Count -gt 0) {
                        $samName -in $adminData.DomainAdminNames
                    } else { $null }

                    $results.Add([PSCustomObject]@{
                        Computer        = $computer
                        AdminName       = $admin.Name
                        PrincipalSource = $admin.PrincipalSource
                        SID             = $admin.SID
                        IsDomainAdmin   = $isDomainAdmin
                        AuditTime       = (Get-Date).ToString("o")
                    })
                }

            } catch {
                $results.Add([PSCustomObject]@{
                    Computer  = $computer
                    Error     = $_.Exception.Message
                    AuditTime = (Get-Date).ToString("o")
                })
            }
        }

        return New-SuccessResponse -Message "Local admin audit completed" -Data @{
            TotalComputers    = $ComputerName.Count
            TotalAdminEntries = $results.Count
            AuditData         = $results
        }
    } -Parameters @{
        ComputerName        = $ComputerName
        IncludeDomainAdmins = [bool]$IncludeDomainAdmins
    } -EnableObservability
}

<#
.SYNOPSIS
    Get open network ports for security auditing.
.PARAMETER ComputerName
    Array of computer names to check
.PARAMETER IncludeUDP
    Include UDP ports in addition to TCP
.PARAMETER WellKnownOnly
    Only show well-known ports (0-1023)
.EXAMPLE
    Get-OpenPorts -ComputerName @("SRV01", "SRV02") -IncludeUDP
.OUTPUTS
    ApiResponse object with open port data
#>
function Get-OpenPorts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [switch]$IncludeUDP,

        [switch]$WellKnownOnly
    )

    return Invoke-AutomationOperation -OperationName "Get-OpenPorts" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName  = $p.ComputerName
        $IncludeUDP    = $p.IncludeUDP
        $WellKnownOnly = $p.WellKnownOnly

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($computer in $ComputerName) {
            try {
                $ports = Invoke-Command -ComputerName $computer -ErrorAction Stop -ScriptBlock {
                    $tcpConnections = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue

                    $udpEndpoints = @()
                    if ($using:IncludeUDP) {
                        $udpEndpoints = Get-NetUDPEndpoint -ErrorAction SilentlyContinue
                    }

                    # Build process lookup table once to avoid per-port Get-Process calls
                    $processByPid = @{}
                    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
                        $processByPid[$_.Id] = $_.ProcessName
                    }

                    $allPorts = @()

                    foreach ($conn in $tcpConnections) {
                        if ($using:WellKnownOnly -and $conn.LocalPort -gt 1023) { continue }
                        $allPorts += @{
                            Protocol      = "TCP"
                            LocalAddress  = $conn.LocalAddress
                            LocalPort     = $conn.LocalPort
                            RemoteAddress = $conn.RemoteAddress
                            RemotePort    = $conn.RemotePort
                            State         = $conn.State.ToString()
                            OwningProcess = $conn.OwningProcess
                            ProcessName   = if ($processByPid.ContainsKey($conn.OwningProcess)) {
                                $processByPid[$conn.OwningProcess]
                            } else { "Unknown" }
                        }
                    }

                    foreach ($ep in $udpEndpoints) {
                        if ($using:WellKnownOnly -and $ep.LocalPort -gt 1023) { continue }
                        $allPorts += @{
                            Protocol      = "UDP"
                            LocalAddress  = $ep.LocalAddress
                            LocalPort     = $ep.LocalPort
                            RemoteAddress = "*"
                            RemotePort    = "*"
                            State         = "Listening"
                            OwningProcess = $ep.OwningProcess
                            ProcessName   = if ($processByPid.ContainsKey($ep.OwningProcess)) {
                                $processByPid[$ep.OwningProcess]
                            } else { "Unknown" }
                        }
                    }

                    return $allPorts
                }

                foreach ($port in $ports) {
                    $results.Add([PSCustomObject]@{
                        Computer      = $computer
                        Protocol      = $port.Protocol
                        LocalAddress  = $port.LocalAddress
                        LocalPort     = $port.LocalPort
                        RemoteAddress = $port.RemoteAddress
                        RemotePort    = $port.RemotePort
                        State         = $port.State
                        ProcessName   = $port.ProcessName
                        ProcessID     = $port.OwningProcess
                        IsWellKnown   = $port.LocalPort -le 1023
                        ScanTime      = (Get-Date).ToString("o")
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

        return New-SuccessResponse -Message "Open port scan completed" -Data @{
            TotalComputers = $ComputerName.Count
            TotalOpenPorts = $results.Count
            PortData       = $results
        }
    } -Parameters @{
        ComputerName   = $ComputerName
        IncludeUDP     = [bool]$IncludeUDP
        WellKnownOnly  = [bool]$WellKnownOnly
    } -EnableObservability
}

<#
.SYNOPSIS
    Enhanced BitLocker status with compliance checking and optional remediation.
.PARAMETER ComputerName
    Array of computer names to check
.PARAMETER Remediate
    Attempt to enable BitLocker on unprotected, fully-decrypted fixed drives
.EXAMPLE
    Get-BitLockerStatus -ComputerName @("PC01", "PC02") -Remediate
.OUTPUTS
    ApiResponse object with BitLocker status and compliance data
#>
function Get-BitLockerStatus {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [switch]$Remediate
    )

    return Invoke-AutomationOperation -OperationName "Get-BitLockerStatus" -ScriptBlock {
        param([hashtable]$p)

        $ComputerName = $p.ComputerName
        $Remediate    = $p.Remediate

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($computer in $ComputerName) {
            try {
                $bitlockerData = Invoke-Command -ComputerName $computer -ErrorAction Stop -ScriptBlock {
                    $volumes = Get-BitLockerVolume -ErrorAction SilentlyContinue
                    if (-not $volumes) { return @() }

                    foreach ($volume in $volumes) {
                        $compliant        = $volume.ProtectionStatus -eq "On"
                        $remediationResult = $null

                        if ($using:Remediate -and -not $compliant -and
                            $volume.VolumeStatus -eq "FullyDecrypted") {
                            try {
                                Enable-BitLocker -MountPoint $volume.MountPoint `
                                    -UsedSpaceOnly -SkipHardwareTest `
                                    -RecoveryPasswordProtector -ErrorAction Stop
                                $remediationResult = "Success"
                            } catch {
                                $remediationResult = "Failed: $($_.Exception.Message)"
                            }
                        }

                        @{
                            MountPoint          = $volume.MountPoint
                            Status              = if ($compliant) { "PROTECTED" } else { "UNPROTECTED" }
                            Compliant           = $compliant
                            VolumeStatus        = $volume.VolumeStatus.ToString()
                            EncryptionPercentage = $volume.EncryptionPercentage
                            ProtectionStatus    = $volume.ProtectionStatus.ToString()
                            EncryptionMethod    = $volume.EncryptionMethod.ToString()
                            KeyProtectors       = ($volume.KeyProtector | ForEach-Object {
                                $_.KeyProtectorType.ToString()
                            }) -join ", "
                            RemediationResult   = $remediationResult
                        }
                    }
                }

                foreach ($volume in $bitlockerData) {
                    $results.Add([PSCustomObject]@{
                        Computer            = $computer
                        MountPoint          = $volume.MountPoint
                        Status              = $volume.Status
                        Compliant           = $volume.Compliant
                        VolumeStatus        = $volume.VolumeStatus
                        EncryptionPercentage = $volume.EncryptionPercentage
                        ProtectionStatus    = $volume.ProtectionStatus
                        EncryptionMethod    = $volume.EncryptionMethod
                        KeyProtectors       = $volume.KeyProtectors
                        RemediationResult   = $volume.RemediationResult
                        CheckTime           = (Get-Date).ToString("o")
                    })
                }

            } catch {
                $results.Add([PSCustomObject]@{
                    Computer  = $computer
                    Error     = $_.Exception.Message
                    CheckTime = (Get-Date).ToString("o")
                })
            }
        }

        $compliantCount    = ($results | Where-Object { $_.Compliant -eq $true }).Count
        $nonCompliantCount = ($results | Where-Object { $_.Compliant -eq $false -and -not $_.Error }).Count

        return New-SuccessResponse -Message "BitLocker status check completed" -Data @{
            TotalComputers     = $ComputerName.Count
            TotalVolumes       = $results.Count
            CompliantVolumes   = $compliantCount
            NonCompliantVolumes = $nonCompliantCount
            ComplianceRate     = if ($results.Count -gt 0) {
                [math]::Round(($compliantCount / $results.Count) * 100, 1)
            } else { 0 }
            BitLockerData      = $results
        }
    } -Parameters @{
        ComputerName = $ComputerName
        Remediate    = [bool]$Remediate
    } -EnableObservability
}

Export-ModuleMember -Function @(
    'Get-FailedLogins',
    'Get-LocalAdminAudit',
    'Get-OpenPorts',
    'Get-BitLockerStatus'
)
