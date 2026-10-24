# Personalization: wallpaper, light/dark mode, and accent color.
# Every change backs up the previous value, writes, and reads the value back.
# Some apps only pick up changes after a restart or sign-out, and the messages say so.
Set-StrictMode -Version Latest

Import-Module -Name (Join-Path $PSScriptRoot '..\core\Wintility.Core.psm1')

$script:PersonalizePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$script:DesktopPath = 'HKCU:\Control Panel\Desktop'
$script:DwmPath = 'HKCU:\Software\Microsoft\Windows\DWM'

function Initialize-WintilityNative {
    [CmdletBinding()]
    param()
    if (-not ('WintilityNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class WintilityNative
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);

    [DllImport("user32.dll", EntryPoint = "SystemParametersInfo", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SystemParametersInfoGet(uint uiAction, uint uiParam, StringBuilder pvParam, uint fWinIni);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

    // Tells Explorer that the contents of a folder changed so it redraws it.
    // SHCNE_UPDATEDIR (0x1000) with SHCNF_PATHW (0x0005) | SHCNF_FLUSH (0x1000).
    public static void RefreshShellFolder(string path)
    {
        IntPtr item = Marshal.StringToHGlobalUni(path);
        try
        {
            SHChangeNotify(0x00001000, 0x1005, item, IntPtr.Zero);
        }
        finally
        {
            Marshal.FreeHGlobal(item);
        }
    }
}
'@
    }
}

function Send-WintilitySettingChange {
    [CmdletBinding()]
    param(
        [string]$Area = 'ImmersiveColorSet',
        [uint32]$Parameter = 0
    )
    Initialize-WintilityNative
    $out = [UIntPtr]::Zero
    $wParam = [UIntPtr]::Zero
    if ($Parameter -ne 0) { $wParam = New-Object System.UIntPtr -ArgumentList ([uint32]$Parameter) }
    # Broadcast WM_SETTINGCHANGE (0x001A) to every top-level window.
    # SMTO_ABORTIFHUNG (0x0002) skips windows that are not responding.
    $reply = [WintilityNative]::SendMessageTimeout([IntPtr]0xFFFF, 0x001A, $wParam, $Area, 0x0002, 5000, [ref]$out)
    return ($reply.ToInt64() -ne 0)
}

function ConvertTo-WintilityDword {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$Value)
    return [BitConverter]::ToInt32([BitConverter]::GetBytes($Value), 0)
}

function Get-WintilitySystemTheme {
    [CmdletBinding()]
    param()
    $value = Get-WintilityRegistryValue -Path $script:PersonalizePath -Name 'AppsUseLightTheme'
    if ($value.Exists -and $value.Value -eq 0) { return 'Dark' }
    return 'Light'
}

function Set-WintilitySystemTheme {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Light', 'Dark')][string]$Mode)

    $value = 0
    if ($Mode -eq 'Light') { $value = 1 }
    $targets = @(
        @{ Path = $script:PersonalizePath; Name = 'AppsUseLightTheme' }
        @{ Path = $script:PersonalizePath; Name = 'SystemUsesLightTheme' }
    )

    return (Invoke-WintilityOperation -Id "Theme$Mode" -Module 'Personalization' -Action {
        $backup = New-WintilityBackup -Label 'Theme' -Targets $targets
        foreach ($target in $targets) {
            Set-WintilityRegistryValue -Path $target.Path -Name $target.Name -Kind 'DWord' -Value $value
        }
        [void](Send-WintilitySettingChange)
        foreach ($target in $targets) {
            $after = Get-WintilityRegistryValue -Path $target.Path -Name $target.Name
            if (-not $after.Exists -or $after.Value -ne $value) {
                throw "$($target.Name) did not read back as $value."
            }
        }
        New-WintilityResult -Id "Theme$Mode" -Name "$Mode mode" -Changed $true -Message "Windows set to $Mode mode. Backup: $backup. Some apps update only after a restart."
    })
}

function Set-WintilityAccentColor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$Argb)

    $value = ConvertTo-WintilityDword -Value $Argb
    $targets = @(@{ Path = $script:DwmPath; Name = 'ColorizationColor' })

    return (Invoke-WintilityOperation -Id 'AccentColor' -Module 'Personalization' -Action {
        $backup = New-WintilityBackup -Label 'AccentColor' -Targets $targets
        Set-WintilityRegistryValue -Path $script:DwmPath -Name 'ColorizationColor' -Kind 'DWord' -Value $value
        [void](Send-WintilitySettingChange)
        $after = Get-WintilityRegistryValue -Path $script:DwmPath -Name 'ColorizationColor'
        if (-not $after.Exists -or $after.Value -ne $value) {
            throw 'Accent color did not read back after writing.'
        }
        New-WintilityResult -Id 'AccentColor' -Name 'Accent color' -Changed $true -Message "Accent color set. Backup: $backup. Windows 11 may recolor some surfaces only after a sign-out."
    })
}

