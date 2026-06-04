# Observability Module
# Prometheus metrics and distributed tracing hooks

class PrometheusMetrics {
    static [hashtable]$Counters   = @{}
    static [hashtable]$Gauges     = @{}
    static [hashtable]$Histograms = @{}
    static [string]$MetricsEndpoint = "http://localhost:9090/metrics"

    # Build a valid Prometheus label string: {key="val",key2="val2"}
    hidden static [string] BuildLabelString([hashtable]$labels) {
        if (-not $labels -or $labels.Count -eq 0) { return "" }
        $pairs = $labels.GetEnumerator() | ForEach-Object { "$($_.Key)=`"$($_.Value)`"" }
        return "{$($pairs -join ',')}"
    }

    static [void] IncrementCounter([string]$name, [hashtable]$labels) {
        $key = "$name-$($labels.Values -join '-')"
        if (-not [PrometheusMetrics]::Counters.ContainsKey($key)) {
            [PrometheusMetrics]::Counters[$key] = @{
                Name   = $name
                Value  = 0
                Labels = $labels
                Help   = "Counter metric for $name"
                Type   = "counter"
            }
        }
        [PrometheusMetrics]::Counters[$key].Value++
    }

    static [void] SetGauge([string]$name, [double]$value, [hashtable]$labels) {
        $key = "$name-$($labels.Values -join '-')"
        [PrometheusMetrics]::Gauges[$key] = @{
            Name   = $name
            Value  = $value
            Labels = $labels
            Help   = "Gauge metric for $name"
            Type   = "gauge"
        }
    }

    static [void] RecordHistogram([string]$name, [double]$value, [hashtable]$labels) {
        $key = "$name-$($labels.Values -join '-')"
        if (-not [PrometheusMetrics]::Histograms.ContainsKey($key)) {
            [PrometheusMetrics]::Histograms[$key] = @{
                Name    = $name
                Values  = [System.Collections.Generic.List[double]]::new()
                Labels  = $labels
                Help    = "Histogram metric for $name"
                Type    = "histogram"
                Buckets = @(0.1, 0.5, 1, 5, 10, 30, 60, 300, 600, 1800, 3600)
            }
        }
        [PrometheusMetrics]::Histograms[$key].Values.Add($value)
    }

    # Returns all metrics as a flat hashtable keyed by metric key (for test access)
    static [hashtable] GetMetrics() {
        $all = @{}
        foreach ($k in [PrometheusMetrics]::Counters.Keys)   { $all[$k] = [PrometheusMetrics]::Counters[$k] }
        foreach ($k in [PrometheusMetrics]::Gauges.Keys)     { $all[$k] = [PrometheusMetrics]::Gauges[$k] }
        foreach ($k in [PrometheusMetrics]::Histograms.Keys) { $all[$k] = [PrometheusMetrics]::Histograms[$k] }
        return $all
    }

    static [string] ExportMetrics() {
        $output = [System.Collections.Generic.List[string]]::new()

        foreach ($counter in [PrometheusMetrics]::Counters.Values) {
            $labelStr = [PrometheusMetrics]::BuildLabelString($counter.Labels)
            $output.Add("# HELP $($counter.Name) $($counter.Help)")
            $output.Add("# TYPE $($counter.Name) counter")
            $output.Add("$($counter.Name)$labelStr $($counter.Value)")
        }

        foreach ($gauge in [PrometheusMetrics]::Gauges.Values) {
            $labelStr = [PrometheusMetrics]::BuildLabelString($gauge.Labels)
            $output.Add("# HELP $($gauge.Name) $($gauge.Help)")
            $output.Add("# TYPE $($gauge.Name) gauge")
            $output.Add("$($gauge.Name)$labelStr $($gauge.Value)")
        }

        foreach ($histogram in [PrometheusMetrics]::Histograms.Values) {
            $labelStr = [PrometheusMetrics]::BuildLabelString($histogram.Labels)
            $baseLabelStr = if ($histogram.Labels.Count -gt 0) {
                # Insert le bucket label alongside existing labels
                $pairs = $histogram.Labels.GetEnumerator() | ForEach-Object { "$($_.Key)=`"$($_.Value)`"" }
                "{le=`"BUCKET_PLACEHOLDER`",$($pairs -join ',')}"
            } else {
                "{le=`"BUCKET_PLACEHOLDER`"}"
            }

            $output.Add("# HELP $($histogram.Name) $($histogram.Help)")
            $output.Add("# TYPE $($histogram.Name) histogram")

            $values = $histogram.Values | Sort-Object
            foreach ($bucket in $histogram.Buckets) {
                $count      = ($values | Where-Object { $_ -le $bucket }).Count
                $bucketLabel = $baseLabelStr -replace 'BUCKET_PLACEHOLDER', $bucket
                $output.Add("$($histogram.Name)_bucket$bucketLabel $count")
            }
            $infLabel = $baseLabelStr -replace 'BUCKET_PLACEHOLDER', '+Inf'
            $output.Add("$($histogram.Name)_bucket$infLabel $($values.Count)")

            $sum = ($values | Measure-Object -Sum).Sum
            $output.Add("$($histogram.Name)_sum$labelStr $sum")
            $output.Add("$($histogram.Name)_count$labelStr $($values.Count)")
        }

        return $output -join "`n"
    }

    static [void] ResetMetrics() {
        [PrometheusMetrics]::Counters   = @{}
        [PrometheusMetrics]::Gauges     = @{}
        [PrometheusMetrics]::Histograms = @{}
    }
}

class DistributedTracing {
    static [hashtable]$ActiveSpans    = @{}
    static [string]$TraceParentHeader = ""

