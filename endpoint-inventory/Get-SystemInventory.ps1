<#
.SYNOPSIS
    Full hardware/software inventory snapshot of one or more machines.
.PARAMETER ComputerName
.PARAMETER ExportCSV
.EXAMPLE
    .\Get-SystemInventory.ps1
    .\Get-SystemInventory.ps1 -ComputerName PC01,PC02,PC03 -ExportCSV "C:\Reports\inventory.csv"
#>
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$ExportCSV
)

$results = @()

foreach ($computer in $ComputerName) {
    Write-Host "`nInventorying $computer..." -ForegroundColor Cyan
    try {
        $data = Invoke-Command -ComputerName $computer -ScriptBlock {
            $os   = Get-CimInstance Win32_OperatingSystem
            $cs   = Get-CimInstance Win32_ComputerSystem
            $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
            $bios = Get-CimInstance Win32_BIOS
            $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
                     ForEach-Object { "$($_.DeviceID) $([math]::Round($_.Size/1GB,1))GB (Free: $([math]::Round($_.FreeSpace/1GB,1))GB)" }
            $nics  = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" |
                     ForEach-Object { "$($_.Description): $($_.IPAddress -join ', ')" }

            [PSCustomObject]@{
                Hostname        = $env:COMPUTERNAME
                Manufacturer    = $cs.Manufacturer
                Model           = $cs.Model
                SerialNumber    = $bios.SerialNumber
                CPU             = $cpu.Name
                CPUCores        = $cpu.NumberOfCores
                RAM_GB          = [math]::Round($cs.TotalPhysicalMemory/1GB, 1)
                OS              = $os.Caption
                OSBuild         = $os.BuildNumber
                OSVersion       = $os.Version
                LastBoot        = $os.LastBootUpTime
                Disks           = $disks -join " | "
                NICs            = $nics -join " | "
                Domain          = $cs.Domain
                CurrentUser     = $cs.UserName
                BIOSVersion     = $bios.SMBIOSBIOSVersion
                BIOSReleaseDate = $bios.ReleaseDate
            }
        } -ErrorAction Stop

        $results += $data
        $data | Format-List
    } catch {
        Write-Host "  [ERROR] $computer : $_" -ForegroundColor Red
    }
}

if ($ExportCSV) {
    $results | Export-Csv $ExportCSV -NoTypeInformation
    Write-Host "`n[OK] Exported to $ExportCSV" -ForegroundColor Green
}
