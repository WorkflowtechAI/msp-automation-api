#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    List all shared mailboxes and who has access (FullAccess, SendAs, SendOnBehalf).
.NOTES
    Requires: Connect-ExchangeOnline
.PARAMETER ExportCSV
.EXAMPLE
    Connect-ExchangeOnline -UserPrincipalName admin@yourdomain.com
    .\Get-SharedMailboxAccess.ps1 -ExportCSV "C:\Reports\shared-mailboxes.csv"
#>
param([string]$ExportCSV)

Write-Host "`n=== Shared Mailbox Access Report ===" -ForegroundColor Cyan

try {
    $sharedMailboxes = Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited
} catch {
    Write-Host "[ERROR] Could not query Exchange. Are you connected? Run: Connect-ExchangeOnline" -ForegroundColor Red
    exit 1
}

Write-Host "Found $($sharedMailboxes.Count) shared mailboxes.`n" -ForegroundColor Yellow

$results = @()

foreach ($mbx in $sharedMailboxes) {
    Write-Host "  $($mbx.DisplayName) <$($mbx.PrimarySmtpAddress)>" -ForegroundColor Cyan

    # Full Access
    $fullAccess = Get-MailboxPermission -Identity $mbx.Identity |
        Where-Object { $_.AccessRights -like "*FullAccess*" -and -not $_.IsInherited -and $_.User -notlike "NT AUTHORITY*" }

    # Send As
    $sendAs = Get-RecipientPermission -Identity $mbx.Identity |
        Where-Object { $_.Trustee -notlike "NT AUTHORITY*" }

    # Send on Behalf
    $sendOnBehalf = $mbx.GrantSendOnBehalfTo

    foreach ($fa in $fullAccess) {
        Write-Host "    [FullAccess] $($fa.User)" -ForegroundColor Green
        $results += [PSCustomObject]@{
            Mailbox      = $mbx.DisplayName
            Email        = $mbx.PrimarySmtpAddress
            User         = $fa.User
            AccessType   = "FullAccess"
        }
    }
    foreach ($sa in $sendAs) {
        Write-Host "    [SendAs]     $($sa.Trustee)" -ForegroundColor Yellow
        $results += [PSCustomObject]@{
            Mailbox    = $mbx.DisplayName
            Email      = $mbx.PrimarySmtpAddress
            User       = $sa.Trustee
            AccessType = "SendAs"
        }
    }
    foreach ($sob in $sendOnBehalf) {
        Write-Host "    [SendOnBehalf] $sob" -ForegroundColor Yellow
        $results += [PSCustomObject]@{
            Mailbox    = $mbx.DisplayName
            Email      = $mbx.PrimarySmtpAddress
            User       = $sob
            AccessType = "SendOnBehalf"
        }
    }

    if (-not $fullAccess -and -not $sendAs -and -not $sendOnBehalf) {
        Write-Host "    [WARN] No delegated access found - orphaned mailbox?" -ForegroundColor Red
        $results += [PSCustomObject]@{
            Mailbox    = $mbx.DisplayName
            Email      = $mbx.PrimarySmtpAddress
            User       = "NONE"
            AccessType = "ORPHANED"
        }
    }
}

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "`n[OK] Exported to $ExportCSV" -ForegroundColor Green
}
