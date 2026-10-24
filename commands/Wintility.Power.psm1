# Power plans. Reads and switches the active Windows power plan with powercfg.
# Switching to a plan that already exists works for a standard user. Creating a plan that is
# missing (High Performance or Ultimate Performance on some PCs) needs administrator access.
Set-StrictMode -Version Latest

Import-Module -Name (Join-Path $PSScriptRoot '..\core\Wintility.Core.psm1')

# Windows' built-in plan identities. These are the same on every PC and in every language.
$script:PlanGuids = @{
    MaximumSavings  = 'a1841308-3541-4fab-bc81-f71556f20b4a'
    Balanced        = '381b4222-f694-41f0-9685-ff5bb260df2e'
    HighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    Ultimate        = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
}
$script:PlanNames = @{
    MaximumSavings  = 'Maximum Power Savings'
    Balanced        = 'Balanced'
    HighPerformance = 'High Performance'
    Ultimate        = 'Ultimate Performance'
}
$script:GuidPattern = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'

function Get-WintilityPowerMemoryPath {
    [CmdletBinding()]
    param()
    return (Join-Path $env:LOCALAPPDATA 'Wintility\power.json')
}

function Read-WintilityPowerMemory {
    [CmdletBinding()]
    param()
    # Remembers the plan the PC had before Wintility first changed it, and the Ultimate plan Wintility created.
    $memory = [PSCustomObject]@{ OriginalGuid = $null; OriginalName = $null; UltimateGuid = $null }
    $path = Get-WintilityPowerMemoryPath
    if (-not (Test-Path -LiteralPath $path)) { return $memory }
    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $memory.OriginalGuid = Get-WintilityProperty -Object $data -Name 'OriginalGuid'
        $memory.OriginalName = Get-WintilityProperty -Object $data -Name 'OriginalName'
        $memory.UltimateGuid = Get-WintilityProperty -Object $data -Name 'UltimateGuid'
    }
    catch {
        Write-WintilityLog -Severity WARN -Module 'Power' -Message "The saved power plan memory could not be read. $($_.Exception.Message)"
    }
    return $memory
}

function Save-WintilityPowerMemory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Memory)
    $path = Get-WintilityPowerMemoryPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $Memory | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}

function Invoke-WintilityPowerCfg {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& powercfg.exe @Arguments 2>&1 | ForEach-Object { "$_" })
    return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function ConvertFrom-WintilityPowerCfgList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines)
    # powercfg prints one plan per line, for example:  Power Scheme GUID: 381b4222-...  (Balanced) *
    # The words around the GUID change with the Windows language, so only the GUID, the
    # name in parentheses and the trailing * (active plan) are used.
    $schemes = New-Object System.Collections.Generic.List[object]
    foreach ($line in $Lines) {
        if ($line -match ($script:GuidPattern + '\s+\((.*)\)\s*(\*)?\s*$')) {
            $schemes.Add([PSCustomObject]@{
                Guid   = $Matches[1].ToLowerInvariant()
                Name   = $Matches[2].Trim()
                Active = $Matches.ContainsKey(3)
            })
        }
    }
    return $schemes.ToArray()
}

function Get-WintilityPowerSchemes {
    [CmdletBinding()]
    param()
    $result = Invoke-WintilityPowerCfg -Arguments @('/list')
    if ($result.ExitCode -ne 0) { throw "powercfg could not list the power plans ($($result.Output -join ' '))." }
    return @(ConvertFrom-WintilityPowerCfgList -Lines $result.Output)
}

function Resolve-WintilityPowerState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Schemes,
        [string]$UltimateGuid
    )
    $list = @($Schemes)
    $byGuid = @{}
    foreach ($scheme in $list) { $byGuid[$scheme.Guid] = $scheme }

    # Ultimate Performance is found by its standard identity, by the plan Wintility created, or by name.
    $ultimate = $null
    if ($byGuid.ContainsKey($script:PlanGuids.Ultimate)) { $ultimate = $byGuid[$script:PlanGuids.Ultimate] }
    elseif ($UltimateGuid -and $byGuid.ContainsKey($UltimateGuid)) { $ultimate = $byGuid[$UltimateGuid] }
    else { $ultimate = @($list | Where-Object { $_.Name -match 'Ultimate' }) | Select-Object -First 1 }

    $active = @($list | Where-Object { $_.Active }) | Select-Object -First 1
    $activeGuid = ''
    $activeName = ''
    $mode = 'Unknown'
    if ($null -ne $active) {
        $activeGuid = $active.Guid
        $activeName = $active.Name
        if ($activeGuid -eq $script:PlanGuids.MaximumSavings) { $mode = 'MaximumSavings' }
        elseif ($activeGuid -eq $script:PlanGuids.Balanced) { $mode = 'Balanced' }
        elseif ($activeGuid -eq $script:PlanGuids.HighPerformance) { $mode = 'HighPerformance' }
        elseif ($null -ne $ultimate -and $activeGuid -eq $ultimate.Guid) { $mode = 'Ultimate' }
        else { $mode = 'Other' }
    }

    $ultimateFound = ''
    if ($null -ne $ultimate) { $ultimateFound = $ultimate.Guid }
    return [PSCustomObject]@{
        Available           = ($list.Count -gt 0)
        Schemes             = $list
        ActiveGuid          = $activeGuid
        ActiveName          = $activeName
        Mode                = $mode
        UltimateGuid        = $ultimateFound
        HasMaximumSavings   = $byGuid.ContainsKey($script:PlanGuids.MaximumSavings)
        HasBalanced         = $byGuid.ContainsKey($script:PlanGuids.Balanced)
        HasHighPerformance  = $byGuid.ContainsKey($script:PlanGuids.HighPerformance)
        HasUltimate         = ($null -ne $ultimate)
    }
}

