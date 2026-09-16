# Client report layer

The audit scripts in this repo collect facts. This turns those facts into the document a
client pays for.

## Why this exists

A client does not buy `Get-MFAStatusReport.ps1`. They buy "here are the four active
accounts with no MFA, here is why that is the thing that ends up in a breach notification,
here is what to do about it." That translation is the billable part, it is the same work
on every engagement, and so it is written once here rather than by hand each time.

The practical consequence: an audit that takes hours the first time takes minutes by the
fifth, while the deliverable stays the same. Price the engagement flat.

## Use

```powershell
# 1. Run whichever audits the engagement covers, exporting CSV.
.\m365-azure\Get-MFAStatusReport.ps1   -ExportCSV .\exports\Get-MFAStatusReport.csv
.\security-audit\Get-BitLockerStatus.ps1 -ExportCSV .\exports\Get-BitLockerStatus.csv
.\user-management\Get-InactiveUsers.ps1  -ExportCSV .\exports\Get-InactiveUsers.csv

# 2. Build the report.
.\reporting\New-ClientAuditReport.ps1 -InputPath .\exports -ClientName "Contoso Ltd" -PreparedBy "Your Firm"
```

Output is one self-contained HTML file. No CDN, no fonts to fetch, no network needed, so
it opens on a client machine that has none and prints to PDF from the browser.

CSV file names must start with the audit name, so `Get-MFAStatusReport-contoso.csv` matches
and `mfa-report.csv` does not. Files with no matching rules are named in the report footer
as **not included**, never folded in as clean.

Try it against the bundled fixtures:

```powershell
.\reporting\New-ClientAuditReport.ps1 -InputPath .\reporting\samples -ClientName "Contoso Ltd"
```

## Adding an audit

Add an entry to `findings-rules.json`, keyed by the script name. No code changes.

```json
"Get-YourAudit": {
  "title": "What the client calls this area",
  "idColumn": "UPN",
  "nameColumn": "DisplayName",
  "rules": [{
    "when": { "column": "SomeColumn", "equals": "False" },
    "and":  { "column": "Enabled", "equals": "True" },
    "severity": "high",
    "finding": "Short label",
    "impact": "Why an owner should care, in their language, not an engineer's.",
    "remediation": "The specific next action."
  }]
}
```

Conditions: `equals` (case-insensitive, trimmed), `contains`, `greaterThan`, `lessThan`.
Numeric comparisons skip the row when either side will not parse, so a blank cell can
never silently satisfy a threshold. `and` adds one extra condition to the same rule.

**Write rules that stand on their own.** A rule that only checks `Enabled` and assumes the
collecting script already filtered will report whatever it is handed. That defect shipped
here once: the dormant-account rule trusted upstream filtering and flagged a user who had
signed in six days earlier. It now tests `DaysInactive` itself.

## Every section states its denominator

A section with no findings reads "0 findings across 143 items checked", never "no issues
found". A check that found nothing and a check that never ran look identical in a report
that omits the population, and the client cannot tell them apart. Clean areas stay in the
report for the same reason.

## Before selling write operations

Read-only audits are safe to run in a client tenant today. The repo's rollback support is
a design goal rather than an implementation, and the Pester suite does not run in CI, so
anything that writes to a client environment needs hardening first. See the root README.
