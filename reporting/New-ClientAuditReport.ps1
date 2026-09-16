#Requires -Version 5.1
<#
.SYNOPSIS
    Turns raw audit script output into the client-ready report a client actually pays for.

.DESCRIPTION
    The scripts in this repo collect facts. Nobody buys facts. They buy the document that
    says which facts matter, how much, and what to do about them. This is that layer, and
    it is deliberately the only part that needs writing once: adding a new audit means
    adding an entry to findings-rules.json, not editing this file.

    Takes one or more CSVs exported by the audit scripts (every one of them supports
    -ExportCSV), matches each to its rules by file name, and emits a single self-contained
    HTML file. No external assets, no CDN, no fonts to fetch, so it opens on a client
    machine with no network and prints to PDF from the browser.

    EVERY SECTION STATES ITS DENOMINATOR. A section with no findings reads "0 of 143
    accounts" and never "no issues found", because a check that found nothing and a check
    that never ran look identical in a report that omits the population, and the client
    cannot tell them apart. That distinction is the difference between a report and a
    reassurance.

.PARAMETER InputPath
    A directory of CSVs, or one or more CSV paths. File names must begin with the audit
    name as it appears in findings-rules.json, e.g. Get-MFAStatusReport-contoso.csv.

.PARAMETER ClientName
    Appears in the report title and header.

.PARAMETER OutputPath
    Where to write the HTML. Defaults to .\<ClientName>-audit-<date>.html

.PARAMETER RulesPath
    Override the rules file. Defaults to findings-rules.json beside this script.

.PARAMETER PreparedBy
    Appears in the footer. Defaults to nothing, so it is never wrong by accident.

.EXAMPLE
    .\New-ClientAuditReport.ps1 -InputPath .\exports -ClientName "Contoso Ltd"

.EXAMPLE
    .\Get-MFAStatusReport.ps1 -ExportCSV .\exports\Get-MFAStatusReport.csv
    .\Get-InactiveUsers.ps1   -ExportCSV .\exports\Get-InactiveUsers.csv
    .\New-ClientAuditReport.ps1 -InputPath .\exports -ClientName "Contoso Ltd" -PreparedBy "EGI"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]] $InputPath,
    [Parameter(Mandatory)][string]   $ClientName,
    [string] $OutputPath,
    [string] $RulesPath,
    [string] $PreparedBy = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- rules

if (-not $RulesPath) {
    $RulesPath = Join-Path $PSScriptRoot 'findings-rules.json'
}
if (-not (Test-Path $RulesPath)) {
    throw "Rules file not found: $RulesPath"
}
$rules = Get-Content $RulesPath -Raw | ConvertFrom-Json

# ---------------------------------------------------------------- inputs

$csvFiles = foreach ($p in $InputPath) {
    if (Test-Path $p -PathType Container) {
        Get-ChildItem -Path $p -Filter *.csv -File
    } elseif (Test-Path $p -PathType Leaf) {
        Get-Item $p
    } else {
        Write-Warning "Skipping path that does not exist: $p"
    }
}

if (-not $csvFiles) {
    throw "No CSV files found under: $($InputPath -join ', ')"
}

# ---------------------------------------------------------------- matching

# A rule matches one column of one row. Comparisons are string-based on purpose: CSV has
# no types, and "False" from Export-Csv is a string whatever it started as. Numeric
# operators parse both sides and skip the row when either side will not parse, so a blank
# or malformed cell can never silently satisfy a "greater than" test.
function Test-Condition {
    param($Row, $Condition)

    $col = $Condition.column
    if (-not ($Row.PSObject.Properties.Name -contains $col)) { return $false }

    $value = [string]$Row.$col

    if ($Condition.PSObject.Properties.Name -contains 'equals') {
        return $value.Trim() -ieq ([string]$Condition.equals).Trim()
    }
    if ($Condition.PSObject.Properties.Name -contains 'contains') {
        return $value -imatch [regex]::Escape([string]$Condition.contains)
    }
    if ($Condition.PSObject.Properties.Name -contains 'greaterThan') {
        $l = 0.0; $r = 0.0
        if (-not [double]::TryParse($value, [ref]$l))                  { return $false }
        if (-not [double]::TryParse([string]$Condition.greaterThan, [ref]$r)) { return $false }
        return $l -gt $r
    }
    if ($Condition.PSObject.Properties.Name -contains 'lessThan') {
        $l = 0.0; $r = 0.0
        if (-not [double]::TryParse($value, [ref]$l))                { return $false }
        if (-not [double]::TryParse([string]$Condition.lessThan, [ref]$r)) { return $false }
        return $l -lt $r
    }
    return $false
}

