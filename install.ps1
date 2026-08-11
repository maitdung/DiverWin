#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Elevated,
    [string]$SourceRoot,
    [string]$ExpectedSourceDigest,
    [string]$ReleaseMetadataUri,
    [ValidateRange(0,2147483647)][int]$UpdateCallerProcessId = 0,
    [string]$FailureReportPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:FreshWinInstallerStage = 'STARTUP'
$script:FreshWinInstallerFailedStage = ''
$script:FreshWinInstallerRollbackResult = 'NotRequired'
$script:FreshWinInstallerLastOutput = ''

function Set-FreshWinInstallerStage {
    param([Parameter(Mandatory = $true)][string]$Stage)
    $script:FreshWinInstallerStage = $Stage
    try { Write-Host ("[FreshWin installer] {0}" -f $Stage) } catch { }
}

function Write-FreshWinInstallerFailureReport {
    param([AllowNull()][object]$ErrorRecord)

    # This is diagnostic metadata only. It is written to the caller-created
    # local temporary path and is never used as executable or installation
    # input. Every diagnostic operation is fail-safe so it cannot mask the
    # original installer failure.
    if ([string]::IsNullOrWhiteSpace($FailureReportPath)) { return }
    try {
        $fullPath = [IO.Path]::GetFullPath($FailureReportPath)
        if ($fullPath -match '[\x00\r\n]' -or $fullPath.StartsWith('\\') -or $fullPath.StartsWith('//')) { return }
        $directory = [IO.Path]::GetDirectoryName($fullPath)
        if ([string]::IsNullOrWhiteSpace($directory) -or -not [IO.Directory]::Exists($directory)) { return }
        $exception = $null
        try { $exception = $ErrorRecord.Exception } catch { }
        $invocation = $null
        try { $invocation = $ErrorRecord.InvocationInfo } catch { }
        $record = [ordered]@{
            schemaVersion     = 1
            stage             = $(if ([string]::IsNullOrWhiteSpace([string]$script:FreshWinInstallerFailedStage)) { [string]$script:FreshWinInstallerStage } else { [string]$script:FreshWinInstallerFailedStage })
            rollbackStage     = [string]$script:FreshWinInstallerStage
            exceptionType     = $(try { [string]$exception.GetType().FullName } catch { '' })
            message           = $(try { [string]$exception.Message } catch { '' })
            scriptStackTrace  = $(try { [string]$ErrorRecord.ScriptStackTrace } catch { '' })
            invocationInfo   = $(try { [string]$invocation.PositionMessage } catch { '' })
            file              = $(try { [string]$invocation.ScriptName } catch { '' })
            line              = $(try { [int]$invocation.ScriptLineNumber } catch { 0 })
            function          = $(try { [string]$invocation.MyCommand.Name } catch { '' })
            stdout            = [string]$script:FreshWinInstallerLastOutput
            stderr            = $(try { [string]$exception.Message } catch { '' })
            rollback          = [string]$script:FreshWinInstallerRollbackResult
        }
        $encoding = New-Object Text.UTF8Encoding -ArgumentList $false
        [IO.File]::WriteAllText($fullPath, (ConvertTo-Json ([pscustomobject]$record) -Depth 8), $encoding)
    }
    catch { }
}

trap {
    Write-FreshWinInstallerFailureReport -ErrorRecord $_
    try { [Console]::Error.WriteLine([string]$_.Exception.Message) } catch { }
    exit 1
}

function Test-FreshWinInstallerAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { if ($identity -is [IDisposable]) { $identity.Dispose() } }
}

function Get-FreshWinInstallerPowerShellPath {
    $path = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    if (-not [IO.File]::Exists($path)) { throw 'Protected Windows PowerShell was not found below the Windows system directory.' }
    return $path
}

