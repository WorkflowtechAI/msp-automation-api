#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
<#
.SYNOPSIS
    Audit M365 license assignments. Shows who has what, unassigned licenses, and users with no license.
.NOTES
    Requires Microsoft Graph connection: Connect-MgGraph -Scopes "User.Read.All","Directory.Read.All"
.PARAMETER ExportCSV
.EXAMPLE
    Connect-MgGraph -Scopes "User.Read.All","Directory.Read.All"
    .\Get-M365LicenseAudit.ps1 -ExportCSV "C:\Reports\licenses.csv"
#>
param([string]$ExportCSV)

# Friendly SKU name map (extend as needed)
$skuNames = @{
    "ENTERPRISEPREMIUM"          = "Microsoft 365 E5"
    "ENTERPRISEPACK"             = "Microsoft 365 E3"
    "SPB"                        = "Microsoft 365 Business Premium"
    "O365_BUSINESS_PREMIUM"      = "Microsoft 365 Business Standard"
    "O365_BUSINESS_ESSENTIALS"   = "Microsoft 365 Business Basic"
    "EXCHANGESTANDARD"           = "Exchange Online Plan 1"
    "EXCHANGEENTERPRISE"         = "Exchange Online Plan 2"
    "TEAMS_EXPLORATORY"          = "Teams Exploratory"
    "FLOW_FREE"                  = "Power Automate Free"
    "POWER_BI_STANDARD"          = "Power BI Free"
}

Write-Host "`n=== M365 License Audit ===" -ForegroundColor Cyan
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Host "[ERROR] Not connected. Run: Connect-MgGraph -Scopes 'User.Read.All','Directory.Read.All'" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "[ERROR] Microsoft Graph module not available or not connected." -ForegroundColor Red
    exit 1
}

# Get subscribed SKUs
$skus = Get-MgSubscribedSku
Write-Host "`n=== Tenant License Summary ===" -ForegroundColor Yellow
foreach ($sku in $skus) {
    $name    = if ($skuNames[$sku.SkuPartNumber]) { $skuNames[$sku.SkuPartNumber] } else { $sku.SkuPartNumber }
    $total   = $sku.PrepaidUnits.Enabled
    $used    = $sku.ConsumedUnits
    $avail   = $total - $used
    $color   = if ($avail -le 0) { "Red" } elseif ($avail -le 5) { "Yellow" } else { "Green" }
    Write-Host ("  {0,-40} Total: {1,4}  Used: {2,4}  Available: {3,4}" -f $name, $total, $used, $avail) -ForegroundColor $color
}

# Get all users with license info
Write-Host "`n=== User License Assignments ===" -ForegroundColor Yellow
$users = Get-MgUser -All -Property DisplayName, UserPrincipalName, AssignedLicenses, AccountEnabled, Department, JobTitle

$results = $users | ForEach-Object {
    $licenses = $_.AssignedLicenses | ForEach-Object {
        $sku = $skus | Where-Object { $_.SkuId -eq $_.SkuId }
        $skuPN = ($skus | Where-Object { $_.SkuId -eq $_.SkuId }).SkuPartNumber
        if ($skuNames[$skuPN]) { $skuNames[$skuPN] } else { $skuPN }
    }
    [PSCustomObject]@{
        DisplayName  = $_.DisplayName
        UPN          = $_.UserPrincipalName
        Department   = $_.Department
        Title        = $_.JobTitle
        Enabled      = $_.AccountEnabled
        LicenseCount = $_.AssignedLicenses.Count
        Licenses     = ($licenses | Sort-Object -Unique) -join ", "
    }
}

$unlicensed = $results | Where-Object { $_.LicenseCount -eq 0 -and $_.Enabled }
Write-Host "`n=== Enabled Users With No License ($($unlicensed.Count)) ===" -ForegroundColor Red
$unlicensed | Format-Table DisplayName, UPN, Department -AutoSize

$results | Format-Table DisplayName, UPN, Enabled, LicenseCount, Licenses -AutoSize

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "[OK] Exported to $ExportCSV" -ForegroundColor Green
}
