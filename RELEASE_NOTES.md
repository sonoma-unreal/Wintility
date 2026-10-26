# Wintility 5.2 Fall Update

## Highlights

- Startup now uses one main window at the user's saved dimensions. Initialization progress animates in place, and Launch crossfades into the ready interface without a window resize or second-window swap.
- Refined the interface with animated switches, themed rounded scrollbars, directional tab transitions, and corrected icon geometry. Public Windows checkouts use the native Segoe UI Variable fallback; local SF Pro files are excluded from Git because their license does not allow bundling in this Windows app.
- Added a toolbar log viewer, removed the bottom status strip, and added a Codex credit with its supplied icon.
- Fixed Power plan detection when `powercfg /list` begins with an empty line.
- Added per-adapter DNS selection for Cloudflare, Google, Quad9, AdGuard, and custom IPv4/IPv6 resolvers, optional native DNS-over-HTTPS, automatic DHCP restore, and DNS cache flushing.

## Verification

Checked on Windows PowerShell 5.1 and PowerShell 7:

- `Wintility.ps1 -CheckOnly` — passed on both versions.
- `tests\SmokeTest.ps1` — passed on both versions.
- `tests\RegistryRoundTripTest.ps1` — passed on both versions; its temporary registry key was cleaned up.
- `tests\validate_config.py` — passed for 83 tweaks.

The WPF window started with the 5.2 Fall Update title. The Launch crossfade and final layouts still need a manual visual check before release; the test suite does not automate those interactions.
