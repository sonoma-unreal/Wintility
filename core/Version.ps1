# Single source of truth for the product version.
# Nothing else in the project should hard-code a version string.

$script:WintilityVersionInfo = [PSCustomObject]@{
    Product = 'Wintility'
    Version = '5.1.1'
    Edition = 'Glowstone Edition'
}

function Get-WintilityVersion {
    [CmdletBinding()]
    param()
    return $script:WintilityVersionInfo
}
