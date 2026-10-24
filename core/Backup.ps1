# Backup and restore for registry values Wintility changes.
# A backup records the prior state of every target, including values that did not
# exist before, so restore can remove them again instead of leaving junk behind.
# Backup and restore live in Core so the UI never owns this logic.

function Get-WintilityBackupDirectory {
    [CmdletBinding()]
    param()
    return (Join-Path $env:LOCALAPPDATA 'Wintility\Backups')
}

function New-WintilityBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        # Each target is a hashtable: @{ Path = 'HKCU:\...'; Name = 'ValueName' }
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets,
        [string]$Directory
    )
    if (-not $Directory) { $Directory = Get-WintilityBackupDirectory }
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    $entries = foreach ($target in @($Targets)) {
        Get-WintilityRegistryValue -Path $target.Path -Name $target.Name
    }

    $safeLabel = ($Label -replace '[^A-Za-z0-9_-]', '_')
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $file = Join-Path $Directory ("{0}_{1}.json" -f $stamp, $safeLabel)

    $document = [PSCustomObject]@{
        Format  = 'Wintility.Backup'
        Version = 1
        Created = (Get-Date).ToString('o')
        Label   = $Label
        Entries = @($entries | Where-Object { $_ })
    }
    $document | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

function Restore-WintilityBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupFile)

    if (-not (Test-Path -LiteralPath $BackupFile)) {
        throw "Backup file not found: $BackupFile"
    }
    $document = Get-Content -LiteralPath $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Get-WintilityProperty -Object $document -Name 'Format') -ne 'Wintility.Backup') {
        throw 'This file is not a Wintility backup.'
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($document.Entries)) {
        $label = "$($entry.Path)\$($entry.Name)"
        $results.Add((Invoke-WintilityOperation -Id $label -Module 'Restore' -Action {
            if ($entry.Exists) {
                Set-WintilityRegistryValue -Path $entry.Path -Name $entry.Name -Kind $entry.Kind -Value $entry.Value
                New-WintilityResult -Id $label -Changed $true -Message 'Restored previous value.'
            }
            else {
                Remove-WintilityRegistryValue -Path $entry.Path -Name $entry.Name
                New-WintilityResult -Id $label -Changed $true -Message 'Removed a value that did not exist before.'
            }
        }))
    }
    return (New-WintilityBatchSummary -Results $results.ToArray())
}

function Get-WintilityLatestBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Label)
    $directory = Get-WintilityBackupDirectory
    if (-not (Test-Path -LiteralPath $directory)) { return $null }
    $file = Get-ChildItem -LiteralPath $directory -Filter "*_$Label.json" |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $file) { return $null }
    return $file.FullName
}
