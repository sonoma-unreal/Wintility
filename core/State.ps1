# Registry helpers. Only HKCU and HKLM are accepted. Anything else is rejected
# before the registry is touched.

function Test-WintilityRegistryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return ($Path -match '^(HKCU|HKLM):\\')
}

function Assert-WintilityRegistryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-WintilityRegistryPath -Path $Path)) {
        throw "Registry path is outside the allowed hives (HKCU or HKLM): $Path"
    }
}

function Get-WintilityRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    Assert-WintilityRegistryPath -Path $Path

    $state = [PSCustomObject]@{ Path = $Path; Name = $Name; Exists = $false; Value = $null; Kind = $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $state }

    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($key.GetValueNames() -notcontains $Name) { return $state }

    $state.Exists = $true
    $state.Kind   = $key.GetValueKind($Name).ToString()
    $state.Value  = $key.GetValue($Name)
    return $state
}

function Set-WintilityRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('DWord', 'QWord', 'String')][string]$Kind,
        [Parameter(Mandatory)][object]$Value
    )
    Assert-WintilityRegistryPath -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force -ErrorAction Stop | Out-Null
}

function Remove-WintilityRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    Assert-WintilityRegistryPath -Path $Path
    if (Test-Path -LiteralPath $Path) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    }
}
