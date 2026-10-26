#requires -Version 5.1
# Smoke test. Read-only: no registry writes, no power changes, no file writes outside the log folder.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The icon dictionary check uses WPF's XamlReader; load it here so the README's
# direct test command works in a fresh Windows PowerShell process.
Add-Type -AssemblyName PresentationFramework

$root = Split-Path -Parent $PSScriptRoot
Import-Module -Name (Join-Path $root 'core\Wintility.Core.psm1') -Force
Set-WintilityRoot -Path $root

$script:Failures = 0
function Assert-Check {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        $script:Failures++
    }
}

Write-Host '================================'
Write-Host 'WINTILITY SMOKE TEST'
Write-Host '================================'

Assert-Check 'Version defined' (((Get-WintilityVersion).Version -eq '5.2') -and ((Get-WintilityVersion).Edition -eq 'Fall Update'))

$tabCounts = @{}
foreach ($name in (Get-WintilityConfigNames)) {
    $config = Get-WintilityConfig -Name $name
    Assert-Check "Config parses and validates: $name" $config.Success
    if ($config.Success -and $name -ne 'presets') {
        foreach ($setting in @($config.Data.settings)) { $tabCounts[$setting.tab] = 1 + [int]$tabCounts[$setting.tab] }
    }
}
foreach ($tab in @('Performance', 'Ads', 'Privacy', 'Internet', 'Storage', 'Debloat')) {
    Assert-Check "Tab has settings: $tab" ($tabCounts.ContainsKey($tab))
}
# A registry setting may be one value or a list of values. Both forms must come back as a list.
$oneValue = [PSCustomObject]@{ registry = [PSCustomObject]@{ path = 'HKCU:\Software\X'; name = 'A' } }
$twoValues = [PSCustomObject]@{ registry = @([PSCustomObject]@{ path = 'HKCU:\Software\X'; name = 'A' }, [PSCustomObject]@{ path = 'HKCU:\Software\X'; name = 'B' }) }
Assert-Check 'Registry entries: one value and a list both work' ((@(Get-WintilityRegistryEntries -Setting $oneValue).Count -eq 1) -and (@(Get-WintilityRegistryEntries -Setting $twoValues).Count -eq 2))

# The validator must refuse a tweak that changes HKLM without being marked admin-only,
# because a standard session would be shown a switch that can never work.
$badTweak = [PSCustomObject]@{ schemaVersion = 1; settings = @([PSCustomObject]@{
    id = 'BadTweak'; name = 'x'; description = 'x'; category = 'x'; tab = 'Performance'; risk = 'Low'; action = 'registry'
    requiresAdmin = $false; requiresRestart = $false; requiresLogoff = $false; reversible = $true; enabledByDefault = $false
    registry = [PSCustomObject]@{ path = 'HKLM:\SOFTWARE\Test'; name = 'V'; type = 'DWord'; appliedValue = 1 } }) }
$badProblems = @(Test-WintilityConfigData -Name 'performance' -Data $badTweak)
Assert-Check 'Validator rejects an HKLM tweak that is not admin-only' (@($badProblems | Where-Object { $_ -like '*requiresAdmin*' }).Count -gt 0)

Assert-Check 'Preset references resolve' (@(Test-WintilityPresetReferences).Count -eq 0)

$result = New-WintilityResult -Id 'Example' -Changed $true -Message 'ok'
Assert-Check 'Result object has standard fields' (
    ($result.PSObject.Properties.Name -contains 'Success') -and
    ($result.PSObject.Properties.Name -contains 'Skipped') -and
    ($result.PSObject.Properties.Name -contains 'RequiresRestart')
)

$batch = Invoke-WintilityBatch -Module 'SmokeTest' -Operations @(
    @{ Id = 'OkOne';  Action = { New-WintilityResult -Id 'OkOne' -Changed $true -Message 'done' } },
    @{ Id = 'Boom';   Action = { throw 'simulated failure' } },
    @{ Id = 'OkTwo';  Action = { New-WintilityResult -Id 'OkTwo' -Changed $true -Message 'done' } }
)
Assert-Check 'One failure does not stop the batch (2 applied, 1 failed)' (($batch.Applied -eq 2) -and ($batch.Failed -eq 1))

