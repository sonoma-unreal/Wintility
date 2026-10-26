# Wintility 5.2 Fall Update

A Windows tweak utility with a macOS-style window, one switch per tweak, and a backup before every change. It runs on Windows PowerShell 5.1 and PowerShell 7, and it is built to be useful on a PC where you are **not** an administrator, such as a school laptop.

See [RELEASE_NOTES.md](RELEASE_NOTES.md) for this update's highlights and verification status.

## Run

Double-click `Launch Wintility.cmd`. Wintility checks everything, opens its window, and the console closes by itself. If something is wrong the console stays open with the details. You can also run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Wintility.ps1
powershell -ExecutionPolicy Bypass -File .\Wintility.ps1 -CheckOnly
powershell -ExecutionPolicy Bypass -File .\tests\SmokeTest.ps1
powershell -ExecutionPolicy Bypass -File .\tests\RegistryRoundTripTest.ps1
```

```bash
python3 tests/validate_config.py
```

## Standard user or administrator

- **Standard session (no admin):** only tweaks that change your own settings (HKCU) are shown. Tweaks that need administrator access are not shown at all, and a tab with nothing left to show is hidden. Settings tells you how many are hidden.
- **Administrator session:** everything is shown. Settings, then Restart as administrator, relaunches with elevation (a school or work PC may block that).

## Tabs

Every tab uses the same layout as Settings: a page header, labelled sections, and rounded cards with an icon tile, a title, a description and the control on the right. Each tweak row also shows its risk and whether it needs a sign-out, a restart, or applies live.

Personalization, Performance, Power, Ads, Privacy, Internet, Storage, Debloat, System Information and Credits. Tweaks are grouped by category inside each tab. Every tweak shows its risk level and whether it needs a sign-out, a restart, or a File Explorer restart.

The Internet tab includes Windows and Edge network tweaks, DNS selection for a connected adapter (Cloudflare, Google, Quad9, AdGuard, or custom IPv4/IPv6 servers), optional native DNS-over-HTTPS setup on supported Windows versions, DHCP DNS restore, and DNS cache flushing. Applying DNS changes requires administrator access.

## How a tweak behaves

- **Switch on:** backs up the current values, writes the new ones, reads each back to confirm. If any value fails, everything is rolled back.
- **Switch off:** restores the newest backup for that tweak. If Wintility never changed it (it was already on), it resets to the Windows default stored in the config, when one is known.
- A tweak can change several registry values at once. Every one of them is checked together.
- Nothing is uninstalled or deleted. Debloat switches change settings or policies, and every one can be reverted.
- Taskbar, desktop and File Explorer tweaks refresh the desktop live, without restarting Explorer. The switch moves first, then the refresh runs in the background (broadcast the change, ask Explorer to redraw, refresh the desktop and open File Explorer windows), so a switch never waits for it. Only if that live refresh cannot run does Wintility restart File Explorer as a fallback. Some taskbar tweaks may still need a restart to show; Settings, then Restart File Explorer, does that (it closes File Explorer windows and nothing else).
- Switches glide between off (red) and on (green). The knob finishes moving before Wintility writes to the registry, so the animation is never cut short, and quick clicks collapse into the last position.
- A switch always shows what the registry really says. If a change fails or is skipped, the switch slides back and the message under it turns red or amber.

## Icons

The interface uses [Lucide](https://lucide.dev/) icons. They are bundled in `assets/icons/lucide.xaml`, so Wintility never downloads them and works with no internet. Lucide is released under the ISC license, and its notice is in `assets/icons/LICENSE.txt`.

## Power tab

Three boxes: Maximum Power Savings, Balanced and High Performance. Click one to switch plans. Double-click High Performance to try **Ultimate Performance**, which is experimental: the box gets an orange glow and an orange warning. Double-click again to go back. Switching between plans your PC already lists works without administrator access. Creating High Performance or Ultimate Performance when your PC does not list them needs administrator access. Wintility remembers the plan your PC started with, and Restore my original plan puts it back.

## Startup

The loading screen uses the main window at its saved size. While Wintility prepares the interface, the background drifts and rotates gently and the progress bar follows initialization steps. When setup is ready, Launch crossfades into the main interface in the same window.

## Config format

One JSON file per tab in `config/`. A setting looks like this (`registry` can be one object or a list):

```json
{
  "id": "ShowSecondsInClock",
  "name": "Show seconds in the taskbar clock",
  "description": "Adds seconds to the clock in the system tray.",
  "tab": "Personalization",
  "category": "Taskbar",
  "risk": "Low",
  "action": "registry",
  "requiresAdmin": false,
  "requiresRestart": false,
  "requiresLogoff": false,
  "requiresExplorerRestart": true,
  "reversible": true,
  "enabledByDefault": false,
  "registry": [
    { "path": "HKCU:\\Software\\...\\Explorer\\Advanced", "name": "ShowSecondsInSystemClock",
      "type": "DWord", "appliedValue": 1, "defaultValue": 0 }
  ]
}
```

- `defaultValue` is what Windows uses when the tweak is off. Use `"removeOnRevert": true` instead when the normal state is that the value does not exist.
- `requiresExplorerRestart` marks a tweak that only shows once the shell redraws. Wintility refreshes the desktop live and restarts File Explorer only if that fails.
- Any value under `HKLM:` must set `"requiresAdmin": true`. The loader refuses the config otherwise, so a standard session can never be shown a switch that cannot work.
- The tweak structure follows the ideas in the [WinUtil architecture reference](https://winutil.christitus.com/code-reference/architecture/) (declarative JSON, original and default values for undo). Wintility is its own project and does not copy WinUtil's code.

## Folders

| Folder | Purpose |
|---|---|
| `core/` | Engine: logging, results, error boundaries, registry helpers, backup/restore, config, app settings |
| `commands/` | Features: settings engine, shell refresh, power plans, personalization (wallpaper, mode, accent), system information |
| `config/` | The tweak definitions, one file per tab, plus presets |
| `ui/` | WPF main window, in-window startup overlay, and the code that connects them to the commands |
| `assets/` | Images |
| `tests/` | Smoke test, registry round-trip test, offline config validator |

## Wallpaper

```
chosen image (PNG is converted to a high-quality JPG first)
  -> backup: current registry value + current TranscodedWallpaper file
  -> copy the image, without an extension, to %APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper
  -> SystemParametersInfo(SPI_SETDESKWALLPAPER), confirmed with SPI_GETDESKWALLPAPER
  -> UpdatePerUserSystemParameters -> broadcast WM_SETTINGCHANGE -> SHChangeNotify on the Desktop folder
```

Your original image is copied, never renamed or moved. If TranscodedWallpaper cannot be replaced, Wintility applies the image directly and says so. Restore previous puts back both the registry value and the old TranscodedWallpaper file (only the five newest copies are kept).

## Verification

The current source snapshot was checked on Windows PowerShell 5.1 and PowerShell 7:

- `Wintility.ps1 -CheckOnly` passed on both versions.
- `tests\SmokeTest.ps1` passed on both versions, including PowerShell parsing, config loading, icon lookup, and XAML loading.
- `tests\RegistryRoundTripTest.ps1` passed on both versions using its temporary `HKCU:\Software\WintilityTest` key.
- `tests\validate_config.py` passed for all 83 tweaks; 19 are admin-only and hidden in a standard session.

The application window started with the 5.2 Fall Update title. The automated checks do not exercise the Launch crossfade or visually inspect layouts, so check those manually on supported Windows/PowerShell versions before publishing.