function Get-WintilityWallpaperInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
    $file = Get-Item -LiteralPath $Path
    $extension = $file.Extension.ToLowerInvariant()
    if (@('.jpg', '.jpeg', '.png', '.bmp') -notcontains $extension) {
        throw "Unsupported format '$extension'. Use JPG, PNG or BMP."
    }

    Add-Type -AssemblyName System.Drawing
    try {
        $image = [System.Drawing.Image]::FromFile($file.FullName)
    }
    catch {
        throw "That file could not be read as an image. It may be damaged, or it may not really be a $extension file."
    }
    try {
        $width = $image.Width
        $height = $image.Height
    }
    finally {
        $image.Dispose()
    }

    return [PSCustomObject]@{
        Name   = $file.Name
        Path   = $file.FullName
        Width  = $width
        Height = $height
        SizeKB = [math]::Round($file.Length / 1KB, 1)
    }
}

function Get-WintilityWallpaperApplyPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $file = Get-Item -LiteralPath $Path
    if ($file.Extension.ToLowerInvariant() -ne '.png') { return $file.FullName }

    # Windows wallpaper handling is most reliable with JPG, so PNG is converted to a staged JPG.
    # Transparent pixels come out black in the converted file.
    $directory = Join-Path $env:LOCALAPPDATA 'Wintility\Wallpaper'
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $target = Join-Path $directory ($file.BaseName + '.jpg')

    Add-Type -AssemblyName System.Drawing
    $image = [System.Drawing.Image]::FromFile($file.FullName)
    try {
        $saved = $false
        try {
            # The default JPG quality is 75, which shows banding on gradients. Ask for 95 instead.
            $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
            if ($null -ne $codec) {
                $parameters = New-Object System.Drawing.Imaging.EncoderParameters -ArgumentList 1
                $parameters.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter -ArgumentList ([System.Drawing.Imaging.Encoder]::Quality), ([long]95)
                $image.Save($target, $codec, $parameters)
                $saved = $true
            }
        }
        catch {
            Write-WintilityLog -Severity WARN -Module 'Personalization' -Message "High-quality JPG encoding failed, using the default encoder. $($_.Exception.Message)"
        }
        if (-not $saved) { $image.Save($target, [System.Drawing.Imaging.ImageFormat]::Jpeg) }
    }
    finally {
        $image.Dispose()
    }
    return $target
}

function Invoke-WallpaperPipeline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    Initialize-WintilityNative
    $notes = New-Object System.Collections.Generic.List[string]

    # 1. SystemParametersInfo(SPI_SETDESKWALLPAPER = 0x14).
    #    Flags: SPIF_UPDATEINIFILE (1) saves it to the profile, SPIF_SENDCHANGE (2) tells Windows.
    $applied = [WintilityNative]::SystemParametersInfo(0x14, 0, $Path, 3)
    if (-not $applied) {
        $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Windows rejected the wallpaper change (error $code)."
    }

    # 2. Ask Windows what the wallpaper is now (SPI_GETDESKWALLPAPER = 0x73).
    $confirmed = $false
    $expected = [System.IO.Path]::GetFileName($Path)
    for ($attempt = 0; $attempt -lt 10 -and -not $confirmed; $attempt++) {
        $buffer = New-Object System.Text.StringBuilder -ArgumentList 520
        if ([WintilityNative]::SystemParametersInfoGet(0x73, [uint32]$buffer.Capacity, $buffer, 0)) {
            $confirmed = ([System.IO.Path]::GetFileName($buffer.ToString()) -ieq $expected)
        }
        if (-not $confirmed) { Start-Sleep -Milliseconds 100 }
    }
    if (-not $confirmed) { $notes.Add('Could not confirm the new wallpaper path. This can be normal on some Windows builds.') }

    # 3. Ask Windows to re-read the per-user settings. This is what makes it reload a replaced file.
    try {
        Start-Process -FilePath 'rundll32.exe' -ArgumentList 'user32.dll,UpdatePerUserSystemParameters 1, True' -WindowStyle Hidden -Wait
    }
    catch {
        $notes.Add("The settings refresh did not run: $($_.Exception.Message)")
    }

    # 4. Broadcast the setting change so running windows reload the wallpaper.
    if (-not (Send-WintilitySettingChange -Area 'Control Panel\Desktop' -Parameter 0x14)) {
        $notes.Add('Some windows did not answer the setting-change broadcast.')
    }

    # 5. SHChangeNotify: tell Explorer to refresh the desktop.
    try {
        [WintilityNative]::RefreshShellFolder([Environment]::GetFolderPath('Desktop'))
    }
    catch {
        $notes.Add("The desktop refresh notification failed: $($_.Exception.Message)")
    }

    return [PSCustomObject]@{ Confirmed = $confirmed; Notes = $notes.ToArray() }
}

function Get-WintilityThemesDirectory {
    [CmdletBinding()]
    param()
    return (Join-Path $env:APPDATA 'Microsoft\Windows\Themes')
}

function Copy-WintilityTranscodedWallpaper {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source)
    $directory = Get-WintilityThemesDirectory
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    # The copy has no file extension, which is how Windows names its own wallpaper cache.
    # The original image is only copied, never renamed or moved.
    $target = Join-Path $directory 'TranscodedWallpaper'
    Copy-Item -LiteralPath $Source -Destination $target -Force -ErrorAction Stop
    return $target
}

