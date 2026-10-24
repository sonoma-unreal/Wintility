#requires -Version 5.1
<#
.SYNOPSIS
    Wintility launcher.
.DESCRIPTION
    Checks that everything is in order, then starts the interface in its own window-less process.
    As soon as the Wintility window is up, this console closes. If something goes wrong the console
    stays open with the details, so the launcher never just disappears.
    Use -CheckOnly to verify the core without opening the window.
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    # Used internally. The launcher starts itself again without a console window, and that copy shows the interface.
    [switch]$Detached,
    [string]$ReadyFile,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$stage = 'Compatibility check'
$logFile = $null

try {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "PowerShell 5.1 or newer is required. Found $($PSVersionTable.PSVersion)."
    }

    $stage = 'Core load'
    Import-Module -Name (Join-Path $PSScriptRoot 'core\Wintility.Core.psm1') -Force

    $stage = 'Configuration root'
    Set-WintilityRoot -Path $PSScriptRoot

    $stage = 'Logging'
    $logFile = Initialize-WintilityLog -Path $LogPath
    $version = Get-WintilityVersion
    $banner = "$($version.Product) $($version.Version) $($version.Edition)"
    Write-WintilityLog -Severity INFO -Module 'Startup' -Message "$banner starting."

    $stage = 'Environment detection'
    $envInfo = Get-WintilityEnvironment

    $stage = 'Configuration validation'
    $configProblems = @()
    foreach ($name in (Get-WintilityConfigNames)) {
        $config = Get-WintilityConfig -Name $name
        if (-not $config.Success) { $configProblems += $config.Problems }
    }
    if ($configProblems.Count -eq 0) {
        $configProblems = @(Test-WintilityPresetReferences)
    }
    if ($configProblems.Count -gt 0) {
        Write-WintilityLog -Severity ERROR -Module 'Config' -Message ($configProblems -join ' | ')
        throw ('Configuration is invalid:' + [Environment]::NewLine + ($configProblems -join [Environment]::NewLine))
    }

    if ($CheckOnly) {
        Write-Host ''
        Write-Host $banner -ForegroundColor Cyan
        Write-Host "[PASS] PowerShell $($envInfo.PowerShellVersion)"
        Write-Host '[PASS] Core modules loaded'
        Write-Host "[PASS] Configuration valid ($((Get-WintilityConfigNames) -join ', '))"
        Write-Host "[INFO] Windows: $($envInfo.IsWindowsOS)   Administrator: $($envInfo.IsAdmin)"
        Write-Host "[INFO] Log: $logFile"
        exit 0
    }

    if (-not $Detached) {
        # Everything checked out. Start the interface in its own process with no console window and
        # wait until its window is up. Then this console can close while Wintility keeps running.
        # The interface process is always started in STA mode, which WPF windows require.
        $stage = 'Starting the interface'
        $signal = Join-Path ([System.IO.Path]::GetTempPath()) ('wintility-ready-{0}.flag' -f [guid]::NewGuid().ToString('N'))
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = (Get-Process -Id $PID).Path
        $start.Arguments = '-STA -NoProfile -ExecutionPolicy Bypass -File "{0}" -Detached -ReadyFile "{1}" -LogPath "{2}"' -f $PSCommandPath, $signal, $logFile
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.WorkingDirectory = $PSScriptRoot
        $child = [System.Diagnostics.Process]::Start($start)

        $deadline = (Get-Date).AddSeconds(60)
        while (-not (Test-Path -LiteralPath $signal) -and -not $child.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 150
        }
        if (Test-Path -LiteralPath $signal) {
            Remove-Item -LiteralPath $signal -Force -ErrorAction SilentlyContinue
            exit 0
        }
        if ($child.HasExited) {
            throw "Wintility stopped while starting (exit code $($child.ExitCode)). A message with the details was shown, and they are in the log."
        }
        throw 'Wintility is taking more than a minute to start. Check the log.'
    }

    $stage = 'User interface'
    Import-Module -Name (Join-Path $PSScriptRoot 'ui\Wintility.UI.psm1')
    Show-WintilityWindow -ReadyFile $ReadyFile
    exit 0
}
catch {
    $problem = $_.Exception.Message
    Write-Host ''
    Write-Host 'Wintility could not start.' -ForegroundColor Red
    Write-Host "Stage: $stage"
    Write-Host "Error: $problem"
    Write-Host "Log:   $logFile"
    if ($Detached) {
        # This copy has no console, so show the problem in a window the user can actually see.
        try {
            Add-Type -AssemblyName PresentationFramework
            [void][System.Windows.MessageBox]::Show(
                "Stage: $stage`nError: $problem`nLog: $logFile",
                'Wintility could not start',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error)
        }
        catch {
            Write-Host 'The error window could not be shown either.'
        }
    }
    exit 1
}
