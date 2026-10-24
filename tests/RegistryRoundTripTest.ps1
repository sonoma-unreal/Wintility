#requires -Version 5.1
# Registry round-trip test. It writes ONLY under HKCU:\Software\WintilityTest and deletes that key at the end.
# It proves the backup and restore engine: several values at once, a value that did not exist before
# (restore must remove it again), and a string value. Run it on a Windows PC, as a normal user.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module -Name (Join-Path $root 'core\Wintility.Core.psm1') -Force
Set-WintilityRoot -Path $root

$testKey = 'HKCU:\Software\WintilityTest'
$backupDirectory = Join-Path $env:TEMP ('WintilityTestBackups_' + [guid]::NewGuid().ToString('N'))
$script:Failures = 0
function Assert-Check {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { Write-Host "[PASS] $Name" -ForegroundColor Green }
    else { Write-Host "[FAIL] $Name" -ForegroundColor Red; $script:Failures++ }
}

Write-Host '================================'
Write-Host 'WINTILITY REGISTRY ROUND TRIP'
Write-Host '================================'

try {
    Set-WintilityRegistryValue -Path $testKey -Name 'Number' -Kind 'DWord' -Value 7
    Set-WintilityRegistryValue -Path $testKey -Name 'Text' -Kind 'String' -Value '400'
    # 'Missing' is deliberately never created before the backup.

    $targets = @(
        @{ Path = $testKey; Name = 'Number' },
        @{ Path = $testKey; Name = 'Text' },
        @{ Path = $testKey; Name = 'Missing' }
    )
    $backup = New-WintilityBackup -Label 'RoundTrip' -Targets $targets -Directory $backupDirectory
    Assert-Check 'Backup file was written' (Test-Path -LiteralPath $backup)

    Set-WintilityRegistryValue -Path $testKey -Name 'Number' -Kind 'DWord' -Value 99
    Set-WintilityRegistryValue -Path $testKey -Name 'Text' -Kind 'String' -Value '0'
    Set-WintilityRegistryValue -Path $testKey -Name 'Missing' -Kind 'DWord' -Value 1
    Set-WintilityRegistryValue -Path $testKey -Name 'Negative' -Kind 'DWord' -Value -1
    Assert-Check 'A DWord of -1 reads back as -1' ((Get-WintilityRegistryValue -Path $testKey -Name 'Negative').Value -eq -1)

    $summary = Restore-WintilityBackup -BackupFile $backup
    Assert-Check 'Restore reports no failures' ($summary.Failed -eq 0)
    Assert-Check 'DWord is back to its old value' ((Get-WintilityRegistryValue -Path $testKey -Name 'Number').Value -eq 7)
    Assert-Check 'String is back to its old value' ((Get-WintilityRegistryValue -Path $testKey -Name 'Text').Value -eq '400')
    Assert-Check 'A value that did not exist before is removed again' (-not (Get-WintilityRegistryValue -Path $testKey -Name 'Missing').Exists)

    $blocked = $false
    try { Set-WintilityRegistryValue -Path 'HKU:\.DEFAULT\Software\WintilityTest' -Name 'X' -Kind 'DWord' -Value 1 } catch { $blocked = $true }
    Assert-Check 'Writes outside HKCU and HKLM are refused' $blocked
}
finally {
    if (Test-Path -LiteralPath $testKey) { Remove-Item -LiteralPath $testKey -Recurse -Force }
    if (Test-Path -LiteralPath $backupDirectory) { Remove-Item -LiteralPath $backupDirectory -Recurse -Force }
}
Assert-Check 'Test key was cleaned up' (-not (Test-Path -LiteralPath $testKey))

Write-Host ''
if ($script:Failures -eq 0) { Write-Host 'RESULT: PASS' -ForegroundColor Green; exit 0 }
Write-Host "RESULT: FAIL ($($script:Failures) check(s))" -ForegroundColor Red
exit 1
