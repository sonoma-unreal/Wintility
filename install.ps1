
#requires -Version 5.1
<#
.SYNOPSIS
    Wintility remote bootstrapper.
.DESCRIPTION
    Downloads the pinned Wintility release launcher and its runtime files
    individually from the specified GitHub repository. Preserves the
    directory structure required by Wintility.ps1.

    Does not modify Wintility.ps1, request elevation, or change persistent
    execution-policy settings.
#>

$ErrorActionPreference = 'Stop'

$Version = 'wintility-5.2-fall-update'
$Repository = 'sonoma-unreal/Wintility'
$ExpectedSha256 = '9b622f0b3c2a4b73dd6ec3de9a5f633d240b08da0ac8f9738c61eb61232b51b4'

$ReleaseUri = "https://github.com/$Repository/releases/download/$Version/Wintility.ps1"
$TreeUri = "https://api.github.com/repos/$Repository/git/trees/$Version" + '?recursive=1'
$RawBase = "https://raw.githubusercontent.com/$Repository/$Version"

$InstallRoot = Join-Path $env:LOCALAPPDATA 'Wintility'
$RuntimePath = Join-Path $InstallRoot $Version
$StagePath = Join-Path $InstallRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
$LauncherPath = Join-Path $RuntimePath 'Wintility.ps1'

$RuntimeDirectories = @(
    'assets/'
    'commands/'
    'config/'
    'core/'
    'ui/'
)

$RequiredFiles = @(
    'Wintility.ps1'
    'assets\background.png'
    'assets\icons\codex.png'
    'assets\icons\lucide.xaml'
    'commands\Wintility.Personalization.psm1'
    'commands\Wintility.Power.psm1'
    'commands\Wintility.Settings.psm1'
    'commands\Wintility.Shell.psm1'
    'commands\Wintility.SystemInfo.psm1'
    'commands\Wintility.Network.psm1'
    'commands\Wintility.Maintenance.psm1'
    'config\ads.json'
    'config\debloat.json'
    'config\internet.json'
    'config\performance.json'
    'config\personalization.json'
    'config\presets.json'
    'config\privacy.json'
    'config\storage.json'
    'core\Wintility.Core.psm1'
    'ui\MainWindow.xaml'
    'ui\CustomDnsDialog.xaml'
    'ui\SplashWindow.xaml'
    'ui\Wintility.UI.psm1'
)

function Write-Status {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host $Message -ForegroundColor $Color
}

function Test-WintilityRuntime {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    foreach ($RelativePath in $RequiredFiles) {
        $FullPath = Join-Path $Path $RelativePath

        if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
            return $false
        }
    }

    $InstalledLauncher = Join-Path $Path 'Wintility.ps1'

    if (-not (Test-Path -LiteralPath $InstalledLauncher -PathType Leaf)) {
        return $false
    }

    $Hash = (Get-FileHash -LiteralPath $InstalledLauncher -Algorithm SHA256).Hash
    return ($Hash -ieq $ExpectedSha256)
}

