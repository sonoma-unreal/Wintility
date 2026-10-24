# Wintility remote bootstrapper
# Downloads a pinned experimental release, verifies its SHA-256, then launches it.
# This script does not request elevation or change persistent execution-policy settings.

$ErrorActionPreference = 'Stop'

$Version = 'wintility-v0.1.0-alpha.1'
$AssetUri = 'https://github.com/wintility/Wintility-Experimental/releases/download/wintility-v0.1.0-alpha.1/Wintility.ps1'
$ExpectedSha256 = 'a3b00cb098d698a744382826977cd0ce5ca79072ed650fd94805bea67b5535d6'

Write-Host ''
Write-Host 'Wintility bootstrapper' -ForegroundColor Cyan
Write-Host "Release: $Version"
Write-Host 'Downloading the launcher from GitHub...'

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('Wintility-Bootstrap-' + [guid]::NewGuid().ToString('N'))
$LauncherPath = Join-Path $TempRoot 'Wintility.ps1'

try {
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

    # Windows PowerShell 5.1 may need TLS 1.2 explicitly on older systems.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    Invoke-WebRequest -Uri $AssetUri -OutFile $LauncherPath -UseBasicParsing

    $ActualSha256 = (Get-FileHash -LiteralPath $LauncherPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualSha256 -ne $ExpectedSha256) {
        throw "SHA-256 verification failed. Expected $ExpectedSha256 but received $ActualSha256. The launcher will NOT be run."
    }

    Write-Host 'SHA-256 verified.' -ForegroundColor Green
    Write-Host 'Starting Wintility...'

    # Use a child process so the application can perform its normal detached startup.
    # Bypass is limited to this child process; no persistent policy is changed.
    $Engine = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (-not $Engine) {
        $Engine = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    }
    if (-not $Engine) {
        throw 'Could not find powershell.exe or pwsh.exe.'
    }

    & $Engine.Source -NoProfile -STA -ExecutionPolicy Bypass -File $LauncherPath
    $LaunchExitCode = $LASTEXITCODE
    if ($LaunchExitCode -ne 0) {
        throw "Wintility launcher exited with code $LaunchExitCode."
    }

    Write-Host 'Wintility startup completed.' -ForegroundColor Green
}
catch {
    Write-Host ''
    Write-Host 'Wintility bootstrap failed:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
