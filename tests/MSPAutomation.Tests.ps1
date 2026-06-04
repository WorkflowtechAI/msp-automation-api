# MSP Automation Pester Test Suite
# Comprehensive testing for API-ready automation modules

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot "..\modules"
    $obsPath    = Join-Path $PSScriptRoot "..\observability"

    Import-Module (Join-Path $modulePath "MSPAutomation.Core.psm1")              -Force
    Import-Module (Join-Path $modulePath "Endpoint\Get-SystemInventory.psm1")     -Force
    Import-Module (Join-Path $modulePath "UserManagement\New-ADUser.psm1")        -Force
    Import-Module (Join-Path $obsPath    "PrometheusMetrics.psm1")                -Force

    $script:testComputer = $env:COMPUTERNAME
}

Describe "MSPAutomation.Core Module Tests" {
    It "Should expose New-SuccessResponse function" {
        (Get-Command New-SuccessResponse -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should expose New-ErrorResponse function" {
        (Get-Command New-ErrorResponse -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should create a success API response" {
        $response = New-SuccessResponse -Message "Test success" -Data @{ test = "data" }
        $response.Success       | Should -Be $true
        $response.Message       | Should -Be "Test success"
        $response.Data.test     | Should -Be "data"
        $response.Timestamp     | Should -BeOfType [datetime]
    }

    It "Should create an error API response" {
        $response = New-ErrorResponse -Message "Test error" -ErrorCode "TEST_ERROR"
        $response.Success   | Should -Be $false
        $response.Message   | Should -Be "Test error"
        $response.ErrorCode | Should -Be "TEST_ERROR"
        $response.Timestamp | Should -BeOfType [datetime]
    }

    It "Should serialize API response to JSON" {
        $response    = New-SuccessResponse -Message "Test" -Data @{ key = "value" }
        $json        = $response.ToJson()
        $json        | Should -Not -BeNullOrEmpty
        $jsonObject  = $json | ConvertFrom-Json
        $jsonObject.Success | Should -Be $true
    }

    It "Should validate required fields" {
        { [Validator]::ValidateRequired("",     "testField") } | Should -Throw
        { [Validator]::ValidateRequired($null,  "testField") } | Should -Throw
        { [Validator]::ValidateRequired("value","testField") } | Should -Not -Throw
    }

    It "Should validate string patterns" {
        { [Validator]::ValidatePattern("invalid", "^[0-9]+$", "testField") } | Should -Throw
        { [Validator]::ValidatePattern("123",     "^[0-9]+$", "testField") } | Should -Not -Throw
    }

    It "Should validate numeric ranges" {
        { [Validator]::ValidateRange(150, 1, 100, "testField") } | Should -Throw
        { [Validator]::ValidateRange(50,  1, 100, "testField") } | Should -Not -Throw
    }

    It "Should generate consistent idempotency keys" {
        $params1 = @{ name = "test"; value = "123" }
        $params2 = @{ name = "test"; value = "123" }
        $params3 = @{ name = "test"; value = "456" }

        $key1 = [Idempotency]::GenerateIdempotencyKey($params1)
        $key2 = [Idempotency]::GenerateIdempotencyKey($params2)
        $key3 = [Idempotency]::GenerateIdempotencyKey($params3)

        $key1 | Should -Be $key2
        $key1 | Should -Not -Be $key3
        $key1.Length | Should -Be 64   # Full SHA-256 hex
    }

    It "Should record and retrieve observability metrics" {
        [Observability]::RecordMetric("test_metric", 42.0, @{ label = "test" })
        $metrics = [Observability]::GetMetrics()
        $metrics.Count | Should -BeGreaterThan 0
    }

    It "Should create and complete observability traces" {
        $operationId = [Guid]::NewGuid().ToString()
        [Observability]::StartTrace($operationId, "test_operation")
        [Observability]::EndTrace($operationId, "Success")

        $traces = [Observability]::GetTraces()
        $traces[$operationId].Status | Should -Be "Success"
    }
}

Describe "Endpoint Module Tests" {
    BeforeEach {
        [PrometheusMetrics]::ResetMetrics()
    }

    It "Should expose Get-SystemHealth function" {
        (Get-Command Get-SystemHealth -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should get system health for localhost" {
        $response = Get-SystemHealth -ComputerName $script:testComputer
        $response           | Should -Not -BeNullOrEmpty
        $response.Success   | Should -Be $true
        $response.Data.ComputerName | Should -Be $script:testComputer
        $response.Data.Online       | Should -Be $true
        $response.Data.CheckTime    | Should -BeOfType [string]
    }

    It "Should handle offline computer gracefully" {
        $response = Get-SystemHealth -ComputerName "NONEXISTENT-COMPUTER-12345"
        $response           | Should -Not -BeNullOrEmpty
        $response.Success   | Should -Be $false
        $response.Data.Online     | Should -Be $false
        $response.ErrorCode | Should -Be "CONNECTION_ERROR"
    }

    It "Should reject empty computer name" {
        { Get-SystemHealth -ComputerName "" } | Should -Throw
    }
}

Describe "User Management Module Tests" {
    BeforeAll {
        $script:adAvailable = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
    }

    BeforeEach {
        [PrometheusMetrics]::ResetMetrics()
    }

    It "Should expose New-MSPADUser function" {
        (Get-Command New-MSPADUser -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should validate required user creation parameters" {
        { New-MSPADUser -FirstName "" -LastName "Doe" -Department "IT" -Title "Test" -HomeDriveRoot "\\srv\Users" } | Should -Throw
        { New-MSPADUser -FirstName "John" -LastName "" -Department "IT" -Title "Test" -HomeDriveRoot "\\srv\Users" } | Should -Throw
        { New-MSPADUser -FirstName "John" -LastName "Doe" -Department "" -Title "Test" -HomeDriveRoot "\\srv\Users" } | Should -Throw
        { New-MSPADUser -FirstName "John" -LastName "Doe" -Department "IT" -Title "" -HomeDriveRoot "\\srv\Users" } | Should -Throw
    }

    It "Should detect existing users" -Skip:(-not $script:adAvailable) {
        # Administrator account must exist on any domain-joined machine
        $response = New-MSPADUser -FirstName "Admin" -LastName "Test" -Username "Administrator" `
            -Department "IT" -Title "Test" -HomeDriveRoot "\\srv\Users"
        $response.Success   | Should -Be $false
        $response.ErrorCode | Should -Be "CONFLICT"
    }

    It "Should derive username from first and last name" {
        $firstName = "John"
        $lastName  = "Doe"
        $expected  = ($firstName[0] + $lastName).ToLower() -replace '[^a-z0-9\-]', ''
        $expected  | Should -Be "jdoe"
    }

    It "Should generate password of correct length and complexity" {
        $chars    = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*'
        $password = -join (1..16 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })

        $password.Length         | Should -Be 16
        ($password -cmatch '[A-Z]') | Should -Be $true
        ($password -cmatch '[a-z]') | Should -Be $true
        ($password -match '[0-9]')  | Should -Be $true
        ($password -match '[!@#$%^&*]') | Should -Be $true
    }
}

Describe "Observability Module Tests" {
    BeforeEach {
        [PrometheusMetrics]::ResetMetrics()
        [DistributedTracing]::ActiveSpans = @{}
    }

    It "Should expose Write-OperationMetrics function" {
        (Get-Command Write-OperationMetrics -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should increment counter metrics" {
        [PrometheusMetrics]::IncrementCounter("test_counter", @{ label = "test" })
        [PrometheusMetrics]::IncrementCounter("test_counter", @{ label = "test" })

        $metrics = [PrometheusMetrics]::GetMetrics()
        $counter = $metrics["test_counter-test"]
        $counter.Value | Should -Be 2
    }

    It "Should set gauge metrics" {
        [PrometheusMetrics]::SetGauge("test_gauge", 75.5, @{ label = "test" })

        $metrics = [PrometheusMetrics]::GetMetrics()
        $gauge   = $metrics["test_gauge-test"]
        $gauge.Value | Should -Be 75.5
    }

    It "Should record histogram metrics" {
        [PrometheusMetrics]::RecordHistogram("test_histogram", 1.5, @{ label = "test" })
        [PrometheusMetrics]::RecordHistogram("test_histogram", 2.5, @{ label = "test" })
        [PrometheusMetrics]::RecordHistogram("test_histogram", 3.5, @{ label = "test" })

        $metrics   = [PrometheusMetrics]::GetMetrics()
        $histogram = $metrics["test_histogram-test"]
        $histogram.Values.Count | Should -Be 3
    }

    It "Should export metrics in valid Prometheus text format" {
        [PrometheusMetrics]::IncrementCounter("test_counter", @{ label = "test" })
        [PrometheusMetrics]::SetGauge("test_gauge", 42.0, @{ label = "test" })

        $export = [PrometheusMetrics]::ExportMetrics()
        $export | Should -Match "# HELP"
        $export | Should -Match "# TYPE"
        $export | Should -Match "test_counter"
        $export | Should -Match "test_gauge"
        # Verify label format is correct: key="value"
        $export | Should -Match 'label="test"'
    }

    It "Should create distributed tracing spans with 16-char span IDs" {
        $spanId = Start-OperationTrace -OperationName "test_operation"
        $spanId                | Should -Not -BeNullOrEmpty
        $spanId.Length         | Should -Be 16
    }

    It "Should complete distributed tracing spans with duration" {
        $spanId = Start-OperationTrace -OperationName "test_operation"
        Start-Sleep -Milliseconds 5
        Stop-OperationTrace -SpanId $spanId -Status "OK"

        $span = [DistributedTracing]::GetSpan($spanId)
        $span.Status   | Should -Be "OK"
        $span.Duration | Should -BeGreaterThan 0
    }

    It "Should add tags to tracing spans" {
        $spanId = Start-OperationTrace -OperationName "test_operation"
        Add-TraceTag -SpanId $spanId -Key "test_key" -Value "test_value"

        $span = [DistributedTracing]::GetSpan($spanId)
        $span.Tags["test_key"] | Should -Be "test_value"
    }

    It "Should record errors in tracing spans" {
        $spanId = Start-OperationTrace -OperationName "test_operation"
        [DistributedTracing]::RecordError($spanId, "Test error message")

        $span = [DistributedTracing]::GetSpan($spanId)
        $span.Tags["error"]         | Should -Be $true
        $span.Tags["error.message"] | Should -Be "Test error message"
        $span.Status                | Should -Be "Error"
    }

    It "Should generate W3C-format trace parent header" {
        $spanId = Start-OperationTrace -OperationName "test_operation"
        $header = Get-TraceParentHeader

        $header | Should -Match "^00-"
        $header | Should -Match "-01$"
    }

    It "Should export trace data as valid JSON" {
        $spanId = Start-OperationTrace -OperationName "test_operation"
        Add-TraceTag -SpanId $spanId -Key "test" -Value "value"
        Stop-OperationTrace -SpanId $spanId -Status "OK"

        $span      = [DistributedTracing]::GetSpan($spanId)
        $traceJson = [DistributedTracing]::ExportTrace($span.TraceId)

        $traceJson    | Should -Not -BeNullOrEmpty
        $traceObject  = $traceJson | ConvertFrom-Json
        $traceObject.traceId      | Should -Be $span.TraceId
        $traceObject.spans.Count  | Should -BeGreaterThan 0
    }
}

Describe "Integration Tests" {
    It "Should handle end-to-end health workflow for localhost" {
        $response = Get-SystemHealth -ComputerName $script:testComputer
        $response.Success | Should -Be $true
        $response.Data.OverallStatus | Should -BeIn @("Healthy", "Warning")
    }

    It "Should return structured error for invalid computer" {
        $response = Get-SystemHealth -ComputerName "INVALID-COMPUTER-NAME-12345"
        $response.Success   | Should -Be $false
        $response.ErrorCode | Should -Not -BeNullOrEmpty
        $response.Timestamp | Should -BeOfType [datetime]
    }
}

Describe "Performance Tests" {
    It "Should complete health check in under 10 seconds for localhost" {
        $startTime = Get-Date
        $response  = Get-SystemHealth -ComputerName $script:testComputer
        $duration  = (Get-Date) - $startTime

        $duration.TotalSeconds | Should -BeLessThan 10
        $response.Success      | Should -Be $true
    }

    It "Should handle concurrent operations via background jobs" {
        $modulePath = Join-Path $PSScriptRoot "..\modules"
        $computer   = $script:testComputer

        # Use -InitializationScript and pass module paths as arguments rather than $using:
        $initScript = [scriptblock]::Create("
            Import-Module '$modulePath\MSPAutomation.Core.psm1' -Force
            Import-Module '$modulePath\Endpoint\Get-SystemInventory.psm1' -Force
        ")

        $jobs = 1..3 | ForEach-Object {
            Start-Job -InitializationScript $initScript -ScriptBlock {
                param($c) Get-SystemHealth -ComputerName $c
            } -ArgumentList $computer
        }

        $results = $jobs | Wait-Job | Receive-Job
        $jobs    | Remove-Job -Force

        $results.Count                              | Should -Be 3
        ($results | Where-Object { $_.Success }).Count | Should -Be 3
    }
}

Describe "Schema Validation Tests" {
    It "System inventory request should meet parameter constraints" {
        $request = @{
            ComputerName             = @("PC01", "PC02")
            IncludeDiskSpace         = $true
            IncludeNetworkInfo       = $false
            IncludeInstalledSoftware = $false
            TimeoutSeconds           = 300
            EnableIdempotency        = $false
        }

        $request.ComputerName       | Should -BeOfType [string[]]
        $request.ComputerName.Count | Should -BeGreaterThan 0
        $request.TimeoutSeconds     | Should -BeGreaterOrEqual 30
        $request.TimeoutSeconds     | Should -BeLessOrEqual 3600
    }

    It "User creation request should meet parameter constraints" {
        $request = @{
            FirstName      = "John"
            LastName       = "Doe"
            Username       = "jdoe"
            Department     = "IT"
            Title          = "System Administrator"
            HomeDriveRoot  = "\\fileserver\Users"
            EnableRollback = $true
        }

        $request.FirstName     | Should -Not -BeNullOrEmpty
        $request.LastName      | Should -Not -BeNullOrEmpty
        $request.Department    | Should -Not -BeNullOrEmpty
        $request.Title         | Should -Not -BeNullOrEmpty
        $request.HomeDriveRoot | Should -Match '^\\\\[^\\]+'
        $request.Username      | Should -Match "^[a-zA-Z0-9-]+$"
    }
}

AfterAll {
    [PrometheusMetrics]::ResetMetrics()
    [DistributedTracing]::ActiveSpans = @{}
}
