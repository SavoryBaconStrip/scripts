<#
.SYNOPSIS
    Collects a detailed Windows system-information report.

.DESCRIPTION
    Creates an HTML report and a plain-text transcript under:
        C:\Temp\SysInfoReports

    The script does not modify system settings. Some sections provide more
    detail when PowerShell is run as Administrator.

.PARAMETER OutputDirectory
    Directory where reports are saved.

.PARAMETER IncludeInstalledSoftware
    Includes installed software from the registry. Enabled by default.

.PARAMETER IncludeEventSummary
    Includes recent Critical and Error events. Enabled by default.

.PARAMETER EventLookbackHours
    Number of hours to examine for recent events. Default: 72.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File C:\Temp\sysinfo.ps1

.EXAMPLE
    .\sysinfo.ps1 -EventLookbackHours 24
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory = 'C:\Temp\SysInfoReports',
    [bool]$IncludeInstalledSoftware = $true,
    [bool]$IncludeEventSummary = $true,
    [ValidateRange(1, 720)]
    [int]$EventLookbackHours = 72
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$computerName = $env:COMPUTERNAME
$reportBase = "SystemInfo_${computerName}_$timestamp"
$htmlPath = Join-Path $OutputDirectory "$reportBase.html"
$textPath = Join-Path $OutputDirectory "$reportBase.txt"

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
Start-Transcript -Path $textPath -Force | Out-Null

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Convert-ToDisplayText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($Value -is [System.Array]) { return ($Value -join ', ') }
    return [string]$Value
}

function Convert-ObjectToHtmlTable {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [AllowNull()]
        [object[]]$Data,

        [string[]]$Properties
    )

    $safeTitle = [System.Net.WebUtility]::HtmlEncode($Title)

    if (-not $Data -or @($Data).Count -eq 0) {
        return "<section><h2>$safeTitle</h2><p class='empty'>No data available.</p></section>"
    }

    try {
        if ($Properties) {
            $table = $Data | Select-Object $Properties | ConvertTo-Html -Fragment
        }
        else {
            $table = $Data | ConvertTo-Html -Fragment
        }

        return "<section><h2>$safeTitle</h2>$table</section>"
    }
    catch {
        $message = [System.Net.WebUtility]::HtmlEncode($_.Exception.Message)
        return "<section><h2>$safeTitle</h2><p class='error'>Unable to render section: $message</p></section>"
    }
}

function Get-SafeCimInstance {
    param(
        [Parameter(Mandatory)]
        [string]$ClassName,

        [string]$Namespace = 'root/cimv2',

        [string]$Filter
    )

    try {
        if ($Filter) {
            return Get-CimInstance -Namespace $Namespace -ClassName $ClassName -Filter $Filter -ErrorAction Stop
        }

        return Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop
    }
    catch {
        Write-Warning "Unable to query ${ClassName}: $($_.Exception.Message)"
        return @()
    }
}

$isAdmin = Test-IsAdministrator
$generatedAt = Get-Date
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

Write-Host "Collecting system information from $computerName..."
Write-Host "Administrator: $isAdmin"
Write-Host "Reports: $OutputDirectory"

$sections = [System.Collections.Generic.List[string]]::new()

# Overview
$os = Get-SafeCimInstance -ClassName Win32_OperatingSystem | Select-Object -First 1
$computerSystem = Get-SafeCimInstance -ClassName Win32_ComputerSystem | Select-Object -First 1
$bios = Get-SafeCimInstance -ClassName Win32_BIOS | Select-Object -First 1
$baseboard = Get-SafeCimInstance -ClassName Win32_BaseBoard | Select-Object -First 1
$processor = Get-SafeCimInstance -ClassName Win32_Processor

$overview = [pscustomobject]@{
    ComputerName        = $computerName
    CurrentUser         = $currentUser
    IsAdministrator     = $isAdmin
    Manufacturer        = $computerSystem.Manufacturer
    Model               = $computerSystem.Model
    DomainOrWorkgroup   = $computerSystem.Domain
    DomainRole          = $computerSystem.DomainRole
    OperatingSystem     = $os.Caption
    OSVersion           = $os.Version
    OSBuild              = $os.BuildNumber
    Architecture        = $os.OSArchitecture
    InstallDate         = $os.InstallDate
    LastBootTime        = $os.LastBootUpTime
    Uptime              = if ($os.LastBootUpTime) { (Get-Date) - $os.LastBootUpTime } else { $null }
    BIOSManufacturer    = $bios.Manufacturer
    BIOSVersion         = ($bios.SMBIOSBIOSVersion -join ', ')
    BIOSReleaseDate     = $bios.ReleaseDate
    SerialNumber        = $bios.SerialNumber
    Baseboard           = "$($baseboard.Manufacturer) $($baseboard.Product)"
    PowerShellVersion   = $PSVersionTable.PSVersion.ToString()
    ReportGenerated     = $generatedAt
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'System Overview' -Data @($overview)))

