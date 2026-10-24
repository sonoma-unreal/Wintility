# Settings engine. Applies the registry settings described in config/.
# A setting can change several registry values at once. Every change is backed up first,
# read back afterwards, and rolled back if any value fails, so a tweak is all-or-nothing.
# Tweaks that need administrator access are skipped here and hidden by the interface.
# Tweaks that change the taskbar, desktop or File Explorer refresh the desktop live afterwards.
Set-StrictMode -Version Latest

Import-Module -Name (Join-Path $PSScriptRoot '..\core\Wintility.Core.psm1')
Import-Module -Name (Join-Path $PSScriptRoot 'Wintility.Shell.psm1')
Set-WintilityRoot -Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

function Find-WintilitySetting {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    foreach ($name in (Get-WintilityTweakConfigNames)) {
        $config = Get-WintilityConfig -Name $name
        if (-not $config.Success) { continue }
        foreach ($setting in @($config.Data.settings)) {
            if ($setting.id -eq $Id) { return $setting }
        }
    }
    return $null
}

function Test-WintilitySettingApplied {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Setting)
    foreach ($entry in (Get-WintilityRegistryEntries -Setting $Setting)) {
        $current = Get-WintilityRegistryValue -Path $entry.path -Name $entry.name
        if (-not $current.Exists -or $current.Value -ne $entry.appliedValue) { return $false }
    }
    return $true
}

function Test-WintilityNeedsShellRefresh {
    [CmdletBinding()]
    param($Setting)
    return ((Get-WintilityProperty -Object $Setting -Name 'requiresExplorerRestart') -eq $true)
}

function Invoke-WintilitySetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [switch]$Preview
    )

    $setting = Find-WintilitySetting -Id $Id
    if ($null -eq $setting) {
        return New-WintilityResult -Id $Id -Success $false -Message 'Unknown setting.' -ErrorDetail "No setting with id '$Id' exists in config."
    }

    $name = $setting.name
    $needsRestart = [bool]$setting.requiresRestart
    $needsLogoff = [bool]$setting.requiresLogoff

    if ([bool]$setting.requiresAdmin -and -not (Test-WintilityAdmin)) {
        return New-WintilityResult -Id $Id -Name $name -Skipped $true -RequiresAdmin $true -Message 'Requires administrator. Skipped because this session is not elevated.'
    }

    $entries = @(Get-WintilityRegistryEntries -Setting $setting)

    if (Test-WintilitySettingApplied -Setting $setting) {
        return New-WintilityResult -Id $Id -Name $name -Changed $false -Message 'Already set. No change needed.' -RequiresRestart $needsRestart -RequiresLogoff $needsLogoff
    }

    if ($Preview) {
        $changes = foreach ($entry in $entries) {
            $current = Get-WintilityRegistryValue -Path $entry.path -Name $entry.name
            $now = 'not set'
            if ($current.Exists) { $now = "$($current.Value)" }
            "$($entry.name) from $now to $($entry.appliedValue)"
        }
        return New-WintilityResult -Id $Id -Name $name -Skipped $true -Message ("Preview only. Would set " + ($changes -join '; ') + '.')
    }

    return Invoke-WintilityOperation -Id $Id -Module 'Settings' -Action {
        $targets = @(foreach ($entry in $entries) { @{ Path = $entry.path; Name = $entry.name } })
        $backupFile = New-WintilityBackup -Label $Id -Targets $targets
        try {
            foreach ($entry in $entries) {
                Set-WintilityRegistryValue -Path $entry.path -Name $entry.name -Kind $entry.type -Value $entry.appliedValue
            }
            foreach ($entry in $entries) {
                $after = Get-WintilityRegistryValue -Path $entry.path -Name $entry.name
                if (-not $after.Exists -or $after.Value -ne $entry.appliedValue) {
                    throw "$($entry.name) did not read back as $($entry.appliedValue) after writing."
                }
            }
        }
        catch {
            $reason = $_.Exception.Message
            $suffix = ' The change could not be rolled back automatically.'
            try {
                $rollback = Restore-WintilityBackup -BackupFile $backupFile
                if ($rollback.Failed -eq 0) { $suffix = ' The partial change was rolled back.' }
            }
            catch {
                Write-WintilityLog -Severity ERROR -Module 'Settings' -Message "Rollback for $Id failed. $($_.Exception.Message)"
            }
            throw ($reason + $suffix)
        }

        New-WintilityResult -Id $Id -Name $name -Changed $true -Message "Applied $($entries.Count) value(s). Backup: $backupFile" -RequiresRestart $needsRestart -RequiresLogoff $needsLogoff
    }
}