    static [string] StartSpan([string]$operationName, [string]$parentSpanId = "") {
        # Use 16 hex chars for spanId to match W3C traceparent spec format
        $spanId  = [Guid]::NewGuid().ToString("N").Substring(0, 16)
        $traceId = if ($parentSpanId -and [DistributedTracing]::ActiveSpans.ContainsKey($parentSpanId)) {
            [DistributedTracing]::ActiveSpans[$parentSpanId].TraceId
        } else {
            [Guid]::NewGuid().ToString("N")
        }

        [DistributedTracing]::ActiveSpans[$spanId] = @{
            TraceId       = $traceId
            SpanId        = $spanId
            ParentSpanId  = $parentSpanId
            OperationName = $operationName
            StartTime     = [DateTimeOffset]::UtcNow
            EndTime       = $null
            Duration      = $null
            Tags          = @{}
            Status        = "Started"
        }

        [DistributedTracing]::TraceParentHeader = "00-$traceId-$spanId-01"
        return $spanId
    }

    static [void] EndSpan([string]$spanId, [string]$status = "OK") {
        if ([DistributedTracing]::ActiveSpans.ContainsKey($spanId)) {
            $start = [DistributedTracing]::ActiveSpans[$spanId].StartTime
            $end   = [DateTimeOffset]::UtcNow
            [DistributedTracing]::ActiveSpans[$spanId].EndTime  = $end
            [DistributedTracing]::ActiveSpans[$spanId].Status   = $status
            [DistributedTracing]::ActiveSpans[$spanId].Duration = ($end - $start).TotalMilliseconds
        }
    }

    static [void] AddTag([string]$spanId, [string]$key, [string]$value) {
        if ([DistributedTracing]::ActiveSpans.ContainsKey($spanId)) {
            [DistributedTracing]::ActiveSpans[$spanId].Tags[$key] = $value
        }
    }

    static [void] RecordError([string]$spanId, [string]$errorMessage) {
        if ([DistributedTracing]::ActiveSpans.ContainsKey($spanId)) {
            [DistributedTracing]::ActiveSpans[$spanId].Tags["error"]         = $true
            [DistributedTracing]::ActiveSpans[$spanId].Tags["error.message"] = $errorMessage
            [DistributedTracing]::ActiveSpans[$spanId].Status                = "Error"
        }
    }

    static [hashtable] GetSpan([string]$spanId) {
        if ([DistributedTracing]::ActiveSpans.ContainsKey($spanId)) {
            return [DistributedTracing]::ActiveSpans[$spanId]
        }
        return $null
    }

    static [object[]] GetTrace([string]$traceId) {
        return @([DistributedTracing]::ActiveSpans.Values | Where-Object { $_.TraceId -eq $traceId })
    }

    static [string] ExportTrace([string]$traceId) {
        $spans = [DistributedTracing]::GetTrace($traceId)
        return @{
            traceId = $traceId
            spans   = @($spans | ForEach-Object {
                @{
                    traceId       = $_.TraceId
                    spanId        = $_.SpanId
                    parentSpanId  = $_.ParentSpanId
                    operationName = $_.OperationName
                    startTime     = $_.StartTime.ToString("o")
                    endTime       = if ($_.EndTime) { $_.EndTime.ToString("o") } else { $null }
                    durationMs    = $_.Duration
                    tags          = $_.Tags
                    status        = $_.Status
                }
            })
        } | ConvertTo-Json -Depth 10
    }
}

# Helper functions

function Write-OperationMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$OperationName,
        [Parameter(Mandatory = $true)] [bool]$Success,
        [double]$DurationMs  = 0,
        [hashtable]$Labels   = @{}
    )

    $defaultLabels = @{
        operation = $OperationName
        status    = if ($Success) { "success" } else { "error" }
    }
    $mergedLabels = $defaultLabels + $Labels

    [PrometheusMetrics]::IncrementCounter("automation_operations_total", $mergedLabels)

    if ($DurationMs -gt 0) {
        [PrometheusMetrics]::RecordHistogram("automation_operation_duration_ms", $DurationMs, $mergedLabels)
    }
}

function Write-SystemMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ComputerName,
        [double]$CPUPercent      = -1,
        [double]$MemoryPercent   = -1,
        [double]$DiskPercent     = -1,
        [int]$StoppedServices    = 0
    )

    $labels = @{ computer = $ComputerName }

    if ($CPUPercent    -ge 0) { [PrometheusMetrics]::SetGauge("system_cpu_percent",    $CPUPercent,    $labels) }
    if ($MemoryPercent -ge 0) { [PrometheusMetrics]::SetGauge("system_memory_percent", $MemoryPercent, $labels) }
    if ($DiskPercent   -ge 0) { [PrometheusMetrics]::SetGauge("system_disk_percent",   $DiskPercent,   $labels) }
    [PrometheusMetrics]::SetGauge("system_stopped_services", $StoppedServices, $labels)
}

function Start-OperationTrace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$OperationName,
        [string]$ParentSpanId = ""
    )
    return [DistributedTracing]::StartSpan($OperationName, $ParentSpanId)
}

function Stop-OperationTrace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$SpanId,
        [string]$Status = "OK"
    )
    [DistributedTracing]::EndSpan($SpanId, $Status)
}

function Add-TraceTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$SpanId,
        [Parameter(Mandatory = $true)] [string]$Key,
        [Parameter(Mandatory = $true)] [string]$Value
    )
    [DistributedTracing]::AddTag($SpanId, $Key, $Value)
}

function Get-TraceParentHeader {
    return [DistributedTracing]::TraceParentHeader
}

Export-ModuleMember -Function @(
    'Write-OperationMetrics',
    'Write-SystemMetrics',
    'Start-OperationTrace',
    'Stop-OperationTrace',
    'Add-TraceTag',
    'Get-TraceParentHeader'
)
