# MSP Automation API Library v2.0

## Overview

This is a production-ready, API-automation library designed specifically for orchestration platforms like Rewst, n8n, and other automation frameworks. It transforms traditional PowerShell scripts into standardized, idempotent, observable API endpoints with comprehensive error handling, rollback capabilities, and enterprise-grade security.

## What Changed in v2.0

**From**: Interactive PowerShell scripts for manual execution  
**To**: API-ready automation modules for orchestration platform integration

### Key Transformations

- **API-Ready Structure**: All modules return standardized JSON responses with HTTP-like error codes
- **Idempotency Guarantees**: Operations can be safely re-run without side effects
- **Rollback Capabilities**: Every destructive operation has an automatic rollback companion
- **Observability Integration**: Built-in Prometheus metrics and distributed tracing (OpenTelemetry-compatible)
- **Security Boundaries**: Documented permission models and least-privilege execution
- **Schema Contracts**: JSON Schema and OpenAPI specifications for all operations
- **Comprehensive Testing**: Pester test suite with CI/CD integration
- **Multi-Tenant Support**: Built-in tenant isolation and context management

## Architecture

```
msp-admin-scripts/
├── modules/                    # API-ready automation modules
│   ├── MSPAutomation.Core.psm1 # Core framework (responses, validation, observability)
│   ├── Endpoint/               # System inventory and health checks
│   ├── Security/               # Security operations and compliance
│   ├── Backup/                 # Backup verification and recovery
│   ├── Patching/               # Patch management operations
│   ├── Compliance/             # Multi-framework compliance auditing
│   └── UserManagement/         # AD user lifecycle with rollback
├── schemas/                    # JSON Schema contracts for validation
├── specs/                      # OpenAPI/Swagger specifications
├── observability/              # Prometheus metrics and distributed tracing
├── security/                   # Security boundaries and permission models
├── tests/                      # Pester test suite
├── rollbacks/                  # Rollback state management
├── config/                     # Configuration management
└── .github/workflows/          # CI/CD pipeline
```

## Quick Start for Orchestration Platforms

### 1. Integration with Rewst

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

### 2. Integration with n8n

```javascript
// PowerShell Execute node
$modulePath = "C:\\Scripts\\msp-admin-scripts\\modules\\Endpoint\\Get-SystemInventory.psm1"
Import-Module $modulePath -Force

$result = Get-SystemInventory -ComputerName @("PC01", "PC02") -IncludeDiskSpace
return $result.ToJson()
```

### 3. Direct PowerShell Usage

```powershell
# Import the core module
Import-Module "C:\Scripts\msp-admin-scripts\modules\MSPAutomation.Core.psm1" -Force

# Import specific module
Import-Module "C:\Scripts\msp-admin-scripts\modules\Endpoint\Get-SystemInventory.psm1" -Force

# Execute operation
$response = Get-SystemInventory -ComputerName @("PC01", "PC02") -IncludeDiskSpace -EnableIdempotency

# Check response
if ($response.Success) {
    $response.Data | ConvertTo-Json -Depth 10
} else {
    Write-Error "Operation failed: $($response.ErrorCode) - $($response.Message)"
}
```

## Available Modules

### Core Module (`MSPAutomation.Core.psm1`)

**Purpose**: Foundation for all automation operations

**Key Classes**:
- `ApiResponse`: Standardized response format with JSON serialization
- `ErrorCodes`: Standardized error code constants
- `Observability`: Metrics and tracing hooks
- `Validator`: Input validation framework
- `Idempotency`: Idempotency key generation and state management
- `SecurityContext`: Multi-tenant security context

**Key Functions**:
- `New-ApiResponse`, `New-ErrorResponse`, `New-SuccessResponse`
- `Invoke-AutomationOperation`: Standardized execution wrapper

### Endpoint Module

**Functions**:
- `Get-SystemInventory`: Comprehensive system inventory with parallel execution
- `Get-SystemHealth`: Quick health status for monitoring dashboards

**Features**:
- Configurable data collection (disks, network, software)
- Timeout management
- Idempotency support
- Observability integration

