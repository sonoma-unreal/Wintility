# Error boundaries. One failing operation must never take down the rest of the batch.
# Actions run immediately and in order, so closures over loop variables are safe.

function Test-WintilityResultObject {
    [CmdletBinding()]
    param($Object)
    if ($null -eq $Object) { return $false }
    $names = @($Object.PSObject.Properties.Name)
    return (($names -contains 'Success') -and ($names -contains 'Changed') -and ($names -contains 'Skipped'))
}

function Invoke-WintilityOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-WintilityLog -Severity INFO -Module $Module -Message "Starting $Id."
    try {
        $outputs = @(& $Action | Where-Object { Test-WintilityResultObject -Object $_ })
        if ($outputs.Count -ne 1) {
            throw "Operation $Id must return exactly one result object, but it returned $($outputs.Count)."
        }
        $result = $outputs[0]

        if (-not $result.Success) { $severity = 'ERROR' }
        elseif ($result.Skipped) { $severity = 'WARN' }
        elseif ($result.Changed) { $severity = 'SUCCESS' }
        else { $severity = 'INFO' }

        Write-WintilityLog -Severity $severity -Module $Module -Message "$Id -> $($result.Message)"
        return $result
    }
    catch {
        $detail = $_.Exception.Message
        Write-WintilityLog -Severity ERROR -Module $Module -Message "$Id failed. $detail"
        return (New-WintilityResult -Id $Id -Success $false -Message 'This operation failed. Other operations continued.' -ErrorDetail $detail)
    }
}

function Invoke-WintilityBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Module,
        # Each entry is a hashtable: @{ Id = 'Name'; Action = { ...returns one result... } }
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Operations
    )
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($operation in @($Operations)) {
        $results.Add((Invoke-WintilityOperation -Id $operation.Id -Module $Module -Action $operation.Action))
    }
    return (New-WintilityBatchSummary -Results $results.ToArray())
}