function ConvertTo-FreshWinInstallerReleaseMetadataUri {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try { $uri = [Uri]$Value } catch { throw 'Release metadata URI is invalid.' }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.DnsSafeHost.ToLowerInvariant() -cne 'github.com' -or
        $uri.AbsolutePath -notmatch '^/[^/]+/[^/]+/releases/latest/download/FreshWin-stable\.release\.json$') {
        throw 'Release metadata URI must be the official HTTPS GitHub latest-release metadata asset.'
    }
    return $uri.AbsoluteUri
}

function Assert-FreshWinInstallerLocalRoot {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -match '[\x00\r\n"]' -or -not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\') -or $Path.StartsWith('//')) {
        throw 'The local FreshWin installation source path is invalid.'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root) -or (New-Object IO.DriveInfo($root)).DriveType -eq [IO.DriveType]::Network) {
        throw 'FreshWin installation requires a local filesystem source.'
    }
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The FreshWin installation source root cannot be a reparse point.' }
    return $fullPath
}

function Invoke-FreshWinSourceValidation {
    param([Parameter(Mandatory = $true)][string]$Root)
    $powershell = Get-FreshWinInstallerPowerShellPath
    $entry = Join-Path $Root 'FreshWin.ps1'
    $output = @(& $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $entry validate --json 2>&1)
    $script:FreshWinInstallerLastOutput = ($output -join [Environment]::NewLine)
    if ($LASTEXITCODE -ne 0) { throw "FreshWin source validation failed: $($output -join [Environment]::NewLine)" }
    try { $validation = ConvertFrom-Json -InputObject ($output -join [Environment]::NewLine) -ErrorAction Stop }
    catch { throw 'FreshWin source validation did not return valid JSON.' }
    if (-not [bool]$validation.IsValid) { throw 'FreshWin source validation reported an invalid project.' }
    return $validation
}

function Send-FreshWinEnvironmentChanged {
    try {
        if ($null -eq ('FreshWin.NativeEnvironment' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace FreshWin {
    public static class NativeEnvironment {
        [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
    }
}
'@
        }
        $result = [UIntPtr]::Zero
        [void][FreshWin.NativeEnvironment]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result)
    }
    catch { Write-Warning 'FreshWin installed successfully, but Windows did not acknowledge the PATH-change notification. Open a new terminal before launching.' }
}

function Set-FreshWinMachinePathEntry {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $current = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    $updated = Add-FreshWinPathEntryValue -CurrentValue ([string]$current) -Entry $InstallRoot
    if ($updated.Length -gt 30000) { throw 'The machine PATH is too large to register FreshWin safely.' }
    if (-not [string]::Equals([string]$current, $updated, [StringComparison]::Ordinal)) {
        [Environment]::SetEnvironmentVariable('Path', $updated, [EnvironmentVariableTarget]::Machine)
        Send-FreshWinEnvironmentChanged
        return $true
    }
    return $false
}

function Test-FreshWinInstalledManifest {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $manifestPath = Join-Path $InstallRoot 'install-manifest.json'
    if (-not [IO.File]::Exists($manifestPath)) { throw 'The installed file manifest is missing.' }
    $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifestPath)) -ErrorAction Stop
    $records = @(Get-FreshWinInstallPayloadRecords -SourceRoot $InstallRoot)
    $digest = Get-FreshWinInstallPayloadDigest -Records $records
    if ($digest -ne [string]$manifest.PayloadDigest) { throw 'Installed FreshWin files do not match the verified installation manifest.' }
    return $manifest
}

