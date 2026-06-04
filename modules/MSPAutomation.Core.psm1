# MSP Automation Core Module
# Provides base functionality for all API-ready automation modules

using namespace System.Collections.Generic
using namespace System.Diagnostics

# Standardized response format
class ApiResponse {
    [bool]$Success
    [string]$Message
    [object]$Data
    [string]$ErrorCode
    [hashtable]$Metadata
    [datetime]$Timestamp

    ApiResponse([bool]$success, [string]$message, [object]$data) {
        $this.Success = $success
        $this.Message = $message
        $this.Data = $data
        $this.ErrorCode = if (-not $success) { "AUTOMATION_ERROR" } else { $null }
        $this.Metadata = @{}
        $this.Timestamp = Get-Date
    }

    [string] ToJson() {
        return $this | ConvertTo-Json -Depth 10
    }
}

# Standardized error codes
enum MSPErrorCode {
    VALIDATION_ERROR
    AUTHORIZATION_ERROR
    NOT_FOUND
    CONFLICT
    RATE_LIMIT_EXCEEDED
    TIMEOUT
    EXTERNAL_SERVICE_ERROR
    DEPENDENCY_ERROR
    PARTIAL_SUCCESS
    CONNECTION_ERROR
    INTERNAL_ERROR
}

# Custom exception for validation failures
class ValidationException : System.Exception {
    ValidationException([string]$message) : base($message) {}
}

# Observability hooks
class Observability {
    static [hashtable]$Metrics = @{}
    static [hashtable]$Traces = @{}

    static [void] RecordMetric([string]$name, [double]$value, [hashtable]$tags) {
        $key = "$name-$($tags.Values -join '-')"
        [Observability]::Metrics[$key] = @{
            Name      = $name
            Value     = $value
            Tags      = $tags
            Timestamp = Get-Date
        }
    }

    static [void] StartTrace([string]$operationId, [string]$operationName) {
        [Observability]::Traces[$operationId] = @{
            OperationName = $operationName
            StartTime     = Get-Date
            Status        = "InProgress"
            Spans         = @()
        }
    }

    static [void] EndTrace([string]$operationId, [string]$status) {
        if ([Observability]::Traces.ContainsKey($operationId)) {
            $start = [Observability]::Traces[$operationId].StartTime
            [Observability]::Traces[$operationId].EndTime  = Get-Date
            [Observability]::Traces[$operationId].Status   = $status
            [Observability]::Traces[$operationId].Duration = (Get-Date) - $start
        }
    }

    static [hashtable] GetMetrics() { return [Observability]::Metrics }
    static [hashtable] GetTraces()  { return [Observability]::Traces  }
}

# Validation framework
class Validator {
    static [bool] ValidateRequired([object]$value, [string]$fieldName) {
        if ($null -eq $value -or $value -eq "") {
            throw [ValidationException]::new("Field '$fieldName' is required")
        }
        return $true
    }

    static [bool] ValidatePattern([string]$value, [string]$pattern, [string]$fieldName) {
        if (-not ($value -match $pattern)) {
            throw [ValidationException]::new("Field '$fieldName' does not match required pattern '$pattern'")
        }
        return $true
    }

    static [bool] ValidateRange([int]$value, [int]$min, [int]$max, [string]$fieldName) {
        if ($value -lt $min -or $value -gt $max) {
            throw [ValidationException]::new("Field '$fieldName' must be between $min and $max")
        }
        return $true
    }

    static [bool] ValidateEnum([object]$value, [array]$validValues, [string]$fieldName) {
        if ($value -notin $validValues) {
            throw [ValidationException]::new("Field '$fieldName' must be one of: $($validValues -join ', ')")
        }
        return $true
    }
}

# Idempotency helper
class Idempotency {
    static [string] GenerateIdempotencyKey([hashtable]$parameters) {
        $paramString = ($parameters.GetEnumerator() |
            Sort-Object Name |
            ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "&"
        $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($paramString)
        $sha256    = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha256.ComputeHash($hashBytes)
            # Return full 32-char hex string to avoid collision risk
            return [System.BitConverter]::ToString($hash).Replace("-", "").ToLower()
        } finally {
            $sha256.Dispose()
        }
    }

    static [bool] CheckIdempotency([string]$key, [string]$stateStorePath) {
        return Test-Path (Join-Path $stateStorePath "$key.json")
    }

    static [object] GetIdempotentResult([string]$key, [string]$stateStorePath) {
        $stateFile = Join-Path $stateStorePath "$key.json"
        if (Test-Path $stateFile) {
            return Get-Content $stateFile -Raw | ConvertFrom-Json
        }
        return $null
    }

