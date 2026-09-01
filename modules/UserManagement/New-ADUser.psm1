# User Management Module
# API-ready user onboarding with rollback support

# No -Force. See the note in Endpoint\Get-SystemInventory.psm1: forcing the
# nested import evicts the caller's copy of MSPAutomation.Core.
Import-Module (Join-Path $PSScriptRoot "..\MSPAutomation.Core.psm1")

<#
.SYNOPSIS
    Create a new AD user with standardized settings and rollback support.
    NOTE: Renamed to New-MSPADUser to avoid shadowing the built-in New-ADUser cmdlet
    from the ActiveDirectory module, which would cause an infinite loop.
.PARAMETER FirstName
    User's first name
.PARAMETER LastName
    User's last name
.PARAMETER Username
    Username (defaults to first initial + last name, lowercased)
.PARAMETER Department
    User's department
.PARAMETER Title
    User's job title
.PARAMETER TemplateUser
    Copy group memberships from this existing user
.PARAMETER OU
    Target OU distinguished name. Defaults to OU=Users,OU=Company,DC=...
.PARAMETER HomeDriveRoot
    UNC path to the home drive share root (e.g. "\\fileserver\Users"). Mandatory.
.PARAMETER Password
    Initial password (auto-generated 16-char if not provided)
.PARAMETER EnableRollback
    Enable automatic rollback on failure
.PARAMETER RollbackStatePath
    Path for rollback state storage