function Test-FreshWinInstallerPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    try {
        $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([char]'\', [char]'/')
        $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([char]'\', [char]'/')
        return [string]::Equals($fullPath, $fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($fullRoot + [IO.Path]::AltDirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Get-FreshWinInstallerLiveProcess {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [int]$IgnoredProcessId = 0)

    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([char]'\', [char]'/', [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    try {
        foreach ($process in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
            if ([int]$process.ProcessId -eq $PID -or ($IgnoredProcessId -gt 0 -and [int]$process.ProcessId -eq $IgnoredProcessId)) { continue }
            $commandLine = [string]$process.CommandLine
            $executable = [string]$process.ExecutablePath
            $freshWinCommand = $false
            if ($commandLine) {
                $freshWinCommand = $commandLine -match ('(?i)' + [regex]::Escape($root) + '[\\/](?:FreshWin\.ps1|bin[\\/]|freshwin\.cmd)')
            }
            if ($freshWinCommand -or
                ($executable -and (Test-FreshWinInstallerPathWithinRoot -Path $executable -Root $root))) {
                [pscustomobject]@{ ProcessId=[int]$process.ProcessId; Name=[string]$process.Name; ExecutablePath=$executable; CommandLine=$commandLine }
            }
        }
    }
    catch { throw "The installer could not verify whether FreshWin is running: $($_.Exception.Message)" }
}

function Copy-FreshWinInstallPayload {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][object[]]$Records
    )

    if (-not [IO.Directory]::Exists($DestinationRoot)) { [void][IO.Directory]::CreateDirectory($DestinationRoot) }
    $rootItem = Get-Item -LiteralPath $DestinationRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installation destination cannot be a reparse point: $DestinationRoot" }
    foreach ($record in @($Records)) {
        $relativePath = ([string]$record.Path).Replace('/', [IO.Path]::DirectorySeparatorChar)
        if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)') { throw "Installation payload path is invalid: $relativePath" }
        $sourcePath = Join-Path $SourceRoot $relativePath
        $destinationPath = Join-Path $DestinationRoot $relativePath
        $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
        if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installation payload source cannot be a reparse point: $sourcePath" }
        $destinationDirectory = [IO.Path]::GetDirectoryName($destinationPath)
        if (-not [IO.Directory]::Exists($destinationDirectory)) { [void][IO.Directory]::CreateDirectory($destinationDirectory) }
        $destinationDirectoryItem = Get-Item -LiteralPath $destinationDirectory -Force -ErrorAction Stop
        if (($destinationDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installation destination cannot traverse a reparse point: $destinationDirectory" }
        [IO.File]::Copy($sourcePath, $destinationPath, $true)
    }
}

function Remove-FreshWinInstallPayloadFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object[]]$Records
    )
    foreach ($record in @($Records)) {
        $path = Join-Path $Root (([string]$record.Path).Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not [IO.File]::Exists($path)) { continue }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to remove a reparse-point installation file: $path" }
        [IO.File]::Delete($path)
    }
}

function Test-FreshWinInstallerPayloadAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][object[]]$Records
    )
    foreach ($record in @($Records)) {
        $path = Join-Path $SourceRoot (([string]$record.Path).Replace('/', [IO.Path]::DirectorySeparatorChar))
        $stream = $null
        try {
            # Probe the same delete/write sharing modes needed by an in-place
            # replacement. This detects a live FreshWin/launcher handle before
            # any protected files are changed.
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        }
        catch {
            throw "The installed FreshWin file is locked or unavailable: $path. Close FreshWin and retry the update."
        }
        finally { if ($null -ne $stream) { $stream.Dispose() } }
    }
}

function Test-FreshWinCommandResolutionInNewProcess {
    param([Parameter(Mandatory = $true)][string]$ExpectedLauncher)
    $powershell = Get-FreshWinInstallerPowerShellPath
    $command = '$c=Get-Command freshwin -CommandType Application -ErrorAction Stop; [Console]::Out.Write($c.Source)'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $powershell
    $start.Arguments = "-NoLogo -NoProfile -EncodedCommand $encoded"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = [IO.Path]::GetPathRoot($ExpectedLauncher)
    $machinePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    $userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    $start.EnvironmentVariables['Path'] = @([string]$machinePath, [string]$userPath) -join ';'
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or -not [string]::Equals([IO.Path]::GetFullPath($stdout.Trim()), [IO.Path]::GetFullPath($ExpectedLauncher), [StringComparison]::OrdinalIgnoreCase)) {
        throw "A new PowerShell process could not resolve the installed freshwin launcher. $stderr"
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'The FreshWin installer supports Windows only.' }
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = $PSScriptRoot }
$SourceRoot = Assert-FreshWinInstallerLocalRoot -Path $SourceRoot
$ReleaseMetadataUri = ConvertTo-FreshWinInstallerReleaseMetadataUri -Value $ReleaseMetadataUri
$commonPath = Join-Path $SourceRoot 'installer\Install.Common.ps1'
if (-not [IO.File]::Exists($commonPath)) { throw 'FreshWin installer support files are missing.' }
. $commonPath

