# Wintility's own preferences: app theme, background image, glass effect and animations.
# These are not system changes, so they are not backed up.

function Get-WintilityAppSettingsPath {
    [CmdletBinding()]
    param()
    return (Join-Path $env:LOCALAPPDATA 'Wintility\settings.json')
}

function Get-WintilityAppSettings {
    [CmdletBinding()]
    param()
    $defaults = [PSCustomObject]@{ AppTheme = 'System'; ShowBackground = $false; Glass = $false; Animations = $true; WindowWidth = 1320.0; WindowHeight = 720.0 }
    $path = Get-WintilityAppSettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return $defaults }
    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $theme = Get-WintilityProperty -Object $data -Name 'AppTheme'
        if ($theme -notin @('System', 'Light', 'Dark')) { $theme = 'System' }
        $background = Get-WintilityProperty -Object $data -Name 'ShowBackground'
        $glass = Get-WintilityProperty -Object $data -Name 'Glass'
        $animations = Get-WintilityProperty -Object $data -Name 'Animations'
        $windowWidth = Get-WintilityProperty -Object $data -Name 'WindowWidth'
        $windowHeight = Get-WintilityProperty -Object $data -Name 'WindowHeight'
        if (-not ($windowWidth -is [ValueType]) -or [double]$windowWidth -lt 800 -or [double]$windowWidth -gt 10000) { $windowWidth = 1320.0 }
        if (-not ($windowHeight -is [ValueType]) -or [double]$windowHeight -lt 480 -or [double]$windowHeight -gt 10000) { $windowHeight = 720.0 }
        return [PSCustomObject]@{
            AppTheme       = $theme
            ShowBackground = ($background -eq $true)
            Glass          = ($glass -eq $true)
            Animations     = ($animations -ne $false)
            WindowWidth    = [double]$windowWidth
            WindowHeight   = [double]$windowHeight
        }
    }
    catch {
        return $defaults
    }
}

function Set-WintilityAppSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('System', 'Light', 'Dark')][string]$AppTheme,
        [Parameter(Mandatory)][bool]$ShowBackground,
        [Parameter(Mandatory)][bool]$Glass,
        [Parameter(Mandatory)][bool]$Animations,
        [double]$WindowWidth = 1320,
        [double]$WindowHeight = 720
    )
    $path = Get-WintilityAppSettingsPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [PSCustomObject]@{ AppTheme = $AppTheme; ShowBackground = $ShowBackground; Glass = $Glass; Animations = $Animations; WindowWidth = $WindowWidth; WindowHeight = $WindowHeight } |
        ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}