function Get-RowLabel {
    param($Row, $AuditRules)

    $parts = @()
    foreach ($key in @('nameColumn', 'idColumn')) {
        if ($AuditRules.PSObject.Properties.Name -contains $key) {
            $col = $AuditRules.$key
            if ($col -and ($Row.PSObject.Properties.Name -contains $col)) {
                $v = [string]$Row.$col
                if ($v -and ($parts -notcontains $v)) { $parts += $v }
            }
        }
    }
    if (-not $parts) {
        # No configured label column resolved, so fall back to the first non-empty cell
        # rather than printing an empty row the client cannot act on.
        $first = $Row.PSObject.Properties | Where-Object { $_.Value } | Select-Object -First 1
        if ($first) { $parts += [string]$first.Value }
    }
    return ($parts -join ' · ')
}

$sections = @()
$unmatched = @()

foreach ($file in $csvFiles) {
    $auditName = ($rules.PSObject.Properties.Name | Where-Object { $file.BaseName -like "$_*" } |
                  Sort-Object Length -Descending | Select-Object -First 1)

    if (-not $auditName) {
        $unmatched += $file.Name
        continue
    }

    $auditRules = $rules.$auditName
    $rows = @(Import-Csv -Path $file.FullName)

    $findings = @()
    foreach ($row in $rows) {
        foreach ($rule in $auditRules.rules) {
            if (-not (Test-Condition -Row $row -Condition $rule.when)) { continue }
            if ($rule.PSObject.Properties.Name -contains 'and') {
                if (-not (Test-Condition -Row $row -Condition $rule.and)) { continue }
            }
            $findings += [pscustomobject]@{
                Severity    = $rule.severity
                Finding     = $rule.finding
                Impact      = $rule.impact
                Remediation = $rule.remediation
                Subject     = Get-RowLabel -Row $row -AuditRules $auditRules
            }
        }
    }

    $sections += [pscustomobject]@{
        Audit      = $auditName
        Title      = $auditRules.title
        Population = $rows.Count
        Findings   = $findings
        Source     = $file.Name
    }
}

if (-not $sections) {
    throw "None of the supplied CSVs matched a known audit. Files seen: $($csvFiles.Name -join ', '). Known audits: $($rules.PSObject.Properties.Name -join ', ')."
}

# ---------------------------------------------------------------- rollup

$allFindings = @($sections | ForEach-Object { $_.Findings })
$high   = @($allFindings | Where-Object { $_.Severity -eq 'high' }).Count
$medium = @($allFindings | Where-Object { $_.Severity -eq 'medium' }).Count
$low    = @($allFindings | Where-Object { $_.Severity -eq 'low' }).Count
$totalChecked = ($sections | Measure-Object -Property Population -Sum).Sum

$headline = if ($high -gt 0) {
    "$high issue$(if($high -ne 1){'s'}) need attention now, out of $totalChecked items checked across $($sections.Count) area$(if($sections.Count -ne 1){'s'})."
} elseif ($medium -gt 0) {
    "No urgent issues. $medium item$(if($medium -ne 1){'s'}) worth scheduling, out of $totalChecked items checked."
} else {
    "No issues found against the rules applied, across $totalChecked items checked in $($sections.Count) area$(if($sections.Count -ne 1){'s'})."
}

# ---------------------------------------------------------------- render

function ConvertTo-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

