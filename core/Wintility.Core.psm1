# Wintility.Core module loader.
# Core is the engine: logging, results, error boundaries, state, backup and config.
# Core contains no UI code and no feature-specific system changes.
Set-StrictMode -Version Latest

$coreFiles = @(
    'Version.ps1'
    'Compatibility.ps1'
    'Logging.ps1'
    'Result.ps1'
    'ErrorHandling.ps1'
    'State.ps1'
    'Backup.ps1'
    'Config.ps1'
    'AppSettings.ps1'
)

foreach ($file in $coreFiles) {
    . (Join-Path $PSScriptRoot $file)
}
