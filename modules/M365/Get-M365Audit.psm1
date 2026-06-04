# M365 Module
# API-ready Microsoft 365 operations and audits

Import-Module (Join-Path $PSScriptRoot "..\MSPAutomation.Core.psm1") -Force

<#
.SYNOPSIS
    Get M365 license audit and utilization report.
.PARAMETER ExportCSV
    Path to export results to CSV
.PARAMETER EnabledOnly
    Only include enabled accounts
.EXAMPLE
    Get-M365LicenseAudit -EnabledOnly -ExportCSV "C:\Reports\m365-licenses.csv"
.OUTPUTS
    ApiResponse object with M365 license data
#>
function Get-M365LicenseAudit {
    [CmdletBinding()]
    param(
        [string]$ExportCSV,
        [switch]$EnabledOnly
    )

    return Invoke-AutomationOperation -OperationName "Get-M365LicenseAudit" -ScriptBlock {
        param([hashtable]$p)

        $ExportCSV   = $p.ExportCSV
        $EnabledOnly = $p.EnabledOnly

        try {
            if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
                return New-ErrorResponse -Message "Microsoft.Graph.Users module is required" `
                    -ErrorCode "DEPENDENCY_ERROR"
            }

            $context = Get-MgContext -ErrorAction SilentlyContinue
            if (-not $context) {
                return New-ErrorResponse -Message "Not connected to Microsoft Graph. Run Connect-MgGraph first." `
                    -ErrorCode "AUTHORIZATION_ERROR"
            }

            Import-Module Microsoft.Graph.Users -ErrorAction Stop

            $results = [System.Collections.Generic.List[PSCustomObject]]::new()

            $users = Get-MgUser -All `
                -Property DisplayName, UserPrincipalName, AccountEnabled, AssignedLicenses, Department, JobTitle `
                -ErrorAction Stop |
                Where-Object { -not $EnabledOnly -or $_.AccountEnabled }

            foreach ($user in $users) {
                $licenseSkuIds = @($user.AssignedLicenses | ForEach-Object { $_.SkuId.ToString() })

                $results.Add([PSCustomObject]@{
                    DisplayName       = $user.DisplayName
                    UserPrincipalName = $user.UserPrincipalName
                    Department        = $user.Department
                    Title             = $user.JobTitle
                    Enabled           = $user.AccountEnabled
                    AssignedLicenses  = $licenseSkuIds.Count
                    LicenseSkus       = $licenseSkuIds -join ", "
                    AuditTime         = (Get-Date).ToString("o")
                })
            }

            if ($ExportCSV) {
                $results | Export-Csv $ExportCSV -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            }

            return New-SuccessResponse -Message "M365 license audit completed" -Data @{
                TotalUsers       = $results.Count
                LicensedUsers    = ($results | Where-Object { $_.AssignedLicenses -gt 0 }).Count
                UnlicensedUsers  = ($results | Where-Object { $_.AssignedLicenses -eq 0 }).Count
                LicenseData      = $results
            }

        } catch {
            return New-ErrorResponse -Message "M365 license audit failed: $($_.Exception.Message)" `
                -ErrorCode "EXTERNAL_SERVICE_ERROR"
        }
    } -Parameters @{
        ExportCSV   = $ExportCSV
        EnabledOnly = [bool]$EnabledOnly
    } -EnableObservability
}

<#
.SYNOPSIS
    Get MFA status report for M365 users.
.PARAMETER EnabledOnly
    Only include enabled accounts
.PARAMETER ExportCSV
    Path to export results to CSV
.EXAMPLE
    Get-MFAStatusReport -EnabledOnly -ExportCSV "C:\Reports\mfa-status.csv"
.OUTPUTS
    ApiResponse object with MFA status data
#>
function Get-MFAStatusReport {
    [CmdletBinding()]
    param(
        [switch]$EnabledOnly,
        [string]$ExportCSV
    )

    return Invoke-AutomationOperation -OperationName "Get-MFAStatusReport" -ScriptBlock {
        param([hashtable]$p)

        $EnabledOnly = $p.EnabledOnly
        $ExportCSV   = $p.ExportCSV

        try {
            if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
                return New-ErrorResponse -Message "Microsoft.Graph.Users module is required" `
                    -ErrorCode "DEPENDENCY_ERROR"
            }

            $context = Get-MgContext -ErrorAction SilentlyContinue
            if (-not $context) {
                return New-ErrorResponse -Message "Not connected to Microsoft Graph. Run Connect-MgGraph first." `
                    -ErrorCode "AUTHORIZATION_ERROR"
            }

            Import-Module Microsoft.Graph.Users -ErrorAction Stop

            $results = [System.Collections.Generic.List[PSCustomObject]]::new()

            $users = Get-MgUser -All `
                -Property Id, DisplayName, UserPrincipalName, AccountEnabled, Department, JobTitle `
                -ErrorAction Stop |
                Where-Object { -not $EnabledOnly -or $_.AccountEnabled }

            foreach ($user in $users) {
                try {
                    $methods     = Get-MgUserAuthenticationMethod -UserId $user.Id -ErrorAction SilentlyContinue
                    $methodTypes = @($methods | ForEach-Object {
                        $_.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.', ''
                    })

                    # Any method beyond password = MFA registered
                    $mfaMethods = @($methodTypes | Where-Object { $_ -ne 'passwordAuthenticationMethod' })
                    $hasMFA     = $mfaMethods.Count -gt 0

                    $results.Add([PSCustomObject]@{
                        DisplayName       = $user.DisplayName
                        UserPrincipalName = $user.UserPrincipalName
                        Department        = $user.Department
                        Title             = $user.JobTitle
                        Enabled           = $user.AccountEnabled
                        MFAEnabled        = $hasMFA
                        MFAMethodCount    = $mfaMethods.Count
                        Methods           = ($methodTypes | Sort-Object -Unique) -join ", "
                        AuditTime         = (Get-Date).ToString("o")
                    })
                } catch {
                    $results.Add([PSCustomObject]@{
                        DisplayName       = $user.DisplayName
                        UserPrincipalName = $user.UserPrincipalName
                        Department        = $user.Department
                        Title             = $user.JobTitle
                        Enabled           = $user.AccountEnabled
                        MFAEnabled        = $null
                        MFAMethodCount    = $null
                        Methods           = "Error: $($_.Exception.Message)"
                        AuditTime         = (Get-Date).ToString("o")
                    })
                }
            }

            if ($ExportCSV) {
                $results | Export-Csv $ExportCSV -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            }

            $noMFA = $results | Where-Object { $_.MFAEnabled -eq $false -and $_.Enabled }

            return New-SuccessResponse -Message "MFA status report completed" -Data @{
                TotalUsers  = $results.Count
                MFAEnabled  = ($results | Where-Object { $_.MFAEnabled -eq $true }).Count
                MFADisabled = $noMFA.Count
                MFAUnknown  = ($results | Where-Object { $null -eq $_.MFAEnabled }).Count
                MFAData     = $results
            }

        } catch {
            return New-ErrorResponse -Message "MFA status report failed: $($_.Exception.Message)" `
                -ErrorCode "EXTERNAL_SERVICE_ERROR"
        }
    } -Parameters @{
        EnabledOnly = [bool]$EnabledOnly
        ExportCSV   = $ExportCSV
    } -EnableObservability
}

