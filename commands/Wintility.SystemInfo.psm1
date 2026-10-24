# System information. Read-only: nothing here changes the system.
# Every section is read inside its own try/catch, so one failing read never hides the others.
# No WMI and no administrator rights are needed.
Set-StrictMode -Version Latest

Import-Module -Name (Join-Path $PSScriptRoot '..\core\Wintility.Core.psm1')

$script:SpeedTestUrl = 'https://speed.cloudflare.com/__down?bytes=25000000'
$script:SpeedTestMaxBytes = 25000000
$script:SpeedTestMaxSeconds = 8

function Format-WintilityBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Format-WintilityLinkSpeed {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$BitsPerSecond)
    if ($BitsPerSecond -le 0) { return 'Unknown' }
    if ($BitsPerSecond -ge 1e9) { return ('{0:N1} Gbps' -f ($BitsPerSecond / 1e9)) }
    return ('{0:N0} Mbps' -f ($BitsPerSecond / 1e6))
}

function Get-WintilityMemoryInfo {
    [CmdletBinding()]
    param()
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $info = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
        return [PSCustomObject]@{
            TotalBytes     = [double]$info.TotalPhysicalMemory
            AvailableBytes = [double]$info.AvailablePhysicalMemory
        }
    }
    catch {
        return $null
    }
}

function Get-WintilityDriveInfo {
    [CmdletBinding()]
    param()
    $list = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -eq [System.IO.DriveType]::Fixed -and $drive.IsReady) {
                $list.Add([PSCustomObject]@{
                    Name       = $drive.Name.TrimEnd('\')
                    TotalBytes = [double]$drive.TotalSize
                    FreeBytes  = [double]$drive.AvailableFreeSpace
                })
            }
        }
    }
    catch {
        Write-Verbose "Drive read failed: $($_.Exception.Message)"
    }
    return $list.ToArray()
}

function Get-WintilityNetworkInfo {
    [CmdletBinding()]
    param()
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel) { continue }

            # The adapter that has an IPv4 default gateway is the one actually carrying traffic.
            $properties = $nic.GetIPProperties()
            $gateway = @($properties.GatewayAddresses | Where-Object {
                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.ToString() -ne '0.0.0.0'
            })
            if ($gateway.Count -eq 0) { continue }
            $address = @($properties.UnicastAddresses | Where-Object {
                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
            }) | Select-Object -First 1
            if ($null -eq $address) { continue }

            # The network name is the connection profile (the Wi-Fi name on wireless). Fall back to the adapter name.
            $name = $nic.Name
            try {
                $index = $properties.GetIPv4Properties().Index
                $connection = Get-NetConnectionProfile -InterfaceIndex $index -ErrorAction Stop
                if ($connection.Name) { $name = $connection.Name }
            }
            catch {
                Write-Verbose "Network name lookup failed: $($_.Exception.Message)"
            }

            $kind = [string]$nic.NetworkInterfaceType
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) { $kind = 'Wi-Fi' }
            elseif ($kind -like '*Ethernet*') { $kind = 'Ethernet' }

            return [PSCustomObject]@{
                Name               = $name
                Adapter            = $nic.Name
                Kind               = $kind
                IPv4               = $address.Address.ToString()
                SpeedBitsPerSecond = [double]$nic.Speed
            }
        }
    }
    catch {
        Write-Verbose "Network read failed: $($_.Exception.Message)"
    }
    return $null
}

function Get-WintilitySystemInfo {
    [CmdletBinding()]
    param()
    return [PSCustomObject]@{
        ComputerName = [Environment]::MachineName
        Memory       = (Get-WintilityMemoryInfo)
        Drives       = @(Get-WintilityDriveInfo)
        Network      = (Get-WintilityNetworkInfo)
    }
}

# The download runs in its own runspace so the window never freezes. The script is
# self-contained because a separate runspace cannot see this module's functions.
$script:SpeedTestWork = {
    param([string]$Url, [int]$MaxBytes, [int]$MaxSeconds)
    $outcome = @{ Success = $false; Bytes = 0L; Seconds = 0.0; Error = $null }
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Timeout = 8000
        $request.ReadWriteTimeout = 8000
        $request.UserAgent = 'Wintility'
        $response = $request.GetResponse()
        try {
            $stream = $response.GetResponseStream()
            $buffer = New-Object byte[] 65536
            $total = 0L
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            while ($total -lt $MaxBytes -and $clock.Elapsed.TotalSeconds -lt $MaxSeconds) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $total += $read
            }
            $clock.Stop()
            $outcome.Bytes = $total
            $outcome.Seconds = $clock.Elapsed.TotalSeconds
            $outcome.Success = ($total -gt 0)
            if (-not $outcome.Success) { $outcome.Error = 'The server returned no data.' }
        }
        finally {
            $response.Close()
        }
    }
    catch {
        $outcome.Error = $_.Exception.Message
    }
    return [PSCustomObject]$outcome
}

function Start-WintilitySpeedTest {
    [CmdletBinding()]
    param()
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $shell = [System.Management.Automation.PowerShell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($script:SpeedTestWork.ToString()).AddArgument($script:SpeedTestUrl).AddArgument($script:SpeedTestMaxBytes).AddArgument($script:SpeedTestMaxSeconds)
    return [PSCustomObject]@{ Shell = $shell; Runspace = $runspace; Handle = $shell.BeginInvoke() }
}

function Receive-WintilitySpeedTest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Job)

    # Returns nothing while the test is still running, and a standard result object when it is done.
    if (-not $Job.Handle.IsCompleted) { return $null }
    try {
        $output = @($Job.Shell.EndInvoke($Job.Handle))
        $raw = $output | Select-Object -Last 1
        if ($null -ne $raw -and $raw.Success -and $raw.Seconds -gt 0) {
            $mbps = ($raw.Bytes * 8.0 / $raw.Seconds) / 1e6
            return (New-WintilityResult -Id 'SpeedTest' -Name 'Internet speed' -Message ('{0:N1} Mbps download' -f $mbps))
        }
        $detail = 'The test returned no result.'
        if ($null -ne $raw -and $raw.Error) { $detail = [string]$raw.Error }
        return (New-WintilityResult -Id 'SpeedTest' -Name 'Internet speed' -Success $false -Message 'The speed test could not finish. The network may block it.' -ErrorDetail $detail)
    }
    catch {
        return (New-WintilityResult -Id 'SpeedTest' -Name 'Internet speed' -Success $false -Message 'The speed test could not finish.' -ErrorDetail $_.Exception.Message)
    }
    finally {
        $Job.Shell.Dispose()
        $Job.Runspace.Dispose()
    }
}
