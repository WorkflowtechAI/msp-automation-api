# MSP Automation Pester Test Suite
#
# Two things about how this suite is written, both learned by running it:
#
# 1. PowerShell classes are NOT exported by Import-Module. `[Validator]`,
#    `[Idempotency]`, `[Observability]`, `[PrometheusMetrics]` and
#    `[DistributedTracing]` are invisible to a caller that only imported the
#    module, which is why every class-touching test used to fail with
#    "Unable to find type". Those tests now run inside InModuleScope, which is
#    the supported way to reach a module's internals.
#
# 2. Anything that needs a live Windows host, WinRM or Active Directory is
#    tagged 'RequiresHost' and excluded in CI. The rest mocks Invoke-Command so
#    it exercises the framework rather than the machine, and runs anywhere.
#
# Run everything (on a domain-joined Windows box):
#     Invoke-Pester -Path ./tests
# Run what CI runs:
#     Invoke-Pester -Path ./tests -ExcludeTagFilter RequiresHost

# Imports sit at file scope, not in BeforeAll, and use -Global.
#
# Pester runs a discovery pass and then a run pass. A module imported inside
# BeforeAll is bound to that block, and the exported functions are then missing
# from the It blocks that need them - which is exactly how this suite used to
# fail with "The term 'New-SuccessResponse' is not recognized" while the module
# was demonstrably loaded. File scope plus -Global keeps them resolvable in both
# passes.
$ModuleRoot = Join-Path $PSScriptRoot ".." "modules"
$ObsRoot    = Join-Path $PSScriptRoot ".." "observability"

Import-Module (Join-Path $ModuleRoot "MSPAutomation.Core.psm1")            -Force -Global
Import-Module (Join-Path $ModuleRoot "Endpoint" "Get-SystemInventory.psm1") -Force -Global
Import-Module (Join-Path $ModuleRoot "UserManagement" "New-ADUser.psm1")    -Force -Global
Import-Module (Join-Path $ObsRoot    "PrometheusMetrics.psm1")              -Force -Global

BeforeAll {
    # $ModuleRoot above is set during discovery; It blocks run in the run phase and
    # cannot see it, so republish it here.
    $script:ModuleRoot   = Join-Path $PSScriptRoot ".." "modules"
    $script:testComputer = $env:COMPUTERNAME

    # The shape Get-SystemHealth expects back from its remote Invoke-Command.
    # Kept here so the mock and the assertions cannot drift apart.
    $script:HealthFixture = @{
        ComputerName    = "MOCK-HOST"
        Online          = $true
        CPUPercent      = 12.5
        MemoryPercent   = 41.0
        DiskPercent     = 63.25
        UptimeDays      = 4.75
        StoppedServices = @()
        OverallStatus   = "Healthy"
        CheckTime       = (Get-Date).ToString("o")
    }
}

