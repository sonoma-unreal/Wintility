# WPF interface. Calls the engine and displays results. Holds no system-change logic.
# Only Show-WintilityWindow is exported. Everything else is private to this module,
# so no helper can trigger PowerShell's unapproved-verb warning.
# Imports are WITHOUT -Force so Core keeps the root and log state the launcher set.
Set-StrictMode -Version Latest

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Import-Module -Name (Join-Path $PSScriptRoot '..\core\Wintility.Core.psm1')
Import-Module -Name (Join-Path $PSScriptRoot '..\commands\Wintility.Settings.psm1')
Import-Module -Name (Join-Path $PSScriptRoot '..\commands\Wintility.Personalization.psm1')
Import-Module -Name (Join-Path $PSScriptRoot '..\commands\Wintility.SystemInfo.psm1')
Import-Module -Name (Join-Path $PSScriptRoot '..\commands\Wintility.Shell.psm1')
Import-Module -Name (Join-Path $PSScriptRoot '..\commands\Wintility.Power.psm1')
Import-Module -Name (Join-Path $PSScriptRoot '..\commands\Wintility.Network.psm1')
Import-Module -Name (Join-Path $PSScriptRoot '..\commands\Wintility.Maintenance.psm1')

$script:RootPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$script:Ui = @{}
$script:Window = $null
$script:WindowHandle = [IntPtr]::Zero
$script:Timer = $null
$script:ClockTimer = $null
$script:SpeedTimer = $null
$script:SpeedJob = $null
$script:SpeedText = 'Internet speed: not tested yet.'
$script:AppliedTheme = $null
$script:GlassOn = $false
$script:AnimationsOn = $true
$script:LastResults = @{}
$script:TweakSettings = $null
$script:PowerState = $null
$script:CustomDnsConfig = $null
$script:LastDnsProviderTag = 'Automatic'
$script:ShellTimer = $null
$script:ShellJob = $null
$script:ShellRefreshAgain = $false
$script:ToggleTimer = $null
$script:PendingToggles = @{}
$script:IsAdmin = $false
$script:RowViews = @{}
$script:PendingWallpaper = $null
$script:SelectedAccent = $null
$script:LaunchInProgress = $false
$script:TabNames = @('Personalization', 'Performance', 'Ads', 'Privacy', 'Internet', 'Storage', 'Debloat')
$script:GlassMinimumBuild = 22621

$script:LightPalette = @{
    WinBrush     = '#F3F3F3'
    CardBrush    = '#E6FFFFFF'
    TextBrush    = '#1A1A1A'
    SubBrush     = '#555555'
    DividerBrush = '#22000000'
    BoxBrush     = '#38000000'
    BtnBrush     = '#FFFFFF'
    BtnTextBrush = '#1A1A1A'
}

$script:DarkPalette = @{
    WinBrush     = '#202020'
    CardBrush    = '#E62B2B2B'
    TextBrush    = '#F0F0F0'
    SubBrush     = '#B8B8B8'
    DividerBrush = '#33FFFFFF'
    BoxBrush     = '#4DFFFFFF'
    BtnBrush     = '#3A3A3A'
    BtnTextBrush = '#F0F0F0'
}

# With the glass effect on, the window and cards become translucent so the blur shows through.
$script:GlassOverrides = @{
    Light = @{ WinBrush = '#66F3F3F3'; CardBrush = '#B3FFFFFF' }
    Dark  = @{ WinBrush = '#66202020'; CardBrush = '#B32B2B2B' }
}

$script:AccentPalette = @(
    @{ Name = 'Blue';   Rgb = '0078D7' }
    @{ Name = 'Teal';   Rgb = '008272' }
    @{ Name = 'Green';  Rgb = '107C10' }
    @{ Name = 'Orange'; Rgb = 'CA5010' }
    @{ Name = 'Red';    Rgb = 'E81123' }
    @{ Name = 'Pink';   Rgb = 'B4009E' }
    @{ Name = 'Purple'; Rgb = '5C2E91' }
    @{ Name = 'Gray';   Rgb = '767676' }
)

function Get-ClockText {
    # Always 12-hour with AM/PM, whatever the PC's regional time format is.
    return [DateTime]::Now.ToString('h:mm:ss tt', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Set-UiStatus {
    param([string]$Text)
    $script:Ui.StatusText.Text = $Text
}

function Get-ResultText {
    param([Parameter(Mandatory)]$Result)
    $text = $Result.Message
    if ($Result.Error) { $text = $Result.Error }
    if ($Result.Warning) { $text += " Note: $($Result.Warning)" }
    return $text
}

function Update-DnsAdapterList {
    try {
        $previousIndex = $null
        if ($script:Ui.DnsAdapterCombo.SelectedItem) { $previousIndex = [uint32]$script:Ui.DnsAdapterCombo.SelectedItem.InterfaceIndex }
        $adapters = @(Get-WintilityNetworkAdapters)
        $script:Ui.DnsAdapterCombo.ItemsSource = $null
        $script:Ui.DnsAdapterCombo.ItemsSource = $adapters
        $selected = $null
        if ($null -ne $previousIndex) { $selected = @($adapters | Where-Object { $_.InterfaceIndex -eq $previousIndex } | Select-Object -First 1)[0] }
        if ($null -eq $selected -and $adapters.Count -gt 0) { $selected = $adapters[0] }
        $script:Ui.DnsAdapterCombo.SelectedItem = $selected
        if ($adapters.Count -eq 0) { $script:Ui.DnsStatusText.Text = 'No connected network adapters were found.' }
        else { Update-DnsAdapterSummary }
    }
    catch {
        $script:Ui.DnsStatusText.Text = "Network adapter details are unavailable: $($_.Exception.Message)"
    }
}

function Update-DnsAdapterSummary {
    $adapter = $script:Ui.DnsAdapterCombo.SelectedItem
    if ($null -eq $adapter) { return }
    $dns = @($adapter.DnsServers)
    if ($dns.Count -gt 0) { $dnsText = $dns -join ', ' }
    else { $dnsText = 'No DNS server currently reported' }
    $script:Ui.DnsStatusText.Text = "$($adapter.InterfaceAlias)  ·  DNS: $dnsText"
}

function Show-CustomDnsDialog {
    $dialog = Read-UiXaml -FileName 'CustomDnsDialog.xaml'
    $dialog.Owner = $script:Window
    $dialog.Resources.MergedDictionaries.Add($script:Window.Resources)
    $serversBox = $dialog.FindName('CustomDnsServersBox')
    $templateBox = $dialog.FindName('CustomDnsDohTemplateBox')
    $cancelButton = $dialog.FindName('CustomDnsCancelButton')
    $saveButton = $dialog.FindName('CustomDnsSaveButton')
    if ($script:CustomDnsConfig) {
        $serversBox.Text = @($script:CustomDnsConfig.Servers) -join ', '
        $templateBox.Text = [string]$script:CustomDnsConfig.DohTemplate
    }
    $saveButton.Add_Click({
        try {
            $servers = @(ConvertTo-WintilityDnsServerList -ServerAddresses @([string]$serversBox.Text))
            $template = [string]$templateBox.Text
            if ($template -and ($template -notmatch '^https://[^\s]+$')) { throw 'The DNS-over-HTTPS template must be a valid HTTPS URL.' }
            $script:CustomDnsDialogResult = [PSCustomObject]@{ Servers = $servers; DohTemplate = $template }
            $dialog.DialogResult = $true
            $dialog.Close()
        }
        catch {
            [System.Windows.MessageBox]::Show(
                $dialog,
                $_.Exception.Message,
                'Custom DNS',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
        }
    }.GetNewClosure())
    $cancelButton.Add_Click({ $dialog.DialogResult = $false; $dialog.Close() }.GetNewClosure())
    $script:CustomDnsDialogResult = $null
    if ($dialog.ShowDialog() -and $script:CustomDnsDialogResult) { return $script:CustomDnsDialogResult }
    return $null
}

function Update-DnsPermissions {
    $allowed = [bool]$script:IsAdmin
    $script:Ui.ApplyDnsButton.IsEnabled = $allowed
    $script:Ui.ResetDnsButton.IsEnabled = $allowed
    $script:Ui.FlushDnsButton.IsEnabled = $allowed
    $script:Ui.DnsAdminNote.Visibility = if ($allowed) { 'Collapsed' } else { 'Visible' }
}

function Invoke-ApplyDnsSelection {
    $adapter = $script:Ui.DnsAdapterCombo.SelectedItem
    if ($null -eq $adapter) { throw 'Select a connected network adapter first.' }
    $providerItem = $script:Ui.DnsProviderCombo.SelectedItem
    $provider = [string]$providerItem.Tag
    if ($provider -eq 'Automatic') {
        $result = Reset-WintilityDnsProvider -InterfaceIndex ([uint32]$adapter.InterfaceIndex)
    }
    else {
        $params = @{
            InterfaceIndex = [uint32]$adapter.InterfaceIndex
            Provider = $provider
            DnsOverHttps = [bool]$script:Ui.DnsDohCheckBox.IsChecked
        }
        if ($provider -eq 'Custom') {
            if (-not $script:CustomDnsConfig) { throw 'Choose Custom DNS and enter its server addresses first.' }
            $params.ServerAddresses = @($script:CustomDnsConfig.Servers)
            $params.DohTemplate = [string]$script:CustomDnsConfig.DohTemplate
        }
        $result = Set-WintilityDnsProvider @params
    }
    Update-DnsAdapterList
    $script:Ui.DnsStatusText.Text = Get-ResultText -Result $result
    Set-UiStatus $result.Message
}

function Update-MaintenancePanel {
    $startupDisabled = Get-WintilityStartupAppsDisabled
    $script:Ui.StartupAppsToggle.IsChecked = $startupDisabled
    if ($startupDisabled) { $script:Ui.StartupAppsStatusText.Text = 'Classic startup entries are disabled and can be restored with this switch.' }
    else { $script:Ui.StartupAppsStatusText.Text = 'This affects Run/RunOnce entries and the Startup folder for this account.' }

    try {
        $compression = Get-WintilityMemoryCompressionState
        $script:Ui.MemoryCompressionBox.IsChecked = $compression
        $script:Ui.MemoryCompressionBox.IsEnabled = [bool]$script:IsAdmin
        if ($script:IsAdmin) {
            if ($compression) { $script:Ui.MemoryCompressionStatusText.Text = 'Enabled. Windows compresses some inactive memory pages when useful.' }
            else { $script:Ui.MemoryCompressionStatusText.Text = 'Disabled. Enabling it may reduce memory pressure.' }
        }
        else { $script:Ui.MemoryCompressionStatusText.Text = 'Changing this Windows setting requires administrator access.' }
    }
    catch {
        $script:Ui.MemoryCompressionBox.IsEnabled = $false
        $script:Ui.MemoryCompressionStatusText.Text = 'Memory compression controls are unavailable on this Windows installation.'
    }
}

function Invoke-UiAction {
    param([Parameter(Mandatory)][scriptblock]$Action)
    try {
        & $Action
    }
    catch {
        Write-WintilityLog -Severity ERROR -Module 'UI' -Message $_.Exception.Message
        Set-UiStatus "Something went wrong: $($_.Exception.Message)"
    }
}

function Read-UiXaml {
    param([Parameter(Mandatory)][string]$FileName)
    [xml]$xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot $FileName) -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader -ArgumentList $xaml
    return [System.Windows.Markup.XamlReader]::Load($reader)
}

function Get-UiControlMap {
    param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][string[]]$Names)
    $map = @{}
    foreach ($name in $Names) {
        $control = $Root.FindName($name)
        if ($null -eq $control) { throw "Interface is missing the control '$name'." }
        $map[$name] = $control
    }
    return $map
}

