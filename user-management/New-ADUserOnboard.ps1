#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Onboard a new AD user with standard MSP settings.
.DESCRIPTION
    Creates an AD user account, sets group memberships, home drive,
    copies group memberships from a template user, and emails credentials.
.PARAMETER FirstName
.PARAMETER LastName
.PARAMETER Username      Defaults to first initial + last name
.PARAMETER Department
.PARAMETER Title
.PARAMETER TemplateUser  Copy group memberships from this user
.PARAMETER OU            Distinguished name of target OU
.PARAMETER Password      If omitted, a random 16-char password is generated
.EXAMPLE
    .\New-ADUserOnboard.ps1 -FirstName John -LastName Doe -Department "Accounting" -Title "Staff Accountant" -TemplateUser "jsmith"
#>
param(
    [Parameter(Mandatory)][string]$FirstName,
    [Parameter(Mandatory)][string]$LastName,
    [string]$Username,
    [Parameter(Mandatory)][string]$Department,
    [Parameter(Mandatory)][string]$Title,
    [string]$TemplateUser,
    [string]$OU,
    [string]$Password
)

# --- Config ---
$Domain         = (Get-ADDomain).DNSRoot
$DefaultOU      = "OU=Users,OU=Company,DC=" + ($Domain -replace "\.", ",DC=")
$HomeDriveRoot  = "\\$Domain\Users"
$HomeDriveLetter = "H"

$TargetOU = if ($OU) { $OU } else { $DefaultOU }

# Generate username if not provided
if (-not $Username) {
    $Username = ($FirstName[0] + $LastName).ToLower() -replace '\s', ''
}

# Generate password if not provided
if (-not $Password) {
    $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*'
    $Password = -join (1..16 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

$SecurePass = ConvertTo-SecureString $Password -AsPlainText -Force

Write-Host "`n=== New User Onboarding ===" -ForegroundColor Cyan
Write-Host "Username  : $Username" -ForegroundColor Yellow
Write-Host "Full Name : $FirstName $LastName"
Write-Host "Title     : $Title"
Write-Host "Dept      : $Department"
Write-Host "OU        : $TargetOU"

# Check for duplicate
if (Get-ADUser -Filter { SamAccountName -eq $Username } -ErrorAction SilentlyContinue) {
    Write-Host "`n[ERROR] User '$Username' already exists in AD." -ForegroundColor Red
    exit 1
}

# Create the user
try {
    New-ADUser `
        -SamAccountName     $Username `
        -UserPrincipalName  "$Username@$Domain" `
        -GivenName          $FirstName `
        -Surname            $LastName `
        -DisplayName        "$FirstName $LastName" `
        -Name               "$FirstName $LastName" `
        -Department         $Department `
        -Title              $Title `
        -AccountPassword    $SecurePass `
        -Enabled            $true `
        -ChangePasswordAtLogon $true `
        -Path               $TargetOU `
        -HomeDrive          $HomeDriveLetter `
        -HomeDirectory      "$HomeDriveRoot\$Username"

    Write-Host "`n[OK] User created." -ForegroundColor Green
} catch {
    Write-Host "`n[ERROR] Failed to create user: $_" -ForegroundColor Red
    exit 1
}

# Copy group memberships from template user
if ($TemplateUser) {
    Write-Host "`nCopying group memberships from '$TemplateUser'..." -ForegroundColor Cyan
    $groups = Get-ADUser $TemplateUser -Properties MemberOf | Select-Object -ExpandProperty MemberOf
    foreach ($group in $groups) {
        try {
            Add-ADGroupMember -Identity $group -Members $Username
            Write-Host "  + $((Get-ADGroup $group).Name)" -ForegroundColor Green
        } catch {
            Write-Host "  [WARN] Could not add to $group : $_" -ForegroundColor Yellow
        }
    }
}

# Create home directory
$homePath = "$HomeDriveRoot\$Username"
if (-not (Test-Path $homePath)) {
    try {
        New-Item -ItemType Directory -Path $homePath | Out-Null
        $acl = Get-Acl $homePath
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "$Domain\$Username", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.SetAccessRule($rule)
        Set-Acl $homePath $acl
        Write-Host "`n[OK] Home directory created: $homePath" -ForegroundColor Green
    } catch {
        Write-Host "`n[WARN] Could not create home directory: $_" -ForegroundColor Yellow
    }
}

Write-Host "`n=== Onboarding Complete ===" -ForegroundColor Cyan
Write-Host "Username : $Username"
Write-Host "Password : $Password  <-- Provide to user securely, they must change on first login"
Write-Host "UPN      : $Username@$Domain`n"