<#
.SYNOPSIS
    Get shared mailbox access report (FullAccess and SendAs permissions).
.PARAMETER ExportCSV
    Path to export results to CSV
.NOTES
    Requires ExchangeOnlineManagement v3+. Uses Get-ConnectionInformation instead of
    Get-PSSession for connection detection (REST-based EXO v3 does not create PSSessions).
.EXAMPLE
    Get-SharedMailboxAccess -ExportCSV "C:\Reports\shared-mailbox-access.csv"
.OUTPUTS
    ApiResponse object with shared mailbox access data
#>
function Get-SharedMailboxAccess {
    [CmdletBinding()]
    param(
        [string]$ExportCSV
    )

    return Invoke-AutomationOperation -OperationName "Get-SharedMailboxAccess" -ScriptBlock {
        param([hashtable]$p)

        $ExportCSV = $p.ExportCSV

        try {
            if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
                return New-ErrorResponse -Message "ExchangeOnlineManagement module is required" `
                    -ErrorCode "DEPENDENCY_ERROR"
            }

            # EXO v3+ uses REST; check via Get-ConnectionInformation, not Get-PSSession
            $connectionInfo = $null
            if (Get-Command Get-ConnectionInformation -ErrorAction SilentlyContinue) {
                $connectionInfo = Get-ConnectionInformation -ErrorAction SilentlyContinue
            }
            if (-not $connectionInfo) {
                return New-ErrorResponse -Message "Not connected to Exchange Online. Run Connect-ExchangeOnline first." `
                    -ErrorCode "AUTHORIZATION_ERROR"
            }

            $results = [System.Collections.Generic.List[PSCustomObject]]::new()

            $sharedMailboxes = Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited -ErrorAction Stop

            foreach ($mailbox in $sharedMailboxes) {
                # FullAccess permissions
                $permissions = Get-MailboxPermission -Identity $mailbox.Identity -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.User -notlike "*NT AUTHORITY*" -and
                        $_.User -notlike "*S-1-5-*" -and
                        $_.IsInherited -eq $false
                    }

                foreach ($permission in $permissions) {
                    $results.Add([PSCustomObject]@{
                        SharedMailbox      = $mailbox.DisplayName
                        SharedMailboxEmail = $mailbox.PrimarySmtpAddress.ToString()
                        User               = $permission.User.ToString()
                        AccessRights       = ($permission.AccessRights -join ", ")
                        PermissionType     = "FullAccess"
                        AuditTime          = (Get-Date).ToString("o")
                    })
                }

                # SendAs permissions - Identity is the mailbox, Trustee is who can send as it
                $sendAsPerms = Get-RecipientPermission -Identity $mailbox.Identity `
                    -AccessRights SendAs -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.Trustee -notlike "*NT AUTHORITY*" -and
                        $_.Trustee -notlike "*S-1-5-*"
                    }

                foreach ($permission in $sendAsPerms) {
                    $results.Add([PSCustomObject]@{
                        SharedMailbox      = $mailbox.DisplayName
                        SharedMailboxEmail = $mailbox.PrimarySmtpAddress.ToString()
                        User               = $permission.Trustee.ToString()
                        AccessRights       = "SendAs"
                        PermissionType     = "SendAs"
                        AuditTime          = (Get-Date).ToString("o")
                    })
                }
            }

            if ($ExportCSV) {
                $results | Export-Csv $ExportCSV -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            }

            return New-SuccessResponse -Message "Shared mailbox access report completed" -Data @{
                TotalSharedMailboxes = $sharedMailboxes.Count
                TotalPermissions     = $results.Count
                AccessData           = $results
            }

        } catch {
            return New-ErrorResponse -Message "Shared mailbox access report failed: $($_.Exception.Message)" `
                -ErrorCode "EXTERNAL_SERVICE_ERROR"
        }
    } -Parameters @{
        ExportCSV = $ExportCSV
    } -EnableObservability
}

Export-ModuleMember -Function @(
    'Get-M365LicenseAudit',
    'Get-MFAStatusReport',
    'Get-SharedMailboxAccess'
)