function New-UiBrush {
    param([Parameter(Mandatory)][string]$Hex)
    $converter = New-Object System.Windows.Media.BrushConverter
    return $converter.ConvertFromString($Hex)
}

function New-UiText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateSet('TextBrush', 'SubBrush')][string]$Role = 'TextBrush',
        [bool]$Bold = $false
    )
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.TextWrapping = 'Wrap'
    $block.Margin = '0,3,0,0'
    if ($Bold) { $block.FontWeight = 'SemiBold' }
    $block.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $Role)
    return $block
}

function Initialize-GlassNative {
    if (-not ('WintilityGlass' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WintilityGlass
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Margins
    {
        public int Left;
        public int Right;
        public int Top;
        public int Bottom;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    // DWMWA_SYSTEMBACKDROP_TYPE (38): 1 = none, 3 = acrylic (blurs what is behind the window). Windows 11 22H2+.
    public static int SetBackdrop(IntPtr hwnd, int type)
    {
        int value = type;
        return DwmSetWindowAttribute(hwnd, 38, ref value, 4);
    }

    // DWMWA_USE_IMMERSIVE_DARK_MODE (20): tints the backdrop dark or light.
    public static int SetDarkMode(IntPtr hwnd, bool dark)
    {
        int value = dark ? 1 : 0;
        return DwmSetWindowAttribute(hwnd, 20, ref value, 4);
    }
}
'@
    }
}

function Set-UiFont {
    param([Parameter(Mandatory)]$Window)
    $fontDirectory = Join-Path $script:RootPath 'assets\fonts'
    if (-not (Test-Path -LiteralPath $fontDirectory -PathType Container)) { return }
    $fontBaseUri = New-Object System.Uri -ArgumentList ((Resolve-Path -LiteralPath $fontDirectory).Path + '\')
    $Window.FontFamily = New-Object System.Windows.Media.FontFamily -ArgumentList $fontBaseUri, '#SF Pro Display'
}

function Set-WindowPalette {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][ValidateSet('Light', 'Dark')][string]$Theme,
        [bool]$Glass = $false
    )
    $palette = $script:LightPalette
    if ($Theme -eq 'Dark') { $palette = $script:DarkPalette }
    $values = @{}
    foreach ($key in $palette.Keys) { $values[$key] = $palette[$key] }
    if ($Glass) {
        $overrides = $script:GlassOverrides[$Theme]
        foreach ($key in $overrides.Keys) { $values[$key] = $overrides[$key] }
    }
    foreach ($key in $values.Keys) {
        $Window.Resources[$key] = New-UiBrush -Hex $values[$key]
    }
}

function Set-UiTheme {
    param([Parameter(Mandatory)][ValidateSet('Light', 'Dark')][string]$Theme)
    Set-WindowPalette -Window $script:Window -Theme $Theme -Glass $script:GlassOn
    $script:AppliedTheme = $Theme
    if ($script:GlassOn) { [void][WintilityGlass]::SetDarkMode($script:WindowHandle, ($Theme -eq 'Dark')) }
}

function Set-WindowGlass {
    param([Parameter(Mandatory)][bool]$Enable)
    $chrome = [System.Windows.Shell.WindowChrome]::GetWindowChrome($script:Window)
    $source = [System.Windows.Interop.HwndSource]::FromHwnd($script:WindowHandle)
    if ($Enable) {
        Initialize-GlassNative
        # The frame is extended over the whole window and WPF stops painting an opaque background,
        # so the Windows backdrop shows through the translucent brushes.
        $source.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
        $chrome.GlassFrameThickness = New-Object System.Windows.Thickness -ArgumentList ([double]-1)
        [void][WintilityGlass]::SetDarkMode($script:WindowHandle, ($script:AppliedTheme -eq 'Dark'))
        $code = [WintilityGlass]::SetBackdrop($script:WindowHandle, 3)
        if ($code -ne 0) {
            $chrome.GlassFrameThickness = New-Object System.Windows.Thickness -ArgumentList ([double]0)
            $script:GlassOn = $false
            $script:Ui.GlassBox.IsChecked = $false
            Set-UiTheme -Theme $script:AppliedTheme
            Set-UiStatus "Windows could not apply the glass effect (code $code). It needs Windows 11."
            return
        }
        $script:GlassOn = $true
    }
    else {
        if ($script:GlassOn) { [void][WintilityGlass]::SetBackdrop($script:WindowHandle, 1) }
        $chrome.GlassFrameThickness = New-Object System.Windows.Thickness -ArgumentList ([double]0)
        $script:GlassOn = $false
    }
    Set-UiTheme -Theme $script:AppliedTheme
}

function Update-AnimationFlag {
    $script:AnimationsOn = ([bool]$script:Ui.AnimationsBox.IsChecked -and [System.Windows.SystemParameters]::ClientAreaAnimation)
}

function Start-FadeIn {
    param([Parameter(Mandatory)]$Element, [int]$Milliseconds = 180)
    $Element.Opacity = 1.0
    if (-not $script:AnimationsOn) { return }
    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.From = 0.0
    $animation.To = 1.0
    $animation.Duration = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds($Milliseconds))
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $animation)
}

function Get-EffectiveTheme {
    $settings = Get-WintilityAppSettings
    if ($settings.AppTheme -eq 'System') { return (Get-WintilitySystemTheme) }
    return $settings.AppTheme
}

function Sync-ThemeWithSystem {
    $settings = Get-WintilityAppSettings
    if ($settings.AppTheme -ne 'System') { return }
    $theme = Get-WintilitySystemTheme
    if ($theme -ne $script:AppliedTheme) { Set-UiTheme -Theme $theme }
}