    static [void] SaveIdempotentResult([string]$key, [object]$result, [string]$stateStorePath) {
        if (-not (Test-Path $stateStorePath)) {
            New-Item -ItemType Directory -Path $stateStorePath -Force | Out-Null
        }
        $result | ConvertTo-Json -Depth 10 |
            Out-File (Join-Path $stateStorePath "$key.json") -Force -Encoding UTF8
    }
}

# Security context
class SecurityContext {
    [string]$TenantId
    [string]$UserId
    [string[]]$Roles
    [hashtable]$Permissions

    SecurityContext([string]$tenantId, [string]$userId) {
        $this.TenantId    = $tenantId
        $this.UserId      = $userId
        $this.Roles       = @()
        $this.Permissions = @{}
    }

    [bool] HasPermission([string]$permission) {
        return $this.Permissions.ContainsKey($permission) -and $this.Permissions[$permission]
    }

    [bool] HasRole([string]$role) {
        return $role -in $this.Roles
    }
}

# Response builder helpers
function New-ApiResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [bool]$Success,
        [Parameter(Mandatory = $true)] [string]$Message,
        [object]$Data,
        [string]$ErrorCode,
        [hashtable]$Metadata
    )
    $response = [ApiResponse]::new($Success, $Message, $Data)
    if ($ErrorCode)  { $response.ErrorCode = $ErrorCode }
    if ($Metadata)   { $response.Metadata  = $Metadata  }
    return $response
}

function New-ErrorResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Message,
        [string]$ErrorCode = "INTERNAL_ERROR",
        [object]$Data,
        [hashtable]$Metadata
    )
    return New-ApiResponse -Success $false -Message $Message -Data $Data `
        -ErrorCode $ErrorCode -Metadata $Metadata
}

function New-SuccessResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Message,
        [object]$Data,
        [hashtable]$Metadata
    )
    return New-ApiResponse -Success $true -Message $Message -Data $Data -Metadata $Metadata
}

# Standardized execution wrapper.
# IMPORTANT: $ScriptBlock must be a plain scriptblock that accepts $Parameters as a
# hashtable via a single [hashtable] param - NOT a param() block with named params.
# Callers invoke it as: { param([hashtable]$p) ... $p.ComputerName ... }
# and pass -Parameters @{ ComputerName = ... }
function Invoke-AutomationOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [string]$OperationName,
        [Parameter(Mandatory = $true)]  [scriptblock]$ScriptBlock,
        [hashtable]$Parameters          = @{},
        [string]$StateStorePath         = "C:\AutomationState",
        [switch]$EnableIdempotency,
        [switch]$EnableObservability
    )

    $operationId = [Guid]::NewGuid().ToString()

    try {
        if ($EnableObservability) {
            [Observability]::StartTrace($operationId, $OperationName)
        }

        # Return cached result for identical parameter sets
        if ($EnableIdempotency -and $Parameters.Count -gt 0) {
            $idempotencyKey = [Idempotency]::GenerateIdempotencyKey($Parameters)
            $existingResult = [Idempotency]::GetIdempotentResult($idempotencyKey, $StateStorePath)
            if ($existingResult) {
                Write-Verbose "[$OperationName] Idempotent: returning cached result for key $idempotencyKey"
                return $existingResult
            }
        }

        # Invoke - pass Parameters hashtable as the sole argument
        $result = & $ScriptBlock $Parameters

        if ($EnableIdempotency -and $Parameters.Count -gt 0 -and $result -is [ApiResponse]) {
            $idempotencyKey = [Idempotency]::GenerateIdempotencyKey($Parameters)
            [Idempotency]::SaveIdempotentResult($idempotencyKey, $result, $StateStorePath)
        }

        if ($EnableObservability) {
            [Observability]::EndTrace($operationId, "Success")
        }

        return $result

    } catch {
        if ($EnableObservability) {
            [Observability]::EndTrace($operationId, "Error")
        }

        return New-ErrorResponse -Message "Operation '$OperationName' failed: $($_.Exception.Message)" `
            -ErrorCode "INTERNAL_ERROR" -Data @{
                Exception        = $_.Exception.Message
                ScriptStackTrace = $_.ScriptStackTrace
            }
    }
}

Export-ModuleMember -Function @(
    'New-ApiResponse',
    'New-ErrorResponse',
    'New-SuccessResponse',
    'Invoke-AutomationOperation'
)