try {
    Write-Host ''
    Write-Status 'Wintility bootstrapper' Cyan
    Write-Status "Repository: $Repository"
    Write-Status "Release:    $Version"
    Write-Status 'Preparing runtime...'

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable. Cannot select a per-user installation directory.'
    }

    # Enable TLS 1.2 for older Windows PowerShell 5.1 installations.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor
            [Net.SecurityProtocolType]::Tls12
    }

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

    # Reuse the installation only when all required files are present
    # and the launcher's pinned SHA-256 hash matches.
    if (Test-WintilityRuntime -Path $RuntimePath) {
        Write-Status 'Existing runtime verified.' Green
    }
    else {
        Write-Status 'Existing runtime is incomplete or outdated.'
        Write-Status 'Retrieving the pinned repository tree...'

        New-Item -ItemType Directory -Path $StagePath -Force | Out-Null

        $Headers = @{
            'User-Agent' = 'Wintility-Bootstrapper'
            'Accept'     = 'application/vnd.github+json'
        }

        $Tree = Invoke-RestMethod -Uri $TreeUri -Headers $Headers

        if ($Tree.truncated) {
            throw 'GitHub returned a truncated repository tree. Installation stopped to avoid an incomplete runtime.'
        }

        if (-not $Tree.tree) {
            throw 'GitHub returned an empty repository tree. Check that the release tag exists.'
        }

        # Download files from the runtime directories only.
        # Important: $RepoPath is the path of each GitHub tree entry.
        $RuntimeFiles = @(
            foreach ($Entry in $Tree.tree) {
                if ($Entry.type -ne 'blob') {
                    continue
                }

                $RepoPath = [string]$Entry.path
                $IsRuntimeFile = $false

                foreach ($Directory in $RuntimeDirectories) {
                    if ($RepoPath.StartsWith(
                        $Directory,
                        [StringComparison]::OrdinalIgnoreCase
                    )) {
                        $IsRuntimeFile = $true
                        break
                    }
                }

                if ($IsRuntimeFile) {
                    $Entry
                }
            }
        )

        if ($RuntimeFiles.Count -eq 0) {
            throw "No runtime files were found for tag '$Version'. Verify that this tag contains the expected runtime directories."
        }

        Write-Status "Found $($RuntimeFiles.Count) runtime files."
        Write-Status 'Downloading runtime files individually...'

        $DownloadedCount = 0

        foreach ($Entry in $RuntimeFiles) {
            $RelativePath = [string]$Entry.path

            # Guard against rooted paths and directory traversal.
            if ([IO.Path]::IsPathRooted($RelativePath) -or
                $RelativePath -match '(^|/)\.\.(/|$)' -or
                $RelativePath.Contains('\')) {
                throw "Unsafe path returned by GitHub: $RelativePath"
            }

            $Destination = Join-Path $StagePath ($RelativePath -replace '/', '\')
            $ParentDirectory = Split-Path -Parent $Destination

            New-Item -ItemType Directory -Path $ParentDirectory -Force |
                Out-Null

            # Encode each URL path segment separately.
            $EncodedPath = (
                $RelativePath -split '/' |
                    ForEach-Object { [Uri]::EscapeDataString($_) }
            ) -join '/'

            $FileUri = "$RawBase/$EncodedPath"

            Invoke-WebRequest `
                -Uri $FileUri `
                -OutFile $Destination `
                -UseBasicParsing

            $DownloadedCount++

            if (($DownloadedCount % 5) -eq 0 -or
                $DownloadedCount -eq $RuntimeFiles.Count) {
                Write-Status "Downloaded $DownloadedCount / $($RuntimeFiles.Count)"
            }
        }

        # Fetch the actual release asset for the launcher.
        Write-Status 'Downloading pinned release launcher...'

        $StagedLauncher = Join-Path $StagePath 'Wintility.ps1'

        Invoke-WebRequest `
            -Uri $ReleaseUri `
            -OutFile $StagedLauncher `
            -UseBasicParsing

        $ActualHash = (
            Get-FileHash -LiteralPath $StagedLauncher -Algorithm SHA256
        ).Hash

        if ($ActualHash -ine $ExpectedSha256) {
            throw "Launcher SHA-256 verification failed. Expected $ExpectedSha256; received $ActualHash. The launcher will not run."
        }

        Write-Status 'Launcher SHA-256 verified.' Green

        # Verify every required runtime file before installing.
        if (-not (Test-WintilityRuntime -Path $StagePath)) {
            $MissingFiles = @(
                foreach ($RelativePath in $RequiredFiles) {
                    $CheckPath = Join-Path $StagePath $RelativePath

                    if (-not (Test-Path -LiteralPath $CheckPath -PathType Leaf)) {
                        $RelativePath
                    }
                }
            )

            if ($MissingFiles.Count -gt 0) {
                throw "Required runtime files are missing:`n$($MissingFiles -join "`n")"
            }

            throw 'The staged runtime failed its integrity check.'
        }

        # Move the completed stage into place. Keep the stage if installation
        # fails so that the previous runtime is not deleted prematurely.
        $PreviousPath = Join-Path $InstallRoot ('.previous-' + [guid]::NewGuid().ToString('N'))

        if (Test-Path -LiteralPath $RuntimePath) {
            Move-Item -LiteralPath $RuntimePath -Destination $PreviousPath
        }

        try {
            Move-Item -LiteralPath $StagePath -Destination $RuntimePath
        }
        catch {
            if (Test-Path -LiteralPath $PreviousPath) {
                Move-Item -LiteralPath $PreviousPath -Destination $RuntimePath
            }

            throw
        }

        if (Test-Path -LiteralPath $PreviousPath) {
            Remove-Item -LiteralPath $PreviousPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Status 'Runtime installed and verified.' Green
    }

    # Final verification immediately before launch.
    if (-not (Test-WintilityRuntime -Path $RuntimePath)) {
        throw 'The installed runtime failed final verification.'
    }

    $LauncherPath = Join-Path $RuntimePath 'Wintility.ps1'

    # Prefer Windows PowerShell 5.1 for compatibility with the existing WPF launcher.
    $Engine = Get-Command powershell.exe -ErrorAction SilentlyContinue

    if (-not $Engine) {
        $Engine = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    }

    if (-not $Engine) {
        throw 'Could not find powershell.exe or pwsh.exe.'
    }

    Write-Status 'Starting Wintility...' Cyan

    # Wintility.ps1 starts its own detached UI process and exits when ready.
    # The runtime remains installed so the detached process can load its files.
    $Process = Start-Process `
        -FilePath $Engine.Source `
        -ArgumentList @(
            '-NoProfile'
            '-STA'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            "`"$LauncherPath`""
        ) `
        -WorkingDirectory $RuntimePath `
        -PassThru `
        -Wait

    if ($Process.ExitCode -ne 0) {
        throw "Wintility launcher exited with code $($Process.ExitCode). Runtime retained at: $RuntimePath"
    }

    Write-Status 'Wintility launcher completed.' Green
    Write-Status "Runtime: $RuntimePath"
}
catch {
    Write-Host ''
    Write-Status 'Wintility bootstrap failed:' Red
    Write-Status $_.Exception.Message Red
    throw
}
finally {
    if (Test-Path -LiteralPath $StagePath) {
        Remove-Item -LiteralPath $StagePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
