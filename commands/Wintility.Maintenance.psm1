# User startup entries and Windows memory/storage maintenance helpers.
Set-StrictMode -Version Latest

function Get-WintilityStartupStatePath {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is not available.' }
    return (Join-Path $env:LOCALAPPDATA 'Wintility\startup-apps.json')
}

function Get-WintilityStartupAppsDisabled {
    return (Test-Path -LiteralPath (Get-WintilityStartupStatePath) -PathType Leaf)
}

function Get-WintilityStartupRegistryEntries {
    foreach ($subKey in @('Software\Microsoft\Windows\CurrentVersion\Run', 'Software\Microsoft\Windows\CurrentVersion\RunOnce')) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subKey, $false)
        if ($null -eq $key) { continue }
        try {
            foreach ($name in $key.GetValueNames()) {
                $kind = $key.GetValueKind($name)
                if ($kind -notin @([Microsoft.Win32.RegistryValueKind]::String, [Microsoft.Win32.RegistryValueKind]::ExpandString)) { continue }
                [PSCustomObject]@{
                    SubKey = $subKey
                    Name = $name
                    Value = [string]$key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    Kind = [string]$kind
                }
            }
        }
        finally { $key.Dispose() }
    }
}

function Set-WintilityStartupAppsDisabled {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Disabled)

    $statePath = Get-WintilityStartupStatePath
    $stateDirectory = Split-Path -Parent $statePath
    $backupRoot = Join-Path $stateDirectory 'StartupAppBackup'

    if (-not $Disabled) {
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            return [PSCustomObject]@{ Changed = $false; Message = 'No Wintility startup-app backup was found.' }
        }
        $manifest = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $pendingRegistry = New-Object System.Collections.Generic.List[object]
        $pendingFiles = New-Object System.Collections.Generic.List[object]
        $warnings = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($manifest.RegistryEntries)) {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey([string]$item.SubKey)
            try {
                if ($key.GetValueNames() -contains [string]$item.Name) {
                    $pendingRegistry.Add($item)
                    $warnings.Add("Kept the current startup entry '$($item.Name)'; the saved version remains backed up.")
                }
                else { $key.SetValue([string]$item.Name, [string]$item.Value, [Microsoft.Win32.RegistryValueKind]([string]$item.Kind)) }
            }
            finally { $key.Dispose() }
        }
        foreach ($item in @($manifest.StartupFiles)) {
            if (-not (Test-Path -LiteralPath ([string]$item.BackupPath) -PathType Leaf)) { continue }
            $parent = Split-Path -Parent ([string]$item.OriginalPath)
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            if (Test-Path -LiteralPath ([string]$item.OriginalPath)) {
                $pendingFiles.Add($item)
                $warnings.Add("Kept the current startup file '$([IO.Path]::GetFileName([string]$item.OriginalPath))'; the saved copy remains backed up.")
                continue
            }
            Move-Item -LiteralPath ([string]$item.BackupPath) -Destination ([string]$item.OriginalPath)
        }
        if ($pendingRegistry.Count -gt 0 -or $pendingFiles.Count -gt 0) {
            $manifest.RegistryEntries = @($pendingRegistry.ToArray())
            $manifest.StartupFiles = @($pendingFiles.ToArray())
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8
        }
        else {
            Remove-Item -LiteralPath $statePath -Force
            if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force }
        }
        $message = 'Restored classic startup entries for this account.'
        if ($warnings.Count -gt 0) { $message += ' ' + ($warnings -join ' ') }
        return [PSCustomObject]@{ Changed = $true; Message = $message }
    }

    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        return [PSCustomObject]@{ Changed = $false; Message = 'Wintility already disabled classic startup entries for this account.' }
    }

    $startupFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $files = @()
    if ($startupFolder -and (Test-Path -LiteralPath $startupFolder)) { $files = @(Get-ChildItem -LiteralPath $startupFolder -File -ErrorAction Stop) }
    $registryEntries = @(Get-WintilityStartupRegistryEntries)
    if ($registryEntries.Count -eq 0 -and $files.Count -eq 0) {
        return [PSCustomObject]@{ Changed = $false; Message = 'No classic startup entries were found for this account.' }
    }

    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $manifest = [PSCustomObject]@{ Version = 1; RegistryEntries = @($registryEntries); StartupFiles = @() }
    $fileBackups = New-Object System.Collections.Generic.List[object]
    try {
        $counter = 0
        foreach ($file in $files) {
            $counter++
            $backupPath = Join-Path $backupRoot ('{0:D3}-{1}' -f $counter, $file.Name)
            Copy-Item -LiteralPath $file.FullName -Destination $backupPath -ErrorAction Stop
            $fileBackups.Add([PSCustomObject]@{ OriginalPath = $file.FullName; BackupPath = $backupPath })
        }
        $manifest.StartupFiles = @($fileBackups.ToArray())
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8
        foreach ($item in $registryEntries) {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey([string]$item.SubKey, $true)
            if ($null -eq $key) { throw "Could not open startup registry key '$($item.SubKey)'." }
            try { $key.DeleteValue([string]$item.Name, $false) }
            finally { $key.Dispose() }
        }
        foreach ($file in $files) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop }
        return [PSCustomObject]@{ Changed = $true; Message = "Disabled $($registryEntries.Count + $files.Count) classic startup item(s) for this account. They will not launch at the next sign-in; running apps were left open." }
    }
    catch {
        $reason = $_.Exception.Message
        foreach ($item in $registryEntries) {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey([string]$item.SubKey)
            try { $key.SetValue([string]$item.Name, [string]$item.Value, [Microsoft.Win32.RegistryValueKind]([string]$item.Kind)) }
            finally { $key.Dispose() }
        }
        foreach ($item in $fileBackups) {
            if ((Test-Path -LiteralPath $item.BackupPath) -and -not (Test-Path -LiteralPath $item.OriginalPath)) {
                Move-Item -LiteralPath $item.BackupPath -Destination $item.OriginalPath -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue }
        throw "Startup apps were not disabled. The attempted changes were rolled back. $reason"
    }
}

function Get-WintilityMemoryCompressionState {
    return [bool](Get-MMAgent -ErrorAction Stop).MemoryCompression
}

function Set-WintilityMemoryCompression {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Enabled)
    if ($Enabled) { Enable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null }
    else { Disable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null }
    $message = if ($Enabled) { 'Memory compression enabled. It can reduce memory pressure, with some CPU cost.' } else { 'Memory compression disabled. This may reduce compression work but can increase memory pressure and paging.' }
    return [PSCustomObject]@{ Changed = $true; Enabled = $Enabled; Message = $message }
}

function Open-WintilityDriveOptimizer {
    Start-Process -FilePath "$env:WINDIR\System32\dfrgui.exe" -ErrorAction Stop
}

Export-ModuleMember -Function Get-WintilityStartupAppsDisabled, Set-WintilityStartupAppsDisabled, Get-WintilityMemoryCompressionState, Set-WintilityMemoryCompression, Open-WintilityDriveOptimizer