$noResult = Invoke-WintilityOperation -Id 'NoResult' -Module 'SmokeTest' -Action { 'just a string' }
Assert-Check 'Operation without a result object is reported as failed' (-not $noResult.Success)

$guarded = $false
try { Get-WintilityRegistryValue -Path 'HKU:\Software\Nope' -Name 'x' | Out-Null } catch { $guarded = $true }
Assert-Check 'Registry guard rejects paths outside HKCU/HKLM' $guarded

Import-Module -Name (Join-Path $root 'commands\Wintility.SystemInfo.psm1')
Import-Module -Name (Join-Path $root 'commands\Wintility.Shell.psm1')
Import-Module -Name (Join-Path $root 'commands\Wintility.Power.psm1')
$systemInfo = Get-WintilitySystemInfo
Assert-Check 'System information reads (PC name)' (-not [string]::IsNullOrWhiteSpace($systemInfo.ComputerName))
Assert-Check 'Byte formatter works' ((Format-WintilityBytes -Bytes 1GB) -match '^1[.,]0 GB$')
$appSettings = Get-WintilityAppSettings
Assert-Check 'App settings have Glass and Animations' (($appSettings.PSObject.Properties.Name -contains 'Glass') -and ($appSettings.PSObject.Properties.Name -contains 'Animations'))

# PowerShell's own parser reads every script. This is a real syntax check, not a guess.
$parseErrors = @()
foreach ($script in @(Get-ChildItem -Path $root -Include '*.ps1', '*.psm1' -Recurse)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) { $parseErrors += ('{0}:{1}: {2}' -f $script.Name, $parseError.Extent.StartLineNumber, $parseError.Message) }
}
Assert-Check 'Every PowerShell file parses' ($parseErrors.Count -eq 0)
foreach ($line in $parseErrors) { Write-Host "       $line" -ForegroundColor Yellow }

# Power plan parsing. powercfg prints one plan per line, and the words around the GUID change with the language.
$sample = @(
    '',
    'Existing Power Schemes (* Active)',
    '-----------------------------------',
    'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced) *',
    '',
    'Power Scheme GUID: a1841308-3541-4fab-bc81-f71556f20b4a  (Power saver)',
    'Power Scheme GUID: 11111111-2222-3333-4444-555555555555  (Ultimate Performance)'
)
$schemes = @(ConvertFrom-WintilityPowerCfgList -Lines $sample)
Assert-Check 'powercfg list parses three plans with one active' (($schemes.Count -eq 3) -and (@($schemes | Where-Object { $_.Active }).Count -eq 1) -and ($schemes[0].Name -eq 'Balanced'))
$state = Resolve-WintilityPowerState -Schemes $schemes
Assert-Check 'Power state: Balanced is active, Ultimate is found by name' (($state.Mode -eq 'Balanced') -and $state.HasUltimate -and $state.HasMaximumSavings -and (-not $state.HasHighPerformance))
$ultimateActive = @($schemes | ForEach-Object { [PSCustomObject]@{ Guid = $_.Guid; Name = $_.Name; Active = ($_.Name -match 'Ultimate') } })
Assert-Check 'Power state: Ultimate is recognized when it is the active plan' ((Resolve-WintilityPowerState -Schemes $ultimateActive).Mode -eq 'Ultimate')
Assert-Check 'Power state: no plans reads as unavailable, not as an error' (-not (Resolve-WintilityPowerState -Schemes @()).Available)
Assert-Check 'Power state reads on this PC without an error (read-only)' ($null -ne (Get-WintilityPowerState))