function Get-WintilityBackupStamp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupFile)
    # Backup files are named <yyyy-MM-dd_HH-mm-ss>_<label>.<ext>. The stamp ties related backups together.
    $name = [System.IO.Path]::GetFileName($BackupFile)
    if ($name -notmatch '^(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})_') { throw "Unexpected backup file name: $name" }
    return $Matches[1]
}

function Backup-WintilityTranscodedWallpaper {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Stamp)
    $current = Join-Path (Get-WintilityThemesDirectory) 'TranscodedWallpaper'
    if (-not (Test-Path -LiteralPath $current)) { return $null }
    $directory = Get-WintilityBackupDirectory
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $file = Join-Path $directory "${Stamp}_TranscodedWallpaper.bak"
    Copy-Item -LiteralPath $current -Destination $file -Force

    # Each copy is a whole image, so keep only the five newest.
    Get-ChildItem -LiteralPath $directory -Filter '*_TranscodedWallpaper.bak' |
        Sort-Object Name -Descending | Select-Object -Skip 5 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    return $file
}

function Restore-WintilityTranscodedWallpaper {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Stamp)
    # Only the copy made at the same moment as the registry backup is valid. Never use an older one.
    $backup = Join-Path (Get-WintilityBackupDirectory) "${Stamp}_TranscodedWallpaper.bak"
    if (-not (Test-Path -LiteralPath $backup)) { return $false }
    $target = Join-Path (Get-WintilityThemesDirectory) 'TranscodedWallpaper'
    Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction Stop
    return $true
}

function Set-WintilityWallpaper {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $info = Get-WintilityWallpaperInfo -Path $Path
    $source = Get-WintilityWallpaperApplyPath -Path $info.Path
    $targets = @(@{ Path = $script:DesktopPath; Name = 'Wallpaper' })

    return (Invoke-WintilityOperation -Id 'Wallpaper' -Module 'Personalization' -Action {
        $registryBackup = New-WintilityBackup -Label 'Wallpaper' -Targets $targets
        $stamp = Get-WintilityBackupStamp -BackupFile $registryBackup
        [void](Backup-WintilityTranscodedWallpaper -Stamp $stamp)

        $notes = New-Object System.Collections.Generic.List[string]
        $method = 'through TranscodedWallpaper'
        try {
            $applyPath = Copy-WintilityTranscodedWallpaper -Source $source
        }
        catch {
            $notes.Add("Could not replace TranscodedWallpaper ($($_.Exception.Message)). Applied the image directly instead.")
            $applyPath = $source
            $method = 'directly'
        }

        $outcome = Invoke-WallpaperPipeline -Path $applyPath
        foreach ($note in $outcome.Notes) { $notes.Add($note) }
        $warning = $null
        if ($notes.Count -gt 0) { $warning = $notes -join ' ' }
        New-WintilityResult -Id 'Wallpaper' -Name $info.Name -Changed $true -Warning $warning -Message "Wallpaper set to $($info.Name) ($($info.Width) x $($info.Height)) $method. Backup: $registryBackup"
    })
}

function Restore-WintilityWallpaper {
    [CmdletBinding()]
    param()

    $registryBackup = Get-WintilityLatestBackup -Label 'Wallpaper'
    if (-not $registryBackup) {
        return (New-WintilityResult -Id 'WallpaperRestore' -Name 'Wallpaper' -Skipped $true -Message 'No wallpaper backup found. Nothing to restore.')
    }
    $stamp = Get-WintilityBackupStamp -BackupFile $registryBackup

    return (Invoke-WintilityOperation -Id 'WallpaperRestore' -Module 'Personalization' -Action {
        $notes = New-Object System.Collections.Generic.List[string]
        try {
            [void](Restore-WintilityTranscodedWallpaper -Stamp $stamp)
        }
        catch {
            $notes.Add("Could not put back the previous TranscodedWallpaper file: $($_.Exception.Message)")
        }

        $summary = Restore-WintilityBackup -BackupFile $registryBackup
        if ($summary.Failed -gt 0) {
            throw "The previous wallpaper setting could not be restored ($($summary.Headline))."
        }
        $previous = Get-WintilityRegistryValue -Path $script:DesktopPath -Name 'Wallpaper'
        if ($previous.Exists -and $previous.Value -and (Test-Path -LiteralPath ([string]$previous.Value))) {
            $outcome = Invoke-WallpaperPipeline -Path ([string]$previous.Value)
            foreach ($note in $outcome.Notes) { $notes.Add($note) }
            $message = "Previous wallpaper restored. $($summary.Headline)"
        }
        else {
            $message = 'The backup was restored, but the previous wallpaper file is gone. Choose a new one.'
        }
        $warning = $null
        if ($notes.Count -gt 0) { $warning = $notes -join ' ' }
        New-WintilityResult -Id 'WallpaperRestore' -Name 'Wallpaper' -Changed $true -Warning $warning -Message $message
    })
}