$sevOrder = @{ high = 0; medium = 1; low = 2 }
$generated = Get-Date -Format 'd MMMM yyyy'

$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine(@"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(ConvertTo-Html $ClientName) — IT Audit</title>
<style>
*{box-sizing:border-box}
body{margin:0;background:#f6f6f4;color:#1c1d1f;font:16px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif}
.page{max-width:52rem;margin:0 auto;padding:0 20px 5rem}
header{padding:3rem 0 1.6rem;border-bottom:2px solid #1c1d1f}
.client{font-size:.78rem;letter-spacing:.14em;text-transform:uppercase;color:#6b6f73;margin:0 0 .5rem}
h1{font-size:2rem;margin:0 0 .6rem;font-weight:600;letter-spacing:-.01em}
.headline{font-size:1.1rem;color:#43474b;margin:0}
.scoreboard{display:flex;gap:.8rem;flex-wrap:wrap;margin:2rem 0}
.tile{flex:1 1 8rem;background:#fff;border:1px solid #e0dedb;border-radius:4px;padding:1rem}
.tile .n{font-size:2rem;font-weight:600;line-height:1;font-variant-numeric:tabular-nums}
.tile .l{font-size:.76rem;letter-spacing:.08em;text-transform:uppercase;color:#6b6f73;margin-top:.35rem}
.tile.high .n{color:#a32a15}.tile.medium .n{color:#9a6508}.tile.ok .n{color:#2c6b48}
h2{font-size:1.28rem;margin:2.6rem 0 .3rem;font-weight:600}
.pop{font-size:.85rem;color:#6b6f73;margin:0 0 1rem;font-variant-numeric:tabular-nums}
.finding{background:#fff;border:1px solid #e0dedb;border-left:4px solid #b9b6b1;border-radius:3px;padding:1rem 1.1rem;margin-bottom:.8rem}
.finding.high{border-left-color:#a32a15}
.finding.medium{border-left-color:#9a6508}
.sev{display:inline-block;font-size:.66rem;letter-spacing:.1em;text-transform:uppercase;font-weight:700;padding:.16em .5em;border-radius:2px;vertical-align:.14em}
.sev.high{background:#f7ded8;color:#a32a15}
.sev.medium{background:#faedd4;color:#7d5206}
.sev.low{background:#e7e5e2;color:#5b5f63}
.fname{font-weight:600;margin-left:.5rem}
.subjects{margin:.7rem 0 0;font-size:.9rem}
.subjects ul{margin:.3rem 0 0;padding-left:1.2rem;columns:2;column-gap:2rem}
@media(max-width:560px){.subjects ul{columns:1}}
.subjects li{margin:.12rem 0}
.meta{margin-top:.7rem;font-size:.9rem;color:#43474b}
.meta b{color:#1c1d1f}
.clear{background:#fff;border:1px solid #e0dedb;border-left:4px solid #2c6b48;border-radius:3px;padding:.9rem 1.1rem;color:#43474b;font-size:.94rem}
footer{margin-top:3.5rem;padding-top:1.2rem;border-top:1px solid #d9d6d2;font-size:.8rem;color:#6b6f73}
@media print{body{background:#fff}.page{max-width:none}.finding,.tile,.clear{break-inside:avoid}}
</style></head><body><div class="page">
<header>
<p class="client">$(ConvertTo-Html $ClientName)</p>
<h1>IT Security and Health Audit</h1>
<p class="headline">$(ConvertTo-Html $headline)</p>
</header>
<div class="scoreboard">
<div class="tile $(if($high -gt 0){'high'}else{'ok'})"><div class="n">$high</div><div class="l">Act now</div></div>
<div class="tile $(if($medium -gt 0){'medium'}else{'ok'})"><div class="n">$medium</div><div class="l">Schedule</div></div>
<div class="tile"><div class="n">$totalChecked</div><div class="l">Items checked</div></div>
<div class="tile"><div class="n">$($sections.Count)</div><div class="l">Areas covered</div></div>
</div>
"@)

# Worst first, because the person paying for this reads the top and stops. Sections sort
# by their most severe finding, then by how many of them there are, and only then by name.
# Clean areas fall to the bottom but are never dropped: the client has to be able to see
# what was checked and came back clean, or the report cannot be told apart from a partial one.
$sectionRank = {
    $f = $_.Findings
    if (-not $f.Count) { return 9 }
    ($f | ForEach-Object { $sevOrder[$_.Severity] } | Measure-Object -Minimum).Minimum
}
foreach ($section in ($sections | Sort-Object $sectionRank, @{ e = { -$_.Findings.Count } }, Title)) {
    $null = $sb.AppendLine("<h2>$(ConvertTo-Html $section.Title)</h2>")
    $null = $sb.AppendLine("<p class='pop'>$($section.Findings.Count) finding$(if($section.Findings.Count -ne 1){'s'}) across $($section.Population) item$(if($section.Population -ne 1){'s'}) checked.</p>")

    if (-not $section.Findings.Count) {
        $null = $sb.AppendLine("<div class='clear'>Nothing matched the rules for this area. $($section.Population) item$(if($section.Population -ne 1){'s'}) checked.</div>")
        continue
    }

    $grouped = $section.Findings | Group-Object Finding |
               Sort-Object @{ e = { $sevOrder[$_.Group[0].Severity] } }, @{ e = { -$_.Count } }

    foreach ($g in $grouped) {
        $first = $g.Group[0]
        $sev = $first.Severity
        $null = $sb.AppendLine("<div class='finding $sev'>")
        $null = $sb.AppendLine("<span class='sev $sev'>$sev</span><span class='fname'>$(ConvertTo-Html $first.Finding) &middot; $($g.Count)</span>")
        $null = $sb.AppendLine("<div class='meta'><b>Why it matters.</b> $(ConvertTo-Html $first.Impact)</div>")
        $null = $sb.AppendLine("<div class='meta'><b>What to do.</b> $(ConvertTo-Html $first.Remediation)</div>")
        $null = $sb.AppendLine("<div class='subjects'><b>Affected:</b><ul>")
        foreach ($s in ($g.Group.Subject | Sort-Object -Unique)) {
            $null = $sb.AppendLine("<li>$(ConvertTo-Html $s)</li>")
        }
        $null = $sb.AppendLine("</ul></div></div>")
    }
}

$sourceList = ($sections | ForEach-Object { "$($_.Source) ($($_.Population) rows)" }) -join ', '
$null = $sb.AppendLine("<footer>")
$null = $sb.AppendLine("Generated $generated$(if($PreparedBy){" by $(ConvertTo-Html $PreparedBy)"}). Source data: $(ConvertTo-Html $sourceList).<br>")
$null = $sb.AppendLine("Every section states the number of items checked. A section reporting nothing means the rules found nothing in that population, not that the area was skipped.")
if ($unmatched.Count) {
    $null = $sb.AppendLine("<br><b>Not included:</b> $(ConvertTo-Html ($unmatched -join ', ')) — no matching rules, so these were left out rather than reported as clean.")
}
$null = $sb.AppendLine("</footer></div></body></html>")

if (-not $OutputPath) {
    $safe = ($ClientName -replace '[^\w\-]', '-') -replace '-+', '-'
    $OutputPath = Join-Path (Get-Location) "$safe-audit-$(Get-Date -Format 'yyyy-MM-dd').html"
}

$sb.ToString() | Set-Content -Path $OutputPath -Encoding UTF8

Write-Host "Report written: $OutputPath" -ForegroundColor Green
Write-Host "  $high act-now, $medium scheduled, $totalChecked items checked across $($sections.Count) areas." -ForegroundColor Gray
if ($unmatched.Count) {
    Write-Warning "No rules for: $($unmatched -join ', '). Left out of the report rather than reported clean."
}

[pscustomobject]@{
    OutputPath = $OutputPath
    High       = $high
    Medium     = $medium
    Low        = $low
    Checked    = $totalChecked
    Sections   = $sections.Count
    Unmatched  = $unmatched
}
