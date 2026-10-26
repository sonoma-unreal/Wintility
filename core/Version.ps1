# Single source of truth for the product version.
# Nothing else in the project should hard-code a version string.

$script:WintilityVersionInfo = [PSCustomObject]@{
    Product = 'Wintility'
    Version = '5.2'
    Edition = 'Fall Update'
}

function Get-WintilityVersion {
    [CmdletBinding()]
    param()
    return $script:WintilityVersionInfo
}