# CPU and memory
$cpuInfo = $processor | Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors,
    MaxClockSpeed, CurrentClockSpeed, SocketDesignation, VirtualizationFirmwareEnabled
$sections.Add((Convert-ObjectToHtmlTable -Title 'Processor' -Data $cpuInfo))

$memoryModules = Get-SafeCimInstance -ClassName Win32_PhysicalMemory | ForEach-Object {
    [pscustomobject]@{
        BankLabel       = $_.BankLabel
        DeviceLocator   = $_.DeviceLocator
        Manufacturer    = $_.Manufacturer
        PartNumber      = ($_.PartNumber -as [string]).Trim()
        CapacityGB      = [math]::Round($_.Capacity / 1GB, 2)
        SpeedMHz        = $_.Speed
        ConfiguredMHz   = $_.ConfiguredClockSpeed
        SerialNumber    = ($_.SerialNumber -as [string]).Trim()
    }
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Physical Memory' -Data $memoryModules))

# Disks and volumes
$physicalDisks = @()
try {
    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $physicalDisks = Get-PhysicalDisk -ErrorAction Stop | Select-Object FriendlyName, Manufacturer, Model,
            SerialNumber, MediaType, BusType, HealthStatus, OperationalStatus,
            @{Name='SizeGB';Expression={[math]::Round($_.Size / 1GB, 2)}}
    }
}
catch {
    Write-Warning "Unable to query physical disks: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Physical Disks' -Data $physicalDisks))

$volumes = @()
try {
    if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
        $volumes = Get-Volume -ErrorAction Stop | Select-Object DriveLetter, FileSystemLabel, FileSystem,
            HealthStatus, OperationalStatus,
            @{Name='SizeGB';Expression={if ($_.Size) {[math]::Round($_.Size / 1GB, 2)}}},
            @{Name='FreeGB';Expression={if ($_.SizeRemaining) {[math]::Round($_.SizeRemaining / 1GB, 2)}}},
            @{Name='FreePercent';Expression={if ($_.Size) {[math]::Round(($_.SizeRemaining / $_.Size) * 100, 1)}}}
    }
}
catch {
    Write-Warning "Unable to query volumes: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Volumes' -Data $volumes))

# Graphics and displays
$videoControllers = Get-SafeCimInstance -ClassName Win32_VideoController | Select-Object Name, AdapterCompatibility,
    DriverVersion, VideoProcessor,
    @{Name='AdapterRAMGB';Expression={if ($_.AdapterRAM) {[math]::Round($_.AdapterRAM / 1GB, 2)}}},
    CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate
$sections.Add((Convert-ObjectToHtmlTable -Title 'Graphics Adapters' -Data $videoControllers))

$monitors = Get-SafeCimInstance -Namespace 'root/wmi' -ClassName WmiMonitorID | ForEach-Object {
    $decode = {
        param($arr)
        if ($null -eq $arr) { return '' }
        return (($arr | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join '').Trim()
    }

    [pscustomobject]@{
        Manufacturer = & $decode $_.ManufacturerName
        ProductCode  = & $decode $_.ProductCodeID
        SerialNumber = & $decode $_.SerialNumberID
        FriendlyName = & $decode $_.UserFriendlyName
        Active       = $_.Active
    }
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Monitors' -Data $monitors))

# Network
$networkAdapters = @()
try {
    if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
        $networkAdapters = Get-NetAdapter -IncludeHidden -ErrorAction Stop | Select-Object Name, InterfaceDescription,
            Status, MacAddress, LinkSpeed, MediaType, PhysicalMediaType, DriverDescription, DriverVersion
    }
}
catch {
    Write-Warning "Unable to query network adapters: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Network Adapters' -Data $networkAdapters))

$ipConfig = @()
try {
    if (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
        $ipConfig = Get-NetIPConfiguration -Detailed -ErrorAction Stop | ForEach-Object {
            $config = $_

            $ipv4 = @(
                $config.IPv4Address |
                    ForEach-Object {
                        if ($_ -is [string]) { $_ }
                        elseif ($_.PSObject.Properties['IPAddress']) { $_.IPAddress }
                        else { [string]$_ }
                    } |
                    Where-Object { $_ }
            )

            $ipv6 = @(
                $config.IPv6Address |
                    ForEach-Object {
                        if ($_ -is [string]) { $_ }
                        elseif ($_.PSObject.Properties['IPAddress']) { $_.IPAddress }
                        else { [string]$_ }
                    } |
                    Where-Object { $_ }
            )

            $gateways = @(
                $config.IPv4DefaultGateway |
                    ForEach-Object {
                        if ($_ -is [string]) { $_ }
                        elseif ($_.PSObject.Properties['NextHop']) { $_.NextHop }
                        else { [string]$_ }
                    } |
                    Where-Object { $_ }
            )

            $dnsServers = @(
                $config.DNSServer |
                    ForEach-Object {
                        if ($_.PSObject.Properties['ServerAddresses']) {
                            $_.ServerAddresses
                        }
                        else {
                            [string]$_
                        }
                    } |
                    Where-Object { $_ }
            )

            [pscustomobject]@{
                InterfaceAlias       = $config.InterfaceAlias
                InterfaceDescription = $config.InterfaceDescription
                NetProfile           = if ($config.NetProfile) { $config.NetProfile.Name } else { '' }
                IPv4Address          = $ipv4 -join ', '
                IPv6Address          = $ipv6 -join ', '
                IPv4Gateway          = $gateways -join ', '
                DNSServers           = $dnsServers -join ', '
            }
        }
    }
}
catch {
    Write-Warning "Unable to query IP configuration: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'IP Configuration' -Data $ipConfig))

$networkProfiles = @()
try {
    if (Get-Command Get-NetConnectionProfile -ErrorAction SilentlyContinue) {
        $networkProfiles = Get-NetConnectionProfile -ErrorAction Stop |
            Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity, IPv6Connectivity
    }
}
catch {
    Write-Warning "Unable to query network profiles: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Network Profiles' -Data $networkProfiles))

$dnsCache = @()
try {
    if (Get-Command Get-DnsClientCache -ErrorAction SilentlyContinue) {
        $dnsCache = Get-DnsClientCache -ErrorAction Stop |
            Select-Object -First 200 Entry, RecordName, RecordType, Data, TimeToLive, Status
    }
}
catch {
    Write-Warning "Unable to query DNS cache: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'DNS Cache (First 200 Entries)' -Data $dnsCache))

# Domain, local admins, GPO
$localAdmins = @()
try {
    if (Get-Command Get-LocalGroupMember -ErrorAction SilentlyContinue) {
        $localAdmins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop |
            Select-Object Name, ObjectClass, PrincipalSource
    }
    else {
        $localAdmins = net localgroup Administrators 2>&1 | ForEach-Object {
            [pscustomobject]@{ Output = $_ }
        }
    }
}
catch {
    Write-Warning "Unable to query local Administrators group: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Local Administrators' -Data $localAdmins))

$gpoSummary = @()
try {
    $gpResultText = gpresult /r /scope computer 2>&1
    $gpoSummary = $gpResultText | ForEach-Object { [pscustomobject]@{ Output = $_ } }
}
catch {
    Write-Warning "Unable to run gpresult: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Computer Group Policy Summary' -Data $gpoSummary))

# Security
$bitLocker = @()
try {
    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        $bitLocker = Get-BitLockerVolume -ErrorAction Stop | Select-Object MountPoint, VolumeType,
            VolumeStatus, ProtectionStatus, EncryptionMethod, EncryptionPercentage, AutoUnlockEnabled
    }
}
catch {
    Write-Warning "Unable to query BitLocker: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'BitLocker' -Data $bitLocker))

$tpmInfo = @()
try {
    if (Get-Command Get-Tpm -ErrorAction SilentlyContinue) {
        $tpmInfo = @(Get-Tpm -ErrorAction Stop)
    }
}
catch {
    Write-Warning "Unable to query TPM: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'TPM' -Data $tpmInfo))

$secureBoot = [pscustomobject]@{
    Supported = $null
    Enabled   = $null
    Error     = $null
}
try {
    $secureBoot.Enabled = Confirm-SecureBootUEFI -ErrorAction Stop
    $secureBoot.Supported = $true
}
catch {
    $secureBoot.Supported = $false
    $secureBoot.Error = $_.Exception.Message
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Secure Boot' -Data @($secureBoot)))

$defender = @()
try {
    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        $defender = Get-MpComputerStatus -ErrorAction Stop | Select-Object AMServiceEnabled, AntispywareEnabled,
            AntivirusEnabled, BehaviorMonitorEnabled, IoavProtectionEnabled, NISEnabled,
            OnAccessProtectionEnabled, RealTimeProtectionEnabled, TamperProtectionSource,
            AntivirusSignatureVersion, AntivirusSignatureLastUpdated, QuickScanAge, FullScanAge
    }
}
catch {
    Write-Warning "Unable to query Microsoft Defender: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Microsoft Defender' -Data $defender))

$firewallProfiles = @()
try {
    if (Get-Command Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
        $firewallProfiles = Get-NetFirewallProfile -ErrorAction Stop | Select-Object Name, Enabled,
            DefaultInboundAction, DefaultOutboundAction, NotifyOnListen, LogFileName, LogMaxSizeKilobytes
    }
}
catch {
    Write-Warning "Unable to query Windows Firewall: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Windows Firewall Profiles' -Data $firewallProfiles))

# Services and startup
$services = Get-Service | Sort-Object Status, DisplayName | Select-Object Status, Name, DisplayName, StartType
$sections.Add((Convert-ObjectToHtmlTable -Title 'Services' -Data $services))

$startupItems = Get-SafeCimInstance -ClassName Win32_StartupCommand |
    Select-Object Name, Command, Location, User
$sections.Add((Convert-ObjectToHtmlTable -Title 'Startup Items' -Data $startupItems))

# Shares and mapped drives
$shares = Get-SafeCimInstance -ClassName Win32_Share | Select-Object Name, Path, Description, Type
$sections.Add((Convert-ObjectToHtmlTable -Title 'Windows Shares' -Data $shares))

$mappedDrives = Get-SafeCimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 4' |
    Select-Object DeviceID, ProviderName, VolumeName
$sections.Add((Convert-ObjectToHtmlTable -Title 'Mapped Drives' -Data $mappedDrives))

# Printers
$printers = Get-SafeCimInstance -ClassName Win32_Printer |
    Select-Object Name, DriverName, PortName, Default, Network, Shared, WorkOffline, PrinterStatus
$sections.Add((Convert-ObjectToHtmlTable -Title 'Printers' -Data $printers))

# Installed updates
$hotfixes = @()
try {
    $hotfixes = Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending |
        Select-Object HotFixID, Description, InstalledBy, InstalledOn
}
catch {
    Write-Warning "Unable to query installed updates: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Installed Windows Updates' -Data $hotfixes))

# Installed software
if ($IncludeInstalledSoftware) {
    $software = @()
    $uninstallPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $uninstallPaths) {
        $parentPath = $path.TrimEnd('\*')

        if (-not (Test-Path -LiteralPath $parentPath)) {
            continue
        }

        try {
            $software += Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName } |
                Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation
        }
        catch {
            Write-Verbose "Unable to query software path $path`: $($_.Exception.Message)"
        }
    }

    $software = $software | Sort-Object DisplayName, DisplayVersion -Unique
    $sections.Add((Convert-ObjectToHtmlTable -Title 'Installed Software' -Data $software))
}

# RDP configuration
$rdp = [pscustomobject]@{
    RemoteDesktopEnabled = $null
    NLARequired          = $null
    RDPServiceStatus     = $null
}
try {
    $tsSettings = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction Stop
    $rdp.RemoteDesktopEnabled = ($tsSettings.fDenyTSConnections -eq 0)

    $nlaSettings = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction Stop
    $rdp.NLARequired = ($nlaSettings.UserAuthentication -eq 1)

    $rdp.RDPServiceStatus = (Get-Service TermService -ErrorAction Stop).Status
}
catch {
    Write-Warning "Unable to query RDP settings: $($_.Exception.Message)"
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Remote Desktop' -Data @($rdp)))

# Pending reboot
$pendingReboot = [ordered]@{
    ComponentBasedServicing = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    WindowsUpdate           = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    PendingFileRename       = $false
    SCCMClient              = $null
    RebootPending           = $false
}

try {
    $sessionManager = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
    $pendingReboot.PendingFileRename = $null -ne $sessionManager.PendingFileRenameOperations
}
catch {}

try {
    $sccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName CCM_ClientUtilities `
        -MethodName DetermineIfRebootPending -ErrorAction Stop
    $pendingReboot.SCCMClient = $sccm.RebootPending
}
catch {}

$pendingReboot.RebootPending = [bool](
    $pendingReboot.ComponentBasedServicing -or
    $pendingReboot.WindowsUpdate -or
    $pendingReboot.PendingFileRename -or
    $pendingReboot.SCCMClient
)
$sections.Add((Convert-ObjectToHtmlTable -Title 'Pending Reboot Status' -Data @([pscustomobject]$pendingReboot)))

# Event summary
if ($IncludeEventSummary) {
    $events = @()
    try {
        $startTime = (Get-Date).AddHours(-$EventLookbackHours)
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = @('System', 'Application')
            Level     = @(1, 2)
            StartTime = $startTime
        } -ErrorAction Stop | Select-Object -First 300 TimeCreated, LogName, Id, LevelDisplayName,
            ProviderName, MachineName,
            @{Name='Message';Expression={
                if ($_.Message) {
                    ($_.Message -replace '\s+', ' ').Trim()
                }
            }}
    }
    catch {
        Write-Warning "Unable to query recent events: $($_.Exception.Message)"
    }

    $sections.Add((Convert-ObjectToHtmlTable -Title "Critical and Error Events — Last $EventLookbackHours Hours (First 300)" -Data $events))
}

# Activation status
$activation = Get-SafeCimInstance -ClassName SoftwareLicensingProduct |
    Where-Object {
        $_.PartialProductKey -and $_.Name -like 'Windows*'
    } |
    Select-Object Name, Description, LicenseStatus, PartialProductKey, GracePeriodRemaining
$sections.Add((Convert-ObjectToHtmlTable -Title 'Windows Activation' -Data $activation))

# Time configuration
$timeService = @()
try {
    $timeService = w32tm /query /status 2>&1 | ForEach-Object {
        [pscustomobject]@{ Output = $_ }
    }
}
catch {
    Write-Warning "Unable to query time service."
}
$sections.Add((Convert-ObjectToHtmlTable -Title 'Windows Time Service' -Data $timeService))

# Environment
$environment = Get-ChildItem Env: | Sort-Object Name | Select-Object Name, Value
$sections.Add((Convert-ObjectToHtmlTable -Title 'Environment Variables' -Data $environment))

# HTML document
$css = @'
<style>
    body {
        font-family: "Segoe UI", Arial, sans-serif;
        margin: 24px;
        background: #f4f6f8;
        color: #1f2933;
    }
    header {
        background: #ffffff;
        border: 1px solid #d9e2ec;
        border-radius: 8px;
        padding: 20px;
        margin-bottom: 20px;
    }
    section {
        background: #ffffff;
        border: 1px solid #d9e2ec;
        border-radius: 8px;
        padding: 18px;
        margin-bottom: 18px;
        overflow-x: auto;
    }
    h1 { margin: 0 0 8px 0; }
    h2 { margin-top: 0; font-size: 1.2rem; }
    .meta { color: #52606d; }
    .warning {
        padding: 10px;
        border: 1px solid #f0b429;
        background: #fffbea;
        border-radius: 5px;
    }
    .empty { color: #7b8794; font-style: italic; }
    .error { color: #ba2525; }
    table {
        border-collapse: collapse;
        width: 100%;
        font-size: 0.9rem;
    }
    th, td {
        border: 1px solid #d9e2ec;
        padding: 7px 9px;
        text-align: left;
        vertical-align: top;
        white-space: pre-wrap;
        word-break: break-word;
    }
    th {
        background: #e9eef3;
        position: sticky;
        top: 0;
    }
    tr:nth-child(even) { background: #f8fafc; }
</style>
'@

$adminNotice = if ($isAdmin) {
    '<p class="meta">The report was collected with administrative rights.</p>'
}
else {
    '<p class="warning">The report was not collected with administrative rights. Some security, event-log, BitLocker, and Group Policy details may be incomplete.</p>'
}

$body = @"
<header>
    <h1>Windows System Information Report</h1>
    <p class="meta"><strong>Computer:</strong> $computerName</p>
    <p class="meta"><strong>Generated:</strong> $($generatedAt.ToString('yyyy-MM-dd HH:mm:ss'))</p>
    <p class="meta"><strong>User:</strong> $([System.Net.WebUtility]::HtmlEncode($currentUser))</p>
    $adminNotice
</header>
$($sections -join "`r`n")
"@

$html = ConvertTo-Html -Title "System Information - $computerName" -Head $css -Body $body
$html | Set-Content -Path $htmlPath -Encoding UTF8

Write-Host ""
Write-Host "Collection complete."
Write-Host "HTML report: $htmlPath"
Write-Host "Text transcript: $textPath"

Stop-Transcript | Out-Null

try {
    Start-Process $htmlPath
}
catch {
    Write-Warning "The report was created but could not be opened automatically."
}
