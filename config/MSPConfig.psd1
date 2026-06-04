# MSP Configuration File
# Modify these values for your environment

@{
    # Domain Configuration
    Domain = @{
        DNSRoot = "yourdomain.com"
        DefaultOU = "OU=Users,OU=Company,DC=yourdomain,DC=com"
        HomeDriveRoot = "\\yourdomain.com\Users"
        HomeDriveLetter = "H"
    }

    # Email Configuration
    Email = @{
        SMTPServer = "smtp.yourdomain.com"
        From = "msp-ops@yourdomain.com"
        Port = 587
        UseSSL = $true
    }

    # Critical Services (default for service health checks)
    CriticalServices = @(
        "wuauserv"           # Windows Update
        "WinDefend"          # Windows Defender
        "EventLog"           # Event Log
        "RpcSs"              # RPC
        "Dnscache"           # DNS Client
        "Dhcp"               # DHCP Client
        "LanmanWorkstation"  # Workstation
        "W32Time"            # Windows Time
        "MpsSvc"             # Windows Firewall
        "BITS"               # Background Intelligent Transfer
        "CryptSvc"           # Cryptographic Services
        "TrustedInstaller"   # Windows Modules Installer
    )

    # Alert Thresholds
    Thresholds = @{
        DiskSpacePercent = 90
        CPUUsagePercent = 90
        MemoryUsagePercent = 90
        UptimeDays = 30
    }

    # Backup Configuration
    Backup = @{
        RetentionDays = 30
        BackupPath = "\\backupserver\backups"
        ExcludePaths = @("C:\Windows\Temp", "C:\Temp")
    }

    # Logging Configuration
    Logging = @{
        Path = "C:\Logs\MSP"
        RetentionDays = 90
        Level = "Info"  # Debug, Info, Warning, Error
    }

    # M365 Configuration
    M365 = @{
        TenantId = "your-tenant-id"
        DefaultLicense = "your-license-sku-id"
    }

    # Security Compliance
    Security = @{
        MaxPasswordAgeDays = 90
        MinPasswordLength = 12
        RequireMFA = $true
        BitLockerRequired = $true
    }

    # Client-Specific Settings (example)
    Clients = @{
        "ClientA" = @{
            OU = "OU=ClientA,OU=Clients,DC=yourdomain,DC=com"
            ContactEmail = "it@clienta.com"
            BackupSchedule = "Daily"
        }
        "ClientB" = @{
            OU = "OU=ClientB,OU=Clients,DC=yourdomain,DC=com"
            ContactEmail = "support@clientb.com"
            BackupSchedule = "Weekly"
        }
    }
}