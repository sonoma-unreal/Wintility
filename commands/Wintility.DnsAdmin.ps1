param(
    [Parameter(Mandatory)][ValidateSet('Apply','Reset','Flush')][string]$Operation,
    [uint32]$InterfaceIndex,
    [ValidateSet('Cloudflare','Google','Quad9','AdGuard')][string]$Provider,
    [switch]$DnsOverHttps
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Import-Module -Name (Join-Path $PSScriptRoot 'Wintility.Network.psm1')

try {
    switch ($Operation) {
        'Apply' { $result = Set-WintilityDnsProvider -InterfaceIndex $InterfaceIndex -Provider $Provider -DnsOverHttps:$DnsOverHttps }
        'Reset' { $result = Reset-WintilityDnsProvider -InterfaceIndex $InterfaceIndex }
        'Flush' { $result = Clear-WintilityDnsCache }
    }
    [System.Windows.MessageBox]::Show([string]$result.Message, 'Wintility DNS', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
}
catch {
    [System.Windows.MessageBox]::Show($_.Exception.Message, 'Wintility DNS', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    exit 1
}
