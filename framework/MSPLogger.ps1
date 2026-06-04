# MSP Logging Framework
# Provides structured logging for MSP operations

using namespace System.Diagnostics

class MSPLogger {
    [string]$LogPath
    [string]$LogName
    [string]$Level
    [int]$RetentionDays

    MSPLogger([string]$LogName, [string]$LogPath = "C:\Logs\MSP", [string]$Level = "Info", [int]$RetentionDays = 90) {
        $this.LogName = $LogName
        $this.LogPath = $LogPath
        $this.Level = $Level
        $this.RetentionDays = $RetentionDays

        # Ensure log directory exists
        if (-not (Test-Path $LogPath)) {
            New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
        }

        # Clean old logs
        $this.CleanOldLogs()
    }

    [string] GetLogFilePath() {
        $date = Get-Date -Format "yyyy-MM-dd"
        return "$($this.LogPath)\$($this.LogName)_$date.log"
    }

    [void] CleanOldLogs() {
        $cutoffDate = (Get-Date).AddDays(-$this.RetentionDays)
        Get-ChildItem $this.LogPath -Filter "$($this.LogName)_*.log" | 
            Where-Object { $_.LastWriteTime -lt $cutoffDate } | 
            Remove-Item -Force
    }

    [bool] ShouldLog([string]$MessageLevel) {
        $levels = @("Debug", "Info", "Warning", "Error")
        $messageLevelIndex = $levels.IndexOf($MessageLevel)
        $configLevelIndex = $levels.IndexOf($this.Level)
        return $messageLevelIndex -ge $configLevelIndex
    }

    [void] WriteLog([string]$Message, [string]$Level = "Info") {
        if (-not $this.ShouldLog($Level)) {
            return
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        $logFile = $this.GetLogFilePath()

        # Write to file
        Add-Content -Path $logFile -Value $logEntry

        # Write to console with color
        $color = switch ($Level) {
            "Debug"   { "Gray" }
            "Info"    { "White" }
            "Warning" { "Yellow" }
            "Error"   { "Red" }
            default   { "White" }
        }
        Write-Host $logEntry -ForegroundColor $color
    }

    [void] Debug([string]$Message) {
        $this.WriteLog($Message, "Debug")
    }

    [void] Info([string]$Message) {
        $this.WriteLog($Message, "Info")
    }

    [void] Warning([string]$Message) {
        $this.WriteLog($Message, "Warning")
    }

    [void] Error([string]$Message) {
        $this.WriteLog($Message, "Error")
    }

    [void] Error([string]$Message, [System.Management.Automation.ErrorRecord]$Exception) {
        $errorMsg = "$Message`nException: $($Exception.Exception.Message)`nStack: $($Exception.ScriptStackTrace)"
        $this.WriteLog($errorMsg, "Error")
    }

    [void] StartOperation([string]$Operation) {
        $this.Info("=== START: $Operation ===")
    }

    [void] EndOperation([string]$Operation) {
        $this.Info("=== END: $Operation ===")
    }

    [void] WriteEventLog([string]$Message, [EventLogEntryType]$EventType = [EventLogEntryType]::Information) {
        try {
            $source = "MSPScripts"
            if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
                [System.Diagnostics.EventLog]::CreateEventSource($source, "Application")
            }
            Write-EventLog -LogName Application -Source $source -EntryType $EventType -EventId 1000 -Message $Message
        } catch {
            $this.Warning("Could not write to event log: $_")
        }
    }
}

# Helper function to get logger instance
function Get-MSPLogger {
    param(
        [string]$LogName,
        [string]$LogPath = "C:\Logs\MSP",
        [string]$Level = "Info",
        [int]$RetentionDays = 90
    )
    return [MSPLogger]::new($LogName, $LogPath, $Level, $RetentionDays)
}