
# Wintility remote bootstrapper
# Downloads the pinned launcher and its runtime dependencies individually.
# Does not modify Wintility.ps1 or require administrator privileges.

$ErrorActionPreference = 'Stop'

$Version = 'wintility-5.1.1-glowstone'
$Repository = 'sonoma-unreal/Wintility'
$LauncherSha256 = '9b622f0b3c2a4b73dd6ec3de9a5f633d240b08da0ac8f9738c61eb61232b51b4'

$ReleaseUri = "https://github.com/$Repository/releases/download/$Version/Wintility.ps1"
$TreeUri = "https://api.github.com/repos/$Repository/git/trees/$Version`?recursive=1"
$RawBase = "https://raw.githubusercontent.com/$Repository/$Version"

$InstallRoot = Join-Path $env:LOCALAPPDATA 'Wintility'
$RuntimePath = Join-Path $InstallRoot $Version
$StagePath = Join-Path $InstallRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
$LauncherPath = Join-Path $RuntimePath 'Wintility.ps1'

$RuntimeDirectories = @(
    'assets/',
    'commands/',
    'config/',
    'core/',
    'ui/'
)

function Write-Status {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host $Message -ForegroundColor $Color
}

try {
    Write-Host ''
    Write-Status 'Wintility bootstrapper' Cyan
    Write-Status "Repository: $Repository"
    Write-Status "Release:    $Version"
    Write-Status 'Preparing the runtime files...'

    if (-not $env:LOCALAPPDATA) {
        throw 'LOCALAPPDATA is unavailable; cannot choose a per-user installation directory.'
    }

    # Windows PowerShell 5.1 may need TLS 1.2 explicitly.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

    # If this exact version is already installed and its launcher matches
    # the expected hash, reuse it without downloading the runtime again.
    if (Test-Path -LiteralPath $LauncherPath -PathType Leaf) {
        $ExistingHash = (Get-FileHash -LiteralPath $LauncherPath -Algorithm SHA256).Hash

        if ($ExistingHash -ieq $LauncherSha256) {
            Write-Status 'Verified existing launcher; reusing installed runtime.' Green
        }
        else {
            Write-Status 'Existing runtime needs to be refreshed.' Yellow
            Remove-Item -LiteralPath $RuntimePath -Recurse -Force
        }
    }

    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
        New-Item -ItemType Directory -Path $StagePath -Force | Out-Null

        Write-Status 'Retrieving the repository file tree...'
        $Tree = Invoke-RestMethod -Uri $TreeUri -Headers @{
            'User-Agent' = 'Wintility-Bootstrapper'
            'Accept'     = 'application/vnd.github+json'
        }

        if ($Tree.truncated) {
            throw 'GitHub returned a truncated repository tree; refusing to install an incomplete runtime.'
        }

        $RuntimeFiles = @(
            $Tree.tree | Where-Object {
                $_.type -eq 'blob' -and (
                    $_.path -eq 'Wintility.ps1' -or
                    @($RuntimeDirectories | Where-Object {
                        $_.path -like "$_*"
                    }).Count -gt 0
                )
            }
        )

        # The release asset is used for the launcher, not a raw repository copy.
        $RuntimeFiles = @($RuntimeFiles | Where-Object { $_.path -ne 'Wintility.ps1' })

        if ($RuntimeFiles.Count -eq 0) {
            throw 'No runtime files were found in the pinned repository tree.'
        }

        Write-Status "Downloading $($RuntimeFiles.Count) runtime files..."

        foreach ($File in $RuntimeFiles) {
            $RelativePath = [string]$File.path

            # Permit only the expected runtime directories.
            $IsRuntimeFile = $false
            foreach ($Directory in $RuntimeDirectories) {
                if ($RelativePath.StartsWith(
                    $Directory,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                    $IsRuntimeFile = $true
                    break
                }
            }

            if (-not $IsRuntimeFile) {
                continue
            }

            # Reject rooted paths or traversal components.
            if ([IO.Path]::IsPathRooted($RelativePath) -or
                $RelativePath -match '(^|/)\.\.(/|$)') {
                throw "Unsafe repository path encountered: $RelativePath"
            }

            $Destination = Join-Path $StagePath ($RelativePath -replace '/', '\')
            $Parent = Split-Path -Parent $Destination
            New-Item -ItemType Directory -Path $Parent -Force | Out-Null

            $EncodedPath = ($RelativePath -split '/' | ForEach-Object {
                [Uri]::EscapeDataString($_)
            }) -join '/'

            $FileUri = "$RawBase/$EncodedPath"
            Invoke-WebRequest -Uri $FileUri -OutFile $Destination -UseBasicParsing
        }

        # Download and verify the release launcher.
        Write-Status 'Downloading the pinned release launcher...'
        $StagedLauncher = Join-Path $StagePath 'Wintility.ps1'
        Invoke-WebRequest -Uri $ReleaseUri -OutFile $StagedLauncher -UseBasicParsing

        $ActualHash = (Get-FileHash -LiteralPath $StagedLauncher -Algorithm SHA256).Hash
        if ($ActualHash -ine $LauncherSha256) {
            throw "Launcher SHA-256 mismatch. Expected $LauncherSha256; received $ActualHash."
        }

        # Check the required structure before installing it.
        $RequiredFiles = @(
            'core\Wintility.Core.psm1',
            'ui\Wintility.UI.psm1',
            'ui\MainWindow.xaml',
            'ui\SplashWindow.xaml'
        )

        foreach ($Required in $RequiredFiles) {
            $RequiredPath = Join-Path $StagePath $Required
            if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
                throw "Required runtime file is missing: $Required"
            }
        }

        Write-Status 'Launcher SHA-256 verified.' Green

        # Install atomically by moving the staged directory into place.
        if (Test-Path -LiteralPath $RuntimePath) {
            Remove-Item -LiteralPath $RuntimePath -Recurse -Force
        }

        Move-Item -LiteralPath $StagePath -Destination $RuntimePath
        Write-Status 'Runtime installed.' Green
    }

    # Verify the launcher again immediately before execution.
    $FinalHash = (Get-FileHash -LiteralPath $LauncherPath -Algorithm SHA256).Hash
    if ($FinalHash -ine $LauncherSha256) {
        throw 'Installed launcher failed final SHA-256 verification.'
    }

    $Engine = if ($PSVersionTable.PSEdition -eq 'Desktop') {
        (Get-Command powershell.exe -ErrorAction SilentlyContinue)
    }
    else {
        (Get-Command pwsh.exe -ErrorAction SilentlyContinue)
    }

    if (-not $Engine) {
        $Engine = Get-Command powershell.exe -ErrorAction SilentlyContinue
    }
    if (-not $Engine) {
        $Engine = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    }
    if (-not $Engine) {
        throw 'Could not find powershell.exe or pwsh.exe.'
    }

    Write-Status 'Starting Wintility...' Cyan

    # Run the existing launcher without editing it. Its detached interface
    # remains able to access the persistent runtime directory.
    $Process = Start-Process `
        -FilePath $Engine.Source `
        -ArgumentList @(
            '-NoProfile',
            '-STA',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$LauncherPath`""
        ) `
        -WorkingDirectory $RuntimePath `
        -PassThru `
        -Wait

    if ($Process.ExitCode -ne 0) {
        throw "Wintility launcher exited with code $($Process.ExitCode). The runtime has been kept at: $RuntimePath"
    }

    Write-Status 'Wintility launcher completed.' Green
    Write-Status "Runtime location: $RuntimePath"
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
