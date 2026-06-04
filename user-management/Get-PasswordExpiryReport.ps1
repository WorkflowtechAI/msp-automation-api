#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Report users whose passwords expire within N days. Optionally email them.
.PARAMETER DaysWarning    Warn users expiring within this many days (default 14)
.PARAMETER SendEmail      Send reminder emails to affected users
.PARAMETER ExportCSV      Path to export results
.EXAMPLE
    .\Get-PasswordExpiryReport.ps1 -DaysWarning 14
    .\Get-PasswordExpiryReport.ps1 -DaysWarning 7 -SendEmail
#>
param(
    [int]$DaysWarning = 14,
    [switch]$SendEmail,
    [string]$ExportCSV,
    [string]$SmtpServer = "smtp.yourdomain.com",
    [string]$FromAddress = "it-alerts@yourdomain.com"
)

$today     = Get-Date
$maxPwAge  = (Get-ADDefaultDomainPasswordPolicy).MaxPasswordAge.Days

Write-Host "`n=== Password Expiry Report (expiring within $DaysWarning days) ===" -ForegroundColor Cyan

$results = Get-ADUser -Filter { Enabled -eq $true -and PasswordNeverExpires -eq $false } `
    -Properties PasswordLastSet, EmailAddress, DisplayName, Department |
    Where-Object { $_.PasswordLastSet -ne $null } |
    ForEach-Object {
        $expiry = $_.PasswordLastSet.AddDays($maxPwAge)
        $daysLeft = ($expiry - $today).Days
        [PSCustomObject]@{
            Username       = $_.SamAccountName
            DisplayName    = $_.DisplayName
            Email          = $_.EmailAddress
            Department     = $_.Department
            PasswordLastSet = $_.PasswordLastSet
            ExpiryDate     = $expiry
            DaysRemaining  = $daysLeft
        }
    } |
    Where-Object { $_.DaysRemaining -le $DaysWarning -and $_.DaysRemaining -ge 0 } |
    Sort-Object DaysRemaining

if ($results.Count -eq 0) {
    Write-Host "No passwords expiring within $DaysWarning days." -ForegroundColor Green
    exit
}

$results | Format-Table Username, DisplayName, Department, ExpiryDate, DaysRemaining -AutoSize
Write-Host "Total: $($results.Count) accounts" -ForegroundColor Yellow

if ($SendEmail) {
    foreach ($r in $results) {
        if (-not $r.Email) { continue }
        $body = @"
Hello $($r.DisplayName),

Your Windows password will expire in $($r.DaysRemaining) day(s) on $($r.ExpiryDate.ToString('MMMM dd, yyyy')).

Please change your password before it expires to avoid being locked out.
You can change your password by pressing Ctrl+Alt+Delete and selecting "Change a password."

If you need assistance, please contact the helpdesk.

IT Support
"@
        try {
            Send-MailMessage -To $r.Email -From $FromAddress -Subject "Action Required: Your password expires in $($r.DaysRemaining) day(s)" `
                -Body $body -SmtpServer $SmtpServer
            Write-Host "  [EMAIL SENT] $($r.Username) -> $($r.Email)" -ForegroundColor Green
        } catch {
            Write-Host "  [ERROR] Could not email $($r.Username): $_" -ForegroundColor Red
        }
    }
}

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "`n[OK] Exported to $ExportCSV" -ForegroundColor Green
}
