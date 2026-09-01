# MSP Automation API Library

## What this is

A **reference implementation** of an API-shaped automation pattern for MSP orchestration
platforms like Rewst and n8n. It takes the usual pile of interactive PowerShell scripts
and shows what they look like when they are rebuilt as callable operations: standardized
JSON responses, machine-checkable input validation, idempotency keys, a metrics and
tracing surface, and schema contracts.

**What it is not:** a published, versioned, production-deployed library. There are no
releases, no tags, no PowerShell Gallery package, and no users besides its author. The
Pester suite does not run in CI (see [Testing](#testing) for why). Treat this as a worked
example of the pattern, not as a dependency.

The pattern is the point. The code demonstrates it on a handful of real operations.

## Status of each capability

Being precise about this up front, because a README that oversells is worse than no
README.

| Capability | Status |
|---|---|
| Standardized JSON responses (`ApiResponse`) | **Implemented** |
| Input validation (`Validator`) | **Implemented** |
| Idempotency keys and state (`Idempotency`) | **Implemented** |
| Multi-tenant security context (`SecurityContext`) | **Implemented** |
| Standardized execution wrapper (`Invoke-AutomationOperation`) | **Implemented** |
| Prometheus metrics | **Implemented** |
| Distributed tracing, W3C `traceparent` format | **Implemented**, hand-rolled. Not an OpenTelemetry SDK integration. |
| JSON Schema contracts | **Partial.** Three schemas, not one per operation. |
| OpenAPI specification | **Partial.** 23 operations described. |
| Pester test suite | **Written, but not run in CI.** No mocking; needs a live host and AD. |
| Rollback | **Not implemented.** Design goal only. See [Rollback](#rollback). |
| CI/CD pipeline | **Standards and secret scanning only.** No Pester run, no packaging, no deploy. |

## Architecture

```
msp-automation-api/
├── modules/
│   ├── MSPAutomation.Core.psm1   Core framework: responses, validation,
│   │                             idempotency, security context, observability hooks
│   ├── Endpoint/                 Get-SystemInventory.psm1, Get-DiskSpaceAlert.psm1
│   ├── M365/                     Get-M365Audit.psm1
│   ├── Maintenance/              Invoke-Maintenance.psm1
│   ├── Network/                  Get-NetworkInfo.psm1
│   ├── Security/                 Get-SecurityAudit.psm1
│   └── UserManagement/           New-ADUser.psm1, Invoke-UserLifecycle.psm1
├── observability/                PrometheusMetrics.psm1 (metrics + W3C tracing)
├── schemas/                      AllModules, Get-SystemInventory, New-ADUser
├── specs/                        msp-automation-openapi.yaml
├── security/                     SecurityBoundaries.md
├── config/                       MSPConfig.psd1
├── tests/                        MSPAutomation.Tests.ps1
├── docs/
└── .github/workflows/            ci-standards, claude-review, secret-scan
```

The `backup-recovery/`, `compliance/`, `endpoint-inventory/`, `m365-azure/`,
`maintenance/`, `network/`, `patch-management/`, `security-audit/` and `user-management/`
directories at the repo root hold the **original v1 interactive scripts**. They are kept
for reference. The API-shaped rewrite lives under `modules/` and covers a subset of them.

`Mail-Zapper.ps1` at the root is a standalone v1 utility, unrelated to the module
framework.

## Quick start

### With Rewst

```json
{
  "workflow": "System Inventory",
  "trigger": "Scheduled",
  "steps": [
    {
      "action": "powershell",
      "module": "MSPAutomation.Core",
      "function": "Invoke-AutomationOperation",
      "parameters": {
        "operation": "Get-SystemInventory",
        "ComputerName": ["PC01", "PC02"],
        "IncludeDiskSpace": true,
        "EnableIdempotency": true
      }
    }
  ]
}
```

### With n8n

```javascript
// PowerShell Execute node
$modulePath = "C:\\Scripts\\msp-automation-api\\modules\\Endpoint\\Get-SystemInventory.psm1"
Import-Module $modulePath -Force

$result = Get-SystemInventory -ComputerName @("PC01", "PC02") -IncludeDiskSpace
return $result.ToJson()
```

### Direct

```powershell
Import-Module "C:\Scripts\msp-automation-api\modules\MSPAutomation.Core.psm1" -Force
Import-Module "C:\Scripts\msp-automation-api\modules\Endpoint\Get-SystemInventory.psm1" -Force

$response = Get-SystemInventory -ComputerName @("PC01", "PC02") -IncludeDiskSpace -EnableIdempotency

if ($response.Success) {
    $response.Data | ConvertTo-Json -Depth 10
} else {
    Write-Error "Operation failed: $($response.ErrorCode) - $($response.Message)"
}
```

## Core module

`modules/MSPAutomation.Core.psm1`

**Classes:** `ApiResponse`, `ValidationException`, `Observability`, `Validator`,
`Idempotency`, `SecurityContext`.

**Exported functions:** `New-ApiResponse`, `New-ErrorResponse`, `New-SuccessResponse`,
`Invoke-AutomationOperation`.

Error codes are string constants used in `ApiResponse.ErrorCode`, not a class.

## Available operations

| Module | Functions |
|---|---|
| Endpoint | `Get-SystemInventory`, `Get-SystemHealth`, `Get-DiskSpaceAlert` |
| M365 | `Get-M365Audit` |
| Maintenance | `Invoke-Maintenance` |
| Network | `Get-NetworkInfo` |
| Security | `Get-SecurityAudit` |
| UserManagement | `New-ADUser`, `Invoke-UserLifecycle` |

`Get-SystemHealth` ships inside `Get-SystemInventory.psm1`.

## Response format

Every operation returns an `ApiResponse`:

```json
{
  "Success": true,
  "Message": "Operation completed successfully",
  "Data": {},
  "ErrorCode": null,
  "Metadata": {},
  "Timestamp": "2026-06-03T16:30:00Z"
}
```

Error shape:

```json
{
  "Success": false,
  "Message": "Validation failed",
  "ErrorCode": "VALIDATION_ERROR",
  "Data": { "Field": "Username", "Issue": "Required field missing" },
  "Metadata": {},
  "Timestamp": "2026-06-03T16:30:00Z"
}
```

Error codes in use: `VALIDATION_ERROR`, `AUTHORIZATION_ERROR`, `NOT_FOUND`, `CONFLICT`,
`RATE_LIMIT_EXCEEDED`, `TIMEOUT`, `EXTERNAL_SERVICE_ERROR`, `INTERNAL_ERROR`.

## Observability

`observability/PrometheusMetrics.psm1` holds two classes, `PrometheusMetrics` and
`DistributedTracing`, and exports six functions.

### Metrics

```powershell
Import-Module "C:\Scripts\msp-automation-api\observability\PrometheusMetrics.psm1" -Force

Write-OperationMetrics -OperationName "Get-SystemInventory" -Success $true -DurationMs 1250
Write-SystemMetrics -ComputerName "PC01" -CPUPercent 45.2 -MemoryPercent 72.1 -DiskPercent 85.3

$metrics = [PrometheusMetrics]::ExportMetrics()
```

### Tracing

```powershell
$spanId = Start-OperationTrace -OperationName "UserCreation"
Add-TraceTag -SpanId $spanId -Key "userId" -Value "jdoe"
Stop-OperationTrace -SpanId $spanId -Status "OK"
Get-TraceParentHeader
```

Spans are emitted in **W3C Trace Context `traceparent` format**, which is what makes them
readable by an OpenTelemetry collector downstream. There is no OTel SDK in this repo and
no exporter. The header format is the whole of the compatibility claim.

## Rollback

**Not implemented.** The design intent is that every destructive operation ships an
`Undo-` companion and that `Invoke-AutomationOperation` records enough state to call it.
Neither exists yet: there is no rollback framework in the core module, no `rollbacks/`
directory, and no `Undo-` function in any module.

`New-ADUser` performs its own cleanup on failure within a single invocation. That is
error handling, not rollback, and it does not survive the process exiting.

If you are evaluating this repo for rollback behaviour, it is not here.

## Security model

`security/SecurityBoundaries.md` documents the permission requirements per module.

Multi-tenant isolation is expressed through `SecurityContext`:

```powershell
$securityContext = [SecurityContext]::new("tenant123", "operator456")
$securityContext.Roles = @("UserAdmin", "SecurityReader")

if ($securityContext.HasPermission("CreateUser")) {
    # proceed
}
```

## Testing

```powershell
Import-Module Pester -MinimumVersion 5.3.0
Invoke-Pester -Path ./tests/MSPAutomation.Tests.ps1 -Verbose
```

**The suite does not run in CI, and this is the honest reason:** it uses no mocking. It
resolves `$env:COMPUTERNAME` and probes for the ActiveDirectory module, so it needs a real
Windows host in a real domain. A clean CI runner has neither, so wiring it into a workflow
today would produce a red build that says nothing about the code.

Fixing it means mocking the AD and WMI calls so the suite tests the framework rather than
the host. That work has not been done.

## CI

`.github/workflows/` contains three workflows, all vendored from the builder kit:

| Workflow | What it does |
|---|---|
| `ci-standards.yml` | Standards-drift check and header/secret-hygiene tests |
| `claude-review.yml` | Automated review on pull requests |
| `secret-scan.yml` | Secret scanning |

`ci-standards.yml` detects Node, Python and .NET projects. **It does not detect
PowerShell**, so no Pester step runs. There is no packaging step, no Trivy scan, no
deployment stage and no notification integration.

## Configuration

`config/MSPConfig.psd1`:

```powershell
@{
    Domain = @{
        DNSRoot    = "yourdomain.com"
        DefaultOU  = "OU=Users,OU=Company,DC=yourdomain,DC=com"
    }
    Logging  = @{ Path = "C:\Logs\MSP"; Level = "Info" }
    Security = @{ BitLockerRequired = $true; RequireMFA = $true }
}
```

Environment variables:

```powershell
$env:MSP_CONFIG_PATH = "C:\Scripts\msp-automation-api\config\MSPConfig.psd1"
$env:MSP_STATE_PATH  = "C:\AutomationState"
$env:MSP_LOG_LEVEL   = "Info"
```

## What the v1 to v2 rewrite changed

| Feature | v1 scripts | v2 modules |
|---|---|---|
| Execution | Interactive | Callable operation |
| Output | Console + CSV | Structured JSON |
| Error handling | try/catch | Standardized error codes |
| Idempotency | Manual | Built in |
| Observability | File logging | Prometheus + W3C tracing |
| Testing | Manual | Pester suite (not yet in CI) |
| Documentation | Comment-based | Schema + OpenAPI, partial coverage |

The v1 scripts remain in the root directories. The rewrite covers a subset of them.

## Known gaps

Listed so nobody has to discover them by reading the source:

- No rollback framework, and no `Undo-` functions.
- Pester suite is unmockable, so it does not run in CI.
- Schema coverage is 3 files, not one per operation.
- The OpenAPI spec describes 23 operations.
- No LICENSE file. Usage terms are undefined; ask before depending on it.
- No releases, tags, or PowerShell Gallery package.
- Performance figures are not published here because none have been measured under
  controlled conditions.

## Roadmap

In the order that would make this a real library:

1. Mock the AD and WMI calls so the Pester suite runs on a clean runner, then add a
   PowerShell detection branch so CI executes it.
2. Add a LICENSE file.
3. Implement the rollback framework the response contract already implies.
4. Bring schema coverage to one file per operation.
5. Publish to the PowerShell Gallery with a real version number.

---

**Maintained by:** Eudai Gestalt Integrations (EGI)
**Contact:** dgb@workflowtech.ai