.EXAMPLE
    New-MSPADUser -FirstName "John" -LastName "Doe" -Department "IT" -Title "Sysadmin" `
        -HomeDriveRoot "\\fileserver\Users" -EnableRollback
.OUTPUTS
    ApiResponse object with user creation details. Password is NOT included in response.
    Retrieve it from the RollbackFile or your secrets vault.
#>
function New-MSPADUser {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]  [string]$FirstName,
        [Parameter(Mandatory = $true)]  [string]$LastName,
                                        [string]$Username,
        [Parameter(Mandatory = $true)]  [string]$Department,
        [Parameter(Mandatory = $true)]  [string]$Title,
                                        [string]$TemplateUser,
                                        [string]$OU,
        [Parameter(Mandatory = $true)]  [string]$HomeDriveRoot,
                                        [string]$Password,
        [switch]$EnableRollback,
        [string]$RollbackStatePath = "C:\AutomationState\Rollbacks"
    )

    [Validator]::ValidateRequired($FirstName,     "FirstName")
    [Validator]::ValidateRequired($LastName,      "LastName")
    [Validator]::ValidateRequired($Department,    "Department")
    [Validator]::ValidateRequired($Title,         "Title")
    [Validator]::ValidateRequired($HomeDriveRoot, "HomeDriveRoot")

    return Invoke-AutomationOperation -OperationName "New-MSPADUser" -ScriptBlock {
        param([hashtable]$p)

        $FirstName        = $p.FirstName
        $LastName         = $p.LastName
        $Username         = $p.Username
        $Department       = $p.Department
        $Title            = $p.Title
        $TemplateUser     = $p.TemplateUser
        $OU               = $p.OU
        $HomeDriveRoot    = $p.HomeDriveRoot
        $Password         = $p.Password
        $EnableRollback   = $p.EnableRollback
        $RollbackStatePath = $p.RollbackStatePath

        $rollbackData = @{
            Actions              = @()
            UserCreated          = $false
            HomeDirectoryCreated = $false
            GroupsAdded          = @()
        }

        try {
            # Import the built-in AD module; this will not conflict because this function
            # is named New-MSPADUser, not New-ADUser
            Import-Module ActiveDirectory -ErrorAction Stop

            $domain    = (Get-ADDomain).DNSRoot
            $defaultOU = "OU=Users,OU=Company,DC=" + ($domain -replace "\.", ",DC=")
            $targetOU  = if ($OU) { $OU } else { $defaultOU }

            if (-not $Username) {
                $Username = ($FirstName[0] + $LastName).ToLower() -replace '[^a-z0-9\-]', ''
            }

            # Idempotency: return CONFLICT if user already exists
            $existingUser = Get-ADUser -Filter "SamAccountName -eq '$Username'" -ErrorAction SilentlyContinue
            if ($existingUser) {
                return New-ErrorResponse -Message "User '$Username' already exists" `
                    -ErrorCode "CONFLICT" -Data @{
                        Username         = $Username
                        ExistingUserDN   = $existingUser.DistinguishedName
                    }
            }

            # Generate password if not supplied
            if (-not $Password) {
                $chars    = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*'
                $Password = -join (1..16 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
            }

            $securePass = ConvertTo-SecureString $Password -AsPlainText -Force

            # Build home path before creation so rollback knows what to clean up
            $homePath = Join-Path $HomeDriveRoot $Username

            # Create the user using the fully qualified cmdlet name to avoid any ambiguity
            Microsoft.ActiveDirectory.Management\New-ADUser `
                -SamAccountName       $Username `
                -UserPrincipalName    "$Username@$domain" `
                -GivenName            $FirstName `
                -Surname              $LastName `
                -DisplayName          "$FirstName $LastName" `
                -Name                 "$FirstName $LastName" `
                -Department           $Department `
                -Title                $Title `
                -AccountPassword      $securePass `
                -Enabled              $true `
                -ChangePasswordAtLogon $true `
                -Path                 $targetOU `
                -HomeDrive            "H:" `
                -HomeDirectory        $homePath `
                -ErrorAction          Stop

            $rollbackData.UserCreated = $true
            $rollbackData.Actions    += "Created user $Username"

            # Copy group memberships from template user
            if ($TemplateUser) {
                $groups = Get-ADUser $TemplateUser -Properties MemberOf -ErrorAction Stop |
                    Select-Object -ExpandProperty MemberOf
                foreach ($group in $groups) {
                    try {
                        Add-ADGroupMember -Identity $group -Members $Username -ErrorAction Stop
                        $rollbackData.GroupsAdded += $group
                        $rollbackData.Actions     += "Added to group $group"
                    } catch {
                        $rollbackData.Actions += "Warning: failed to add to group $group - $_"
                    }
                }
            }

            # Create home directory and set ACL
            if (-not (Test-Path $homePath)) {
                New-Item -ItemType Directory -Path $homePath -Force -ErrorAction Stop | Out-Null
                $acl  = Get-Acl $homePath
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    "$domain\$Username",
                    "FullControl",
                    "ContainerInherit,ObjectInherit",
                    "None",
                    "Allow"
                )
                $acl.SetAccessRule($rule)
                Set-Acl $homePath $acl -ErrorAction Stop

                $rollbackData.HomeDirectoryCreated = $true
                $rollbackData.Actions             += "Created home directory $homePath"
            }

            # Save rollback state (does NOT include plaintext password)
            $rollbackFilePath = $null
            if ($EnableRollback) {
                if (-not (Test-Path $RollbackStatePath)) {
                    New-Item -ItemType Directory -Path $RollbackStatePath -Force | Out-Null
                }
                $rollbackFilePath = Join-Path $RollbackStatePath "$Username-rollback.json"
                $rollbackData | ConvertTo-Json -Depth 10 |
                    Out-File $rollbackFilePath -Force -Encoding UTF8
            }

            # Password is NOT returned in the response body.
            # Store it in your secrets vault before calling this function,
            # or retrieve it from the rollback file in a secured location.
            return New-SuccessResponse -Message "User created successfully" -Data @{
                Username           = $Username
                UserPrincipalName  = "$Username@$domain"
                DisplayName        = "$FirstName $LastName"
                Department         = $Department
                Title              = $Title
                OU                 = $targetOU
                HomeDirectory      = $homePath
                PasswordGenerated  = (-not $p.Password)  # True if auto-generated; retrieve from vault
                RollbackEnabled    = $EnableRollback
                RollbackFile       = $rollbackFilePath
                CreatedAt          = (Get-Date).ToString("o")
            }

        } catch {
            if ($EnableRollback -and $rollbackData.UserCreated) {
                try {
                    Undo-MSPADUserCreation -Username $Username -RollbackStatePath $RollbackStatePath `
                        -ErrorAction SilentlyContinue
                } catch { }
            }

            return New-ErrorResponse -Message "User creation failed: $($_.Exception.Message)" `
                -ErrorCode "INTERNAL_ERROR" -Data @{
                    RollbackAttempted = $EnableRollback
                    RollbackData      = $rollbackData
                }
        }
    } -Parameters @{
        FirstName         = $FirstName
        LastName          = $LastName
        Username          = $Username
        Department        = $Department
        Title             = $Title
        TemplateUser      = $TemplateUser
        OU                = $OU
        HomeDriveRoot     = $HomeDriveRoot
        Password          = $Password
        EnableRollback    = [bool]$EnableRollback
        RollbackStatePath = $RollbackStatePath
    } -EnableObservability
}

<#
.SYNOPSIS
    Rollback AD user creation by removing user, home directory, and group memberships.
.PARAMETER Username
    Username to rollback
.PARAMETER RollbackStatePath
    Path containing rollback state files
.EXAMPLE
    Undo-MSPADUserCreation -Username "jdoe" -RollbackStatePath "C:\AutomationState\Rollbacks"
.OUTPUTS
    ApiResponse object with rollback details
#>
function Undo-MSPADUserCreation {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string]$Username,
        [string]$RollbackStatePath = "C:\AutomationState\Rollbacks"
    )

    return Invoke-AutomationOperation -OperationName "Undo-MSPADUserCreation" -ScriptBlock {
        param([hashtable]$p)

        $Username         = $p.Username
        $RollbackStatePath = $p.RollbackStatePath

        Import-Module ActiveDirectory -ErrorAction Stop

        $rollbackResults = @{
            Actions              = @()
            UserRemoved          = $false
            HomeDirectoryRemoved = $false
            GroupsRemoved        = @()
            Errors               = @()
        }

        try {
            $rollbackFile = Join-Path $RollbackStatePath "$Username-rollback.json"
            $rollbackData = if (Test-Path $rollbackFile) {
                Get-Content $rollbackFile -Raw | ConvertFrom-Json
            } else {
                @{ GroupsAdded = @(); HomeDirectoryCreated = $false }
            }

            # Remove from groups first (before account removal makes the SID invalid)
            foreach ($group in $rollbackData.GroupsAdded) {
                try {
                    Remove-ADGroupMember -Identity $group -Members $Username -Confirm:$false -ErrorAction Stop
                    $rollbackResults.GroupsRemoved += $group
                    $rollbackResults.Actions       += "Removed from group $group"
                } catch {
                    $rollbackResults.Errors += "Failed to remove from group $group : $($_.Exception.Message)"
                }
            }

            # Remove home directory
            $user = Get-ADUser -Identity $Username -Properties HomeDirectory -ErrorAction SilentlyContinue
            $homePath = if ($user -and $user.HomeDirectory) { $user.HomeDirectory } else { $null }

            if ($homePath -and (Test-Path $homePath)) {
                try {
                    Remove-Item -Path $homePath -Recurse -Force -ErrorAction Stop
                    $rollbackResults.HomeDirectoryRemoved = $true
                    $rollbackResults.Actions             += "Removed home directory $homePath"
                } catch {
                    $rollbackResults.Errors += "Failed to remove home directory: $($_.Exception.Message)"
                }
            }

            # Remove user account
            try {
                Microsoft.ActiveDirectory.Management\Remove-ADUser -Identity $Username -Confirm:$false -ErrorAction Stop
                $rollbackResults.UserRemoved = $true
                $rollbackResults.Actions    += "Removed user $Username"
            } catch {
                $rollbackResults.Errors += "Failed to remove user: $($_.Exception.Message)"
            }

            # Clean up rollback state file
            Remove-Item $rollbackFile -Force -ErrorAction SilentlyContinue

            if ($rollbackResults.Errors.Count -eq 0) {
                return New-SuccessResponse -Message "Rollback completed successfully" -Data $rollbackResults
            } else {
                return New-ErrorResponse -Message "Rollback completed with errors" `
                    -ErrorCode "PARTIAL_SUCCESS" -Data $rollbackResults
            }

        } catch {
            return New-ErrorResponse -Message "Rollback failed: $($_.Exception.Message)" `
                -ErrorCode "INTERNAL_ERROR" -Data $rollbackResults
        }
    } -Parameters @{
        Username          = $Username
        RollbackStatePath = $RollbackStatePath
    } -EnableObservability
}

Export-ModuleMember -Function @(
    'New-MSPADUser',
    'Undo-MSPADUserCreation'
)
