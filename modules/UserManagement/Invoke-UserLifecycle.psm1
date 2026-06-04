# User Lifecycle Module
# API-ready user offboarding and lifecycle operations

Import-Module (Join-Path $PSScriptRoot "..\MSPAutomation.Core.psm1") -Force

<#
.SYNOPSIS
    Get inactive users for cleanup or review.
.PARAMETER DaysInactive
    Number of days of inactivity to consider inactive (default: 90)
.PARAMETER SearchBase
    LDAP search base for user search
.EXAMPLE
    Get-InactiveUsers -DaysInactive 120 -SearchBase "OU=Users,DC=domain,DC=com"
.OUTPUTS
    ApiResponse object with inactive user data
#>
function Get-InactiveUsers {
    [CmdletBinding()]
    param(
        [ValidateRange(30, 730)]
        [int]$DaysInactive = 90,

        [string]$SearchBase
    )

    return Invoke-AutomationOperation -OperationName "Get-InactiveUsers" -ScriptBlock {
        param([hashtable]$p)

        $DaysInactive = $p.DaysInactive
        $SearchBase   = $p.SearchBase

        try {
            Import-Module ActiveDirectory -ErrorAction Stop

            $cutoffDate = (Get-Date).AddDays(-$DaysInactive)

            # Get-ADUser with Filter; Search-ADAccount does not support -Filter with LastLogonDate
            $getUserParams = @{
                Filter     = "Enabled -eq `$true"
                Properties = @("LastLogonDate", "LastLogonTimestamp", "PasswordLastSet", "WhenCreated")
            }
            if ($SearchBase) { $getUserParams["SearchBase"] = $SearchBase }

            $allEnabledUsers = Get-ADUser @getUserParams -ResultPageSize 5000

            $results = [System.Collections.Generic.List[PSCustomObject]]::new()

            foreach ($user in $allEnabledUsers) {
                # LastLogonDate replicates lazily; fall back to LastLogonTimestamp if needed
                $lastLogon = if ($user.LastLogonDate) {
                    $user.LastLogonDate
                } elseif ($user.LastLogonTimestamp -and $user.LastLogonTimestamp -gt 0) {
                    [DateTime]::FromFileTime($user.LastLogonTimestamp)
                } else {
                    $null
                }

                # Skip users who have logged in recently
                if ($lastLogon -and $lastLogon -ge $cutoffDate) { continue }

                $daysSinceLogon = if ($lastLogon) {
                    [math]::Round(((Get-Date) - $lastLogon).TotalDays, 0)
                } else { "Never" }

                $passwordLastSet = if ($user.PasswordLastSet) {
                    $user.PasswordLastSet.ToString("o")
                } else { $null }

                $results.Add([PSCustomObject]@{
                    SamAccountName    = $user.SamAccountName
                    DisplayName       = $user.Name
                    UserPrincipalName = $user.UserPrincipalName
                    DistinguishedName = $user.DistinguishedName
                    Enabled           = $user.Enabled
                    LastLogonDate     = if ($lastLogon) { $lastLogon.ToString("o") } else { "Never" }
                    DaysSinceLogon    = $daysSinceLogon
                    PasswordLastSet   = $passwordLastSet
                    WhenCreated       = $user.WhenCreated.ToString("o")
                    AuditTime         = (Get-Date).ToString("o")
                })
            }

            return New-SuccessResponse -Message "Inactive user scan completed" -Data @{
                DaysInactiveThreshold = $DaysInactive
                TotalInactiveUsers    = $results.Count
                InactiveUserData      = $results
            }

        } catch {
            return New-ErrorResponse -Message "Inactive user scan failed: $($_.Exception.Message)" `
                -ErrorCode "EXTERNAL_SERVICE_ERROR"
        }
    } -Parameters @{
        DaysInactive = $DaysInactive
        SearchBase   = $SearchBase
    } -EnableObservability
}

<#
.SYNOPSIS
    Get password expiry report for users.
.PARAMETER DaysToExpiry
    Number of days to look ahead for expiring passwords (default: 30)
.PARAMETER SearchBase
    LDAP search base for user search
.EXAMPLE
    Get-PasswordExpiryReport -DaysToExpiry 14 -SearchBase "OU=Users,DC=domain,DC=com"
.OUTPUTS
    ApiResponse object with password expiry data
#>
function Get-PasswordExpiryReport {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 365)]
        [int]$DaysToExpiry = 30,

        [string]$SearchBase
    )

    return Invoke-AutomationOperation -OperationName "Get-PasswordExpiryReport" -ScriptBlock {
        param([hashtable]$p)

        $DaysToExpiry = $p.DaysToExpiry
        $SearchBase   = $p.SearchBase

        try {
            Import-Module ActiveDirectory -ErrorAction Stop

            $maxPasswordAge = (Get-ADDefaultDomainPasswordPolicy).MaxPasswordAge

            $getUserParams = @{
                Filter     = "Enabled -eq `$true -and PasswordNeverExpires -eq `$false"
                Properties = @("PasswordLastSet", "PasswordNeverExpires", "PasswordExpired")
            }
            if ($SearchBase) { $getUserParams["SearchBase"] = $SearchBase }

            $users      = Get-ADUser @getUserParams -ResultPageSize 5000
            $results    = [System.Collections.Generic.List[PSCustomObject]]::new()
            $cutoffDate = (Get-Date).AddDays($DaysToExpiry)

            foreach ($user in $users) {
                # Guard against null PasswordLastSet (accounts that never had a password set)
                if (-not $user.PasswordLastSet) { continue }

                $expiryDate      = $user.PasswordLastSet + $maxPasswordAge
                $daysUntilExpiry = [math]::Round(($expiryDate - (Get-Date)).TotalDays, 0)

                # Include already-expired accounts and those expiring within threshold
                if ($daysUntilExpiry -le $DaysToExpiry) {
                    $results.Add([PSCustomObject]@{
                        SamAccountName    = $user.SamAccountName
                        DisplayName       = $user.Name
                        UserPrincipalName = $user.UserPrincipalName
                        DistinguishedName = $user.DistinguishedName
                        PasswordLastSet   = $user.PasswordLastSet.ToString("o")
                        PasswordExpiryDate = $expiryDate.ToString("o")
                        DaysUntilExpiry   = $daysUntilExpiry
                        IsExpired         = ($daysUntilExpiry -lt 0 -or $user.PasswordExpired)
                        AuditTime         = (Get-Date).ToString("o")
                    })
                }
            }

            return New-SuccessResponse -Message "Password expiry report completed" -Data @{
                DaysToExpiryThreshold = $DaysToExpiry
                TotalExpiringSoon     = $results.Count
                AlreadyExpired        = ($results | Where-Object { $_.IsExpired }).Count
                ExpiryData            = ($results | Sort-Object DaysUntilExpiry)
            }

        } catch {
            return New-ErrorResponse -Message "Password expiry report failed: $($_.Exception.Message)" `
                -ErrorCode "EXTERNAL_SERVICE_ERROR"
        }
    } -Parameters @{
        DaysToExpiry = $DaysToExpiry
        SearchBase   = $SearchBase
    } -EnableObservability
}

