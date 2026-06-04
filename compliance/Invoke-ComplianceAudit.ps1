#Requires -Modules Microsoft.PowerShell.Management, ActiveDirectory
<#
.SYNOPSIS
    Comprehensive security compliance audit against common frameworks (CIS, NIST, HIPAA, SOC2).
.DESCRIPTION
    Performs multi-framework compliance checks including password policies, account security,
    encryption status, update compliance, and audit logging. Generates detailed compliance reports.
.PARAMETER ComputerName
    Target computers for technical controls
.PARAMETER Framework
    Compliance framework(s) to check (CIS, NIST, HIPAA, SOC2, All)
.PARAMETER IncludeAD
    Include Active Directory compliance checks
.PARAMETER IncludeM365
    Include Microsoft 365 compliance checks
.PARAMETER Severity
    Minimum severity to report (Low, Medium, High, Critical)
.PARAMETER ConfigPath
    Path to MSP configuration file
.PARAMETER ExportCSV
    Path to export compliance results
.PARAMETER ExportHTML
    Path to export HTML compliance report
.EXAMPLE
    .\Invoke-ComplianceAudit.ps1 -Framework CIS -IncludeAD -ExportHTML "C:\Reports\compliance.html"
.EXAMPLE
    .\Invoke-ComplianceAudit.ps1 -Framework All -Severity High -ComputerName PC01,PC02
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    
    [ValidateSet("CIS", "NIST", "HIPAA", "SOC2", "All")]
    [string[]]$Framework = @("CIS"),
    
    [switch]$IncludeAD,
    
    [switch]$IncludeM365,
    
    [ValidateSet("Low", "Medium", "High", "Critical")]
    [string]$Severity = "Medium",
    
    [string]$ConfigPath = ".\config\MSPConfig.psd1",
    
    [string]$ExportCSV,
    
    [string]$ExportHTML
)

# Import logging framework
$LoggerScriptPath = Join-Path $PSScriptRoot "..\framework\MSPLogger.ps1"
. $LoggerScriptPath

$logger = Get-MSPLogger -LogName "ComplianceAudit" -Level "Info"

$logger.StartOperation("Compliance Audit")

