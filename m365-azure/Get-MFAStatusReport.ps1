#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Reports
<#
.SYNOPSIS
    Report MFA registration status for all M365 users. Flags users with MFA disabled.
.NOTES
    Requires: Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All","User.Read.All","AuditLog.Read.All"
.PARAMETER ExportCSV
.PARAMETER EnabledOnly    Only show enabled accounts
.EXAMPLE
    Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All","User.Read.All","AuditLog.Read.All"
    .\Get-MFAStatusReport.ps1 -EnabledOnly -ExportCSV "C:\Reports\mfa-status.csv"
#>
param(
    [switch]$EnabledOnly,
    [string]$ExportCSV
)

Write-Host "`n=== M365 MFA Status Report ===" -ForegroundColor Cyan

$context = Get-MgContext
if (-not $context) {
    Write-Host "[ERROR] Not connected. Run: Connect-MgGraph -Scopes 'UserAuthenticationMethod.Read.All','User.Read.All'" -ForegroundColor Red
    exit 1
}

Write-Host "Fetching users (this may take a moment)..." -ForegroundColor Yellow
$users = Get-MgUser -All -Property DisplayName, UserPrincipalName, AccountEnabled, Department, JobTitle |
    Where-Object { -not $EnabledOnly -or $_.AccountEnabled }

$results = @()
$i = 0
foreach ($user in $users) {
    $i++
    Write-Progress -Activity "Checking MFA" -Status "$i of $($users.Count): $($user.UserPrincipalName)" -PercentComplete (($i / $users.Count) * 100)

    try {
        $methods = Get-MgUserAuthenticationMethod -UserId $user.Id
        $methodTypes = $methods | ForEach-Object { $_.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.', '' }

        $hasMFA = $methodTypes | Where-Object { $_ -notin @('passwordAuthenticationMethod') }

        $results += [PSCustomObject]@{
            DisplayName  = $user.DisplayName
            UPN          = $user.UserPrincipalName
            Department   = $user.Department
            Title        = $user.JobTitle
            Enabled      = $user.AccountEnabled
            MFAEnabled   = ($hasMFA.Count -gt 0)
            Methods      = ($methodTypes | Sort-Object -Unique) -join ", "
        }
    } catch {
        $results += [PSCustomObject]@{
            DisplayName = $user.DisplayName; UPN = $user.UserPrincipalName
            Enabled = $user.AccountEnabled; MFAEnabled = "ERROR"; Methods = $_
        }
    }
}

Write-Progress -Completed -Activity "Checking MFA"

$noMFA = $results | Where-Object { $_.MFAEnabled -eq $false -and $_.Enabled }
Write-Host "`n=== Users Without MFA ($($noMFA.Count) of $($results.Count)) ===" -ForegroundColor Red
$noMFA | Format-Table DisplayName, UPN, Department, Methods -AutoSize

$mfaCount = ($results | Where-Object { $_.MFAEnabled -eq $true }).Count
Write-Host "`nMFA enabled : $mfaCount / $($results.Count)" -ForegroundColor $(if ($noMFA.Count -gt 0) { "Yellow" } else { "Green" })

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "[OK] Exported to $ExportCSV" -ForegroundColor Green
}
