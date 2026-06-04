<#
.SYNOPSIS
    Enumerate local Administrators group on one or more machines.
    Flags unexpected members (non-standard accounts).
.PARAMETER ComputerName   Hostnames to check (default: localhost)
.PARAMETER AllowedAdmins  Accounts that are expected/allowed (e.g. domain admin accounts)
.PARAMETER ExportCSV
.EXAMPLE
    .\Get-LocalAdminAudit.ps1 -ComputerName PC01,PC02 -AllowedAdmins "DOMAIN\Domain Admins","DOMAIN\IT-Admins"
#>
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string[]]$AllowedAdmins = @(),
    [string]$ExportCSV
)

$results = @()

foreach ($computer in $ComputerName) {
    Write-Host "`nAuditing $computer..." -ForegroundColor Cyan
    try {
        $members = Invoke-Command -ComputerName $computer -ScriptBlock {
            $group = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators,group"
            $group.Members() | ForEach-Object {
                $ads = [ADSI]$_
                [PSCustomObject]@{
                    Name   = $ads.Name[0]
                    Type   = $ads.Class
                    Path   = $ads.Path
                }
            }
        } -ErrorAction Stop

        foreach ($m in $members) {
            $flagged = $m.Name -notin $AllowedAdmins -and $m.Path -notlike "*Domain Admins*"
            $color   = if ($flagged) { "Yellow" } else { "Green" }
            Write-Host "  $($m.Name)  [$($m.Type)]$(if ($flagged) {' <-- REVIEW'})" -ForegroundColor $color

            $results += [PSCustomObject]@{
                Computer   = $computer
                Account    = $m.Name
                Type       = $m.Type
                Path       = $m.Path
                NeedsReview = $flagged
            }
        }
    } catch {
        Write-Host "  [ERROR] $computer : $_" -ForegroundColor Red
    }
}

$flagged = $results | Where-Object { $_.NeedsReview }
if ($flagged.Count -gt 0) {
    Write-Host "`n=== Accounts Needing Review ===" -ForegroundColor Red
    $flagged | Format-Table Computer, Account, Type, Path -AutoSize
}

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "`n[OK] Exported to $ExportCSV" -ForegroundColor Green
}