# Icons: the dictionary must load, and every icon the window and the code ask for must exist in it.
$iconProblem = $null
try {
    [xml]$iconXml = Get-Content -LiteralPath (Join-Path $root 'assets\icons\lucide.xaml') -Raw -Encoding UTF8
    $iconDictionary = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader -ArgumentList $iconXml))
    $wanted = @{}
    foreach ($file in @('ui\MainWindow.xaml', 'ui\Wintility.UI.psm1')) {
        $text = Get-Content -LiteralPath (Join-Path $root $file) -Raw -Encoding UTF8
        foreach ($match in [regex]::Matches($text, '(?<![A-Za-z$])Icon\.([A-Za-z]+)')) { $wanted[$match.Groups[1].Value] = $true }
        foreach ($match in [regex]::Matches($text, "-Icon '([A-Za-z]+)'")) { $wanted[$match.Groups[1].Value] = $true }
    }
    foreach ($configFile in @(Get-ChildItem -LiteralPath (Join-Path $root 'config') -Filter '*.json')) {
        foreach ($match in [regex]::Matches((Get-Content -LiteralPath $configFile.FullName -Raw -Encoding UTF8), '"icon"\s*:\s*"([A-Za-z0-9]+)"')) { $wanted[$match.Groups[1].Value] = $true }
    }
    $missingIcons = @($wanted.Keys | Where-Object { -not $iconDictionary.Contains("Icon.$_") })
    if ($missingIcons.Count -gt 0) { $iconProblem = 'Missing icons: ' + ($missingIcons -join ', ') }
}
catch {
    $iconProblem = $_.Exception.Message
}
Assert-Check 'Icons load and every icon in use exists' ($null -eq $iconProblem)
if ($iconProblem) { Write-Host "       $iconProblem" -ForegroundColor Yellow }

$shellCommands = @('Update-WintilityShell', 'Start-WintilityShellRefresh', 'Receive-WintilityShellRefresh', 'Invoke-WintilityShellRefresh')
$missingShell = @($shellCommands | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
Assert-Check 'Shell refresh commands exist (not run: they would refresh your desktop)' ($missingShell.Count -eq 0)

# Every command a module exports must use an approved verb. This is the check
# behind PowerShell's "unapproved verbs" import warning.
$approved = @((Get-Verb).Verb)
$badNames = @()
$modulePaths = @(
    'core\Wintility.Core.psm1',
    'commands\Wintility.Settings.psm1',
    'commands\Wintility.Personalization.psm1',
    'commands\Wintility.SystemInfo.psm1',
    'commands\Wintility.Shell.psm1',
    'commands\Wintility.Power.psm1',
    'ui\Wintility.UI.psm1'
)
foreach ($relative in $modulePaths) {
    $module = Import-Module -Name (Join-Path $root $relative) -PassThru
    foreach ($command in $module.ExportedCommands.Values) {
        $verb = ($command.Name -split '-')[0]
        if ($approved -notcontains $verb) { $badNames += $command.Name }
    }
}
Assert-Check 'All exported commands use approved verbs' ($badNames.Count -eq 0)
if ($badNames.Count -gt 0) { Write-Host ('       Unapproved: ' + ($badNames -join ', ')) -ForegroundColor Yellow }

# Load the real window definitions. This is the check that catches XAML the parser rejects.
# XAML needs an STA thread, which Windows PowerShell 5.1 has by default.
Add-Type -AssemblyName PresentationFramework
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA) {
    foreach ($file in @('MainWindow.xaml', 'SplashWindow.xaml')) {
        $loaded = $false
        try {
            [xml]$xaml = Get-Content -LiteralPath (Join-Path $root "ui\$file") -Raw -Encoding UTF8
            $reader = New-Object System.Xml.XmlNodeReader -ArgumentList $xaml
            [void][System.Windows.Markup.XamlReader]::Load($reader)
            $loaded = $true
        }
        catch {
            Write-Host "       $($_.Exception.Message)" -ForegroundColor Yellow
        }
        Assert-Check "Window XAML loads: $file" $loaded
    }
}
else {
    Write-Host '[SKIP] Window XAML loads (needs an STA session; use Windows PowerShell 5.1)' -ForegroundColor Yellow
}

$wallpaperCommands = @('Copy-WintilityTranscodedWallpaper', 'Backup-WintilityTranscodedWallpaper', 'Restore-WintilityTranscodedWallpaper', 'Set-WintilityWallpaper', 'Restore-WintilityWallpaper')
$missingWallpaper = @($wallpaperCommands | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
Assert-Check 'Wallpaper commands exist' ($missingWallpaper.Count -eq 0)

$restartCommand = Get-Command -Name 'Restart-WintilityExplorer' -ErrorAction SilentlyContinue
Assert-Check 'Restart-WintilityExplorer exists (not run: it would close Explorer windows)' ($null -ne $restartCommand)

Write-Host ''
if ($script:Failures -eq 0) {
    Write-Host 'RESULT: PASS' -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: FAIL ($($script:Failures) check(s))" -ForegroundColor Red
exit 1