**Schema**: `schemas/Get-SystemInventory.schema.json`

### User Management Module

**Functions**:
- `New-ADUser`: Create AD users with standardized settings
- `Undo-ADUserCreation`: Automatic rollback of user creation

**Features**:
- Template user copying
- Home directory creation with permissions
- Automatic rollback on failure
- Group membership management
- Idempotency checks

**Schema**: `schemas/New-ADUser.schema.json`

**Rollback**: Automatic rollback state management

## Standardized Response Format

All modules return `ApiResponse` objects:

```json
{
  "Success": true,
  "Message": "Operation completed successfully",
  "Data": {
    // Operation-specific data
  },
  "ErrorCode": null,
  "Metadata": {},
  "Timestamp": "2026-06-03T16:30:00Z"
}
```

### Error Response Format

```json
{
  "Success": false,
  "Message": "Validation failed",
  "ErrorCode": "VALIDATION_ERROR",
  "Data": {
    "Field": "Username",
    "Issue": "Required field missing"
  },
  "Metadata": {},
  "Timestamp": "2026-06-03T16:30:00Z"
}
```

### Standard Error Codes

- `VALIDATION_ERROR`: Input validation failed
- `AUTHORIZATION_ERROR`: Permission denied
- `NOT_FOUND`: Resource not found
- `CONFLICT`: Resource already exists (idempotency)
- `RATE_LIMIT_EXCEEDED`: Too many requests
- `TIMEOUT`: Operation timed out
- `EXTERNAL_SERVICE_ERROR`: Third-party service failure
- `INTERNAL_ERROR`: Unexpected error

## Observability Integration

### Prometheus Metrics

```powershell
# Import observability module
Import-Module "C:\Scripts\msp-admin-scripts\observability\PrometheusMetrics.psm1" -Force

# Record operation metrics
Record-OperationMetrics -OperationName "Get-SystemInventory" -Success $true -DurationMs 1250

# Record system metrics
Record-SystemMetrics -ComputerName "PC01" -CPUPercent 45.2 -MemoryPercent 72.1 -DiskPercent 85.3

# Export metrics for Prometheus
$metrics = [PrometheusMetrics]::ExportMetrics()
```

### Distributed Tracing

```powershell
# Start a trace
$spanId = Start-OperationTrace -OperationName "UserCreation"

# Add tags
Add-TraceTag -SpanId $spanId -Key "userId" -Value "jdoe"
Add-TraceTag -SpanId $spanId -Key "tenantId" -Value "tenant123"

# Complete the trace
Stop-OperationTrace -SpanId $spanId -Status "OK"

# Get trace parent header for propagation
$header = Get-TraceParentHeader
```

## Security Model

### Permission Requirements

Each module documents exact permission requirements in `security/SecurityBoundaries.md`:

- **Endpoint**: Local Administrator, WinRM access
- **User Management**: AD user creation, file system ACLs
- **Security**: BitLocker, Defender, security logs
- **Backup**: Backup system read access
- **Patching**: Windows Update, service control, reboot
- **Compliance**: Read-only access to all systems

### Multi-Tenant Isolation

```powershell
# Create security context
$securityContext = [SecurityContext]::new("tenant123", "operator456")
$securityContext.Roles = @("UserAdmin", "SecurityReader")

# Check permissions
if ($securityContext.HasPermission("CreateUser")) {
    # Proceed with operation
}
```

## Testing

### Run Pester Tests

```powershell
# Import Pester
Import-Module Pester -MinimumVersion 5.3.0

# Run all tests
Invoke-Pester -Path ./tests/MSPAutomation.Tests.ps1 -Verbose

# Run specific test suite
Invoke-Pester -Path ./tests/MSPAutomation.Tests.ps1 -Filter "Endpoint Module Tests"
```

### CI/CD Pipeline

The library includes a GitHub Actions CI/CD pipeline that:

- Runs Pester tests on every push
- Validates JSON schemas
- Validates OpenAPI specifications
- Performs security scanning with Trivy
- Builds and packages modules
- Deploys to production environments
- Sends notifications via Slack