function Save-AppSettingsFromUi {
    $theme = 'System'
    if ($script:Ui.LightRadio.IsChecked) { $theme = 'Light' }
    elseif ($script:Ui.DarkRadio.IsChecked) { $theme = 'Dark' }
    $windowWidth = [double]$script:Window.Width
    $windowHeight = [double]$script:Window.Height
    if ($script:Window.WindowState -eq 'Maximized') {
        $windowWidth = [double]$script:Window.RestoreBounds.Width
        $windowHeight = [double]$script:Window.RestoreBounds.Height
    }
    Set-WintilityAppSettings -AppTheme $theme `
        -ShowBackground ([bool]$script:Ui.ShowBackgroundBox.IsChecked) `
        -Glass ([bool]$script:Ui.GlassBox.IsChecked) `
        -Animations ([bool]$script:Ui.AnimationsBox.IsChecked) `
        -WindowWidth $windowWidth `
        -WindowHeight $windowHeight
}

function Update-AppTheme {
    Save-AppSettingsFromUi
    $effective = Get-EffectiveTheme
    if ($effective -ne $script:AppliedTheme) { Set-UiTheme -Theme $effective }
    Set-UiStatus "App theme: $effective."
}

function Set-BackgroundVisibility {
    param([bool]$Show)
    if ($Show) { $script:Ui.BackgroundImage.Visibility = 'Visible' }
    else { $script:Ui.BackgroundImage.Visibility = 'Collapsed' }
}

function Update-SplashProgress {
    param([int]$Percent, [string]$Text)
    if ($script:AnimationsOn -and $script:Ui.SplashBar.Value -ne $Percent) {
        $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
        $animation.To = $Percent
        $animation.Duration = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(240))
        $animation.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
        $animation.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
        $script:Ui.SplashBar.BeginAnimation([System.Windows.Controls.ProgressBar]::ValueProperty, $animation)
    }
    else { $script:Ui.SplashBar.Value = $Percent }
    $script:Ui.SplashStatus.Text = $Text
}

function Get-AllTweakSettings {
    # The config files do not change while the app runs, so they are read once.
    if ($null -eq $script:TweakSettings) {
        $all = New-Object System.Collections.Generic.List[object]
        foreach ($name in (Get-WintilityTweakConfigNames)) {
            $config = Get-WintilityConfig -Name $name
            if ($config.Success) {
                foreach ($setting in @($config.Data.settings)) { $all.Add($setting) }
            }
        }
        $script:TweakSettings = $all.ToArray()
    }
    return $script:TweakSettings
}

function Test-TweakVisible {
    param([Parameter(Mandatory)]$Setting)
    # Tweaks that need administrator access are not shown at all in a standard session.
    if ([bool]$Setting.requiresAdmin -and -not $script:IsAdmin) { return $false }
    return $true
}

function Get-HiddenTweakCount {
    return @(Get-AllTweakSettings | Where-Object { -not (Test-TweakVisible -Setting $_) }).Count
}

function Invoke-SettingToggle {
    param([Parameter(Mandatory)][string]$Id, [bool]$Turn)
    $setting = Find-WintilitySetting -Id $Id
    $view = $script:RowViews[$Id]
    try {
        if ((Test-WintilitySettingApplied -Setting $setting) -eq $Turn) {
            # The switch is already where the user wants it (for example a quick on-then-off). Write nothing.
            $result = New-WintilityResult -Id $Id -Name $setting.name -Changed $false -Message 'Already in that position. No change needed.'
        }
        elseif ($Turn) { $result = Invoke-WintilitySetting -Id $Id }
        else { $result = Restore-WintilitySetting -Id $Id }
    }
    catch {
        $result = New-WintilityResult -Id $Id -Success $false -Message 'This change failed.' -ErrorDetail $_.Exception.Message
    }
    $script:LastResults[$Id] = $result

    $message = Get-ResultText -Result $result
    if ($null -ne $view) {
        # The switch always shows what the registry really says, so it can never be left in the wrong position.
        try { $view.Toggle.IsChecked = (Test-WintilitySettingApplied -Setting $setting) }
        catch { Write-WintilityLog -Severity WARN -Module 'UI' -Message "Could not read the state of $Id. $($_.Exception.Message)" }
        $view.Message.Text = $message
        $view.Message.Visibility = 'Visible'
        Set-ResultTone -Block $view.Message -Result $result
    }

    # Taskbar, desktop and File Explorer tweaks refresh the desktop in the background after the switch has moved.
    if ($result.Success -and $result.Changed -and (Test-WintilityNeedsShellRefresh -Setting $setting)) {
        Set-UiStatus "$message Refreshing the desktop..."
        Request-ShellRefresh
    }
    else {
        Set-UiStatus $message
    }
}

function New-UiChip {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Hex)
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontSize = 11
    $label.FontWeight = 'SemiBold'
    $label.Foreground = New-UiBrush -Hex $Hex
    $chip = New-Object System.Windows.Controls.Border
    $chip.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList ([double]6)
    $chip.Padding = '8,2'
    $chip.Margin = '0,0,6,4'
    # '#26' makes the same color about 15 percent opaque, for the soft background.
    $chip.Background = New-UiBrush -Hex ('#26' + $Hex.TrimStart('#'))
    $chip.Child = $label
    return $chip
}

function Request-SettingToggle {
    param([Parameter(Mandatory)][string]$Id, [bool]$Turn)
    # Let the switch finish gliding first. The registry work starts a moment later, so the
    # animation is never cut short. Several quick clicks collapse into the last one.
    $script:PendingToggles[$Id] = $Turn
    if ($null -eq $script:ToggleTimer) {
        $script:ToggleTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ToggleTimer.Interval = [TimeSpan]::FromMilliseconds(380)
        $script:ToggleTimer.Add_Tick({ Invoke-UiAction { Invoke-PendingToggle } })
    }
    $script:ToggleTimer.Stop()
    $script:ToggleTimer.Start()
}

function Invoke-PendingToggle {
    $script:ToggleTimer.Stop()
    $pending = $script:PendingToggles
    $script:PendingToggles = @{}
    foreach ($id in @($pending.Keys)) {
        Invoke-UiAction { Invoke-SettingToggle -Id $id -Turn ([bool]$pending[$id]) }
    }
}

function New-TweakRow {
    param([Parameter(Mandatory)]$Setting, [bool]$Last = $false)
    $result = $script:LastResults[$Setting.id]

    $grid = New-Object System.Windows.Controls.Grid
    $iconColumn = New-Object System.Windows.Controls.ColumnDefinition
    $iconColumn.Width = [System.Windows.GridLength]::Auto
    $textColumn = New-Object System.Windows.Controls.ColumnDefinition
    $textColumn.Width = New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)
    $switchColumn = New-Object System.Windows.Controls.ColumnDefinition
    $switchColumn.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($iconColumn)
    $grid.ColumnDefinitions.Add($textColumn)
    $grid.ColumnDefinitions.Add($switchColumn)

    # Icon tile
    $iconKey = Get-WintilityProperty -Object $Setting -Name 'icon'
    if (-not $iconKey) { $iconKey = 'SlidersHorizontal' }
    $glyph = New-UiIcon -Key $iconKey -Size 20
    $glyph.Foreground = New-UiBrush -Hex '#BFE4FF'
    $glyph.HorizontalAlignment = 'Center'
    $tile = New-Object System.Windows.Controls.Border
    $tile.Width = 38
    $tile.Height = 38
    $tile.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList ([double]10)
    $tile.Background = New-UiBrush -Hex '#1B4B78'
    $tile.VerticalAlignment = 'Top'
    $tile.Child = $glyph
    [System.Windows.Controls.Grid]::SetColumn($tile, 0)
    $grid.Children.Add($tile) | Out-Null

    # Title, description, chips and the result line
    $text = New-Object System.Windows.Controls.StackPanel
    $text.Margin = '14,0,18,0'
    $text.VerticalAlignment = 'Center'
    $title = New-UiText -Text $Setting.name -Role 'TextBrush' -Bold $true
    $title.FontSize = 14.5
    $title.Margin = '0'
    $text.Children.Add($title) | Out-Null
    $description = New-UiText -Text $Setting.description -Role 'SubBrush'
    $description.FontSize = 12.5
    $description.Margin = '0,3,0,0'
    $text.Children.Add($description) | Out-Null

    $chips = New-Object System.Windows.Controls.WrapPanel
    $chips.Margin = '0,8,0,0'
    $riskColors = @{ Low = '#34C759'; Medium = '#E8A33D'; High = '#E5484D' }
    $chips.Children.Add((New-UiChip -Text "$($Setting.risk) risk" -Hex $riskColors[[string]$Setting.risk])) | Out-Null
    if ([bool]$Setting.requiresAdmin) { $chips.Children.Add((New-UiChip -Text 'Needs admin' -Hex '#5BB4FF')) | Out-Null }
    if ([bool]$Setting.requiresRestart) { $chips.Children.Add((New-UiChip -Text 'Restart needed' -Hex '#5BB4FF')) | Out-Null }
    if ([bool]$Setting.requiresLogoff) { $chips.Children.Add((New-UiChip -Text 'Sign-out needed' -Hex '#5BB4FF')) | Out-Null }
    if ((Get-WintilityProperty -Object $Setting -Name 'requiresExplorerRestart') -eq $true) { $chips.Children.Add((New-UiChip -Text 'Applies live' -Hex '#5BB4FF')) | Out-Null }
    $text.Children.Add($chips) | Out-Null

    $messageBlock = New-UiText -Text '' -Role 'TextBrush'
    $messageBlock.Margin = '0,4,0,0'
    $messageBlock.Visibility = 'Collapsed'
    if ($result) {
        $messageBlock.Text = (Get-ResultText -Result $result)
        $messageBlock.Visibility = 'Visible'
        Set-ResultTone -Block $messageBlock -Result $result
    }
    $text.Children.Add($messageBlock) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($text, 1)
    $grid.Children.Add($text) | Out-Null

    # The switch
    $toggle = New-Object System.Windows.Controls.Primitives.ToggleButton
    $toggle.Style = $script:Window.FindResource('MacSwitch')
    $toggle.IsChecked = (Test-WintilitySettingApplied -Setting $Setting)
    $toggle.Tag = $Setting.id
    $toggle.VerticalAlignment = 'Center'
    $toggle.Add_Click({
        param($sender, $e)
        Invoke-UiAction { Request-SettingToggle -Id $sender.Tag -Turn ([bool]$sender.IsChecked) }
    })
    [System.Windows.Controls.Grid]::SetColumn($toggle, 2)
    $grid.Children.Add($toggle) | Out-Null
    $script:RowViews[$Setting.id] = @{ Toggle = $toggle; Message = $messageBlock }

    $row = New-Object System.Windows.Controls.Border
    $row.Padding = '18,16'
    if ($Last) { $row.BorderThickness = '0' } else { $row.BorderThickness = '0,0,0,1' }
    $row.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'DividerBrush')
    $row.Child = $grid
    return $row
}

function Update-TweakPanel {
    param([Parameter(Mandatory)][string]$Tab)
    $panel = $script:Ui["Panel_$Tab"]
    $panel.Children.Clear()
    $settings = @(Get-AllTweakSettings | Where-Object { $_.tab -eq $Tab -and (Test-TweakVisible -Setting $_) } | Sort-Object -Property category, name)

    # One labelled card per category, with a row for each tweak.
    foreach ($group in @($settings | Group-Object -Property category)) {
        $label = New-UiText -Text $group.Name.ToUpperInvariant() -Role 'SubBrush' -Bold $true
        $label.FontSize = 11.5
        $label.Margin = '6,0,0,8'
        $panel.Children.Add($label) | Out-Null

        $rows = New-Object System.Windows.Controls.StackPanel
        $members = @($group.Group)
        $index = 0
        foreach ($member in $members) {
            $index++
            $rows.Children.Add((New-TweakRow -Setting $member -Last ($index -eq $members.Count))) | Out-Null
        }
        $card = New-Object System.Windows.Controls.Border
        $card.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList ([double]12)
        $card.BorderThickness = '1'
        $card.Margin = '0,0,0,24'
        $card.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'CardBrush')
        $card.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'DividerBrush')
        $card.Child = $rows
        $panel.Children.Add($card) | Out-Null
    }
}

function Update-AllTweakPanels {
    foreach ($tab in $script:TabNames) {
        Update-TweakPanel -Tab $tab
        # Personalization also holds the wallpaper, mode and accent cards, so it always stays.
        if ($tab -eq 'Personalization') { continue }
        # A tab with nothing to show (everything on it needs administrator access) is hidden.
        foreach ($item in $script:Ui.MainTabs.Items) {
            if ($item.Header -eq $tab) {
                if ($script:Ui["Panel_$tab"].Children.Count -eq 0) { $item.Visibility = 'Collapsed' }
                else { $item.Visibility = 'Visible' }
            }
        }
    }
}

function Import-UiIcons {
    # The Lucide icons ship inside Wintility, so they work offline and never depend on a website.
    [xml]$xaml = Get-Content -LiteralPath (Join-Path $script:RootPath 'assets\icons\lucide.xaml') -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader -ArgumentList $xaml
    $icons = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:Window.Resources.MergedDictionaries.Add($icons)
}

function New-UiIcon {
    param(
        [Parameter(Mandatory)][string]$Key,
        [double]$Size = 18,
        [string]$Role = 'SubBrush'
    )
    $icon = New-Object System.Windows.Controls.Control
    $icon.Style = $script:Window.FindResource('LucideIcon')
    $icon.Tag = $script:Window.FindResource("Icon.$Key")
    $icon.Width = $Size
    $icon.Height = $Size
    $icon.VerticalAlignment = 'Center'
    $icon.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, $Role)
    return $icon
}

function Set-ResultTone {
    param([Parameter(Mandatory)]$Block, [Parameter(Mandatory)]$Result)
    # A failed change is red and a skipped one is amber, so a message can never be mistaken for a success.
    if (-not $Result.Success) { $Block.Foreground = New-UiBrush -Hex '#E5484D' }
    elseif ($Result.Skipped) { $Block.Foreground = New-UiBrush -Hex '#E8A33D' }
    else { $Block.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush') }
}

function Request-ShellRefresh {
    # Refreshes the desktop in the background so a switch never waits for it. If a refresh is already
    # running, one more is queued, so quick toggles still end with a fully refreshed desktop.
    if ($script:ShellJob) { $script:ShellRefreshAgain = $true; return }
    if ($null -eq $script:ShellTimer) {
        $script:ShellTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ShellTimer.Interval = [TimeSpan]::FromMilliseconds(250)
        $script:ShellTimer.Add_Tick({ Invoke-UiAction { Update-ShellRefresh } })
    }
    $script:ShellJob = Start-WintilityShellRefresh
    $script:ShellTimer.Start()
}

function Update-ShellRefresh {
    if ($null -eq $script:ShellJob) { $script:ShellTimer.Stop(); return }
    $outcome = Receive-WintilityShellRefresh -Job $script:ShellJob -TimeoutSeconds 25
    if ($null -eq $outcome) { return }
    $script:ShellJob = $null
    if ($script:ShellRefreshAgain) {
        $script:ShellRefreshAgain = $false
        $script:ShellJob = Start-WintilityShellRefresh
        return
    }
    $script:ShellTimer.Stop()
    if ($outcome.Refreshed) { Set-UiStatus 'Desktop refreshed.'; return }

    # The live refresh did not work, so fall back to restarting File Explorer.
    Write-WintilityLog -Severity WARN -Module 'UI' -Message ('Live refresh failed. ' + ($outcome.Notes -join ' '))
    $restart = Restart-WintilityExplorer
    if ($restart.Success -and -not $restart.Skipped) { Set-UiStatus 'The live refresh did not work, so File Explorer was restarted.' }
    else { Set-UiStatus 'The desktop could not be refreshed automatically. Use Restart File Explorer in Settings.' }
}

function New-InfoCard {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Value,
        [string[]]$Details = @(),
        [string]$Icon
    )
    $stack = New-Object System.Windows.Controls.StackPanel
    $heading = New-Object System.Windows.Controls.StackPanel
    $heading.Orientation = 'Horizontal'
    if ($Icon) {
        $glyph = New-UiIcon -Key $Icon -Size 18 -Role 'SubBrush'
        $glyph.Margin = '0,0,8,0'
        $heading.Children.Add($glyph) | Out-Null
    }
    $titleText = New-UiText -Text $Title -Role 'SubBrush' -Bold $true
    $titleText.Margin = '0'
    $titleText.VerticalAlignment = 'Center'
    $heading.Children.Add($titleText) | Out-Null
    $stack.Children.Add($heading) | Out-Null
    $valueText = New-UiText -Text $Value -Role 'TextBrush' -Bold $true
    $valueText.FontSize = 22
    $valueText.Margin = '0,6,0,6'
    $stack.Children.Add($valueText) | Out-Null
    foreach ($detail in $Details) {
        $stack.Children.Add((New-UiText -Text $detail -Role 'SubBrush')) | Out-Null
    }

    $border = New-Object System.Windows.Controls.Border
    $border.Padding = '18'
    $border.Margin = '6'
    $border.BorderThickness = '1.5'
    $border.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList ([double]12)
    $border.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'BoxBrush')
    $border.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'CardBrush')
    $border.Child = $stack
    return $border
}

function Update-SystemInfoPanel {
    $panel = $script:Ui.SystemInfoPanel
    $panel.Children.Clear()
    $info = Get-WintilitySystemInfo
    $unavailable = 'Unavailable on this system.'

    $panel.Children.Add((New-InfoCard -Icon 'Monitor' -Title 'PC name' -Value $info.ComputerName)) | Out-Null

    if ($info.Memory) {
        $available = Format-WintilityBytes -Bytes $info.Memory.AvailableBytes
        $panel.Children.Add((New-InfoCard -Icon 'MemoryStick' -Title 'Memory (RAM)' -Value (Format-WintilityBytes -Bytes $info.Memory.TotalBytes) -Details @("$available available right now"))) | Out-Null
    }
    else {
        $panel.Children.Add((New-InfoCard -Icon 'MemoryStick' -Title 'Memory (RAM)' -Value $unavailable)) | Out-Null
    }

    $drives = @($info.Drives)
    if ($drives.Count -gt 0) {
        $primary = $drives | Where-Object { $_.Name -eq $env:SystemDrive } | Select-Object -First 1
        if (-not $primary) { $primary = $drives[0] }
        $others = @($drives | Where-Object { $_.Name -ne $primary.Name } | ForEach-Object {
            '{0}  {1} free of {2}' -f $_.Name, (Format-WintilityBytes -Bytes $_.FreeBytes), (Format-WintilityBytes -Bytes $_.TotalBytes)
        })
        $value = '{0} free of {1}' -f (Format-WintilityBytes -Bytes $primary.FreeBytes), (Format-WintilityBytes -Bytes $primary.TotalBytes)
        $panel.Children.Add((New-InfoCard -Icon 'HardDrive' -Title "Storage ($($primary.Name))" -Value $value -Details $others)) | Out-Null
    }
    else {
        $panel.Children.Add((New-InfoCard -Icon 'HardDrive' -Title 'Storage' -Value $unavailable)) | Out-Null
    }

    if ($info.Network) {
        $speed = Format-WintilityLinkSpeed -BitsPerSecond $info.Network.SpeedBitsPerSecond
        $details = @(
            "IP address: $($info.Network.IPv4)",
            "Connection: $($info.Network.Kind)",
            "Link speed: $speed (what your adapter negotiated, not your internet speed)"
        )
        $card = New-InfoCard -Icon 'Wifi' -Title 'Network' -Value $info.Network.Name -Details $details
        $stack = $card.Child
        $stack.Children.Add((New-UiText -Text $script:SpeedText -Role 'TextBrush')) | Out-Null

        $button = New-Object System.Windows.Controls.Button
        $button.Content = 'Test internet speed'
        $button.Width = 170
        $button.Height = 30
        $button.HorizontalAlignment = 'Left'
        $button.Margin = '0,10,0,0'
        $button.IsEnabled = ($null -eq $script:SpeedJob)
        $button.ToolTip = 'Downloads up to 25 MB from Cloudflare to measure your download speed.'
        $button.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'BtnBrush')
        $button.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'BtnTextBrush')
        $button.Add_Click({ Invoke-UiAction { Invoke-SpeedTest } })
        $stack.Children.Add($button) | Out-Null
        $panel.Children.Add($card) | Out-Null
    }
    else {
        $panel.Children.Add((New-InfoCard -Icon 'Wifi' -Title 'Network' -Value 'Not connected' -Details @('No network adapter with a gateway was found.'))) | Out-Null
    }
}

function Invoke-SpeedTest {
    if ($script:SpeedJob) { return }
    $job = Start-WintilitySpeedTest
    $script:SpeedJob = $job
    $script:SpeedText = 'Internet speed: testing, this can take up to 10 seconds...'
    $script:SpeedTimer.Start()
    Update-SystemInfoPanel
}

function Confirm-Yes {
    param([Parameter(Mandatory)][string]$Text)
    $answer = [System.Windows.MessageBox]::Show(
        $Text,
        'Confirm',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)
    return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}

function Invoke-RestoreDialog {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Wintility backup (*.json)|*.json'
    $directory = Get-WintilityBackupDirectory
    if (Test-Path -LiteralPath $directory) { $dialog.InitialDirectory = $directory }
    if (-not $dialog.ShowDialog($script:Window)) { return }
    $summary = Restore-WintilityBackup -BackupFile $dialog.FileName
    Update-AllTweakPanels
    Set-UiStatus "Restore: $($summary.Headline)"
}

function Invoke-ChooseWallpaper {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Images (*.jpg;*.jpeg;*.png;*.bmp)|*.jpg;*.jpeg;*.png;*.bmp'
    if (-not $dialog.ShowDialog($script:Window)) { return }

    $info = Get-WintilityWallpaperInfo -Path $dialog.FileName
    $script:PendingWallpaper = $info.Path

    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.UriSource = New-Object System.Uri -ArgumentList $info.Path
    $bitmap.DecodePixelWidth = 640
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.EndInit()
    $script:Ui.WallpaperPreview.Source = $bitmap
    $script:Ui.WallpaperInfoText.Text = "$($info.Name)  |  $($info.Width) x $($info.Height)  |  $($info.SizeKB) KB"
    Set-UiStatus 'Wallpaper selected. Click Apply wallpaper to set it.'
}

function Invoke-ApplyWallpaper {
    if (-not $script:PendingWallpaper) {
        Set-UiStatus 'Choose an image first.'
        return
    }
    if (-not (Confirm-Yes -Text 'Set this image as your wallpaper? The current one is backed up first.')) { return }
    $result = Set-WintilityWallpaper -Path $script:PendingWallpaper
    Set-UiStatus (Get-ResultText -Result $result)
}

function Invoke-RestoreWallpaper {
    $result = Restore-WintilityWallpaper
    Set-UiStatus (Get-ResultText -Result $result)
}

function Invoke-SetSystemMode {
    param([Parameter(Mandatory)][ValidateSet('Light', 'Dark')][string]$Mode)
    if (-not (Confirm-Yes -Text "Switch Windows to $Mode mode? The current setting is backed up first.")) { return }
    $result = Set-WintilitySystemTheme -Mode $Mode
    $script:Ui.ModeText.Text = (Get-ResultText -Result $result)
    Set-UiStatus (Get-ResultText -Result $result)
}

function Select-Accent {
    param([Parameter(Mandatory)][uint32]$Argb, [Parameter(Mandatory)][string]$Name)
    $script:SelectedAccent = $Argb
    $script:Ui.AccentText.Text = "Selected: $Name. Click Apply accent to set it."
}

function Invoke-ApplyAccent {
    if ($null -eq $script:SelectedAccent) {
        Set-UiStatus 'Pick a color first.'
        return
    }
    if (-not (Confirm-Yes -Text 'Apply this accent color? The current one is backed up first.')) { return }
    $result = Set-WintilityAccentColor -Argb $script:SelectedAccent
    Set-UiStatus (Get-ResultText -Result $result)
}

function Initialize-AccentSwatches {
    foreach ($accent in $script:AccentPalette) {
        $rgb = [Convert]::ToUInt32($accent.Rgb, 16)
        $argb = [uint32](([uint64]0xC4 -shl 24) -bor [uint64]$rgb)
        $red = [byte](($rgb -shr 16) -band 0xFF)
        $green = [byte](($rgb -shr 8) -band 0xFF)
        $blue = [byte]($rgb -band 0xFF)
        $color = [System.Windows.Media.Color]::FromRgb($red, $green, $blue)

        $button = New-Object System.Windows.Controls.Button
        $button.Width = 40
        $button.Height = 40
        $button.Margin = '0,0,8,8'
        $button.ToolTip = $accent.Name
        $button.Tag = $argb
        $button.Background = New-Object System.Windows.Media.SolidColorBrush -ArgumentList $color
        $button.Add_Click({
            param($sender, $e)
            Invoke-UiAction { Select-Accent -Argb $sender.Tag -Name $sender.ToolTip }
        })
        $script:Ui.AccentPanel.Children.Add($button) | Out-Null
    }
}

function Set-PowerBoxStyle {
    param(
        [Parameter(Mandatory)]$Box,
        [Parameter(Mandatory)]$Icon,
        [Parameter(Mandatory)][object[]]$Texts,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Selected', 'Ultimate', 'Unavailable')][string]$Style
    )
    $Box.Effect = $null
    $Box.Opacity = 1.0
    if ($Style -eq 'Normal' -or $Style -eq 'Unavailable') {
        # Follow the app theme again. Icon, title, description and status use their normal colors.
        $Box.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'CardBrush')
        $Box.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'DividerBrush')
        $Icon.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'TextBrush')
        $roles = @('TextBrush', 'SubBrush', 'SubBrush')
        for ($i = 0; $i -lt $Texts.Count; $i++) {
            $Texts[$i].SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $roles[$i])
        }
        if ($Style -eq 'Unavailable') { $Box.Opacity = 0.45 }
        return
    }

    foreach ($text in $Texts) { $text.Foreground = New-UiBrush -Hex '#EAF6FF' }
    $Icon.Foreground = New-UiBrush -Hex '#EAF6FF'
    if ($Style -eq 'Selected') {
        $Box.Background = New-UiBrush -Hex '#1B4B78'
        $Box.BorderBrush = New-UiBrush -Hex '#5BB4FF'
        return
    }
    # Ultimate Performance: warm background, orange border, orange icon and an orange glow around the box.
    $Icon.Foreground = New-UiBrush -Hex '#FF9F0A'
    $Box.Background = New-UiBrush -Hex '#3B2A10'
    $Box.BorderBrush = New-UiBrush -Hex '#FF9F0A'
    $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $glow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#FF9F0A')
    $glow.BlurRadius = 28
    $glow.ShadowDepth = 0
    $glow.Opacity = 0.95
    $Box.Effect = $glow
}

function Update-PowerView {
    $state = Get-WintilityPowerState
    $script:PowerState = $state

    if (-not $state.Available) {
        $script:Ui.PowerActiveText.Text = 'Power plans could not be read on this PC.'
    }
    elseif ($state.Mode -eq 'Ultimate') {
        $script:Ui.PowerActiveText.Text = 'Active plan: Ultimate Performance (experimental)'
    }
    elseif ($state.Mode -eq 'Other') {
        $script:Ui.PowerActiveText.Text = "Active plan: $($state.ActiveName). This is a custom plan, so none of the boxes is selected."
    }
    else {
        $script:Ui.PowerActiveText.Text = "Active plan: $($state.ActiveName)"
    }

    $boxes = @(
        @{ Key = 'MaximumSavings'; Has = $state.HasMaximumSavings; Box = $script:Ui.PowerSaverBox; Icon = $script:Ui.PowerSaverIcon; Title = $script:Ui.PowerSaverTitle; Desc = $script:Ui.PowerSaverDesc; Status = $script:Ui.PowerSaverStatus }
        @{ Key = 'Balanced'; Has = $state.HasBalanced; Box = $script:Ui.PowerBalancedBox; Icon = $script:Ui.PowerBalancedIcon; Title = $script:Ui.PowerBalancedTitle; Desc = $script:Ui.PowerBalancedDesc; Status = $script:Ui.PowerBalancedStatus }
    )
    foreach ($item in $boxes) {
        if (-not $item.Has) { $style = 'Unavailable'; $status = 'Not available on this PC' }
        elseif ($state.Mode -eq $item.Key) { $style = 'Selected'; $status = 'Active' }
        else { $style = 'Normal'; $status = 'Click to switch' }
        $item.Status.Text = $status
        Set-PowerBoxStyle -Box $item.Box -Icon $item.Icon -Texts @($item.Title, $item.Desc, $item.Status) -Style $style
    }

    # High Performance box. It turns into Ultimate Performance, with an orange glow and a flame, when that plan is active.
    $texts = @($script:Ui.PowerHighTitle, $script:Ui.PowerHighDesc, $script:Ui.PowerHighStatus)
    if ($state.Mode -eq 'Ultimate') {
        $script:Ui.PowerHighIcon.Tag = $script:Window.FindResource('Icon.Flame')
        $script:Ui.PowerHighTitle.Text = 'Ultimate Performance'
        $script:Ui.PowerHighDesc.Text = 'Removes small delays and keeps the CPU at full speed. Double-click again to go back to High Performance.'
        $script:Ui.PowerHighStatus.Text = 'Active (experimental)'
        $script:Ui.PowerHighWarning.Visibility = 'Visible'
        Set-PowerBoxStyle -Box $script:Ui.PowerHighBox -Icon $script:Ui.PowerHighIcon -Texts $texts -Style 'Ultimate'
        return
    }
    $script:Ui.PowerHighIcon.Tag = $script:Window.FindResource('Icon.Rocket')
    $script:Ui.PowerHighTitle.Text = 'High Performance'
    $script:Ui.PowerHighDesc.Text = 'Keeps the CPU responsive for demanding apps and games. Uses more battery and runs warmer. Double-click to try Ultimate Performance.'
    $script:Ui.PowerHighWarning.Visibility = 'Collapsed'
    if ($state.Mode -eq 'HighPerformance') { $style = 'Selected'; $status = 'Active' }
    elseif ($state.HasHighPerformance) { $style = 'Normal'; $status = 'Click to switch' }
    elseif ($script:IsAdmin) { $style = 'Normal'; $status = 'Click to create and switch' }
    else { $style = 'Unavailable'; $status = 'Not on this PC. Creating it needs administrator access.' }
    $script:Ui.PowerHighStatus.Text = $status
    Set-PowerBoxStyle -Box $script:Ui.PowerHighBox -Icon $script:Ui.PowerHighIcon -Texts $texts -Style $style
}

function Select-PowerMode {
    param([Parameter(Mandatory)][ValidateSet('MaximumSavings', 'Balanced', 'HighPerformance', 'Ultimate')][string]$Mode)
    $result = Set-WintilityPowerPlan -Mode $Mode
    Update-PowerView
    Set-UiStatus (Get-ResultText -Result $result)
}

function Invoke-UltimateToggle {
    # Double-click on the High Performance box: switch between High and Ultimate Performance.
    $state = Get-WintilityPowerState
    if ($state.Mode -eq 'Ultimate') { Select-PowerMode -Mode 'HighPerformance' }
    else { Select-PowerMode -Mode 'Ultimate' }
}

function Invoke-RestorePowerPlan {
    $result = Restore-WintilityPowerPlan
    Update-PowerView
    Set-UiStatus (Get-ResultText -Result $result)
}

function Invoke-RestartExplorer {
    if (-not (Confirm-Yes -Text 'Restart File Explorer? Open File Explorer windows will close. Your other apps are not affected.')) { return }
    $result = Restart-WintilityExplorer
    Set-UiStatus (Get-ResultText -Result $result)
}

function Restart-WintilityElevated {
    $launcher = Join-Path $script:RootPath 'Wintility.ps1'
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $launcher))
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs
    $script:Window.Close()
}

function Switch-SettingsView {
    # The tab strip hides while Settings is open, so the window background (and glass) shows behind it.
    if ($script:Ui.SettingsView.Visibility -eq 'Visible') {
        $script:Ui.SettingsView.Visibility = 'Collapsed'
        $script:Ui.MainTabs.Visibility = 'Visible'
        Start-FadeIn -Element $script:Ui.MainTabs -Milliseconds 160
    }
    else {
        $script:Ui.LogView.Visibility = 'Collapsed'
        $script:Ui.MainTabs.Visibility = 'Collapsed'
        $script:Ui.SettingsView.Visibility = 'Visible'
        Start-FadeIn -Element $script:Ui.SettingsView -Milliseconds 160
    }
}

function Update-LogViewer {
    $directory = Join-Path $env:LOCALAPPDATA 'Wintility\Logs'
    $script:Ui.LogLocationText.Text = $directory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $script:Ui.LogText.Text = 'No application logs have been written yet.'
        return
    }

    $files = @(Get-ChildItem -LiteralPath $directory -Filter 'wintility_*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)
    $sections = New-Object System.Collections.Generic.List[string]
    $remaining = 5000
    foreach ($file in $files) {
        if ($remaining -le 0) { break }
        $tail = [math]::Min(1000, $remaining)
        try {
            $lines = @(Get-Content -LiteralPath $file.FullName -Tail $tail -ErrorAction Stop)
            if ($lines.Count -gt 0) {
                $sections.Insert(0, ('[{0}]' -f $file.Name) + [Environment]::NewLine + ($lines -join [Environment]::NewLine))
                $remaining -= $lines.Count
            }
        }
        catch {
            $sections.Insert(0, ('[{0}] Could not read this log: {1}' -f $file.Name, $_.Exception.Message))
        }
    }
    if ($sections.Count -eq 0) { $script:Ui.LogText.Text = 'No application logs have been written yet.' }
    else {
        $script:Ui.LogText.Text = $sections -join ([Environment]::NewLine + [Environment]::NewLine)
        $script:Ui.LogText.CaretIndex = $script:Ui.LogText.Text.Length
        $script:Ui.LogText.ScrollToEnd()
    }
}

function Switch-LogView {
    if ($script:Ui.LogView.Visibility -eq 'Visible') {
        $script:Ui.LogView.Visibility = 'Collapsed'
        $script:Ui.MainTabs.Visibility = 'Visible'
        Start-FadeIn -Element $script:Ui.MainTabs -Milliseconds 160
        return
    }
    $script:Ui.SettingsView.Visibility = 'Collapsed'
    $script:Ui.MainTabs.Visibility = 'Collapsed'
    $script:Ui.LogView.Visibility = 'Visible'
    Update-LogViewer
    Start-FadeIn -Element $script:Ui.LogView -Milliseconds 160
}

function Start-TabContentTransition {
    param([Parameter(Mandatory)]$TabControl)
    $current = $TabControl.Template.FindName('PART_SelectedContentHost', $TabControl)
    $previous = $TabControl.Template.FindName('PART_PreviousContentHost', $TabControl)
    if (-not $current -or -not $previous) { return }

    if ($null -eq $script:LastTabIndex) {
        $script:LastTabIndex = $TabControl.Items.IndexOf($TabControl.SelectedItem)
        $current.Content = $TabControl.SelectedItem.Content
        return
    }

    $oldX = 0.0; $oldOpacity = 1.0
    if ($current.RenderTransform -is [System.Windows.Media.TranslateTransform]) {
        $oldX = [double]$current.RenderTransform.X
    }
    $oldOpacity = [double]$current.Opacity
    $current.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    if ($current.RenderTransform -is [System.Windows.Media.TranslateTransform]) {
        $current.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
    }
    $current.RenderTransform = New-Object System.Windows.Media.TranslateTransform -ArgumentList $oldX, 0

    $previous.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    if ($previous.RenderTransform -is [System.Windows.Media.TranslateTransform]) {
        $previous.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
    }
    $leavingContent = $current.Content
    $current.Content = $null
    $previous.Content = $leavingContent
    $previous.Visibility = 'Visible'
    $previous.Opacity = $oldOpacity
    $previous.RenderTransform = New-Object System.Windows.Media.TranslateTransform -ArgumentList $oldX, 0

    $newIndex = $TabControl.Items.IndexOf($TabControl.SelectedItem)
    $direction = if ($newIndex -gt $script:LastTabIndex) { 1.0 } else { -1.0 }
    $script:LastTabIndex = $newIndex
    $current.Content = $TabControl.SelectedItem.Content
    if (-not $script:AnimationsOn) {
        $previous.Visibility = 'Collapsed'; $previous.Content = $null
        $current.Opacity = 1.0; $current.RenderTransform = New-Object System.Windows.Media.TranslateTransform
        return
    }

    $script:TabTransitionGeneration++
    $generation = $script:TabTransitionGeneration
    $current.RenderTransform = New-Object System.Windows.Media.TranslateTransform -ArgumentList (24.0 * $direction), 0
    $current.Opacity = 0.72
    $tabDuration = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(360))
    $previousOut = New-Object System.Windows.Media.Animation.DoubleAnimation
    $previousOut.To = -24.0 * $direction; $previousOut.Duration = $tabDuration
    $previousOut.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    $previousOut.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $previousFade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $previousFade.To = 0.0; $previousFade.Duration = $previousOut.Duration
    $script:PreviousTabHost = $previous
    $previousFade.Add_Completed({
        if ($generation -eq $script:TabTransitionGeneration) { $script:PreviousTabHost.Visibility = 'Collapsed'; $script:PreviousTabHost.Content = $null }
    }.GetNewClosure())
    $previous.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $previousOut)
    $previous.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $previousFade)

    $incoming = New-Object System.Windows.Media.Animation.DoubleAnimation
    $incoming.From = 24.0 * $direction; $incoming.To = 0.0
    $incoming.Duration = $tabDuration
    $incoming.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    $incoming.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fadeIn.From = 0.72; $fadeIn.To = 1.0; $fadeIn.Duration = $incoming.Duration
    $current.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $incoming)
    $current.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)
}

function Connect-UiEvents {
    $script:Ui.CloseButton.Add_Click({ $script:Window.Close() })
    $script:Ui.MinimizeButton.Add_Click({ $script:Window.WindowState = 'Minimized' })
    $script:Ui.MaximizeButton.Add_Click({
        if ($script:Window.WindowState -eq 'Maximized') { $script:Window.WindowState = 'Normal' }
        else { $script:Window.WindowState = 'Maximized' }
    })

    $script:Ui.GearButton.Add_Click({ Invoke-UiAction { Switch-SettingsView } })
    $script:Ui.SettingsDoneButton.Add_Click({ Invoke-UiAction { Switch-SettingsView } })
    $script:Ui.LogButton.Add_Click({ Invoke-UiAction { Switch-LogView } })
    $script:Ui.RefreshLogButton.Add_Click({ Invoke-UiAction { Update-LogViewer } })
    $script:Ui.LogDoneButton.Add_Click({ Invoke-UiAction { Switch-LogView } })
    $script:Ui.DnsAdapterCombo.Add_SelectionChanged({ Invoke-UiAction { Update-DnsAdapterSummary } })
    $script:Ui.RefreshDnsAdaptersButton.Add_Click({ Invoke-UiAction { Update-DnsAdapterList } })
    $script:Ui.DnsProviderCombo.Add_SelectionChanged({
        param($sender, $e)
        if ($e.OriginalSource -ne $sender -or $null -eq $sender.SelectedItem) { return }
        $tag = [string]$sender.SelectedItem.Tag
        $script:Ui.DnsDohCheckBox.IsEnabled = ($tag -ne 'Automatic')
        if ($tag -eq 'Custom') {
            Invoke-UiAction {
                $custom = Show-CustomDnsDialog
                if ($custom) {
                    $script:CustomDnsConfig = $custom
                    $script:LastDnsProviderTag = 'Custom'
                    $script:Ui.DnsStatusText.Text = "Custom DNS: $(@($custom.Servers) -join ', ')"
                }
                else {
                    $restore = @($sender.Items | Where-Object { $_.Tag -eq $script:LastDnsProviderTag } | Select-Object -First 1)[0]
                    if ($restore) { $sender.SelectedItem = $restore }
                }
            }
        }
        else { $script:LastDnsProviderTag = $tag }
    })
    $script:Ui.ApplyDnsButton.Add_Click({ Invoke-UiAction { Invoke-ApplyDnsSelection } })
    $script:Ui.ResetDnsButton.Add_Click({
        Invoke-UiAction {
            $adapter = $script:Ui.DnsAdapterCombo.SelectedItem
            if ($null -eq $adapter) { throw 'Select a connected network adapter first.' }
            $result = Reset-WintilityDnsProvider -InterfaceIndex ([uint32]$adapter.InterfaceIndex)
            Update-DnsAdapterList
            $script:Ui.DnsStatusText.Text = Get-ResultText -Result $result
            Set-UiStatus $result.Message
        }
    })
    $script:Ui.FlushDnsButton.Add_Click({
        Invoke-UiAction {
            $result = Clear-WintilityDnsCache
            $script:Ui.DnsStatusText.Text = Get-ResultText -Result $result
            Set-UiStatus $result.Message
        }
    })
    $script:Ui.StartupAppsToggle.Add_Click({
        param($sender, $e)
        Invoke-UiAction {
            $disable = [bool]$sender.IsChecked
            if ($disable) {
                $answer = [System.Windows.MessageBox]::Show(
                    $script:Window,
                    'Disable classic Run/RunOnce and Startup-folder entries for this account? Wintility saves a restore copy. Running apps are not closed.',
                    'Disable startup apps',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Question
                )
                if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { $sender.IsChecked = $false; return }
            }
            try {
                $result = Set-WintilityStartupAppsDisabled -Disabled $disable
                $sender.IsChecked = Get-WintilityStartupAppsDisabled
                $script:Ui.StartupAppsStatusText.Text = $result.Message
                Set-UiStatus $result.Message
            }
            catch {
                $sender.IsChecked = Get-WintilityStartupAppsDisabled
                throw
            }
        }
    })
    $script:Ui.MemoryCompressionBox.Add_Click({
        param($sender, $e)
        Invoke-UiAction {
            try {
                $result = Set-WintilityMemoryCompression -Enabled ([bool]$sender.IsChecked)
                $script:Ui.MemoryCompressionStatusText.Text = $result.Message
                Set-UiStatus $result.Message
            }
            catch {
                try { $sender.IsChecked = Get-WintilityMemoryCompressionState } catch { $sender.IsChecked = $false }
                throw
            }
        }
    })
    $script:Ui.OpenStartupSettingsButton.Add_Click({ Invoke-UiAction { Start-Process -FilePath 'ms-settings:startup' } })
    $script:Ui.OpenDriveOptimizerButton.Add_Click({ Invoke-UiAction { Open-WintilityDriveOptimizer } })
    $script:Ui.MainTabs.ApplyTemplate()
    if ($script:Ui.MainTabs.SelectedIndex -lt 0) { $script:Ui.MainTabs.SelectedIndex = 0 }
    $script:LastTabIndex = $null
    $script:TabTransitionGeneration = 0
    Start-TabContentTransition -TabControl $script:Ui.MainTabs
    $script:Ui.MainTabs.Add_SelectionChanged({
        param($sender, $e)
        if ($e.OriginalSource -ne $sender) { return }
        Invoke-UiAction {
            Start-TabContentTransition -TabControl $script:Ui.MainTabs
            # The active plan can change outside Wintility, so read it again whenever this tab opens.
            if ($script:Ui.MainTabs.SelectedItem.Header -eq 'Power') { Update-PowerView }
        }
    })

    $script:Ui.RefreshInfoButton.Add_Click({ Invoke-UiAction { Update-SystemInfoPanel } })
    $script:Ui.ClaudeLink.Add_MouseLeftButtonUp({
        param($sender, $e)
        Invoke-UiAction { Start-Process -FilePath ([string]$sender.Tag) }
    })

    $script:Ui.RestoreBackupButton.Add_Click({ Invoke-UiAction { Invoke-RestoreDialog } })
    $script:Ui.ElevateButton.Add_Click({ Invoke-UiAction { Restart-WintilityElevated } })
    $script:Ui.RestartExplorerButton.Add_Click({ Invoke-UiAction { Invoke-RestartExplorer } })
    $script:Ui.RestorePowerButton.Add_Click({ Invoke-UiAction { Invoke-RestorePowerPlan } })
    $script:Ui.PowerSaverBox.Add_MouseLeftButtonDown({ Invoke-UiAction { Select-PowerMode -Mode 'MaximumSavings' } })
    $script:Ui.PowerBalancedBox.Add_MouseLeftButtonDown({ Invoke-UiAction { Select-PowerMode -Mode 'Balanced' } })
    $script:Ui.PowerHighBox.Add_MouseLeftButtonDown({
        param($sender, $e)
        Invoke-UiAction {
            if ($e.ClickCount -ge 2) { Invoke-UltimateToggle; return }
            # A single click only switches to High Performance from another plan. Once High or Ultimate
            # is active, only a double-click changes it, so the first click of a double-click cannot undo it.
            $mode = $script:PowerState.Mode
            if ($mode -eq 'HighPerformance' -or $mode -eq 'Ultimate') {
                Set-UiStatus 'Double-click this box to switch between High Performance and Ultimate Performance (experimental).'
                return
            }
            Select-PowerMode -Mode 'HighPerformance'
        }
    })
    $script:Ui.ChooseWallpaperButton.Add_Click({ Invoke-UiAction { Invoke-ChooseWallpaper } })
    $script:Ui.ApplyWallpaperButton.Add_Click({ Invoke-UiAction { Invoke-ApplyWallpaper } })
    $script:Ui.RestoreWallpaperButton.Add_Click({ Invoke-UiAction { Invoke-RestoreWallpaper } })
    $script:Ui.LightModeButton.Add_Click({ Invoke-UiAction { Invoke-SetSystemMode -Mode 'Light' } })
    $script:Ui.DarkModeButton.Add_Click({ Invoke-UiAction { Invoke-SetSystemMode -Mode 'Dark' } })
    $script:Ui.ApplyAccentButton.Add_Click({ Invoke-UiAction { Invoke-ApplyAccent } })

    $script:Ui.FollowSystemRadio.Add_Checked({ Invoke-UiAction { Update-AppTheme } })
    $script:Ui.LightRadio.Add_Checked({ Invoke-UiAction { Update-AppTheme } })
    $script:Ui.DarkRadio.Add_Checked({ Invoke-UiAction { Update-AppTheme } })
    $script:Ui.ShowBackgroundBox.Add_Checked({
        Invoke-UiAction {
            Set-BackgroundVisibility -Show $true
            Save-AppSettingsFromUi
        }
    })
    $script:Ui.ShowBackgroundBox.Add_Unchecked({
        Invoke-UiAction {
            Set-BackgroundVisibility -Show $false
            Save-AppSettingsFromUi
        }
    })
    $script:Ui.GlassBox.Add_Checked({
        Invoke-UiAction {
            Set-WindowGlass -Enable $true
            Save-AppSettingsFromUi
        }
    })
    $script:Ui.GlassBox.Add_Unchecked({
        Invoke-UiAction {
            Set-WindowGlass -Enable $false
            Save-AppSettingsFromUi
        }
    })
    $script:Ui.AnimationsBox.Add_Checked({ Invoke-UiAction { Update-AnimationFlag; Save-AppSettingsFromUi } })
    $script:Ui.AnimationsBox.Add_Unchecked({ Invoke-UiAction { Update-AnimationFlag; Save-AppSettingsFromUi } })
}

function Initialize-UiTimers {
    # Follow-Windows theme check, every 5 seconds.
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromSeconds(5)
    $script:Timer.Add_Tick({ Invoke-UiAction { Sync-ThemeWithSystem } })

    # The Home clock reads the PC's own clock every second.
    $script:ClockTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ClockTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:ClockTimer.Add_Tick({ Invoke-UiAction { $script:Ui.HomeClock.Text = (Get-ClockText) } })

    # Polls the background speed test. Started only while a test is running.
    $script:SpeedTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SpeedTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:SpeedTimer.Add_Tick({
        Invoke-UiAction {
            if (-not $script:SpeedJob) { $script:SpeedTimer.Stop(); return }
            $result = Receive-WintilitySpeedTest -Job $script:SpeedJob
            if ($null -eq $result) { return }
            $script:SpeedTimer.Stop()
            $script:SpeedJob = $null
            if ($result.Success) { $script:SpeedText = "Internet speed: $($result.Message)" }
            else { $script:SpeedText = "Internet speed: $($result.Message) ($($result.Error))" }
            Update-SystemInfoPanel
        }
    })
}

function Start-SplashBackgroundMotion {
    if (-not $script:AnimationsOn) { return }
    $image = $script:Ui.SplashBackground
    $group = $image.RenderTransform
    $rotation = $group.Children[0]
    $drift = $group.Children[1]
    $rotate = New-Object System.Windows.Media.Animation.DoubleAnimation
    $rotate.From = 0; $rotate.To = 360
    $rotate.Duration = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromSeconds(70))
    $rotate.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $rotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $rotate)
    foreach ($pair in @(@('X', 10.0), @('Y', -6.0))) {
        $driftAnimation = New-Object System.Windows.Media.Animation.DoubleAnimation
        $driftAnimation.From = -[double]$pair[1]; $driftAnimation.To = [double]$pair[1]
        $driftAnimation.Duration = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromSeconds(12))
        $driftAnimation.AutoReverse = $true
        $driftAnimation.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $property = if ($pair[0] -eq 'X') { [System.Windows.Media.TranslateTransform]::XProperty } else { [System.Windows.Media.TranslateTransform]::YProperty }
        $drift.BeginAnimation($property, $driftAnimation)
    }
}

function Show-SplashLaunchPrompt {
    if ($script:AnimationsOn) {
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fade.To = 0.0
        $fade.Duration = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(160))
        $fade.Add_Completed({ Complete-SplashPrompt })
        $script:Ui.SplashProgressPanel.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    }
    else { Complete-SplashPrompt }
}

function Complete-SplashPrompt {
    $script:Ui.SplashProgressPanel.Visibility = 'Collapsed'
    $launch = $script:Ui.SplashLaunchPanel
    $launch.Visibility = 'Visible'
    Start-FadeIn -Element $launch -Milliseconds 180
}

function Complete-SplashLaunch {
    $transform = $script:Ui.SplashBackground.RenderTransform
    $transform.Children[0].BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    $transform.Children[1].BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
    $transform.Children[1].BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    $script:Ui.StartupOverlay.Visibility = 'Collapsed'
    $script:Ui.MainContent.IsHitTestVisible = $true
    $script:MainDialogCompleted = $true
}

function Begin-SplashLaunch {
    if ($script:LaunchInProgress) { return }
    $script:LaunchInProgress = $true
    $script:Ui.LaunchButton.IsEnabled = $false
    if (-not $script:AnimationsOn) {
        $script:Ui.MainContent.Opacity = 1.0
        $script:Ui.MainContent.IsHitTestVisible = $true
        Complete-SplashLaunch
        return
    }
    $storyboard = New-Object System.Windows.Media.Animation.Storyboard
    foreach ($pair in @(
        @{ Element = $script:Ui.MainContent; From = 0.0; To = 1.0 },
        @{ Element = $script:Ui.StartupOverlay; From = 1.0; To = 0.0 }
    )) {
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fade.From = [double]$pair.From
        $fade.To = [double]$pair.To
        $fade.Duration = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(300))
        $fade.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
        $fade.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
        [System.Windows.Media.Animation.Storyboard]::SetTarget($fade, $pair.Element)
        [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($fade, [System.Windows.PropertyPath]::new([System.Windows.UIElement]::OpacityProperty))
        [void]$storyboard.Children.Add($fade)
    }
    $storyboard.Add_Completed({ Complete-SplashLaunch })
    $storyboard.Begin($script:Window)
}

function Initialize-WintilityWindow {
    param([Parameter(Mandatory)]$Version, [Parameter(Mandatory)]$Bounds)

    $script:Window = Read-UiXaml -FileName 'MainWindow.xaml'
    $script:Window.Title = "$($Version.Product) $($Version.Version) $($Version.Edition)"
    Set-UiFont -Window $script:Window
    Import-UiIcons
    $names = @('RootGrid','MainContent','StartupOverlay','SplashBackground','SplashProgressPanel','SplashBar','SplashStatus','SplashVersion','SplashLaunchPanel','LaunchButton','BackgroundImage','AdminText','GearButton','LogButton','CloseButton','MinimizeButton','MaximizeButton','HomeClock','HomeTitle','HomeEdition','MainTabs','SettingsView','SettingsDoneButton','LogView','LogLocationText','LogText','RefreshLogButton','LogDoneButton','DnsAdapterCombo','DnsProviderCombo','DnsDohCheckBox','DnsAdminNote','DnsStatusText','RefreshDnsAdaptersButton','ApplyDnsButton','ResetDnsButton','FlushDnsButton','StartupAppsToggle','StartupAppsStatusText','OpenStartupSettingsButton','MemoryCompressionBox','MemoryCompressionStatusText','OpenDriveOptimizerButton','ElevateCard','ElevateNote','ElevateButton','RestartExplorerButton','PowerActiveText','PowerSaverBox','PowerSaverTitle','PowerSaverDesc','PowerSaverStatus','PowerBalancedBox','PowerBalancedTitle','PowerBalancedDesc','PowerBalancedStatus','PowerSaverIcon','PowerBalancedIcon','PowerHighIcon','PowerHighBox','PowerHighTitle','PowerHighDesc','PowerHighStatus','PowerHighWarning','RestorePowerButton','RestoreBackupButton','ChooseWallpaperButton','WallpaperPreview','WallpaperInfoText','ApplyWallpaperButton','RestoreWallpaperButton','LightModeButton','DarkModeButton','ModeText','AccentPanel','AccentText','ApplyAccentButton','FollowSystemRadio','LightRadio','DarkRadio','ShowBackgroundBox','GlassBox','GlassNote','AnimationsBox','SystemInfoPanel','RefreshInfoButton','ClaudeLink','CodexCreditIcon','VersionText','StatusText')
    foreach ($tab in $script:TabNames) { $names += "Panel_$tab" }
    $script:Ui = Get-UiControlMap -Root $script:Window -Names $names
    $script:Window.MinWidth = [math]::Min($script:Window.MinWidth, [System.Windows.SystemParameters]::WorkArea.Width)
    $script:Window.MinHeight = [math]::Min($script:Window.MinHeight, [System.Windows.SystemParameters]::WorkArea.Height)
    $script:Window.WindowStartupLocation = 'Manual'
    $script:Window.Width = $Bounds.Width
    $script:Window.Height = $Bounds.Height
    $script:Window.Left = $Bounds.Left
    $script:Window.Top = $Bounds.Top
    $script:Ui.MainContent.Opacity = 0.0
    $script:Ui.MainContent.IsHitTestVisible = $false
    $script:Ui.StartupOverlay.Opacity = 0.0
    $script:Ui.SplashVersion.Text = "$($Version.Version)  |  $($Version.Edition)"
    $script:Ui.SplashBar.Value = 10
    $script:WindowHandle = (New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:Window).EnsureHandle()
    Set-UiTheme -Theme (Get-EffectiveTheme)
    Initialize-UiTimers

    $backgroundPath = Join-Path $script:RootPath 'assets\background.png'
    if (Test-Path -LiteralPath $backgroundPath) {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit(); $bitmap.UriSource = New-Object System.Uri -ArgumentList $backgroundPath
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bitmap.EndInit()
        $script:Ui.SplashBackground.Source = $bitmap
        $script:Ui.BackgroundImage.Source = $bitmap
    }
    $codexIconPath = Join-Path $script:RootPath 'assets\icons\codex.png'
    if (Test-Path -LiteralPath $codexIconPath) {
        $codexBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $codexBitmap.BeginInit(); $codexBitmap.UriSource = New-Object System.Uri -ArgumentList $codexIconPath
        $codexBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $codexBitmap.EndInit()
        $script:Ui.CodexCreditIcon.Source = $codexBitmap
    }
    Start-SplashBackgroundMotion
    $script:Window.Add_Loaded({
        Start-FadeIn -Element $script:Ui.StartupOverlay -Milliseconds 260
    })
    $script:Window.Add_Closed({
        if ($script:StartupSettingsReady) { Save-AppSettingsFromUi }
        foreach ($timer in @($script:Timer,$script:ClockTimer,$script:SpeedTimer,$script:ShellTimer,$script:ToggleTimer,$script:StartupTimer)) { if ($timer) { $timer.Stop() } }
    })
}

function Show-WintilityWindow {
    [CmdletBinding()]
    param([string]$ReadyFile)

    $script:StartupReadyFile = $ReadyFile
    $script:StartupFailed = $false
    $script:MainDialogCompleted = $false
    $script:StartupSettingsReady = $false
    $version = Get-WintilityVersion
    $settings = Get-WintilityAppSettings
    $script:AnimationsOn = ([bool]$settings.Animations -and [System.Windows.SystemParameters]::ClientAreaAnimation)
    $work = [System.Windows.SystemParameters]::WorkArea
    $windowWidth = [math]::Min([math]::Max([double]$settings.WindowWidth, 1120.0), [double]$work.Width)
    $windowHeight = [math]::Min([math]::Max([double]$settings.WindowHeight, 540.0), [double]$work.Height)
    $windowBounds = @{
        Width = $windowWidth; Height = $windowHeight
        Left = $work.Left + (($work.Width - $windowWidth) / 2)
        Top = $work.Top + (($work.Height - $windowHeight) / 2)
    }
    $script:StartupContext = @{ Version = $version; Settings = $settings; WindowBounds = $windowBounds }
    Initialize-WintilityWindow -Version $version -Bounds $windowBounds

    $script:StartupQueue = New-Object System.Collections.Queue
    $script:StartupQueue.Enqueue([PSCustomObject]@{ Percent = 30; Text = 'Applying your preferences...'; Tab = $null; Action = {
        Set-UiTheme -Theme (Get-EffectiveTheme)
        $script:Ui.VersionText.Text = "$($script:StartupContext.Version.Product) $($script:StartupContext.Version.Version) $($script:StartupContext.Version.Edition)"
        $script:Ui.HomeTitle.Text = "$($script:StartupContext.Version.Product) $($script:StartupContext.Version.Version)"
        $script:Ui.HomeEdition.Text = $script:StartupContext.Version.Edition
        $script:Ui.HomeClock.Text = Get-ClockText
    }})
    $script:StartupQueue.Enqueue([PSCustomObject]@{ Percent = 50; Text = 'Checking permissions...'; Tab = $null; Action = {
        $script:IsAdmin = Test-WintilityAdmin
        if ($script:IsAdmin) { $script:Ui.AdminText.Text = 'Running elevated'; $script:Ui.ElevateCard.Visibility = 'Collapsed' }
        else { $script:Ui.AdminText.Text = 'Standard user. Tweaks that need administrator access are hidden.'; $script:Ui.ElevateNote.Text = "$(Get-HiddenTweakCount) more tweaks are hidden because they need administrator access." }
    }})
    $script:StartupQueue.Enqueue([PSCustomObject]@{ Percent = 54; Text = 'Preparing settings panels...'; Tab = $null; Action = {
        Initialize-AccentSwatches
        Update-PowerView
        Update-DnsAdapterList
        Update-DnsPermissions
        Update-MaintenancePanel
    }})
    $tabIndex = 0
    foreach ($tabName in $script:TabNames) {
        $tabIndex++
        $tabPercent = 54 + [int][math]::Floor(24 * $tabIndex / $script:TabNames.Count)
        $script:StartupQueue.Enqueue([PSCustomObject]@{ Percent = $tabPercent; Text = "Reading $tabName settings..."; Tab = $tabName; Action = {
            param($name)
            Update-TweakPanel -Tab $name
            if ($name -ne 'Personalization') {
                foreach ($item in $script:Ui.MainTabs.Items) {
                    if ($item.Header -eq $name) {
                        if ($script:Ui["Panel_$name"].Children.Count -eq 0) { $item.Visibility = 'Collapsed' }
                        else { $item.Visibility = 'Visible' }
                    }
                }
            }
        }})
    }
    $script:StartupQueue.Enqueue([PSCustomObject]@{ Percent = 82; Text = 'Reading system information...'; Tab = $null; Action = { Update-SystemInfoPanel }})
    $script:StartupQueue.Enqueue([PSCustomObject]@{ Percent = 94; Text = 'Preparing the window...'; Tab = $null; Action = {
        $settings = $script:StartupContext.Settings
        $script:Ui.FollowSystemRadio.IsChecked = ($settings.AppTheme -eq 'System')
        $script:Ui.LightRadio.IsChecked = ($settings.AppTheme -eq 'Light')
        $script:Ui.DarkRadio.IsChecked = ($settings.AppTheme -eq 'Dark')
        $script:Ui.ShowBackgroundBox.IsChecked = $settings.ShowBackground
        Set-BackgroundVisibility -Show $settings.ShowBackground
        $glassSupported = ((Get-WintilityEnvironment).WindowBuild -ge $script:GlassMinimumBuild)
        if ($glassSupported) { $script:Ui.GlassNote.Text = 'Uses the Windows 11 backdrop. If the window looks wrong, turn this off.' }
        else { $script:Ui.GlassBox.IsEnabled = $false; $script:Ui.GlassNote.Text = 'Needs Windows 11 (build 22621 or newer).' }
        $script:Ui.GlassBox.IsChecked = ($settings.Glass -and $glassSupported)
        if ($script:Ui.GlassBox.IsChecked) { Set-WindowGlass -Enable $true }
        $script:Ui.AnimationsBox.IsChecked = $settings.Animations
        Update-AnimationFlag
        Connect-UiEvents
        $script:StartupSettingsReady = $true
        $script:Timer.Start(); $script:ClockTimer.Start()
    }})
    $script:StartupTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:StartupTimer.Interval = [TimeSpan]::FromMilliseconds(40)
    $script:StartupTimer.Add_Tick({
        try {
            if ($script:StartupQueue.Count -gt 0) {
                $step = $script:StartupQueue.Dequeue()
                & $step.Action $step.Tab
                Update-SplashProgress -Percent $step.Percent -Text $step.Text
            }
            else {
                $script:StartupTimer.Stop()
                Update-SplashProgress -Percent 100 -Text 'Ready'
                if ($script:StartupReadyFile) {
                    try { New-Item -ItemType File -Path $script:StartupReadyFile -Force | Out-Null }
                    catch { Write-WintilityLog -Severity WARN -Module 'UI' -Message "The ready signal could not be written. $($_.Exception.Message)" }
                }
                Show-SplashLaunchPrompt
            }
        }
        catch {
            $script:StartupTimer.Stop()
            $script:StartupFailed = $true
            Write-WintilityLog -Severity ERROR -Module 'UI' -Message "Startup failed. $($_.Exception.Message)"
            $script:Ui.SplashStatus.Text = "Startup failed: $($_.Exception.Message)"
            $script:Window.Close()
        }
    })
    $script:Ui.LaunchButton.Add_Click({ Begin-SplashLaunch })
    $script:StartupTimer.Start()
    Update-SplashProgress -Percent 10 -Text 'Loading the interface...'
    [void]$script:Window.ShowDialog()

    if ($script:MainDialogCompleted) { return }
    if ($script:StartupFailed) { throw 'Wintility initialization failed. See the application log for details.' }
    throw 'Wintility startup was closed before Launch.'
}

Export-ModuleMember -Function Show-WintilityWindow
