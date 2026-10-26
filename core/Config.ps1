# Configuration loading and validation.
# JSON describes WHAT can be changed. The feature engine decides HOW.
# Config is validated before anything uses it, so a broken file produces a readable
# report instead of a crash deep inside a feature.

$script:WintilityRoot = $null
$script:WintilityConfigCache = @{}
$script:WintilityConfigSchemaVersion = 1
$script:WintilityTabs = @('Personalization', 'Performance', 'Ads', 'Privacy', 'Internet', 'Storage', 'Debloat')
$script:WintilityRisks = @('Low', 'Medium', 'High')
$script:WintilityActions = @('registry')
$script:WintilityRegistryTypes = @('DWord', 'QWord', 'String')
$script:WintilityIdPattern = '^[A-Za-z][A-Za-z0-9]{2,63}$'
$script:WintilityRegistryPattern = '^(HKCU|HKLM):\\'
$script:WintilityBooleanFlags = @('requiresAdmin', 'requiresRestart', 'requiresLogoff', 'reversible', 'enabledByDefault')

function Set-WintilityRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $script:WintilityRoot = $Path
    $script:WintilityConfigCache = @{}
}

function Get-WintilityConfigDirectory {
    [CmdletBinding()]
    param()
    if (-not $script:WintilityRoot) {
        throw 'Wintility root has not been set. Call Set-WintilityRoot first.'
    }
    return (Join-Path $script:WintilityRoot 'config')
}

function Test-WintilityHasProperty {
    [CmdletBinding()]
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-WintilityProperty {
    [CmdletBinding()]
    param($Object, [string]$Name)
    if (Test-WintilityHasProperty -Object $Object -Name $Name) { return $Object.$Name }
    return $null
}

function Read-WintilityConfigFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path (Get-WintilityConfigDirectory) "$Name.json"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Config file is missing: $Name.json"
    }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        throw "Config file is not valid JSON: $Name.json. $($_.Exception.Message)"
    }
}

function Test-WintilityConfigData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()][object]$Data
    )
    $problems = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Data) {
        $problems.Add("$Name.json is empty.")
        return $problems.ToArray()
    }
    if ((Get-WintilityProperty -Object $Data -Name 'schemaVersion') -ne $script:WintilityConfigSchemaVersion) {
        $problems.Add("$Name.json has an unsupported schemaVersion (expected $($script:WintilityConfigSchemaVersion)).")
    }

    if ($Name -eq 'presets') {
        $presets = @(Get-WintilityProperty -Object $Data -Name 'presets')
        if ($presets.Count -eq 0) { $problems.Add('presets.json defines no presets.') }
        $seen = @{}
        foreach ($preset in $presets) {
            $presetName = Get-WintilityProperty -Object $preset -Name 'name'
            if ([string]::IsNullOrWhiteSpace($presetName)) {
                $problems.Add('presets.json has a preset with no name.')
                continue
            }
            if ($seen.ContainsKey($presetName)) { $problems.Add("presets.json defines preset '$presetName' twice.") }
            $seen[$presetName] = $true
            if (@(Get-WintilityProperty -Object $preset -Name 'settings').Count -eq 0) {
                $problems.Add("Preset '$presetName' has no settings.")
            }
        }
        return $problems.ToArray()
    }

    $items = @(Get-WintilityProperty -Object $Data -Name 'settings')
    if ($items.Count -eq 0) {
        $problems.Add("$Name.json defines no settings.")
        return $problems.ToArray()
    }

    $seen = @{}
    foreach ($item in $items) {
        $id = Get-WintilityProperty -Object $item -Name 'id'
        if (-not $id -or $id -notmatch $script:WintilityIdPattern) {
            $problems.Add("$Name.json has an invalid id '$id'.")
            continue
        }
        $label = "$Name.json / $id"

        if ($seen.ContainsKey($id)) { $problems.Add("$label is defined more than once.") }
        $seen[$id] = $true

        if ([string]::IsNullOrWhiteSpace((Get-WintilityProperty -Object $item -Name 'name'))) {
            $problems.Add("$label has no name.")
        }
        if ([string]::IsNullOrWhiteSpace((Get-WintilityProperty -Object $item -Name 'description'))) {
            $problems.Add("$label has no description.")
        }
        if ([string]::IsNullOrWhiteSpace((Get-WintilityProperty -Object $item -Name 'category'))) {
            $problems.Add("$label has no category.")
        }
        $iconName = Get-WintilityProperty -Object $item -Name 'icon'
        if ($null -ne $iconName -and ($iconName -isnot [string] -or $iconName -notmatch '^[A-Za-z0-9]+$')) {
            $problems.Add("$label has an invalid icon name.")
        }
        if ($script:WintilityTabs -notcontains (Get-WintilityProperty -Object $item -Name 'tab')) {
            $problems.Add("$label has an unknown tab.")
        }
        if ($script:WintilityRisks -notcontains (Get-WintilityProperty -Object $item -Name 'risk')) {
            $problems.Add("$label has an unknown risk level.")
        }

        $action = Get-WintilityProperty -Object $item -Name 'action'
        if ($script:WintilityActions -notcontains $action) {
            $problems.Add("$label has an unknown action.")
            continue
        }

        foreach ($flag in $script:WintilityBooleanFlags) {
            if ((Get-WintilityProperty -Object $item -Name $flag) -isnot [bool]) {
                $problems.Add("$label needs '$flag' set to true or false.")
            }
        }
        if ((Get-WintilityProperty -Object $item -Name 'reversible') -ne $true) {
            $problems.Add("$label must be reversible.")
        }
        $explorerFlag = Get-WintilityProperty -Object $item -Name 'requiresExplorerRestart'
        if ($null -ne $explorerFlag -and $explorerFlag -isnot [bool]) {
            $problems.Add("$label needs 'requiresExplorerRestart' set to true or false.")
        }

        if ($action -eq 'registry') {
            $entries = @(Get-WintilityRegistryEntries -Setting $item)
            if ($entries.Count -eq 0) { $problems.Add("$label has no registry values.") }
            $touchesMachine = $false
            $number = 0
            foreach ($reg in $entries) {
                $number++
                $where = "$label (value $number)"
                $path = Get-WintilityProperty -Object $reg -Name 'path'
                if (-not $path -or $path -notmatch $script:WintilityRegistryPattern) {
                    $problems.Add("$where has a registry path that must start with HKCU:\ or HKLM:\.")
                }
                elseif ($path -like 'HKLM:*') {
                    $touchesMachine = $true
                }
                if ([string]::IsNullOrWhiteSpace((Get-WintilityProperty -Object $reg -Name 'name'))) {
                    $problems.Add("$where is missing its registry value name.")
                }
                $type = Get-WintilityProperty -Object $reg -Name 'type'
                if ($script:WintilityRegistryTypes -notcontains $type) {
                    $problems.Add("$where has a registry type that must be DWord, QWord or String.")
                }
                $applied = Get-WintilityProperty -Object $reg -Name 'appliedValue'
                if ($null -eq $applied) {
                    $problems.Add("$where is missing appliedValue.")
                }
                elseif (-not (Test-WintilityValueMatchesType -Value $applied -Type $type)) {
                    $problems.Add("$where has an appliedValue that does not match its type.")
                }
                $hasDefault = Test-WintilityHasProperty -Object $reg -Name 'defaultValue'
                $removes = ((Get-WintilityProperty -Object $reg -Name 'removeOnRevert') -eq $true)
                if ($hasDefault -and $removes) {
                    $problems.Add("$where cannot have both defaultValue and removeOnRevert.")
                }
                if ($hasDefault -and -not (Test-WintilityValueMatchesType -Value (Get-WintilityProperty -Object $reg -Name 'defaultValue') -Type $type)) {
                    $problems.Add("$where has a defaultValue that does not match its type.")
                }
            }
            # HKLM changes always need administrator access. Standard sessions hide these tweaks entirely.
            if ($touchesMachine -and (Get-WintilityProperty -Object $item -Name 'requiresAdmin') -ne $true) {
                $problems.Add("$label changes HKLM, so it must set requiresAdmin to true.")
            }
        }
    }
    return $problems.ToArray()
}