## Configuration

### Configuration File

Edit `config/MSPConfig.psd1` for environment-specific settings:

```powershell
@{
    Domain = @{
        DNSRoot = "yourdomain.com"
        DefaultOU = "OU=Users,OU=Company,DC=yourdomain,DC=com"
    }
    Logging = @{
        Path = "C:\Logs\MSP"
        Level = "Info"
    }
    Security = @{
        BitLockerRequired = $true
        RequireMFA = $true
    }
}
```

### Environment Variables

```powershell
$env:MSP_CONFIG_PATH = "C:\Scripts\msp-admin-scripts\config\MSPConfig.psd1"
$env:MSP_STATE_PATH = "C:\AutomationState"
$env:MSP_LOG_LEVEL = "Info"
```

## Migration from v1.0 Scripts

### Key Differences

| Feature | v1.0 Scripts | v2.0 Modules |
|---------|-------------|--------------|
| Execution | Interactive | API-ready |
| Output | Console + CSV | Structured JSON |
| Error Handling | Basic try/catch | Standardized error codes |
| Idempotency | Manual | Built-in |
| Rollback | Manual | Automatic |
| Observability | File logging | Prometheus + Tracing |
| Testing | Manual | Comprehensive Pester |
| Documentation | Comment-based | Schema + OpenAPI |

### Migration Example

**Old (v1.0)**:
```powershell
.\Get-SystemInventory.ps1 -ComputerName PC01,PC02 -ExportCSV "inventory.csv"
```

**New (v2.0)**:
```powershell
$response = Get-SystemInventory -ComputerName @("PC01", "PC02") -EnableIdempotency
if ($response.Success) {
    $response.Data.Inventory | ConvertTo-Json -Depth 10 | Out-File "inventory.json"
}
```

## Performance Characteristics

### Benchmarks

- **System Health Check**: < 2 seconds per system
- **System Inventory**: ~5 seconds per system (with basic info)
- **User Creation**: ~3 seconds (without template)
- **Parallel Execution**: Scales linearly to 10 concurrent operations

### Resource Usage

- **Memory**: ~50MB base + ~10MB per concurrent operation
- **CPU**: Minimal during steady state, spikes during WMI queries
- **Network**: ~1KB per system for health checks, ~50KB for full inventory

## Troubleshooting

### Common Issues

**Module Import Errors**:
```powershell
# Ensure PowerShell 7+ is installed
pwsh --version

# Check execution policy
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**Permission Errors**:
```powershell
# Verify you have required permissions
# Check security/SecurityBoundaries.md for specific requirements
```

**Idempotency State Issues**:
```powershell
# Clear idempotency state if needed
Remove-Item "C:\AutomationState\*" -Recurse -Force
```

## Roadmap

### v2.1 (Planned)
- Additional modules for remaining v1.0 scripts
- Azure AD and Microsoft Graph integration
- Enhanced rollback capabilities
- Performance optimizations

### v2.2 (Planned)
- Additional compliance frameworks (ISO 27001, PCI DSS)
- Cloud platform modules (AWS, Azure, GCP)
- Advanced threat detection integration
- Mobile device management modules

### v3.0 (Future)
- REST API wrapper for HTTP access
- GraphQL interface
- Web UI for manual operations
- Advanced workflow orchestration

## Support and Contribution

### Getting Help
- Check `security/SecurityBoundaries.md` for permission issues
- Review test files for usage examples
- Enable verbose logging for debugging
- Check observability metrics for performance issues

### Contributing
- Follow existing code patterns in modules
- Add comprehensive Pester tests for new functions
- Update JSON schemas for new operations
- Document security boundaries for new modules
- Update OpenAPI specs for new endpoints

## License

This automation library is provided as operational tools for MSP environments. Customize and adapt to your specific needs while maintaining security best practices and compliance requirements.

---

**Version**: 2.0.0  
**Last Updated**: 2026-06-03  
**Maintained By**: Eudai Gestalt Integrations (EGI)  
**Support**: dgb@workflowtech.ai