function Get-WintilityPowerState {
    [CmdletBinding()]
    param()
    try {
        $schemes = @(Get-WintilityPowerSchemes)
    }
    catch {
        Write-WintilityLog -Severity WARN -Module 'Power' -Message "Power plans unavailable. $($_.Exception.Message)"
        return (Resolve-WintilityPowerState -Schemes @())
    }
    $memory = Read-WintilityPowerMemory
    return (Resolve-WintilityPowerState -Schemes $schemes -UltimateGuid ([string]$memory.UltimateGuid))
}

function New-WintilityPowerScheme {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('HighPerformance', 'Ultimate')][string]$Mode)
    # Windows keeps these two plans hidden on some PCs. Duplicating the built-in plan makes it appear.
    # Giving the copy the plan's own identity keeps it recognizable in every language.
    $source = $script:PlanGuids[$Mode]
    $result = Invoke-WintilityPowerCfg -Arguments @('-duplicatescheme', $source, $source)
    if ($result.ExitCode -ne 0) { $result = Invoke-WintilityPowerCfg -Arguments @('-duplicatescheme', $source) }
    if ($result.ExitCode -ne 0) { throw "Windows could not create the plan ($($result.Output -join ' '))." }
    foreach ($line in $result.Output) {
        if ($line -match $script:GuidPattern) { return $Matches[1].ToLowerInvariant() }
    }
    return $source
}

function Set-WintilityPowerPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('MaximumSavings', 'Balanced', 'HighPerformance', 'Ultimate')][string]$Mode)

    $id = "PowerPlan$Mode"
    $label = $script:PlanNames[$Mode]

    return (Invoke-WintilityOperation -Id $id -Module 'Power' -Action {
        $state = Get-WintilityPowerState
        if (-not $state.Available) {
            throw 'Power plans could not be read on this PC, so nothing was changed.'
        }

        $target = $null
        if ($Mode -eq 'MaximumSavings' -and $state.HasMaximumSavings) { $target = $script:PlanGuids.MaximumSavings }
        elseif ($Mode -eq 'Balanced' -and $state.HasBalanced) { $target = $script:PlanGuids.Balanced }
        elseif ($Mode -eq 'HighPerformance' -and $state.HasHighPerformance) { $target = $script:PlanGuids.HighPerformance }
        elseif ($Mode -eq 'Ultimate' -and $state.HasUltimate) { $target = $state.UltimateGuid }

        if ($null -eq $target) {
            if ($Mode -ne 'HighPerformance' -and $Mode -ne 'Ultimate') {
                return (New-WintilityResult -Id $id -Name $label -Skipped $true -Message "$label is not available on this PC.")
            }
            if (-not (Test-WintilityAdmin)) {
                return (New-WintilityResult -Id $id -Name $label -Skipped $true -RequiresAdmin $true -Message "$label is not on this PC yet. Creating it needs administrator access. Restart Wintility as administrator from Settings.")
            }
            $target = New-WintilityPowerScheme -Mode $Mode
        }

        # Remember the plan the PC started with, once, so it can always be put back.
        $memory = Read-WintilityPowerMemory
        if (-not $memory.OriginalGuid -and $state.ActiveGuid) {
            $memory.OriginalGuid = $state.ActiveGuid
            $memory.OriginalName = $state.ActiveName
        }
        if ($Mode -eq 'Ultimate') { $memory.UltimateGuid = $target }
        Save-WintilityPowerMemory -Memory $memory

        if ($state.ActiveGuid -eq $target) {
            return (New-WintilityResult -Id $id -Name $label -Changed $false -Message "Already using $label.")
        }

        $set = Invoke-WintilityPowerCfg -Arguments @('/setactive', $target)
        if ($set.ExitCode -ne 0) {
            throw "Windows did not switch the plan ($($set.Output -join ' ')). A policy on this PC may control the power plan."
        }
        $after = Get-WintilityPowerState
        if ($after.ActiveGuid -ne $target) { throw 'Windows did not report the new power plan.' }

        $warning = $null
        if ($Mode -eq 'Ultimate') {
            $warning = 'Experimental: Ultimate Performance keeps the CPU at high speed. Expect more heat, fan noise and battery drain.'
        }
        New-WintilityResult -Id $id -Name $label -Changed $true -Warning $warning -Message "Power plan set to $label."
    })
}

function Restore-WintilityPowerPlan {
    [CmdletBinding()]
    param()
    $memory = Read-WintilityPowerMemory
    if (-not $memory.OriginalGuid) {
        return (New-WintilityResult -Id 'PowerPlanRestore' -Skipped $true -Message 'Wintility has not changed your power plan yet, so there is nothing to restore.')
    }
    return (Invoke-WintilityOperation -Id 'PowerPlanRestore' -Module 'Power' -Action {
        $state = Get-WintilityPowerState
        if ($state.ActiveGuid -eq $memory.OriginalGuid) {
            return (New-WintilityResult -Id 'PowerPlanRestore' -Changed $false -Message 'You are already on your original power plan.')
        }
        $stillExists = @($state.Schemes | Where-Object { $_.Guid -eq $memory.OriginalGuid }).Count -gt 0
        if (-not $stillExists) {
            return (New-WintilityResult -Id 'PowerPlanRestore' -Skipped $true -Message 'Your original power plan no longer exists on this PC.')
        }
        $set = Invoke-WintilityPowerCfg -Arguments @('/setactive', [string]$memory.OriginalGuid)
        if ($set.ExitCode -ne 0) { throw "Windows did not switch the plan ($($set.Output -join ' '))." }
        New-WintilityResult -Id 'PowerPlanRestore' -Changed $true -Message "Back on your original power plan ($($memory.OriginalName))."
    })
}