function Restore-WintilitySetting {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)

    $file = Get-WintilityLatestBackup -Label $Id
    if ($file) {
        return (Invoke-WintilityOperation -Id $Id -Module 'Settings' -Action {
            $summary = Restore-WintilityBackup -BackupFile $file
            if ($summary.Failed -gt 0) {
                throw "Some values could not be put back ($($summary.Headline))."
            }
            New-WintilityResult -Id $Id -Changed $true -Message "Reverted to the value from before. $($summary.Headline)"
        })
    }

    # No backup means Wintility never changed this setting, so it was already on. Use the Windows
    # default from config when every value has one, so the switch can still be turned off.
    $setting = Find-WintilitySetting -Id $Id
    $entries = @()
    if ($null -ne $setting) { $entries = @(Get-WintilityRegistryEntries -Setting $setting) }
    $unknown = @($entries | Where-Object {
        -not (Test-WintilityHasProperty -Object $_ -Name 'defaultValue') -and -not ((Get-WintilityProperty -Object $_ -Name 'removeOnRevert') -eq $true)
    })
    if ($entries.Count -eq 0 -or $unknown.Count -gt 0) {
        return New-WintilityResult -Id $Id -Skipped $true -Message 'Nothing to revert. No backup exists and Windows has no known default for this setting.'
    }

    return (Invoke-WintilityOperation -Id $Id -Module 'Settings' -Action {
        foreach ($entry in $entries) {
            if ((Get-WintilityProperty -Object $entry -Name 'removeOnRevert') -eq $true) {
                Remove-WintilityRegistryValue -Path $entry.path -Name $entry.name
            }
            else {
                Set-WintilityRegistryValue -Path $entry.path -Name $entry.name -Kind $entry.type -Value $entry.defaultValue
            }
        }
        foreach ($entry in $entries) {
            $after = Get-WintilityRegistryValue -Path $entry.path -Name $entry.name
            if ((Get-WintilityProperty -Object $entry -Name 'removeOnRevert') -eq $true) {
                if ($after.Exists) { throw "$($entry.name) could not be removed." }
            }
            elseif (-not $after.Exists -or $after.Value -ne $entry.defaultValue) {
                throw "$($entry.name) did not read back as $($entry.defaultValue) after writing."
            }
        }
        New-WintilityResult -Id $Id -Changed $true -Message 'Reset to the Windows default.'
    })
}

function Invoke-WintilityPreset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Preview
    )
    $presets = Get-WintilityConfig -Name 'presets'
    if (-not $presets.Success) { throw 'presets.json is invalid. Run Wintility.ps1 -CheckOnly for details.' }

    $preset = @($presets.Data.presets) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($null -eq $preset) { throw "No preset named '$Name'." }

    # Each setting runs immediately and in order. Invoke-WintilitySetting already isolates failures.
    $results = foreach ($id in @($preset.settings)) {
        Invoke-WintilitySetting -Id $id -Preview:$Preview
    }
    # Tweaks that change the shell are refreshed once at the end, not after every single one.
    $needsRefresh = $false
    foreach ($result in @($results)) {
        if ($result.Changed -and (Test-WintilityNeedsShellRefresh -Setting (Find-WintilitySetting -Id $result.Id))) { $needsRefresh = $true }
    }
    if ($needsRefresh) { [void](Invoke-WintilityShellRefresh) }
    return (New-WintilityBatchSummary -Results @($results))
}