if (-not $Elevated -and -not (Test-FreshWinInstallerAdministrator)) {
    Set-FreshWinInstallerStage 'VALIDATE SOURCE'
    $validation = Invoke-FreshWinSourceValidation -Root $SourceRoot
    $sourceRecords = @(Get-FreshWinInstallPayloadRecords -SourceRoot $SourceRoot)
    $sourceDigest = Get-FreshWinInstallPayloadDigest -Records $sourceRecords
    $powershell = Get-FreshWinInstallerPowerShellPath
    Set-FreshWinInstallerStage 'ELEVATE'
    $failureReportPath = Join-Path ([IO.Path]::GetTempPath()) ('FreshWin-install-failure-' + [guid]::NewGuid().ToString('N') + '.json')
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated -SourceRoot "{1}" -ExpectedSourceDigest {2} -FailureReportPath "{3}"' -f $PSCommandPath, $SourceRoot, $sourceDigest, $failureReportPath
    if (-not [string]::IsNullOrWhiteSpace($ReleaseMetadataUri)) { $arguments += ' -ReleaseMetadataUri "{0}"' -f $ReleaseMetadataUri }
    if ($UpdateCallerProcessId -gt 0) { $arguments += ' -UpdateCallerProcessId {0}' -f $UpdateCallerProcessId }
    try {
        $elevatedProcess = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    }
    catch {
        throw "The FreshWin installer could not start the elevated child: $($_.Exception.Message)"
    }
    if ([int]$elevatedProcess.ExitCode -ne 0) {
        $failure = $null
        try {
            if ([IO.File]::Exists($failureReportPath)) {
                $failure = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($failureReportPath)) -ErrorAction Stop
            }
        } catch { $failure = $null }
        $detail = if ($null -ne $failure) {
            "Stage=$($failure.stage); RollbackStage=$($failure.rollbackStage); ExceptionType=$($failure.exceptionType); Message=$($failure.message); File=$($failure.file); Line=$($failure.line); Function=$($failure.function); ScriptStackTrace=$($failure.scriptStackTrace); InvocationInfo=$($failure.invocationInfo); Stdout=$($failure.stdout); Stderr=$($failure.stderr); Rollback=$($failure.rollback)"
        } else {
            'The elevated child did not publish a structured failure report.'
        }
        # Do not let the parent trap overwrite the child evidence while
        # rethrowing the propagated failure.
        $FailureReportPath = $null
        throw "Elevated FreshWin installation failed with exit code $($elevatedProcess.ExitCode). $detail"
    }
    if ([IO.File]::Exists($failureReportPath)) { Remove-Item -LiteralPath $failureReportPath -Force -ErrorAction SilentlyContinue }
    Set-FreshWinInstallerStage 'VERIFY INSTALLED HASHES'
    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    $installedRoot = [IO.Path]::Combine($programFiles, 'FreshWin')
    Test-FreshWinCommandResolutionInNewProcess -ExpectedLauncher (Join-Path (Join-Path $installedRoot 'bin') 'freshwin.cmd')
    $manifest = Test-FreshWinInstalledManifest -InstallRoot $installedRoot
    Set-FreshWinInstallerStage 'VERIFY LAUNCHER'
    Write-Host "FreshWin $($manifest.Version) installed at $installedRoot"
    Write-Host 'Verified in a new non-elevated PowerShell process: Get-Command freshwin'
    exit 0
}

