param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest

$projectPath = [System.IO.Path]::GetFullPath($ProjectRoot)
$relativeFiles = @(
    'src/Core/Common.ps1',
    'src/Scanner/Platform.ps1',
    'src/Core/Config.ps1',
    'src/Core/Cache.ps1',
    'src/Core/Localization.ps1',
    'src/Core/Logger.ps1',
    'src/Core/Update.ps1',
    'src/Core/Manifest.ps1',
    'src/Core/ProcessRunner.ps1',
    'src/Core/State.ps1',
    'src/Core/Assistant.ps1',
    'src/Core/Bootstrap.ps1',
    'src/Scanner/Hardware.ps1',
    'src/Scanner/Network.ps1',
    'src/Scanner/Software.ps1',
    'src/Scanner/System.ps1',
    'src/Scanner/Activation.ps1',
    'src/Scanner/WindowsUpdate.ps1',
    'src/Scanner/Readiness.ps1',
    'src/Drivers/DriverScanner.ps1',
    'src/Drivers/DriverResolver.ps1',
    'src/Operations/Common.ps1',
    'src/Operations/DriverBackup.ps1',
    'src/Operations/NetworkRescue.ps1',
    'src/Operations/SecurityStatus.ps1',
    'src/Operations/Diagnostics.ps1',
    'src/Operations/PreReset.ps1',
    'src/Operations/DduRecovery.ps1',
    'src/Packages/Catalog.ps1',
    'src/Packages/Compatibility.ps1',
    'src/Packages/Detector.ps1',
    'src/Packages/Resolver.ps1',
    'src/Packages/Installer.ps1',
    'src/Packages/Verifier.ps1',
    'src/Recommendation/Profiles.ps1',
    'src/Recommendation/Rules.ps1',
    'src/Execution/Progress.ps1',
    'src/Execution/Planner.ps1',
    'src/Execution/Resume.ps1',
    'src/Execution/Elevation.ps1',
    'src/Execution/Queue.ps1',
    'src/UI/Input.ps1',
    'src/UI/Selection.ps1',
    'src/UI/Terminal.ps1',
    'src/Core/Validation.ps1',
    'src/UI/Cli.ps1'
)

foreach ($relativeFile in $relativeFiles) {
    $path = Join-Path $projectPath $relativeFile
    if (-not [System.IO.File]::Exists($path)) { throw "Required source file is missing: $relativeFile" }
    . $path
}

$script:FreshWinLoadedSourceFiles = @($relativeFiles)
