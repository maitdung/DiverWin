#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    # An already elevated PowerShell process must reject an unprotected source
    # tree before any sibling script, module, or catalog data is loaded.  The
    # bootstrap intentionally uses only .NET so module auto-loading cannot
    # resolve a same-name command from a user-writable module directory first.
    $bootstrapWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $bootstrapAdministrator = $false
    $programFilesRoots = [Collections.Generic.List[string]]::new()
    if ($bootstrapWindows) {
        foreach ($candidateRoot in @(
                [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
                [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86))) {
            if (-not [string]::IsNullOrWhiteSpace([string]$candidateRoot)) {
                # Windows PowerShell 5.1 binds TrimEnd arguments as Char;
                # keep each separator explicitly one character long.
                $programFilesRoots.Add([IO.Path]::GetFullPath([string]$candidateRoot).TrimEnd([char]'\', [char]'/') + [IO.Path]::DirectorySeparatorChar)
            }
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            $bootstrapAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        finally { if ($identity -is [IDisposable]) { $identity.Dispose() } }
    }
    if ($bootstrapAdministrator) {
        $entryPath = [IO.Path]::GetFullPath($PSCommandPath)
        $projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
        $entryBelowProtectedRoot = $false
        foreach ($programFilesRoot in $programFilesRoots) {
            if ($entryPath.StartsWith($programFilesRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $entryBelowProtectedRoot = $true
                break
            }
        }
        if (-not $entryBelowProtectedRoot) {
            throw 'Privileged FreshWin execution requires a protected Program Files installation before the module can be loaded.'
        }

        $trustedWriteSids = @(
            'S-1-5-18',       # LocalSystem
            'S-1-5-32-544',   # Builtin Administrators
            'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' # TrustedInstaller
        )
        # Use only the atomic rights that can mutate or replace the current
        # filesystem object. Composite values such as FullControl and Modify
        # also contain ordinary read/execute bits and cannot be ORed into a
        # membership-test mask. The high generic bits are handled separately.
        $specificWriteRights = 852310L # write/append/attributes/delete/DACL/owner
        $genericAllRight = 268435456L
        $genericWriteRight = 1073741824L
        $protectedPaths = [Collections.Generic.List[string]]::new()
        $protectedPaths.Add($projectRoot)
        $enumeratedCount = 0
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($projectRoot, '*', [IO.SearchOption]::AllDirectories)) {
            $enumeratedCount++
            if ($enumeratedCount -gt 20000) { throw 'The FreshWin source tree exceeds the bootstrap trust-check limit.' }
            $attributes = [IO.File]::GetAttributes($path)
            $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Privileged FreshWin execution refused a reparse point: $path"
            }
            if ($isDirectory -or [IO.Path]::GetExtension($path).ToLowerInvariant() -in @('.ps1', '.psm1', '.psd1', '.json', '.cmd')) {
                $protectedPaths.Add([IO.Path]::GetFullPath($path))
            }
        }
        foreach ($path in $protectedPaths) {
            $attributes = [IO.File]::GetAttributes($path)
            $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
            $fileSystemInfo = if ($isDirectory) { [IO.DirectoryInfo]::new($path) } else { [IO.FileInfo]::new($path) }
            try {
                $acl = if ($isDirectory) {
                    $desktopAclMethod = [IO.Directory].GetMethod('GetAccessControl', [type[]]@([string]))
                    if ($null -ne $desktopAclMethod) {
                        # Windows PowerShell 5.1 runs on .NET Framework, where
                        # this is a static Directory API rather than an extension.
                        [IO.Directory]::GetAccessControl($path)
                    }
                    else {
                        [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]$fileSystemInfo)
                    }
                }
                else {
                    $desktopAclMethod = [IO.File].GetMethod('GetAccessControl', [type[]]@([string]))
                    if ($null -ne $desktopAclMethod) {
                        [IO.File]::GetAccessControl($path)
                    }
                    else {
                        [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]$fileSystemInfo)
                    }
                }
            }
            catch { throw "Privileged FreshWin execution could not read the ACL of: $path" }
            try {
                $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            }
            catch { throw "Privileged FreshWin execution could not validate the owner of: $path" }
            if ($trustedWriteSids -notcontains $ownerSid) {
                throw "Privileged FreshWin execution refused an untrusted source owner: $path"
            }
            $accessRules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
            foreach ($rule in $accessRules) {
                if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
                # An inherit-only ACE describes possible child inheritance; it
                # grants no access to the object whose ACL is being checked.
                # Every protected child is enumerated and checked independently.
                if (([int]$rule.PropagationFlags -band [int][Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
                $rightsMask = ([int64]$rule.FileSystemRights) -band 4294967295L
                $grantsWrite = (($rightsMask -band $genericAllRight) -ne 0) -or
                    (($rightsMask -band $genericWriteRight) -ne 0) -or
                    (($rightsMask -band $specificWriteRights) -ne 0)
                if (-not $grantsWrite) { continue }
                $ruleSid = $rule.IdentityReference.Value
                if ($trustedWriteSids -notcontains $ruleSid) {
                    throw "Privileged FreshWin execution refused an untrusted writable ACL: $path"
                }
            }
        }

    }

    if ($bootstrapWindows) {
        # From this point onward, automatic module discovery is constrained to
        # protected operating-system and PowerShell installation directories.
        $trustedModuleRoots = [Collections.Generic.List[string]]::new()
        $windowsModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
        if ([IO.Directory]::Exists($windowsModuleRoot)) { $trustedModuleRoots.Add($windowsModuleRoot) }
        $powerShellModuleRoot = [IO.Path]::Combine($PSHOME, 'Modules')
        if ([IO.Directory]::Exists($powerShellModuleRoot)) {
            $trustedPowerShellHome = $false
            $normalizedPowerShellHome = [IO.Path]::GetFullPath($PSHOME).TrimEnd([char]'\', [char]'/') + [IO.Path]::DirectorySeparatorChar
            foreach ($protectedRoot in $programFilesRoots) {
                if ($normalizedPowerShellHome.StartsWith($protectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                    $trustedPowerShellHome = $true
                    break
                }
            }
            $normalizedSystemDirectory = [IO.Path]::GetFullPath([Environment]::SystemDirectory).TrimEnd([char]'\', [char]'/') + [IO.Path]::DirectorySeparatorChar
            if ($normalizedPowerShellHome.StartsWith($normalizedSystemDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                $trustedPowerShellHome = $true
            }
            if ($trustedPowerShellHome) { $trustedModuleRoots.Add($powerShellModuleRoot) }
        }
        if ($trustedModuleRoots.Count -eq 0) { throw 'No protected Windows PowerShell module directory is available.' }
        $env:PSModulePath = [string]::Join([IO.Path]::PathSeparator, $trustedModuleRoots.ToArray())
    }

    Import-Module ([IO.Path]::Combine($PSScriptRoot, 'FreshWin.psd1')) -Force -ErrorAction Stop
    $startupArguments = ConvertFrom-FreshWinCommandLine -Arguments $args
    $commandName = if ($startupArguments.Valid) { ([string]$startupArguments.Command).ToLowerInvariant() } else { 'invalid' }
    if ($commandName -in @('--help', '-h', '/?')) { $commandName = 'help' }
    if ($commandName -in @('--version', '-v')) { $commandName = 'version' }
    $readOnlyCommands = @(
        'help', '?', '--help', '-h', 'version', '--version', '-v',
        'validate', 'catalog', 'list', 'search', 'status', 'doctor', 'diagnostics',
        'apps', 'drivers', 'updates', 'update', 'gaming', 'developer', 'security', 'history',
        'recommend', 'plan', 'network-rescue', 'ddu-plan'
    )
    $dryRunStartup = [bool]$startupArguments.DryRun
    $explicitOutput = -not [string]::IsNullOrWhiteSpace([string]$startupArguments.OutputPath)
    $readOnlyStartup = -not [bool]$startupArguments.Valid -or -not (Test-FreshWinWindows) -or $dryRunStartup -or
        (($readOnlyCommands -contains $commandName) -and -not ($commandName -eq 'plan' -and $explicitOutput) -and -not ($commandName -eq 'update' -and [bool]$startupArguments.Yes))
    [void](Initialize-FreshWinRuntime -ProjectRoot $PSScriptRoot -ReadOnly:$readOnlyStartup -VerboseTerminal:($args -contains '--verbose'))
    if ((Test-FreshWinWindows) -and (Test-FreshWinAdministrator)) {
        $sourceTrust = Test-FreshWinElevationSourceTrust -EntryScriptPath $PSCommandPath
        if (-not $sourceTrust.Trusted) {
            throw "Privileged FreshWin execution requires a protected Program Files installation: $($sourceTrust.Reason)"
        }
    }
    $result = Invoke-FreshWinCli -Arguments $args -EntryScriptPath $PSCommandPath
    exit [int]$result.ExitCode
}
catch {
    # Capture the original record before any optional localization/redaction
    # attempt can replace the automatic catch variable. ACL failures happen
    # before the FreshWin module and its diagnostic helpers are available.
    $startupError = $_
    $message = '<unavailable>'
    try { $message = [string]$startupError.Exception.Message } catch { }
    try { $message = Protect-FreshWinSensitiveText -Text $message } catch { }
    $exceptionType = '<unavailable>'
    $scriptStackTrace = '<unavailable>'
    $invocationInfo = '<unavailable>'
    $failureFile = '<unavailable>'
    $failureLine = '<unavailable>'
    $failureFunction = '<unavailable>'
    try { $exceptionType = [string]$startupError.Exception.GetType().FullName } catch { }
    try { if (-not [string]::IsNullOrWhiteSpace([string]$startupError.ScriptStackTrace)) { $scriptStackTrace = [string]$startupError.ScriptStackTrace } } catch { }
    try { if (-not [string]::IsNullOrWhiteSpace([string]$startupError.InvocationInfo.PositionMessage)) { $invocationInfo = [string]$startupError.InvocationInfo.PositionMessage } } catch { }
    try { if (-not [string]::IsNullOrWhiteSpace([string]$startupError.InvocationInfo.ScriptName)) { $failureFile = [string]$startupError.InvocationInfo.ScriptName } } catch { }
    try { if ($null -ne $startupError.InvocationInfo.ScriptLineNumber) { $failureLine = [string]$startupError.InvocationInfo.ScriptLineNumber } } catch { }
    try { if ($null -ne $startupError.InvocationInfo.MyCommand -and -not [string]::IsNullOrWhiteSpace([string]$startupError.InvocationInfo.MyCommand.Name)) { $failureFunction = [string]$startupError.InvocationInfo.MyCommand.Name } } catch { }
    $diagnosticLines = @(
        "FreshWin failed: $message",
        "ExceptionType: $exceptionType",
        "ScriptStackTrace: $scriptStackTrace",
        "InvocationInfo: $invocationInfo",
        "File: $failureFile",
        "Line: $failureLine",
        "Function: $failureFunction"
    )
    foreach ($diagnosticLine in $diagnosticLines) {
        try { [Console]::Error.WriteLine([string]$diagnosticLine) }
        catch { try { [Console]::Out.WriteLine([string]$diagnosticLine) } catch { } }
    }
    exit 1
}
