# Environment detection. Nothing here changes the system.
# Wintility assumes neither administrator rights nor PowerShell 7.

function Test-WintilityAdmin {
    [CmdletBinding()]
    param()
    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal -ArgumentList $identity
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-WintilityEnvironment {
    [CmdletBinding()]
    param()
    $psVersion = $PSVersionTable.PSVersion
    return [PSCustomObject]@{
        PowerShellVersion = $psVersion.ToString()
        PowerShellMajor   = $psVersion.Major
        IsPowerShell7     = ($psVersion.Major -ge 7)
        IsWindowsOS       = ($env:OS -eq 'Windows_NT')
        WindowBuild      = [Environment]::OSVersion.Version.Build
        IsAdmin           = (Test-WintilityAdmin)
    }
}
