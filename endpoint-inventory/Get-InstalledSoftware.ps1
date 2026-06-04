<#
.SYNOPSIS
    List all installed software on one or more machines. Useful for license audits and finding unapproved software.
.PARAMETER ComputerName
.PARAMETER Filter         Filter by name (wildcard, e.g. "Adobe*")
.PARAMETER ExportCSV
.EXAMPLE
    .\Get-InstalledSoftware.ps1 -ComputerName PC01
    .\Get-InstalledSoftware.ps1 -Filter "Adobe*" -ExportCSV "C:\Reports\adobe.csv"
#>
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$Filter = "*",
    [string]$ExportCSV
)

$results = @()
$regPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

foreach ($computer in $ComputerName) {
    Write-Host "`nQuerying $computer..." -ForegroundColor Cyan
    try {
        $software = Invoke-Command -ComputerName $computer -ArgumentList $regPaths, $Filter -ScriptBlock {
            param($paths, $filter)
            $paths | ForEach-Object {
                Get-ItemProperty $_ -ErrorAction SilentlyContinue
            } |
            Where-Object { $_.DisplayName -like $filter -and $_.DisplayName } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate,
                @{N="InstallDateFormatted";E={
                    if ($_.InstallDate -match '^\d{8}$') {
                        [datetime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null).ToString('yyyy-MM-dd')
                    } else { $_.InstallDate }
                }},
                @{N="SizeMB";E={[math]::Round($_.EstimatedSize/1024, 1)}} |
            Sort-Object DisplayName -Unique
        } -ErrorAction Stop

        Write-Host "  Found $($software.Count) packages" -ForegroundColor Green
        $software | Format-Table DisplayName, DisplayVersion, Publisher, InstallDateFormatted, SizeMB -AutoSize

        $software | ForEach-Object {
            $_ | Add-Member -NotePropertyName Computer -NotePropertyValue $computer -PassThru
        } | ForEach-Object { $results += $_ }
    } catch {
        Write-Host "  [ERROR] $computer : $_" -ForegroundColor Red
    }
}

if ($ExportCSV) {
    $results | Select-Object Computer, DisplayName, DisplayVersion, Publisher, InstallDateFormatted, SizeMB |
        Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "`n[OK] Exported to $ExportCSV" -ForegroundColor Green
}
