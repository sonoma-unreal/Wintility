# Standard result objects. Every public operation returns one of these, so the UI
# can display outcomes without knowing how each operation works.

function New-WintilityResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Name = $null,
        [bool]$Success = $true,
        [bool]$Changed = $false,
        [bool]$Skipped = $false,
        [string]$Message = $null,
        [string]$Warning = $null,
        [string]$ErrorDetail = $null,
        [bool]$RequiresAdmin = $false,
        [bool]$RequiresLogoff = $false,
        [bool]$RequiresRestart = $false
    )
    return [PSCustomObject]@{
        Success         = $Success
        Changed         = $Changed
        Skipped         = $Skipped
        Id              = $Id
        Name            = $Name
        Message         = $Message
        Warning         = $Warning
        Error           = $ErrorDetail
        RequiresAdmin   = $RequiresAdmin
        RequiresLogoff  = $RequiresLogoff
        RequiresRestart = $RequiresRestart
    }
}

function New-WintilityBatchSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results
    )
    $list = @($Results)
    $applied = 0
    $unchanged = 0
    $skipped = 0
    $failed = 0
    foreach ($item in $list) {
        if ($item.Skipped) { $skipped++ }
        elseif (-not $item.Success) { $failed++ }
        elseif ($item.Changed) { $applied++ }
        else { $unchanged++ }
    }
    return [PSCustomObject]@{
        Total     = $list.Count
        Applied   = $applied
        Unchanged = $unchanged
        Skipped   = $skipped
        Failed    = $failed
        FailedIds = @($list | Where-Object { -not $_.Success -and -not $_.Skipped } | ForEach-Object { $_.Id })
        Headline  = ('{0} applied, {1} unchanged, {2} skipped, {3} failed' -f $applied, $unchanged, $skipped, $failed)
        Results   = $list
    }
}
