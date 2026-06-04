#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Pull failed login attempts from Security event log. Good for spotting brute force or lockout patterns.
.PARAMETER ComputerName   Target machine (default: localhost)
.PARAMETER Hours          How far back to look (default: 24)
.PARAMETER Threshold      Flag users with more than this many failures (default: 5)
.PARAMETER ExportCSV
.EXAMPLE
    .\Get-FailedLogins.ps1 -Hours 24 -Threshold 5
    .\Get-FailedLogins.ps1 -ComputerName DC01 -Hours 48
#>
param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [int]$Hours = 24,
    [int]$Threshold = 5,
    [string]$ExportCSV
)

$startTime = (Get-Date).AddHours(-$Hours)

Write-Host "`n=== Failed Login Report ===" -ForegroundColor Cyan
Write-Host "Computer : $ComputerName"
Write-Host "Period   : Last $Hours hours (since $($startTime.ToString('yyyy-MM-dd HH:mm')))"
Write-Host "Threshold: $Threshold failures`n"

try {
    $events = Get-WinEvent -ComputerName $ComputerName -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4625
        StartTime = $startTime
    } -ErrorAction Stop
} catch {
    Write-Host "[ERROR] Could not read event log: $_" -ForegroundColor Red
    exit 1
}

if ($events.Count -eq 0) {
    Write-Host "No failed logins found in the last $Hours hours." -ForegroundColor Green
    exit
}

$results = $events | ForEach-Object {
    $xml = [xml]$_.ToXml()
    $data = $xml.Event.EventData.Data
    [PSCustomObject]@{
        TimeCreated    = $_.TimeCreated
        Username       = ($data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'
        Domain         = ($data | Where-Object { $_.Name -eq 'TargetDomainName' }).'#text'
        SourceIP       = ($data | Where-Object { $_.Name -eq 'IpAddress' }).'#text'
        LogonType      = ($data | Where-Object { $_.Name -eq 'LogonType' }).'#text'
        FailureReason  = ($data | Where-Object { $_.Name -eq 'SubStatus' }).'#text'
        WorkstationName = ($data | Where-Object { $_.Name -eq 'WorkstationName' }).'#text'
    }
} | Where-Object { $_.Username -notlike "*$" -and $_.Username -ne "-" }

# Group by username
$summary = $results | Group-Object Username | Sort-Object Count -Descending |
    Select-Object @{N="Username";E={$_.Name}},
                  @{N="FailureCount";E={$_.Count}},
                  @{N="LastAttempt";E={($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated}},
                  @{N="SourceIPs";E={($_.Group.SourceIP | Sort-Object -Unique) -join ", "}}

Write-Host "=== By User ===" -ForegroundColor Yellow
$summary | Format-Table -AutoSize

$flagged = $summary | Where-Object { $_.FailureCount -ge $Threshold }
if ($flagged.Count -gt 0) {
    Write-Host "=== FLAGGED (>= $Threshold failures) ===" -ForegroundColor Red
    $flagged | Format-Table -AutoSize
}

# Top source IPs
Write-Host "=== Top Source IPs ===" -ForegroundColor Yellow
$results | Group-Object SourceIP | Sort-Object Count -Descending | Select-Object -First 10 |
    Select-Object @{N="SourceIP";E={$_.Name}}, Count | Format-Table -AutoSize

Write-Host "Total failed attempts: $($results.Count)"

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "`n[OK] Full detail exported to $ExportCSV" -ForegroundColor Green
}