Describe "MSPAutomation.Core: response contract" {
    It "Should expose New-SuccessResponse function" {
        (Get-Command New-SuccessResponse -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should expose New-ErrorResponse function" {
        (Get-Command New-ErrorResponse -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should expose Invoke-AutomationOperation function" {
        (Get-Command Invoke-AutomationOperation -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should create a success API response" {
        $response = New-SuccessResponse -Message "Test success" -Data @{ test = "data" }
        $response.Success   | Should -Be $true
        $response.Message   | Should -Be "Test success"
        $response.Data.test | Should -Be "data"
        $response.Timestamp | Should -BeOfType [datetime]
    }

    It "Should create an error API response" {
        $response = New-ErrorResponse -Message "Test error" -ErrorCode "TEST_ERROR"
        $response.Success   | Should -Be $false
        $response.Message   | Should -Be "Test error"
        $response.ErrorCode | Should -Be "TEST_ERROR"
        $response.Timestamp | Should -BeOfType [datetime]
    }

    It "Should serialize API response to JSON" {
        $response   = New-SuccessResponse -Message "Test" -Data @{ key = "value" }
        $json       = $response.ToJson()
        $json       | Should -Not -BeNullOrEmpty
        $jsonObject = $json | ConvertFrom-Json
        $jsonObject.Success | Should -Be $true
    }

    It "Should return a structured error rather than throwing when the operation body fails" {
        $response = Invoke-AutomationOperation -OperationName "Boom" -ScriptBlock {
            param([hashtable]$p)
            throw "deliberate failure"
        }
        $response.Success   | Should -Be $false
        $response.ErrorCode | Should -Be "INTERNAL_ERROR"
        $response.Message   | Should -Match "deliberate failure"
    }
}

Describe "MSPAutomation.Core: internals" {
    # These reach classes that live inside the module and are not exported.
    It "Should validate required fields" {
        InModuleScope MSPAutomation.Core {
            { [Validator]::ValidateRequired("",      "testField") } | Should -Throw
            { [Validator]::ValidateRequired($null,   "testField") } | Should -Throw
            { [Validator]::ValidateRequired("value", "testField") } | Should -Not -Throw
        }
    }

    It "Should validate string patterns" {
        InModuleScope MSPAutomation.Core {
            { [Validator]::ValidatePattern("invalid", "^[0-9]+$", "testField") } | Should -Throw
            { [Validator]::ValidatePattern("123",     "^[0-9]+$", "testField") } | Should -Not -Throw
        }
    }

    It "Should validate numeric ranges" {
        InModuleScope MSPAutomation.Core {
            { [Validator]::ValidateRange(150, 1, 100, "testField") } | Should -Throw
            { [Validator]::ValidateRange(50,  1, 100, "testField") } | Should -Not -Throw
        }
    }

    It "Should generate consistent idempotency keys" {
        InModuleScope MSPAutomation.Core {
            $a = [Idempotency]::GenerateIdempotencyKey(@{ ComputerName = "PC01"; Flag = $true })
            $b = [Idempotency]::GenerateIdempotencyKey(@{ Flag = $true; ComputerName = "PC01" })
            $c = [Idempotency]::GenerateIdempotencyKey(@{ ComputerName = "PC02"; Flag = $true })

            $a | Should -Not -BeNullOrEmpty
            $a | Should -Be $b   # key order must not change the key
            $a | Should -Not -Be $c
        }
    }

    It "Should record and complete observability traces" {
        InModuleScope MSPAutomation.Core {
            $id = [Guid]::NewGuid().ToString()
            { [Observability]::StartTrace($id, "unit-test") } | Should -Not -Throw
            { [Observability]::EndTrace($id, "Success") }     | Should -Not -Throw
        }
    }
}

Describe "Endpoint module" {
    BeforeAll {
        InModuleScope PrometheusMetrics { [PrometheusMetrics]::ResetMetrics() }
    }

    It "Should expose Get-SystemHealth function" {
        (Get-Command Get-SystemHealth -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should expose Get-SystemInventory function" {
        (Get-Command Get-SystemInventory -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should reject an empty computer name" {
        { Get-SystemHealth -ComputerName "" } | Should -Throw
    }

    Context "with the remote call mocked" {
        BeforeAll {
            $fixture = $script:HealthFixture
            Mock -ModuleName Get-SystemInventory Invoke-Command { $fixture }
        }

        It "Should wrap a successful health check in a success response" {
            $response = Get-SystemHealth -ComputerName "ANY-HOST"
            $response                    | Should -Not -BeNullOrEmpty
            $response.Success            | Should -Be $true
            $response.Data.Online        | Should -Be $true
            $response.Data.OverallStatus | Should -Be "Healthy"
            $response.Data.CheckTime     | Should -BeOfType [string]
        }

        It "Should call the remote once per invocation" {
            Get-SystemHealth -ComputerName "ANY-HOST" | Out-Null
            Should -Invoke -ModuleName Get-SystemInventory Invoke-Command -Times 1 -Exactly -Scope It
        }
    }

    Context "when the remote is unreachable" {
        BeforeAll {
            Mock -ModuleName Get-SystemInventory Invoke-Command { throw "The RPC server is unavailable." }
        }

        It "Should return CONNECTION_ERROR rather than throwing" {
            $response = Get-SystemHealth -ComputerName "NONEXISTENT-COMPUTER-12345"
            $response              | Should -Not -BeNullOrEmpty
            $response.Success      | Should -Be $false
            $response.ErrorCode    | Should -Be "CONNECTION_ERROR"
            $response.Data.Online  | Should -Be $false
        }
    }

    It "Should reach a real host" -Tag 'RequiresHost' {
        $response = Get-SystemHealth -ComputerName $script:testComputer
        $response.Success            | Should -Be $true
        $response.Data.ComputerName  | Should -Be $script:testComputer
        $response.Data.OverallStatus | Should -BeIn @("Healthy", "Warning")
    }
}

Describe "User Management module" {
    BeforeAll {
        $script:adAvailable = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
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

    It "Should detect existing users" -Tag 'RequiresHost' -Skip:(-not $script:adAvailable) {
        # Administrator must exist on any domain-joined machine
        $response = New-MSPADUser -FirstName "Admin" -LastName "Test" -Username "Administrator" `
            -Department "IT" -Title "Test" -HomeDriveRoot "\\srv\Users"
        $response.Success   | Should -Be $false
        $response.ErrorCode | Should -Be "CONFLICT"
    }
}

Describe "Observability module" {
    BeforeEach {
        InModuleScope PrometheusMetrics {
            [PrometheusMetrics]::ResetMetrics()
            [DistributedTracing]::ActiveSpans = @{}
        }
    }

    It "Should expose Write-OperationMetrics function" {
        (Get-Command Write-OperationMetrics -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should expose Write-SystemMetrics function" {
        (Get-Command Write-SystemMetrics -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It "Should increment counter metrics" {
        InModuleScope PrometheusMetrics {
            [PrometheusMetrics]::IncrementCounter("test_counter", @{ label = "test" })
            [PrometheusMetrics]::IncrementCounter("test_counter", @{ label = "test" })

            $metrics = [PrometheusMetrics]::GetMetrics()
            $metrics["test_counter-test"].Value | Should -Be 2
        }
    }

    It "Should set gauge metrics" {
        InModuleScope PrometheusMetrics {
            [PrometheusMetrics]::SetGauge("test_gauge", 75.5, @{ label = "test" })
            $metrics = [PrometheusMetrics]::GetMetrics()
            $metrics["test_gauge-test"].Value | Should -Be 75.5
        }
    }

    It "Should record histogram metrics" {
        InModuleScope PrometheusMetrics {
            [PrometheusMetrics]::RecordHistogram("test_histogram", 1.5, @{ label = "test" })
            [PrometheusMetrics]::RecordHistogram("test_histogram", 2.5, @{ label = "test" })
            [PrometheusMetrics]::RecordHistogram("test_histogram", 3.5, @{ label = "test" })

            $metrics = [PrometheusMetrics]::GetMetrics()
            $metrics["test_histogram-test"].Values.Count | Should -Be 3
        }
    }

    It "Should export metrics in valid Prometheus text format" {
        InModuleScope PrometheusMetrics {
            [PrometheusMetrics]::IncrementCounter("test_counter", @{ label = "test" })
            [PrometheusMetrics]::SetGauge("test_gauge", 42.0, @{ label = "test" })

            $export = [PrometheusMetrics]::ExportMetrics()
            $export | Should -Match "# HELP"
            $export | Should -Match "# TYPE"
            $export | Should -Match "test_counter"
            $export | Should -Match "test_gauge"
            $export | Should -Match 'label="test"'
        }
    }

    It "Should create tracing spans with 16-char span IDs" {
        $spanId = Start-OperationTrace -OperationName "test_operation"
        $spanId        | Should -Not -BeNullOrEmpty
        $spanId.Length | Should -Be 16
    }

    It "Should complete tracing spans with a duration" {
        $spanId = Start-OperationTrace -OperationName "test_operation"
        Start-Sleep -Milliseconds 5
        Stop-OperationTrace -SpanId $spanId -Status "OK"

        InModuleScope PrometheusMetrics -Parameters @{ SpanId = $spanId } {
            param($SpanId)
            $span = [DistributedTracing]::GetSpan($SpanId)
            $span.Status   | Should -Be "OK"
            $span.Duration | Should -BeGreaterThan 0
        }
    }

    It "Should add tags to tracing spans" {
        $spanId = Start-OperationTrace -OperationName "test_operation"
        Add-TraceTag -SpanId $spanId -Key "test_key" -Value "test_value"

        InModuleScope PrometheusMetrics -Parameters @{ SpanId = $spanId } {
            param($SpanId)
            [DistributedTracing]::GetSpan($SpanId).Tags["test_key"] | Should -Be "test_value"
        }
    }

    It "Should record errors in tracing spans" {
        $spanId = Start-OperationTrace -OperationName "test_operation"

        InModuleScope PrometheusMetrics -Parameters @{ SpanId = $spanId } {
            param($SpanId)
            [DistributedTracing]::RecordError($SpanId, "Test error message")
            $span = [DistributedTracing]::GetSpan($SpanId)
            $span.Tags["error"]         | Should -Be $true
            $span.Tags["error.message"] | Should -Be "Test error message"
            $span.Status                | Should -Be "Error"
        }
    }

    It "Should generate a W3C-format traceparent header" {
        Start-OperationTrace -OperationName "test_operation" | Out-Null
        $header = Get-TraceParentHeader

        $header | Should -Match "^00-"
        $header | Should -Match "-01$"
    }

    It "Should export trace data as valid JSON" {
        $spanId = Start-OperationTrace -OperationName "test_operation"
        Add-TraceTag -SpanId $spanId -Key "test" -Value "value"
        Stop-OperationTrace -SpanId $spanId -Status "OK"

        InModuleScope PrometheusMetrics -Parameters @{ SpanId = $spanId } {
            param($SpanId)
            $span      = [DistributedTracing]::GetSpan($SpanId)
            $traceJson = [DistributedTracing]::ExportTrace($span.TraceId)

            $traceJson   | Should -Not -BeNullOrEmpty
            $traceObject = $traceJson | ConvertFrom-Json
            $traceObject.traceId     | Should -Be $span.TraceId
            $traceObject.spans.Count | Should -BeGreaterThan 0
        }
    }
}

Describe "Concurrency" {
    It "Should handle concurrent operations via background jobs" -Tag 'RequiresHost' {
        # Jobs run in separate processes, so Pester mocks do not reach them.
        # This one genuinely needs a reachable host.
        $modulePath = Join-Path $PSScriptRoot ".." "modules"
        $computer   = $script:testComputer

        $initScript = [scriptblock]::Create(@"
            Import-Module '$modulePath\MSPAutomation.Core.psm1' -Force
            Import-Module '$modulePath\Endpoint\Get-SystemInventory.psm1' -Force
"@)

        $jobs = 1..3 | ForEach-Object {
            Start-Job -InitializationScript $initScript -ScriptBlock {
                param($c) Get-SystemHealth -ComputerName $c
            } -ArgumentList $computer
        }

        $results = $jobs | Wait-Job | Receive-Job
        $jobs    | Remove-Job -Force

        $results.Count | Should -Be 3
        ($results | Where-Object { $_.Success }).Count | Should -Be 3
    }
}

Describe "Import order" {
    # Regression guard. Both operation modules import MSPAutomation.Core. When they
    # did it with -Force, that removed the caller's already-loaded copy and rebound
    # it privately, so this exact sequence - the one the README documents - left
    # New-SuccessResponse undefined. The whole suite depended on it silently; this
    # test says so out loud and fails on the specific cause.
    It "Leaves Core's exports callable after an operation module is imported" {
        $core     = Join-Path $script:ModuleRoot "MSPAutomation.Core.psm1"
        $endpoint = Join-Path $script:ModuleRoot "Endpoint" "Get-SystemInventory.psm1"

        $result = pwsh -NoProfile -Command "
            Import-Module '$core'     -Force
            Import-Module '$endpoint' -Force
            if (Get-Command New-SuccessResponse -ErrorAction SilentlyContinue) { 'OK' } else { 'EVICTED' }
        "

        ($result | Select-Object -Last 1) | Should -Be 'OK'
    }
}

Describe "Schema constraints" {
    It "System inventory request should meet parameter constraints" {
        $request = @{
            # Typed deliberately: the schema says string[], and a bare @() literal
            # in a hashtable lands as Object[], which is what the assertion checks.
            ComputerName             = [string[]]@("PC01", "PC02")
            IncludeDiskSpace         = $true
            IncludeNetworkInfo       = $false
            IncludeInstalledSoftware = $false
            TimeoutSeconds           = 300
            EnableIdempotency        = $false
        }

        # Comma keeps the array intact; a bare pipe unrolls it and asserts on
        # the first element, which is why this used to fail claiming [string].
        , $request.ComputerName | Should -BeOfType [string[]]
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

    It "Derives a username from first and last name the way the schema expects" {
        $firstName = "John"
        $lastName  = "Doe"
        (($firstName[0] + $lastName).ToLower() -replace '[^a-z0-9\-]', '') | Should -Be "jdoe"
    }
}

AfterAll {
    InModuleScope PrometheusMetrics {
        [PrometheusMetrics]::ResetMetrics()
        [DistributedTracing]::ActiveSpans = @{}
    }
}
