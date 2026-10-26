# DNS and adapter operations for the Internet tab.
Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot '..\core\Wintility.Core.psm1')

$script:DnsProviders = @{
    Cloudflare = @{ Servers = @('1.1.1.1','1.0.0.1','2606:4700:4700::1111','2606:4700:4700::1001'); Doh = 'https://cloudflare-dns.com/dns-query' }
    Google     = @{ Servers = @('8.8.8.8','8.8.4.4','2001:4860:4860::8888','2001:4860:4860::8844'); Doh = 'https://dns.google/dns-query' }
    Quad9      = @{ Servers = @('9.9.9.9','149.112.112.112','2620:fe::fe','2620:fe::9'); Doh = 'https://dns.quad9.net/dns-query' }
    AdGuard    = @{ Servers = @('94.140.14.14','94.140.15.15','2a10:50c0::ad1:ff','2a10:50c0::ad2:ff'); Doh = 'https://dns.adguard-dns.com/dns-query' }
}

function Test-WintilityNetworkAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-WintilityNetworkAdmin {
    if (-not (Test-WintilityNetworkAdmin)) {
        throw 'Changing adapter DNS settings requires administrator access. Restart Wintility as administrator from Settings.'
    }
}

function Get-WintilityNetworkAdapters {
    [CmdletBinding()]
    param()

    $configurations = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.NetAdapter.Status -eq 'Up' })
    foreach ($configuration in $configurations) {
        $index = [uint32]$configuration.InterfaceIndex
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $index -ErrorAction SilentlyContinue |
            ForEach-Object { $_.ServerAddresses } | Where-Object { $_ })
        $ipv4 = @($configuration.IPv4Address | ForEach-Object { $_.IPAddress }) -join ', '
        $ipv6 = @($configuration.IPv6Address | ForEach-Object { $_.IPAddress }) -join ', '
        $address = @($ipv4, $ipv6 | Where-Object { $_ }) -join '  |  '
        [PSCustomObject]@{
            InterfaceAlias = [string]$configuration.InterfaceAlias
            InterfaceIndex = $index
            Status = [string]$configuration.NetAdapter.Status
            Addresses = $address
            DnsServers = @($dns | Select-Object -Unique)
        }
    }
}

function Set-WintilityDnsOverHttps {
    param([Parameter(Mandatory)][string[]]$ServerAddresses, [AllowEmptyString()][string]$Template, [Parameter(Mandatory)][bool]$Enabled)

    $addCommand = Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue
    $setCommand = Get-Command Set-DnsClientDohServerAddress -ErrorAction SilentlyContinue
    if ($Enabled -and -not $addCommand) {
        throw 'This Windows version does not expose native DNS-over-HTTPS configuration. DNS addresses were not changed.'
    }
    if (-not $Enabled -and -not $setCommand) { return }
    $uri = $null
    if ($Enabled -and (-not [Uri]::TryCreate($Template, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https')) {
        throw 'DNS over HTTPS needs a valid HTTPS resolver template.'
    }

    foreach ($server in $ServerAddresses) {
        $existing = @(Get-DnsClientDohServerAddress -ServerAddress $server -ErrorAction SilentlyContinue)
        if ($Enabled) {
            if ($existing.Count -gt 0) {
                Set-DnsClientDohServerAddress -ServerAddress $server -DohTemplate $Template -AutoUpgrade $true -AllowFallbackToUdp $false -ErrorAction Stop | Out-Null
            }
            else {
                Add-DnsClientDohServerAddress -ServerAddress $server -DohTemplate $Template -AutoUpgrade $true -AllowFallbackToUdp $false -ErrorAction Stop | Out-Null
            }
        }
        elseif ($existing.Count -gt 0) {
            Set-DnsClientDohServerAddress -ServerAddress $server -AutoUpgrade $false -AllowFallbackToUdp $true -ErrorAction Stop | Out-Null
        }
    }
}

function Set-WintilityDnsProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uint32]$InterfaceIndex,
        [Parameter(Mandatory)][ValidateSet('Cloudflare','Google','Quad9','AdGuard')][string]$Provider,
        [bool]$DnsOverHttps = $false
    )

    Assert-WintilityNetworkAdmin
    $adapter = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction Stop
    if ($adapter.Status -ne 'Up') { throw 'That network adapter is no longer connected. Refresh the adapter list and try again.' }

    $providerInfo = $script:DnsProviders[$Provider]
    $servers = @($providerInfo.Servers)
    $template = $providerInfo.Doh

    $before = @(Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ErrorAction Stop | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ } | Select-Object -Unique)
    if ($DnsOverHttps) { Set-WintilityDnsOverHttps -ServerAddresses $servers -Template $template -Enabled $true }
    else { Set-WintilityDnsOverHttps -ServerAddresses $servers -Template ($template -as [string]) -Enabled $false }

    try {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $servers -ErrorAction Stop | Out-Null
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    }
    catch {
        if ($before.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $before -ErrorAction SilentlyContinue | Out-Null
        }
        throw
    }

    $mode = if ($DnsOverHttps) { 'with DNS over HTTPS enabled' } else { 'without DNS over HTTPS' }
    return (New-WintilityResult -Id 'DnsProvider' -Name 'DNS resolver' -Changed $true -Message "Set $($adapter.Name) to $Provider $mode. DNS cache flushed.")
}

function Reset-WintilityDnsProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$InterfaceIndex)
    Assert-WintilityNetworkAdmin
    $adapter = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction Stop
    Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ResetServerAddresses -ErrorAction Stop | Out-Null
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    return (New-WintilityResult -Id 'DnsReset' -Name 'DNS resolver' -Changed $true -Message "Restored automatic DNS for $($adapter.Name). DNS cache flushed.")
}

function Clear-WintilityDnsCache {
    [CmdletBinding()]
    param()
    Assert-WintilityNetworkAdmin
    Clear-DnsClientCache -ErrorAction Stop
    return (New-WintilityResult -Id 'DnsFlush' -Name 'DNS cache' -Changed $true -Message 'Windows DNS resolver cache flushed.')
}

Export-ModuleMember -Function Get-WintilityNetworkAdapters, Set-WintilityDnsProvider, Reset-WintilityDnsProvider, Clear-WintilityDnsCache