function Get-WintilityConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('personalization', 'performance', 'privacy', 'ads', 'internet', 'storage', 'debloat', 'presets')]
        [string]$Name
    )
    # Config files do not change while Wintility runs, so each one is read and validated only once.
    if ($script:WintilityConfigCache.ContainsKey($Name)) { return $script:WintilityConfigCache[$Name] }

    try {
        $data = Read-WintilityConfigFile -Name $Name
        $problems = @(Test-WintilityConfigData -Name $Name -Data $data)
        $result = [PSCustomObject]@{
            Success  = ($problems.Count -eq 0)
            Name     = $Name
            Data     = $data
            Problems = $problems
        }
    }
    catch {
        $result = [PSCustomObject]@{
            Success  = $false
            Name     = $Name
            Data     = $null
            Problems = @($_.Exception.Message)
        }
    }
    $script:WintilityConfigCache[$Name] = $result
    return $result
}

function Test-WintilityPresetReferences {
    [CmdletBinding()]
    param()
    $problems = New-Object System.Collections.Generic.List[string]
    $known = @{}

    foreach ($name in (Get-WintilityTweakConfigNames)) {
        $config = Get-WintilityConfig -Name $name
        if (-not $config.Success) {
            $problems.Add("Cannot verify presets because $name.json is invalid.")
            continue
        }
        foreach ($setting in @($config.Data.settings)) {
            if ($known.ContainsKey($setting.id)) {
                $problems.Add("Setting '$($setting.id)' is defined in more than one file.")
            }
            $known[$setting.id] = $true
        }
    }

    $presetConfig = Get-WintilityConfig -Name 'presets'
    if (-not $presetConfig.Success) {
        $problems.Add('Cannot verify presets because presets.json is invalid.')
    }
    else {
        foreach ($preset in @($presetConfig.Data.presets)) {
            foreach ($id in @($preset.settings)) {
                if (-not $known.ContainsKey($id)) {
                    $problems.Add("Preset '$($preset.name)' references unknown setting '$id'.")
                }
            }
        }
    }
    return $problems.ToArray()
}

function Get-WintilityTweakConfigNames {
    [CmdletBinding()]
    param()
    return @('personalization', 'performance', 'privacy', 'ads', 'internet', 'storage', 'debloat')
}

function Get-WintilityConfigNames {
    [CmdletBinding()]
    param()
    return @((Get-WintilityTweakConfigNames) + 'presets')
}

function Get-WintilityRegistryEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Setting)
    # A setting's "registry" can be one object or a list of them. Always hand back a list.
    $registry = Get-WintilityProperty -Object $Setting -Name 'registry'
    if ($null -eq $registry) { return @() }
    return @($registry)
}

function Test-WintilityValueMatchesType {
    [CmdletBinding()]
    param($Value, [string]$Type)
    if ($Type -eq 'String') { return ($Value -is [string]) }
    if ($Type -eq 'DWord' -or $Type -eq 'QWord') { return (($Value -is [int]) -or ($Value -is [long])) }
    return $false
}
