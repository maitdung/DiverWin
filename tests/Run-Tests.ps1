[CmdletBinding()]
param(
    [switch]$IncludeWindowsIntegration,
    [string]$NamePattern
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot 'TestHarness.ps1')
. (Join-Path $PSScriptRoot 'Load-FreshWin.ps1') -ProjectRoot $projectRoot

$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Sort-Object Name)
if ($testFiles.Count -eq 0) { throw 'No FreshWin test files were found.' }
foreach ($testFile in $testFiles) { . $testFile.FullName }

$result = Invoke-FreshWinRegisteredTests -ProjectRoot $projectRoot `
    -IncludeWindowsIntegration:$IncludeWindowsIntegration -NamePattern $NamePattern
if ($result.Failed -gt 0) { exit 1 }
exit 0
