#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Offboard an AD user: disable, strip groups, move to disabled OU, log everything.
.PARAMETER Username       SamAccountName of departing user
.PARAMETER DisabledOU     OU to move account to (defaults to OU=Disabled Users)
.PARAMETER ManagerNotify  Email manager a summary (requires Send-MailMessage config below)
.EXAMPLE
    .\Remove-ADUserOffboard.ps1 -Username jdoe
#>
param(
    [Parameter(Mandatory)][string]$Username,
    [string]$DisabledOU,
    [switch]$ManagerNotify
)

$Domain      = (Get-ADDomain).DNSRoot
$DefaultDisOU = "OU=Disabled Users,DC=" + ($Domain -replace "\.", ",DC=")
$TargetOU    = if ($DisabledOU) { $DisabledOU } else { $DefaultDisOU }
$LogPath     = "$PSScriptRoot\offboard-log.txt"
$Timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm"

$user = Get-ADUser $Username -Properties DisplayName, EmailAddress, Department, Title, Manager, MemberOf, DistinguishedName -ErrorAction Stop

Write-Host "`n=== Offboarding: $($user.DisplayName) ($Username) ===" -ForegroundColor Cyan

$log = @"
=== Offboard Log: $($user.DisplayName) ($Username) ===
Date       : $Timestamp
Dept       : $($user.Department)
Title      : $($user.Title)
Email      : $($user.EmailAddress)
"@

# 1. Disable account
Disable-ADAccount -Identity $Username
Write-Host "[OK] Account disabled." -ForegroundColor Green
$log += "`nAccount    : DISABLED"

# 2. Clear password to random (prevent any cached auth)
$newPass = -join (1..24 | ForEach-Object { [char](Get-Random -Minimum 33 -Maximum 126) })
Set-ADAccountPassword -Identity $Username -NewPassword (ConvertTo-SecureString $newPass -AsPlainText -Force) -Reset
$log += "`nPassword   : Reset to random"

# 3. Strip all group memberships (log them first)
$groups = $user.MemberOf
$log += "`nGroups Removed:"
foreach ($group in $groups) {
    $gname = (Get-ADGroup $group).Name
    try {
        Remove-ADGroupMember -Identity $group -Members $Username -Confirm:$false
        Write-Host "  - Removed from: $gname" -ForegroundColor Yellow
        $log += "`n  - $gname"
    } catch {
        Write-Host "  [WARN] Could not remove from $gname : $_" -ForegroundColor Yellow
        $log += "`n  [WARN] Could not remove from $gname"
    }
}

# 4. Update description with offboard date
Set-ADUser -Identity $Username -Description "DISABLED $Timestamp - Offboarded"

# 5. Move to disabled OU
try {
    Move-ADObject -Identity $user.DistinguishedName -TargetPath $TargetOU
    Write-Host "[OK] Moved to: $TargetOU" -ForegroundColor Green
    $log += "`nMoved To   : $TargetOU"
} catch {
    Write-Host "[WARN] Could not move account: $_" -ForegroundColor Yellow
    $log += "`n[WARN] Could not move account: $_"
}

# 6. Manager notification (optional)
if ($ManagerNotify -and $user.Manager) {
    $manager = Get-ADUser $user.Manager -Properties EmailAddress
    if ($manager.EmailAddress) {
        # Configure SMTP settings for your environment
        $smtpServer = "smtp.yourdomain.com"
        $from       = "it-alerts@yourdomain.com"
        try {
            Send-MailMessage -To $manager.EmailAddress -From $from -Subject "Account Offboarded: $($user.DisplayName)" `
                -Body $log -SmtpServer $smtpServer
            Write-Host "[OK] Manager notified: $($manager.EmailAddress)" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Could not email manager: $_" -ForegroundColor Yellow
        }
    }
}

# 7. Write log
$log | Out-File $LogPath -Append
Write-Host "`n[OK] Log written to $LogPath" -ForegroundColor Green
Write-Host "`n=== Offboarding Complete ===`n" -ForegroundColor Cyan
Write-Host "REMINDER: Revoke M365 licenses, forwarding, and any app access manually." -ForegroundColor Yellow