if (-not (Test-FreshWinInstallerAdministrator)) { throw 'FreshWin installation did not receive administrator rights.' }
Set-FreshWinInstallerStage 'VALIDATE SOURCE'
$sourceRecords = @(Get-FreshWinInstallPayloadRecords -SourceRoot $SourceRoot)
$sourceDigest = Get-FreshWinInstallPayloadDigest -Records $sourceRecords
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceDigest) -and $sourceDigest -cne $ExpectedSourceDigest) {
    throw 'The local FreshWin source changed after validation and before elevated installation.'
}

$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
if ([string]::IsNullOrWhiteSpace($programFiles)) { throw 'Windows Program Files could not be resolved.' }
$programFiles = [IO.Path]::GetFullPath($programFiles)
$installRoot = [IO.Path]::Combine($programFiles, 'FreshWin')
$stagingRoot = [IO.Path]::Combine($programFiles, 'FreshWin.install-' + [guid]::NewGuid().ToString('N'))
$backupRoot = [IO.Path]::Combine($programFiles, 'FreshWin.previous-' + [guid]::NewGuid().ToString('N'))
$backupCreated = $false
$liveRootCreated = $false
$liveContentChanged = $false
$oldPayloadRecords = @()
$stagedPayloadRecords = @()
$oldManifestPath = Join-Path $installRoot 'install-manifest.json'
$stagedManifestPath = Join-Path $stagingRoot 'install-manifest.json'
$machinePathBeforeInstall = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
$machinePathChanged = $false
try {
    Set-FreshWinInstallerStage 'STAGE NEW VERSION'
    if ([IO.Directory]::Exists($stagingRoot) -or [IO.File]::Exists($stagingRoot)) { throw "The staging path already exists: $stagingRoot" }
    if ([IO.Directory]::Exists($backupRoot) -or [IO.File]::Exists($backupRoot)) { throw "The backup path already exists: $backupRoot" }
    [void][IO.Directory]::CreateDirectory($stagingRoot)
    foreach ($record in $sourceRecords) {
        $relativePath = ([string]$record.Path).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $sourcePath = Join-Path $SourceRoot $relativePath
        $destinationPath = Join-Path $stagingRoot $relativePath
        $destinationDirectory = [IO.Path]::GetDirectoryName($destinationPath)
        if (-not [IO.Directory]::Exists($destinationDirectory)) { [void][IO.Directory]::CreateDirectory($destinationDirectory) }
        [IO.File]::Copy($sourcePath, $destinationPath, $false)
    }
    Set-FreshWinInstallerStage 'VERIFY STAGED FILES'
    $stagedRecords = @(Get-FreshWinInstallPayloadRecords -SourceRoot $stagingRoot)
    $stagedDigest = Get-FreshWinInstallPayloadDigest -Records $stagedRecords
    if ($stagedDigest -cne $sourceDigest) { throw 'The protected staged copy failed file-integrity verification.' }

    $manifestText = [IO.File]::ReadAllText((Join-Path $stagingRoot 'FreshWin.psd1'))
    $versionMatch = [regex]::Match($manifestText, "(?m)^\s*ModuleVersion\s*=\s*'([^']+)'\s*$")
    if (-not $versionMatch.Success) { throw 'The staged module version could not be read.' }
    $installManifest = [pscustomobject][ordered]@{
        SchemaVersion='FreshWin.InstallManifest/1'; Version=$versionMatch.Groups[1].Value
        InstalledAtUtc=[DateTimeOffset]::UtcNow.ToString('o'); InstallRoot=$installRoot
        ReleaseMetadataUri=$ReleaseMetadataUri; PayloadDigest=$stagedDigest; Files=$stagedRecords
    }
    $utf8 = New-Object Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText((Join-Path $stagingRoot 'install-manifest.json'), (ConvertTo-Json $installManifest -Depth 8), $utf8)

    Set-FreshWinInstallerStage 'VALIDATE SOURCE'
    [void](Invoke-FreshWinSourceValidation -Root $stagingRoot)
    Set-FreshWinInstallerStage 'VALIDATE CURRENT INSTALLATION'
    if ([IO.Directory]::Exists($installRoot)) {
        $existing = Get-Item -LiteralPath $installRoot -Force -ErrorAction Stop
        if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The existing FreshWin installation is a reparse point and will not be replaced.' }
        if (Test-FreshWinInstallerPathWithinRoot -Path $SourceRoot -Root $installRoot) {
            throw "The installer source is inside the live FreshWin installation. Run install.cmd from a checkout outside $installRoot."
        }
        $running = @(Get-FreshWinInstallerLiveProcess -InstallRoot $installRoot -IgnoredProcessId $UpdateCallerProcessId)
        if ($running.Count -gt 0) {
            $details = @($running | ForEach-Object { '{0} (PID {1})' -f $_.Name, $_.ProcessId }) -join ', '
            throw "FreshWin is currently running from ${installRoot}: $details. Close FreshWin and retry the update."
        }
        if (-not [IO.File]::Exists((Join-Path $installRoot 'install-manifest.json'))) {
            throw 'The existing FreshWin installation has no install manifest; refusing an unsafe in-place update.'
        }
        [void](Test-FreshWinInstalledManifest -InstallRoot $installRoot)
        $oldPayloadRecords = @(Get-FreshWinInstallPayloadRecords -SourceRoot $installRoot)
        Test-FreshWinInstallerPayloadAvailable -SourceRoot $installRoot -Records $oldPayloadRecords
    }
    Set-FreshWinInstallerStage 'INSTALL / REPLACE CORE'
    Set-FreshWinInstallerStage 'BACKUP CURRENT INSTALL'
    if ([IO.File]::Exists($installRoot)) { throw "The existing FreshWin installation path is a file, not a protected directory: $installRoot" }
    if ([IO.Directory]::Exists($installRoot)) {
        $existing = Get-Item -LiteralPath $installRoot -Force -ErrorAction Stop
        if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The existing FreshWin installation is a reparse point and will not be replaced.' }
        [void][IO.Directory]::CreateDirectory($backupRoot)
        Copy-FreshWinInstallPayload -SourceRoot $installRoot -DestinationRoot $backupRoot -Records $oldPayloadRecords
        [IO.File]::Copy((Join-Path $installRoot 'install-manifest.json'), (Join-Path $backupRoot 'install-manifest.json'), $true)
        $backupCreated = $true
    }
    if (-not [IO.Directory]::Exists($installRoot)) {
        [void][IO.Directory]::CreateDirectory($installRoot)
        $liveRootCreated = $true
    }
    Set-FreshWinInstallerStage 'REPLACE FILES'
    $stagedPayloadRecords = @($stagedRecords)
    $stagedPaths = @($stagedPayloadRecords | ForEach-Object { [string]$_.Path })
    $staleRecords = @($oldPayloadRecords | Where-Object { $stagedPaths -notcontains ([string]$_.Path) })
    if ($staleRecords.Count -gt 0) { Remove-FreshWinInstallPayloadFiles -Root $installRoot -Records $staleRecords }
    Copy-FreshWinInstallPayload -SourceRoot $stagingRoot -DestinationRoot $installRoot -Records $stagedPayloadRecords
    [IO.File]::Copy($stagedManifestPath, (Join-Path $installRoot 'install-manifest.json'), $true)
    $liveContentChanged = $true
    Set-FreshWinInstallerStage 'VERIFY INSTALLED FILES'
    Set-FreshWinInstallerStage 'VERIFY INSTALLED HASHES'
    [void](Test-FreshWinInstalledManifest -InstallRoot $installRoot)
    Set-FreshWinInstallerStage 'VERIFY ACL'
    [void](Invoke-FreshWinSourceValidation -Root $installRoot)
    $launcherRoot = Join-Path $installRoot 'bin'
    Set-FreshWinInstallerStage 'VERIFY PATH'
    $machinePathChanged = Set-FreshWinMachinePathEntry -InstallRoot $launcherRoot
    Set-FreshWinInstallerStage 'VERIFY LAUNCHER'
    Test-FreshWinCommandResolutionInNewProcess -ExpectedLauncher (Join-Path $launcherRoot 'freshwin.cmd')
    Set-FreshWinInstallerStage 'COMMIT'
    if ($backupCreated -and [IO.Directory]::Exists($backupRoot)) {
        [IO.Directory]::Delete($backupRoot, $true)
        $backupCreated = $false
    }
    Set-FreshWinInstallerStage 'COMPLETE'
    Write-Host "FreshWin $($versionMatch.Groups[1].Value) installed at $installRoot"
    Write-Host "Launcher registered on the machine PATH: $(Join-Path $launcherRoot 'freshwin.cmd')"
}
catch {
    $originalError = $_
    $script:FreshWinInstallerFailedStage = [string]$script:FreshWinInstallerStage
    Set-FreshWinInstallerStage 'ROLLBACK'
    $rollbackErrors = New-Object Collections.Generic.List[string]
    $script:FreshWinInstallerRollbackResult = 'Started'
    if ($machinePathChanged) {
        try {
            [Environment]::SetEnvironmentVariable('Path', $machinePathBeforeInstall, [EnvironmentVariableTarget]::Machine)
            Send-FreshWinEnvironmentChanged
        } catch { $rollbackErrors.Add("PATH restore: $($_.Exception.Message)") }
    }
    if ($backupCreated -and [IO.Directory]::Exists($backupRoot)) {
        try {
            $restoreRecords = @($oldPayloadRecords + $stagedPayloadRecords | Sort-Object Path -Unique)
            if ([IO.Directory]::Exists($installRoot)) {
                Remove-FreshWinInstallPayloadFiles -Root $installRoot -Records $restoreRecords
                $liveManifest = Join-Path $installRoot 'install-manifest.json'
                if ([IO.File]::Exists($liveManifest)) { [IO.File]::Delete($liveManifest) }
            }
            Copy-FreshWinInstallPayload -SourceRoot $backupRoot -DestinationRoot $installRoot -Records $oldPayloadRecords
            [IO.File]::Copy((Join-Path $backupRoot 'install-manifest.json'), (Join-Path $installRoot 'install-manifest.json'), $true)
            [void](Test-FreshWinInstalledManifest -InstallRoot $installRoot)
            $backupCreated = $false
        } catch { $rollbackErrors.Add("previous installation restore: $($_.Exception.Message)") }
    } elseif ($liveRootCreated -and [IO.Directory]::Exists($installRoot)) {
        try {
            Remove-FreshWinInstallPayloadFiles -Root $installRoot -Records $stagedPayloadRecords
            $newManifest = Join-Path $installRoot 'install-manifest.json'
            if ([IO.File]::Exists($newManifest)) { [IO.File]::Delete($newManifest) }
            if (@([IO.Directory]::EnumerateFileSystemEntries($installRoot)).Count -eq 0) { [IO.Directory]::Delete($installRoot) }
        } catch { $rollbackErrors.Add("new installation removal: $($_.Exception.Message)") }
    }
    if ([IO.Directory]::Exists($backupRoot) -and -not $backupCreated) {
        try { [IO.Directory]::Delete($backupRoot, $true) } catch { $rollbackErrors.Add("backup cleanup: $($_.Exception.Message)") }
    }
    $script:FreshWinInstallerRollbackResult = if (-not $backupCreated -and -not $liveContentChanged -and -not $machinePathChanged -and $rollbackErrors.Count -eq 0) {
        'NotRequired'
    } elseif ($rollbackErrors.Count -eq 0) {
        'Succeeded'
    } else {
        'Failed: ' + ($rollbackErrors -join ' | ')
    }
    if ($rollbackErrors.Count -gt 0) {
        throw ("$($originalError.Exception.Message) Rollback result: $($script:FreshWinInstallerRollbackResult)")
    }
    throw $originalError
}
finally {
    if ([IO.Directory]::Exists($stagingRoot)) {
        try { [IO.Directory]::Delete($stagingRoot, $true) } catch { }
    }
}