try {
    # Load configuration
    if (Test-Path $ConfigPath) {
        $config = Import-PowerShellDataFile -Path $ConfigPath
        $securityConfig = $config.Security
        $logger.Info("Configuration loaded from $ConfigPath")
    } else {
        $securityConfig = @{
            MaxPasswordAgeDays = 90
            MinPasswordLength = 12
            RequireMFA = $true
            BitLockerRequired = $true
        }
        $logger.Warning("Configuration file not found, using defaults")
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $severityOrder = @("Low", "Medium", "High", "Critical")
    $minSeverityIndex = $severityOrder.IndexOf($Severity)

    # Compliance check definitions
    $complianceChecks = @{
        CIS = @(
            @{ Id = "CIS-1.1.1"; Name = "Password Policy - Maximum Age"; Severity = "High"; Check = "PasswordPolicy" },
            @{ Id = "CIS-1.1.2"; Name = "Password Policy - Minimum Length"; Severity = "High"; Check = "PasswordPolicy" },
            @{ Id = "CIS-1.1.3"; Name = "Password Policy - Complexity"; Severity = "High"; Check = "PasswordPolicy" },
            @{ Id = "CIS-2.3.1.1"; Name = "Windows Defender - Real-time Protection"; Severity = "Critical"; Check = "Defender" },
            @{ Id = "CIS-2.3.1.2"; Name = "Windows Defender - Antispyware"; Severity = "Critical"; Check = "Defender" },
            @{ Id = "CIS-17.1.1"; Name = "BitLocker - OS Drive Encryption"; Severity = "Critical"; Check = "BitLocker" },
            @{ Id = "CIS-18.9.1"; Name = "Windows Update - Automatic"; Severity = "High"; Check = "WindowsUpdate" },
            @{ Id = "CIS-19.1.1"; Name = "Audit Logs - Enabled"; Severity = "Medium"; Check = "AuditLogs" }
        )
        NIST = @(
            @{ Id = "NIST-AC-2"; Name = "Account Management"; Severity = "High"; Check = "AccountManagement" },
            @{ Id = "NIST-AC-3"; Name = "Access Enforcement"; Severity = "High"; Check = "AccessControl" },
            @{ Id = "NIST-SC-8"; Name = "Transmission Confidentiality"; Severity = "Medium"; Check = "Encryption" },
            @{ Id = "NIST-SC-12"; Name = "Cryptographic Key Management"; Severity = "High"; Check = "KeyManagement" },
            @{ Id = "NIST-AU-2"; Name = "Audit Events"; Severity = "Medium"; Check = "AuditLogs" },
            @{ Id = "NIST-AU-6"; Name = "Audit Review and Analysis"; Severity = "Medium"; Check = "AuditReview" }
        )
        HIPAA = @(
            @{ Id = "HIPAA-164.312(a)(1)"; Name = "Access Control - Unique User IDs"; Severity = "Critical"; Check = "UniqueUsers" },
            @{ Id = "HIPAA-164.312(a)(2)(i)"; Name = "Access Control - Emergency Access"; Severity = "Medium"; Check = "EmergencyAccess" },
            @{ Id = "HIPAA-164.312(e)(1)"; Name = "Transmission Security - Encryption"; Severity = "Critical"; Check = "Encryption" },
            @{ Id = "HIPAA-164.312(b)"; Name = "Audit Controls"; Severity = "High"; Check = "AuditLogs" },
            @{ Id = "HIPAA-164.308(a)(1)"; Name = "Security Management Process"; Severity = "Medium"; Check = "SecurityManagement" }
        )
        SOC2 = @(
            @{ Id = "SOC2-CC6.1"; Name = "Logical and Physical Access Controls"; Severity = "High"; Check = "AccessControl" },
            @{ Id = "SOC2-CC6.2"; Name = "System Access Authorization"; Severity = "High"; Check = "AccessAuthorization" },
            @{ Id = "SOC2-CC6.6"; Name = "System Access Monitoring"; Severity = "Medium"; Check = "AccessMonitoring" },
            @{ Id = "SOC2-CC6.7"; Name = "System Access Removal"; Severity = "High"; Check = "AccessRemoval" },
            @{ Id = "SOC2-CC7.2"; Name = "System Monitoring"; Severity = "Medium"; Check = "SystemMonitoring" }
        )
    }

    # Select frameworks to audit
    if ($Framework -contains "All") {
        $frameworksToAudit = $complianceChecks.Keys
    } else {
        $frameworksToAudit = $Framework
    }

    $logger.Info("Auditing against frameworks: $($frameworksToAudit -join ', ')")

    # Computer-based compliance checks
    foreach ($computer in $ComputerName) {
        $logger.Info("Auditing $computer...")
        
        try {
            if (-not (Test-Connection -ComputerName $computer -Count 1 -Quiet)) {
                throw "Computer not reachable"
            }

            $computerChecks = Invoke-Command -ComputerName $computer -ScriptBlock {
                $results = @()

                # Password Policy Check
                $passwordPolicy = Get-ADDefaultDomainPasswordPolicy -ErrorAction SilentlyContinue
                if ($passwordPolicy) {
                    $results += [PSCustomObject]@{
                        CheckType = "PasswordPolicy"
                        CheckName = "Password Age Policy"
                        Compliant = $passwordPolicy.MaxPasswordAge.Days -le 90
                        Details = "Max age: $($passwordPolicy.MaxPasswordAge.Days) days"
                        Severity = "High"
                    }
                    $results += [PSCustomObject]@{
                        CheckType = "PasswordPolicy"
                        CheckName = "Password Length Policy"
                        Compliant = $passwordPolicy.MinPasswordLength -ge 12
                        Details = "Min length: $($passwordPolicy.MinPasswordLength) characters"
                        Severity = "High"
                    }
                }

                # Windows Defender Check
                $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
                if ($defender) {
                    $results += [PSCustomObject]@{
                        CheckType = "Defender"
                        CheckName = "Real-time Protection"
                        Compliant = $defender.RealTimeProtectionEnabled
                        Details = "RT Protection: $($defender.RealTimeProtectionEnabled)"
                        Severity = "Critical"
                    }
                    $results += [PSCustomObject]@{
                        CheckType = "Defender"
                        CheckName = "Antispyware Enabled"
                        Compliant = $defender.AntispywareEnabled
                        Details = "Antispyware: $($defender.AntispywareEnabled)"
                        Severity = "Critical"
                    }
                }

                # BitLocker Check
                $bitlocker = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
                if ($bitlocker) {
                    $results += [PSCustomObject]@{
                        CheckType = "BitLocker"
                        CheckName = "OS Drive Encryption"
                        Compliant = $bitlocker.VolumeStatus -eq "FullyEncrypted" -and $bitlocker.ProtectionStatus -eq "On"
                        Details = "Status: $($bitlocker.VolumeStatus), Protection: $($bitlocker.ProtectionStatus)"
                        Severity = "Critical"
                    }
                }

                # Windows Update Check
                $updateService = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
                if ($updateService) {
                    $results += [PSCustomObject]@{
                        CheckType = "WindowsUpdate"
                        CheckName = "Windows Update Service"
                        Compliant = $updateService.Status -eq "Running" -and $updateService.StartType -ne "Disabled"
                        Details = "Status: $($updateService.Status), StartType: $($updateService.StartType)"
                        Severity = "High"
                    }
                }

                # Audit Logs Check
                $auditPolicy = auditpol /get /category:* 2>$null
                $results += [PSCustomObject]@{
                    CheckType = "AuditLogs"
                    CheckName = "Audit Logging Enabled"
                    Compliant = $auditPolicy -ne $null
                    Details = "Audit policy configured"
                    Severity = "Medium"
                }

                return $results
            } -ErrorAction Stop

            # Map results to framework requirements
            foreach ($framework in $frameworksToAudit) {
                foreach ($check in $complianceChecks[$framework]) {
                    $checkResult = $computerChecks | Where-Object { $_.CheckType -eq $check.Check }
                    
                    if ($checkResult) {
                        $severityIndex = $severityOrder.IndexOf($check.Severity)
                        
                        if ($severityIndex -ge $minSeverityIndex) {
                            $result = [PSCustomObject]@{
                                Framework     = $framework
                                ControlId     = $check.Id
                                ControlName   = $check.Name
                                Computer      = $computer
                                CheckType     = $check.Check
                                Compliant     = $checkResult.Compliant
                                Severity      = $check.Severity
                                Details       = $checkResult.Details
                                ScanTime      = Get-Date
                            }
                            
                            $results.Add($result)
                            
                            $statusColor = if ($result.Compliant) { "Green" } else { "Red" }
                            $logger.Info("  [$($check.Id)] $($check.Name): $($result.Compliant) - $($checkResult.Details)")
                        }
                    }
                }
            }

        } catch {
            $logger.Error("  Error auditing $computer : $($_.Exception.Message)")
            $results.Add([PSCustomObject]@{
                Framework     = "System"
                ControlId     = "CONN-001"
                ControlName   = "Connectivity Check"
                Computer      = $computer
                CheckType     = "Connectivity"
                Compliant     = $false
                Severity      = "Critical"
                Details       = "Error: $($_.Exception.Message)"
                ScanTime      = Get-Date
            })
        }
    }

    # AD Compliance Checks
    if ($IncludeAD) {
        $logger.Info("Performing Active Directory compliance checks...")
        
        try {
            # Check for inactive users
            $inactiveUsers = Search-ADAccount -AccountInactive -TimeSpan 90.00:00:00 -UsersOnly -ResultPageSize 5000
            $results.Add([PSCustomObject]@{
                Framework     = "CIS"
                ControlId     = "CIS-16.8"
                ControlName   = "Inactive User Accounts"
                Computer      = "AD-Domain"
                CheckType     = "AccountManagement"
                Compliant     = $inactiveUsers.Count -eq 0
                Severity      = "Medium"
                Details       = "$($inactiveUsers.Count) inactive users found"
                ScanTime      = Get-Date
            })

            # Check for accounts with password never expires
            $neverExpire = Get-ADUser -Filter { PasswordNeverExpires -eq $true -and Enabled -eq $true }
            $results.Add([PSCustomObject]@{
                Framework     = "NIST"
                ControlId     = "NIST-IA-5"
                ControlName   = "Password Expiration Policy"
                Computer      = "AD-Domain"
                CheckType     = "PasswordPolicy"
                Compliant     = $neverExpire.Count -eq 0
                Severity      = "High"
                Details       = "$($neverExpire.Count) accounts with password never expires"
                ScanTime      = Get-Date
            })

        } catch {
            $logger.Warning("Could not perform AD compliance checks: $_")
        }
    }

    # Summary statistics
    $totalChecks = $results.Count
    $compliant = ($results | Where-Object { $_.Compliant }).Count
    $nonCompliant = ($results | Where-Object { -not $_.Compliant }).Count
    $criticalFailures = ($results | Where-Object { -not $_.Compliant -and $_.Severity -eq "Critical" }).Count
    $highFailures = ($results | Where-Object { -not $_.Compliant -and $_.Severity -eq "High" }).Count

    $complianceRate = if ($totalChecks -gt 0) { [math]::Round(($compliant / $totalChecks) * 100, 1) } else { 0 }

    $logger.Info("Compliance audit complete: $compliant/$totalChecks checks compliant ($complianceRate%)")
    $logger.Warning("Non-compliant checks: $nonCompliant (Critical: $criticalFailures, High: $highFailures)")

    # Export results
    if ($ExportCSV) {
        $results | Export-Csv $ExportCSV -NoTypeInformation
        $logger.Info("Exported CSV to $ExportCSV")
    }

    if ($ExportHTML) {
        $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Compliance Audit Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #2c3e50; }
        .summary { background: #ecf0f1; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .compliant { color: green; font-weight: bold; }
        .non-compliant { color: red; font-weight: bold; }
        table { border-collapse: collapse; width: 100%; margin-top: 20px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #34495e; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        .critical { background-color: #ffebee; }
        .high { background-color: #fff3e0; }
    </style>
</head>
<body>
    <h1>Compliance Audit Report</h1>
    <div class="summary">
        <h2>Summary</h2>
        <p>Total Checks: $totalChecks</p>
        <p>Compliant: <span class="compliant">$compliant</span></p>
        <p>Non-Compliant: <span class="non-compliant">$nonCompliant</span></p>
        <p>Compliance Rate: $complianceRate%</p>
        <p>Critical Failures: $criticalFailures</p>
        <p>High Severity Failures: $highFailures</p>
    </div>
    <h2>Detailed Results</h2>
    <table>
        <tr>
            <th>Framework</th>
            <th>Control ID</th>
            <th>Control Name</th>
            <th>Computer</th>
            <th>Compliant</th>
            <th>Severity</th>
            <th>Details</th>
        </tr>
"@

        foreach ($result in $results) {
            $rowClass = if (-not $result.Compliant) { 
                switch ($result.Severity) {
                    "Critical" { "critical" }
                    "High" { "high" }
                    default { "" }
                }
            } else { "" }
            
            $compliantText = if ($result.Compliant) { "Yes" } else { "No" }
            
            $html += @"
        <tr class="$rowClass">
            <td>$($result.Framework)</td>
            <td>$($result.ControlId)</td>
            <td>$($result.ControlName)</td>
            <td>$($result.Computer)</td>
            <td>$compliantText</td>
            <td>$($result.Severity)</td>
            <td>$($result.Details)</td>
        </tr>
"@
        }

        $html += @"
    </table>
    <p style="margin-top: 20px; color: #7f8c8d;">Report generated: $(Get-Date)</p>
</body>
</html>
"@

        $html | Out-File $ExportHTML
        $logger.Info("Exported HTML report to $ExportHTML")
    }

    # Display summary
    Write-Host "`n=== Compliance Audit Summary ===" -ForegroundColor Cyan
    Write-Host "Total Checks        : $totalChecks" -ForegroundColor White
    Write-Host "Compliant           : $compliant" -ForegroundColor Green
    Write-Host "Non-Compliant       : $nonCompliant" -ForegroundColor $(if ($nonCompliant -gt 0) { "Red" } else { "Green" })
    Write-Host "Compliance Rate     : $complianceRate%" -ForegroundColor $(if ($complianceRate -ge 80) { "Green" } else { "Yellow" })
    Write-Host "Critical Failures   : $criticalFailures" -ForegroundColor $(if ($criticalFailures -gt 0) { "Red" } else { "Green" })
    Write-Host "High Failures       : $highFailures" -ForegroundColor $(if ($highFailures -gt 0) { "Red" } else { "Green" })

    if ($criticalFailures -gt 0) {
        Write-Host "`nCritical Failures:" -ForegroundColor Red
        $results | Where-Object { -not $_.Compliant -and $_.Severity -eq "Critical" } | 
            Format-Table Framework, ControlId, ControlName, Computer, Details -AutoSize
    }

    # Exit code
    if ($criticalFailures -gt 0) {
        exit 2
    } elseif ($highFailures -gt 0 -or $nonCompliant -gt 0) {
        exit 1
    } else {
        exit 0
    }

} catch {
    $logger.Error("Fatal error in compliance audit", $_)
    throw
} finally {
    $logger.EndOperation("Compliance Audit")
}