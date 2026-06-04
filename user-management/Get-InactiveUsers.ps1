#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Report on AD accounts inactive for N days. Optionally disable them.
.PARAMETER DaysInactive   Threshold in days (default 90)
.PARAMETER Disable        Actually disable the accounts found
.PARAMETER ExportCSV      Path to export results
.EXAMPLE
    .\Get-InactiveUsers.ps1 -DaysInactive 90
    .\Get-InactiveUsers.ps1 -DaysInactive 60 -Disable -ExportCSV "C:\Reports\inactive.csv"
#>
param(
    [int]$DaysInactive = 90,
    [switch]$Disable,
    [string]$ExportCSV
)

$cutoff = (Get-Date).AddDays(-$DaysInactive)

Write-Host "`n=== Inactive User Report (>$DaysInactive days) ===" -ForegroundColor Cyan
Write-Host "Cutoff date: $($cutoff.ToString('yyyy-MM-dd'))`n"

$users = Get-ADUser -Filter { Enabled -eq $true } -Properties LastLogonDate, PasswordLastSet, Department, Title, Manager |
    Where-Object {
        ($_.LastLogonDate -lt $cutoff -or $_.LastLogonDate -eq $null) -and
        $_.DistinguishedName -notlike "*OU=Service Accounts*"
    } |
    Select-Object @{N="Username";E={$_.SamAccountName}},
                  @{N="DisplayName";E={$_.Name}},
                  @{N="Department";E={$_.Department}},
                  @{N="Title";E={$_.Title}},
                  @{N="LastLogon";E={$_.LastLogonDate}},
                  @{N="PasswordLastSet";E={$_.PasswordLastSet}},
                  @{N="DaysSinceLogon";E={
                      if ($_.LastLogonDate) { (New-TimeSpan -Start $_.LastLogonDate -End (Get-Date)).Days }
                      else { "Never" }
                  }} |
    Sort-Object DaysSinceLogon -Descending

if ($users.Count -eq 0) {
    Write-Host "No inactive users found." -ForegroundColor Green
    exit
}

$users | Format-Table -AutoSize

Write-Host "Total inactive accounts: $($users.Count)" -ForegroundColor Yellow

if ($Disable) {
    Write-Host "`nDisabling accounts..." -ForegroundColor Red
    foreach ($u in $users) {
        try {
            Disable-ADAccount -Identity $u.Username
            Set-ADUser -Identity $u.Username -Description "AUTO-DISABLED $(Get-Date -Format 'yyyy-MM-dd') - Inactive >$DaysInactive days"
            Write-Host "  [DISABLED] $($u.Username)" -ForegroundColor Yellow
        } catch {
            Write-Host "  [ERROR] $($u.Username): $_" -ForegroundColor Red
        }
    }
}

if ($ExportCSV) {
    $users | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "`n[OK] Exported to $ExportCSV" -ForegroundColor Green
}
