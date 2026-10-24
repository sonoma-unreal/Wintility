# Logging: one plain-text file per run under %LOCALAPPDATA%\Wintility\Logs.
# Logging must never be the reason an operation fails, so write errors are swallowed.
# Never pass passwords, tokens or personal data to Write-WintilityLog.

$script:WintilityLogPath = $null

function Initialize-WintilityLog {
    [CmdletBinding()]
    param([string]$Path)
    $script:WintilityLogPath = $null
    if ($Path) {
        # The launcher starts the interface in a second process. It keeps writing to the same log.
        $script:WintilityLogPath = $Path
        return $script:WintilityLogPath
    }
    try {
        $directory = Join-Path $env:LOCALAPPDATA 'Wintility\Logs'
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
        $script:WintilityLogPath = Join-Path $directory "wintility_$stamp.log"
    }
    catch {
        $script:WintilityLogPath = $null
    }
    return $script:WintilityLogPath
}

function Write-WintilityLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')][string]$Severity,
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '{0} [{1}] [{2}] {3}' -f $timestamp, $Severity, $Module, $Message
    Write-Verbose $line
    if ($script:WintilityLogPath) {
        try {
            Add-Content -LiteralPath $script:WintilityLogPath -Value $line -Encoding UTF8
        }
        catch {
            Write-Verbose "Log write failed: $($_.Exception.Message)"
        }
    }
}
