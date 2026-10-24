# Shell refresh. After a taskbar, desktop or File Explorer tweak, Windows still shows the old state
# until Explorer re-reads its settings. This module asks Explorer to do that live, with no restart.
# Restarting File Explorer is only the fallback, used when the live refresh cannot run.
# The interface runs the refresh in a background runspace, so a switch never waits for it.
Set-StrictMode -Version Latest

Import-Module -Name (Join-Path $PSScriptRoot '..\core\Wintility.Core.psm1')

# Kept as its own type, separate from the wallpaper and theme code, so a problem here can never affect them.
$script:ShellNativeSource = @'
using System;
using System.Runtime.InteropServices;

public static class WintilityShellNative
{
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string className, string windowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowName);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    // Tells every top-level window that a setting changed.
    // SMTO_ABORTIFHUNG (0x2) skips windows that are not responding.
    public static bool Broadcast(string area)
    {
        UIntPtr result;
        IntPtr reply = SendMessageTimeout((IntPtr)0xFFFF, 0x001A, UIntPtr.Zero, area, 0x0002, 1000, out result);
        return reply != IntPtr.Zero;
    }

    // SHCNE_ASSOCCHANGED (0x08000000) with SHCNF_FLUSH (0x1000): Explorer redraws icons and open folder views.
    public static void NotifyAssocChanged()
    {
        SHChangeNotify(0x08000000, 0x1000, IntPtr.Zero, IntPtr.Zero);
    }

    // Finds the window that draws the desktop icons.
    private static IntPtr FindDesktopView()
    {
        IntPtr view = FindWindowEx(FindWindow("Progman", null), IntPtr.Zero, "SHELLDLL_DefView", null);
        if (view != IntPtr.Zero) { return view; }
        IntPtr worker = IntPtr.Zero;
        while (true)
        {
            worker = FindWindowEx(IntPtr.Zero, worker, "WorkerW", null);
            if (worker == IntPtr.Zero) { return IntPtr.Zero; }
            view = FindWindowEx(worker, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (view != IntPtr.Zero) { return view; }
        }
    }

    // Sends the Refresh command (0x7103) to the desktop view, the same as right-click > Refresh.
    public static bool RefreshDesktop()
    {
        IntPtr view = FindDesktopView();
        if (view == IntPtr.Zero) { return false; }
        return PostMessage(view, 0x0111, (IntPtr)0x7103, IntPtr.Zero);
    }
}
'@

# The whole live refresh. It uses nothing from the rest of Wintility, so it can also run in a
# background runspace while the window stays responsive.
$script:ShellRefreshWork = {
    param([string]$NativeSource)
    $notes = New-Object System.Collections.Generic.List[string]
    try {
        if (-not ('WintilityShellNative' -as [type])) { Add-Type -TypeDefinition $NativeSource }
    }
    catch {
        return [PSCustomObject]@{ Refreshed = $false; Notes = @("The shell refresh could not start: $($_.Exception.Message)") }
    }

    $refreshed = $true

    # 1. Tell Explorer and running apps which kind of setting changed.
    foreach ($area in @('ShellState', 'TraySettings', 'Policy')) {
        try {
            if (-not [WintilityShellNative]::Broadcast($area)) { $notes.Add("Some windows did not answer the $area notice.") }
        }
        catch {
            $refreshed = $false
            $notes.Add("The $area notice failed: $($_.Exception.Message)")
        }
    }

    # 2. Ask Explorer to redraw icons and open folder views.
    try {
        [WintilityShellNative]::NotifyAssocChanged()
    }
    catch {
        $refreshed = $false
        $notes.Add("The Explorer refresh notice failed: $($_.Exception.Message)")
    }

    # 3. Refresh the desktop itself.
    try {
        if (-not [WintilityShellNative]::RefreshDesktop()) {
            $refreshed = $false
            $notes.Add('The desktop window could not be found.')
        }
    }
    catch {
        $refreshed = $false
        $notes.Add("The desktop refresh failed: $($_.Exception.Message)")
    }

    # 4. Refresh every open File Explorer window.
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($window in @($shell.Windows())) {
            try { $window.Refresh() }
            catch { Write-Verbose 'A window did not accept a refresh. Windows that are not File Explorer do this normally.' }
        }
    }
    catch {
        $notes.Add("Open File Explorer windows could not be refreshed: $($_.Exception.Message)")
    }

    return [PSCustomObject]@{ Refreshed = $refreshed; Notes = $notes.ToArray() }
}