<#
.SYNOPSIS
    Offboard an AD user with comprehensive cleanup: archive, group removal, disable, optional delete.
.PARAMETER Username
    Username to offboard
.PARAMETER RemoveHomeDirectory
    Remove user's home directory (only after archiving if ArchivePath is specified)
.PARAMETER RemoveGroupMemberships
    Remove user from all groups
.PARAMETER DisableOnly
    Only disable account rather than deleting it (recommended default for compliance)
.PARAMETER ArchivePath
    UNC or local path to archive user's home directory before deletion
.EXAMPLE
    Remove-MSPADUserOffboard -Username "jdoe" -RemoveHomeDirectory -ArchivePath "\\server\archives"
.OUTPUTS
    ApiResponse object with offboarding results
#>
function Remove-MSPADUserOffboard {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string]$Username,
        [switch]$RemoveHomeDirectory,
        [switch]$RemoveGroupMemberships,
        [switch]$DisableOnly,
        [string]$ArchivePath
    )

    return Invoke-AutomationOperation -OperationName "Remove-MSPADUserOffboard" -ScriptBlock {
        param([hashtable]$p)

        $Username              = $p.Username
        $RemoveHomeDirectory   = $p.RemoveHomeDirectory
        $RemoveGroupMemberships = $p.RemoveGroupMemberships
        $DisableOnly           = $p.DisableOnly
        $ArchivePath           = $p.ArchivePath

        $offboardingResults = @{
            Actions                 = @()
            UserDisabled            = $false
            UserRemoved             = $false
            HomeDirectoryRemoved    = $false
            GroupMembershipsRemoved = @()
            DataArchived            = $false
            ArchivePath             = $null
            Errors                  = @()
        }

        try {
            Import-Module ActiveDirectory -ErrorAction Stop

            $user = Get-ADUser -Identity $Username -Properties HomeDirectory, MemberOf -ErrorAction Stop

            # Archive data before any destructive operations
            if ($ArchivePath -and $user.HomeDirectory -and (Test-Path $user.HomeDirectory)) {
                try {
                    $archiveDir = Join-Path $ArchivePath $Username
                    if (-not (Test-Path $archiveDir)) {
                        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
                    }
                    Copy-Item -Path $user.HomeDirectory -Destination $archiveDir -Recurse -Force -ErrorAction Stop
                    $offboardingResults.DataArchived = $true
                    $offboardingResults.ArchivePath  = $archiveDir
                    $offboardingResults.Actions     += "Archived home directory to $archiveDir"
                } catch {
                    $offboardingResults.Errors += "Archive failed: $($_.Exception.Message)"
                }
            }

            # Remove from groups
            if ($RemoveGroupMemberships) {
                foreach ($group in $user.MemberOf) {
                    try {
                        Remove-ADGroupMember -Identity $group -Members $user -Confirm:$false -ErrorAction Stop
                        $offboardingResults.GroupMembershipsRemoved += $group
                        $offboardingResults.Actions                 += "Removed from group $group"
                    } catch {
                        $offboardingResults.Errors += "Failed to remove from group $group : $($_.Exception.Message)"
                    }
                }
            }

            # Disable account first (always done as a safety step before deletion)
            try {
                Disable-ADAccount -Identity $user -ErrorAction Stop
                $offboardingResults.UserDisabled = $true
                $offboardingResults.Actions     += "Disabled account $Username"
            } catch {
                $offboardingResults.Errors += "Failed to disable account: $($_.Exception.Message)"
            }

            # Remove home directory (only after successful archive or explicit override)
            if ($RemoveHomeDirectory -and $user.HomeDirectory -and (Test-Path $user.HomeDirectory)) {
                if (-not $ArchivePath -or $offboardingResults.DataArchived) {
                    try {
                        Remove-Item -Path $user.HomeDirectory -Recurse -Force -ErrorAction Stop
                        $offboardingResults.HomeDirectoryRemoved = $true
                        $offboardingResults.Actions             += "Removed home directory $($user.HomeDirectory)"
                    } catch {
                        $offboardingResults.Errors += "Failed to remove home directory: $($_.Exception.Message)"
                    }
                } else {
                    $offboardingResults.Errors += "Home directory NOT removed: archive was requested but failed"
                }
            }

            # Delete account only if not DisableOnly and account was successfully disabled
            if (-not $DisableOnly -and $offboardingResults.UserDisabled) {
                try {
                    Microsoft.ActiveDirectory.Management\Remove-ADUser -Identity $user -Confirm:$false -ErrorAction Stop
                    $offboardingResults.UserRemoved = $true
                    $offboardingResults.Actions    += "Removed account $Username"
                } catch {
                    $offboardingResults.Errors += "Failed to remove account: $($_.Exception.Message)"
                }
            }

            if ($offboardingResults.Errors.Count -eq 0) {
                return New-SuccessResponse -Message "User offboarding completed successfully" -Data $offboardingResults
            } else {
                return New-ErrorResponse -Message "User offboarding completed with errors" `
                    -ErrorCode "PARTIAL_SUCCESS" -Data $offboardingResults
            }

        } catch {
            return New-ErrorResponse -Message "User offboarding failed: $($_.Exception.Message)" `
                -ErrorCode "INTERNAL_ERROR" -Data $offboardingResults
        }
    } -Parameters @{
        Username               = $Username
        RemoveHomeDirectory    = [bool]$RemoveHomeDirectory
        RemoveGroupMemberships = [bool]$RemoveGroupMemberships
        DisableOnly            = [bool]$DisableOnly
        ArchivePath            = $ArchivePath
    } -EnableObservability
}

Export-ModuleMember -Function @(
    'Get-InactiveUsers',
    'Get-PasswordExpiryReport',
    'Remove-MSPADUserOffboard'
)