function Update-WintilityShell {
    [CmdletBinding()]
    param()
    return (& $script:ShellRefreshWork $script:ShellNativeSource)
}

function Start-WintilityShellRefresh {
    [CmdletBinding()]
    param()
    # COM needs a single-threaded apartment, so the background runspace is created as STA.
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $runspace.Open()
    $shell = [System.Management.Automation.PowerShell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($script:ShellRefreshWork.ToString()).AddArgument($script:ShellNativeSource)
    $handle = $shell.BeginInvoke()
    return [PSCustomObject]@{ Shell = $shell; Runspace = $runspace; Handle = $handle; Clock = [System.Diagnostics.Stopwatch]::StartNew() }
}

function Receive-WintilityShellRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Job,
        [int]$TimeoutSeconds = 25
    )
    if (-not $Job.Handle.IsCompleted) {
        if ($Job.Clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) { return $null }
        # Windows is not answering. Stop waiting and report it, so the caller can use the fallback.
        [void]$Job.Shell.BeginStop($null, $null)
        return [PSCustomObject]@{ Refreshed = $false; Notes = @('The desktop refresh timed out.') }
    }
    try {
        $last = @($Job.Shell.EndInvoke($Job.Handle)) | Select-Object -Last 1
        if ($null -eq $last) { return [PSCustomObject]@{ Refreshed = $false; Notes = @('The desktop refresh returned nothing.') } }
        return [PSCustomObject]@{ Refreshed = [bool]$last.Refreshed; Notes = @($last.Notes) }
    }
    catch {
        return [PSCustomObject]@{ Refreshed = $false; Notes = @("The desktop refresh failed: $($_.Exception.Message)") }
    }
    finally {
        $Job.Shell.Dispose()
        $Job.Runspace.Dispose()
    }
}

function Restart-WintilityExplorer {
    [CmdletBinding()]
    param()
    return (Invoke-WintilityOperation -Id 'RestartExplorer' -Module 'Shell' -Action {
        $session = (Get-Process -Id $PID).SessionId
        $running = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
        if ($running.Count -eq 0) {
            New-WintilityResult -Id 'RestartExplorer' -Name 'File Explorer' -Skipped $true -Message 'File Explorer is not running in this session.'
            return
        }
        $running | Stop-Process -Force
        # Windows normally restarts the shell by itself. Give it a moment, then start it if it did not.
        $deadline = (Get-Date).AddSeconds(4)
        do {
            Start-Sleep -Milliseconds 300
            $back = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
        } while ($back.Count -eq 0 -and (Get-Date) -lt $deadline)
        if ($back.Count -eq 0) { Start-Process -FilePath 'explorer.exe' }
        New-WintilityResult -Id 'RestartExplorer' -Name 'File Explorer' -Changed $true -Message 'File Explorer restarted. Open File Explorer windows were closed.'
    })
}

function Invoke-WintilityShellRefresh {
    [CmdletBinding()]
    param()
    # The blocking version, for scripts and presets. The interface uses Start-WintilityShellRefresh instead.
    $live = Update-WintilityShell
    if ($live.Refreshed) {
        return [PSCustomObject]@{ Restarted = $false; Message = 'Desktop refreshed.' }
    }
    Write-WintilityLog -Severity WARN -Module 'Shell' -Message ('Live refresh failed. ' + ($live.Notes -join ' '))
    $restart = Restart-WintilityExplorer
    if ($restart.Success -and -not $restart.Skipped) {
        return [PSCustomObject]@{ Restarted = $true; Message = 'The live refresh did not work, so File Explorer was restarted.' }
    }
    return [PSCustomObject]@{ Restarted = $false; Message = 'The desktop could not be refreshed automatically. Use Restart File Explorer in Settings.' }
}
