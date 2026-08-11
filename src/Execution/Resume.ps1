Set-StrictMode -Version 2.0

function Test-FreshWinLocalCheckpointPath {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00\r\n]' -or
        -not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\') -or $Path.StartsWith('//')) {
        return $false
    }
    try { $fullPath = [IO.Path]::GetFullPath($Path) }
    catch { return $false }
    if ($fullPath.StartsWith('\\') -or $fullPath.StartsWith('//')) { return $false }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return $fullPath.StartsWith('/') -and -not $fullPath.StartsWith('//')
    }
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root) -or $root -notmatch '^[A-Za-z]:[\\/]$') { return $false }
    try {
        if ((New-Object IO.DriveInfo($root)).DriveType -eq [IO.DriveType]::Network) { return $false }
    }
    catch { return $false }
    $drive = Get-PSDrive -Name $root.Substring(0, 1) -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($null -eq $drive) { return $false }
    $displayRoot = if ($null -ne $drive.PSObject.Properties['DisplayRoot']) { [string]$drive.DisplayRoot } else { '' }
    if ($displayRoot.StartsWith('\\') -or $displayRoot.StartsWith('//') -or
        ([string]$drive.Root).StartsWith('\\') -or ([string]$drive.Root).StartsWith('//')) { return $false }
    return $true
}

function Get-FreshWinFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $fullPath -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to hash reparse-point file '$fullPath'."
    }
    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Get-FreshWinTrustedPowerShellPath {
    [CmdletBinding()]
    param([string]$SystemDirectory)

    if ([string]::IsNullOrWhiteSpace($SystemDirectory)) {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            throw 'A trusted PowerShell executable can be resolved only on Windows.'
        }
        $SystemDirectory = [Environment]::SystemDirectory
    }
    if ([string]::IsNullOrWhiteSpace($SystemDirectory) -or
        -not [IO.Path]::IsPathRooted($SystemDirectory) -or
        $SystemDirectory -match '[\x00\r\n]') {
        throw 'Windows did not report a safe system directory.'
    }

    $systemRoot = [IO.Path]::GetFullPath($SystemDirectory).TrimEnd([char]'\', [char]'/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $systemRoot 'WindowsPowerShell\v1.0\powershell.exe'))
    $requiredPrefix = $systemRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.File]::Exists($candidate)) {
        throw 'The protected Windows PowerShell executable was not found below the system directory.'
    }
    $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The Windows PowerShell executable cannot be a reparse point.'
    }
    return $candidate
}

function Get-FreshWinExecutionDataRoot {
    [CmdletBinding()]
    param([string]$OverridePath)

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) { return [System.IO.Path]::GetFullPath($OverridePath) }
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localData)) {
        if ($env:LOCALAPPDATA) { $localData = $env:LOCALAPPDATA }
        else { $localData = [System.IO.Path]::GetTempPath() }
    }
    return (Join-Path $localData 'FreshWin')
}

function Get-FreshWinDefaultCheckpointPath {
    [CmdletBinding()]
    param([string]$DataRoot)

    $root = Get-FreshWinExecutionDataRoot -OverridePath $DataRoot
    return (Join-Path (Join-Path $root 'state') 'execution-checkpoint.json')
}

function Get-FreshWinProtectedCheckpointPath {
    [CmdletBinding()]
    param(
        [string]$DataRoot,
        [string]$ReaderSid,
        [scriptblock]$DirectoryProtector
    )

    if (-not [string]::IsNullOrWhiteSpace($ReaderSid) -and
        ($ReaderSid.Length -gt 184 -or $ReaderSid -notmatch '^S-\d-\d+(?:-\d+){1,15}$')) {
        throw 'Protected checkpoint reader SID is invalid.'
    }

    $windows = if ($null -ne (Get-Command Test-FreshWinWindows -ErrorAction SilentlyContinue)) {
        [bool](Test-FreshWinWindows)
    } else { [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT }
    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        if (-not $windows) { throw 'A protected checkpoint root must be supplied for a non-Windows fixture.' }
        $commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        if ([string]::IsNullOrWhiteSpace($commonData)) { throw 'Windows common application data is unavailable.' }
        $DataRoot = Join-Path $commonData 'FreshWin'
    }

    if ($DataRoot -match '[\x00\r\n]' -or -not [IO.Path]::IsPathRooted($DataRoot)) {
        throw 'Protected checkpoint root must be an absolute local path.'
    }
    $root = [IO.Path]::GetFullPath($DataRoot)
    if ($root.StartsWith('\\') -or $root.StartsWith('//')) {
        throw 'Protected checkpoints cannot be stored on a network path.'
    }
    $filesystemRoot = [IO.Path]::GetPathRoot($root)
    if ([string]::Equals($root.TrimEnd([char]'\', [char]'/'), $filesystemRoot.TrimEnd([char]'\', [char]'/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The filesystem root cannot be used as the protected checkpoint directory.'
    }

    if ($windows) {
        if ([string]::IsNullOrWhiteSpace($filesystemRoot) -or $filesystemRoot -notmatch '^[A-Za-z]:[\\/]$') {
            throw 'Protected checkpoints require a local filesystem drive.'
        }
        try {
            if ((New-Object IO.DriveInfo($filesystemRoot)).DriveType -eq [IO.DriveType]::Network) {
                throw 'Protected checkpoints cannot be stored on a network drive.'
            }
        }
        catch {
            if ($_.Exception.Message -like 'Protected checkpoints*') { throw }
            throw 'The protected checkpoint drive could not be validated.'
        }
        $drive = Get-PSDrive -Name $filesystemRoot.Substring(0, 1) -PSProvider FileSystem -ErrorAction SilentlyContinue
        if ($null -eq $drive) { throw 'The protected checkpoint drive could not be validated.' }
        $displayRoot = if ($null -ne $drive.PSObject.Properties['DisplayRoot']) { [string]$drive.DisplayRoot } else { '' }
        if ($displayRoot.StartsWith('\\') -or $displayRoot.StartsWith('//') -or
            ([string]$drive.Root).StartsWith('\\') -or ([string]$drive.Root).StartsWith('//')) {
            throw 'Protected checkpoints cannot be stored on a mapped network drive.'
        }

        # Validate the existing ancestor chain before creating privileged state.
        # This prevents a pre-created junction from redirecting ProgramData writes.
        $existingAncestor = $root
        while (-not [IO.Directory]::Exists($existingAncestor)) {
            $parent = [IO.Path]::GetDirectoryName($existingAncestor)
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $existingAncestor) {
                throw 'The protected checkpoint directory ancestry could not be validated.'
            }
            $existingAncestor = $parent
        }
        $ancestorItem = Get-Item -LiteralPath $existingAncestor -Force -ErrorAction Stop
        while ($null -ne $ancestorItem) {
            if (($ancestorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Protected checkpoint paths cannot traverse reparse point '$($ancestorItem.FullName)'."
            }
            if ([string]::Equals($ancestorItem.FullName.TrimEnd([char]'\', [char]'/'), $filesystemRoot.TrimEnd([char]'\', [char]'/'), [StringComparison]::OrdinalIgnoreCase)) { break }
            $ancestorItem = $ancestorItem.Parent
        }
    }

    $stateDirectory = Join-Path $root 'state'
    [void][IO.Directory]::CreateDirectory($stateDirectory)
    foreach ($candidate in @($root, $stateDirectory)) {
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Protected checkpoint directory cannot be a reparse point: $candidate"
        }
    }

    if ($null -ne $DirectoryProtector) {
        if (-not [bool](& $DirectoryProtector $stateDirectory $ReaderSid)) { throw 'The protected-checkpoint directory provider rejected the directory.' }
    }
    else {
        if (-not $windows -or -not (Test-FreshWinAdministrator)) {
            throw 'Administrator rights are required to create a protected execution checkpoint.'
        }
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $checkpointReaderSid = if ([string]::IsNullOrWhiteSpace($ReaderSid)) {
            $currentSid
        } else {
            New-Object Security.Principal.SecurityIdentifier -ArgumentList $ReaderSid
        }
        $administratorsSid = New-Object Security.Principal.SecurityIdentifier -ArgumentList ([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        $systemSid = New-Object Security.Principal.SecurityIdentifier -ArgumentList ([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        foreach ($protectedDirectory in @($root, $stateDirectory)) {
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            $acl.SetOwner($administratorsSid)
            foreach ($sid in @($administratorsSid, $systemSid)) {
                $fullControlRule = New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList @(
                    $sid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow
                )
                [void]$acl.AddAccessRule($fullControlRule)
            }
            # RunOnce may read the hash-bound checkpoint after reboot, but an
            # unelevated process cannot replace or rewrite privileged state.
            $readRule = New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList @(
                $checkpointReaderSid,
                [Security.AccessControl.FileSystemRights]::ReadAndExecute,
                $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )
            [void]$acl.AddAccessRule($readRule)
            Set-Acl -LiteralPath $protectedDirectory -AclObject $acl -ErrorAction Stop
        }
        foreach ($protectedDirectory in @($root, $stateDirectory)) {
            $protectedItem = Get-Item -LiteralPath $protectedDirectory -Force -ErrorAction Stop
            if (($protectedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Protected checkpoint directory became a reparse point: $protectedDirectory"
            }
        }
    }

    return (Join-Path $stateDirectory 'execution-checkpoint.json')
}

function Get-FreshWinProtectedExecutionResultPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-fA-F0-9]{32}$')]
        [string]$HandoffId,
        [string]$DataRoot
    )

    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            throw 'A protected execution-result root must be supplied for a non-Windows fixture.'
        }
        $commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        if ([string]::IsNullOrWhiteSpace($commonData)) { throw 'Windows common application data is unavailable.' }
        $DataRoot = Join-Path $commonData 'FreshWin'
    }
    if ($DataRoot -match '[\x00\r\n]' -or -not [IO.Path]::IsPathRooted($DataRoot)) {
        throw 'Protected execution-result root must be an absolute local path.'
    }
    $root = [IO.Path]::GetFullPath($DataRoot)
    if ($root.StartsWith('\\') -or $root.StartsWith('//')) {
        throw 'Protected execution results cannot be stored on a network path.'
    }
    $filesystemRoot = [IO.Path]::GetPathRoot($root)
    if ([string]::Equals($root.TrimEnd([char]'\', [char]'/'), $filesystemRoot.TrimEnd([char]'\', [char]'/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The filesystem root cannot be used as the protected execution-result directory.'
    }
    return (Join-Path (Join-Path $root 'state') ('execution-result-{0}.json' -f $HandoffId.ToLowerInvariant()))
}

function ConvertTo-FreshWinElevatedResultText {
    [CmdletBinding()]
    param([AllowNull()][object]$Value, [ValidateRange(1, 32768)][int]$MaximumLength = 4096)

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($null -ne (Get-Command -Name Protect-FreshWinSensitiveText -ErrorAction SilentlyContinue)) {
        $text = Protect-FreshWinSensitiveText -Text $text
    }
    $text = $text -replace '[\x00]', ''
    if ($text.Length -gt $MaximumLength) { $text = $text.Substring(0, $MaximumLength) }
    return $text
}

function Save-FreshWinElevatedExecutionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-fA-F0-9]{32}$')]
        [string]$HandoffId,
        [string]$DataRoot
    )

    $path = Get-FreshWinProtectedExecutionResultPath -HandoffId $HandoffId -DataRoot $DataRoot
    $stateDirectory = [IO.Path]::GetDirectoryName($path)
    if (-not [IO.Directory]::Exists($stateDirectory)) {
        throw 'The elevated child did not initialize the protected state directory.'
    }
    $stateItem = Get-Item -LiteralPath $stateDirectory -Force -ErrorAction Stop
    if (($stateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The protected execution-result directory cannot be a reparse point.'
    }

    $planId = ([string](Get-FreshWinPropertyValue -InputObject $Result -Name 'PlanId' -Default '')).ToLowerInvariant()
    if ($planId -notmatch '^[a-f0-9]{32}$') { throw 'Elevated execution result plan ID is invalid.' }
    $status = [string](Get-FreshWinPropertyValue -InputObject $Result -Name 'Status' -Default '')
    if ($status -notin @('Started', 'Succeeded', 'Failed', 'CompletedWithIssues', 'RebootRequired')) {
        throw 'Elevated execution result status is invalid.'
    }
    $packageId = [string](Get-FreshWinPropertyValue -InputObject $Result -Name 'PackageId' -Default '')
    if ($packageId -and $packageId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'Elevated execution result package ID is invalid.' }

    $resultItems = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-FreshWinPropertyValue -InputObject $Result -Name 'Items' -Default @())) {
        if ($resultItems.Count -ge 250) { throw 'Elevated execution result contains too many items.' }
        $itemPackageId = [string](Get-FreshWinPropertyValue -InputObject $item -Name 'PackageId' -Default '')
        if ($itemPackageId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'Elevated execution result contains an invalid package ID.' }
        $resultItems.Add([pscustomobject][ordered]@{
            packageId    = $itemPackageId
            name         = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $item 'Name' '') 512
            action       = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $item 'Action' '') 32
            state        = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $item 'State' '') 64
            outcome      = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $item 'Outcome' '') 64
            stage        = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $item 'FailedStage' '') 128
            source       = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $item 'Source' '') 1024
            exitCode     = Get-FreshWinPropertyValue $item 'ExitCode' $null
            reason       = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $item 'Reason' '') 4096
            verified     = [bool](Get-FreshWinPropertyValue $item 'Verified' $false)
            verification = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $item 'Verification' '') 128
            outputSummary = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $item 'OutputSummary' '') 4096
        })
    }

    $record = [pscustomobject][ordered]@{
        schemaVersion    = 1
        handoffId        = $HandoffId.ToLowerInvariant()
        planId           = $planId
        savedAtUtc       = [DateTimeOffset]::UtcNow.ToString('o')
        status           = $status
        stage            = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $Result 'Stage' '') 128
        packageId        = $packageId
        reason           = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $Result 'Reason' '') 4096
        exceptionType    = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $Result 'ExceptionType' '') 1024
        exceptionMessage = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $Result 'ExceptionMessage' '') 4096
        childExitCode    = Get-FreshWinPropertyValue $Result 'ChildExitCode' $null
        logPath          = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $Result 'LogPath' '') 4096
        checkpointPath   = ConvertTo-FreshWinElevatedResultText (Get-FreshWinPropertyValue $Result 'CheckpointPath' '') 4096
        items            = $resultItems.ToArray()
        summary          = Get-FreshWinPropertyValue $Result 'Summary' $null
    }
    $json = $record | ConvertTo-Json -Depth 12
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
    $bytes = $encoding.GetBytes($json)
    if ($bytes.Length -gt 2MB) { throw 'Elevated execution result exceeds the 2 MB safety limit.' }
    $temporaryPath = Join-Path $stateDirectory ('.execution-result-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $bytes)
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    return $path
}

function Get-FreshWinElevatedExecutionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-fA-F0-9]{32}$')]
        [string]$HandoffId,
        [string]$DataRoot
    )

    $path = Get-FreshWinProtectedExecutionResultPath -HandoffId $HandoffId -DataRoot $DataRoot
    if (-not [IO.File]::Exists($path)) { return $null }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Elevated execution result cannot be a reparse point.' }
    if ($item.Length -gt 2MB) { throw 'Elevated execution result exceeds the 2 MB safety limit.' }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    try { $json = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
    catch { throw 'Elevated execution result is not valid UTF-8.' }
    $result = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    if ([int](Get-FreshWinPropertyValue $result 'schemaVersion' 0) -ne 1 -or
        [string](Get-FreshWinPropertyValue $result 'handoffId' '') -cne $HandoffId.ToLowerInvariant()) {
        throw 'Elevated execution result does not match the requested handoff.'
    }
    if ([string](Get-FreshWinPropertyValue $result 'planId' '') -notmatch '^[a-f0-9]{32}$') { throw 'Elevated execution result plan ID is invalid.' }
    if ([string](Get-FreshWinPropertyValue $result 'status' '') -notin @('Started', 'Succeeded', 'Failed', 'CompletedWithIssues', 'RebootRequired')) {
        throw 'Elevated execution result status is invalid.'
    }
    return $result
}

function ConvertTo-FreshWinBootSessionMarker {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $lastBootValue = Get-FreshWinPropertyValue -InputObject $Value -Name 'LastBootUpTime' -Default $Value
    $lastBoot = ConvertTo-FreshWinDateTimeOffset -Value $lastBootValue
    if ($null -eq $lastBoot) {
        throw 'The Windows boot-session provider returned an invalid LastBootUpTime value.'
    }
    return $lastBoot.ToUniversalTime().ToString('o')
}

function Get-FreshWinBootSessionMarker {
    [CmdletBinding()]
    param([scriptblock]$BootSessionProvider)

    if ($null -ne $BootSessionProvider) {
        $provided = @(& $BootSessionProvider)
        if ($provided.Count -ne 1) {
            throw 'The Windows boot-session provider must return exactly one LastBootUpTime value.'
        }
        return ConvertTo-FreshWinBootSessionMarker -Value $provided[0]
    }

    $windows = if ($null -ne (Get-Command -Name Test-FreshWinWindows -ErrorAction SilentlyContinue)) {
        [bool](Test-FreshWinWindows)
    } else { [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT }
    if (-not $windows) { return $null }

    try {
        $getCimInstance = Get-Command -Name Get-CimInstance -CommandType Cmdlet -ErrorAction Stop |
            Select-Object -First 1
        $operatingSystems = @(& $getCimInstance -ClassName Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop)
        if ($operatingSystems.Count -ne 1) { return $null }
        return ConvertTo-FreshWinBootSessionMarker -Value $operatingSystems[0]
    }
    catch {
        # A checkpoint remains useful recovery evidence when CIM is damaged,
        # but resume must fail closed because a reboot cannot then be proven.
        return $null
    }
}

function ConvertTo-FreshWinCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [scriptblock]$BootSessionProvider
    )

    $items = foreach ($item in @($Plan.Items)) {
        [ordered]@{
            packageId       = [string]$item.PackageId
            action          = [string]$item.Action
            state           = [string]$item.State
            attempts        = [int]$item.Attempts
            restartRequired = [bool]$item.RestartRequired
            result           = if ($null -eq $item.Result) { $null } else {
                [ordered]@{
                    outcome  = [string](Get-FreshWinPropertyValue -InputObject $item.Result -Name 'Outcome' -Default '')
                    stage    = [string](Get-FreshWinPropertyValue -InputObject $item.Result -Name 'Stage' -Default '')
                    exitCode = Get-FreshWinPropertyValue -InputObject $item.Result -Name 'ExitCode'
                    rebootRequired = [bool](Get-FreshWinPropertyValue -InputObject $item.Result -Name 'RebootRequired' -Default $false)
                    retryAfterReboot = [bool](Get-FreshWinPropertyValue -InputObject $item.Result -Name 'RetryAfterReboot' -Default $false)
                    message  = [string](Get-FreshWinPropertyValue -InputObject $item.Result -Name 'Message' -Default '')
                }
            }
            verification     = if ($null -eq $item.Verification) { $null } else {
                [ordered]@{
                    status   = [string](Get-FreshWinPropertyValue -InputObject $item.Verification -Name 'Status' -Default '')
                    verified = [bool](Get-FreshWinPropertyValue -InputObject $item.Verification -Name 'Verified' -Default $false)
                    detail   = [string](Get-FreshWinPropertyValue -InputObject $item.Verification -Name 'Detail' -Default '')
                }
            }
        }
    }

    $checkpoint = [ordered]@{
        schemaVersion       = 1
        planId              = [string]$Plan.Id
        savedAtUtc          = [DateTimeOffset]::UtcNow.ToString('o')
        status              = [string]$Plan.Status
        dryRun              = [bool]$Plan.DryRun
        updatePolicy        = [string]$Plan.UpdatePolicy
        requestedPackageIds = @($Plan.RequestedPackageIds)
        items               = @($items)
    }
    # LastBootUpTime is an OS-observed boot-session marker. It is written only
    # for a real reboot boundary, then compared before any resumed plan can be
    # rebuilt or executed. Null preserves schema-1 readability when an older
    # checkpoint or a damaged CIM provider cannot supply trustworthy evidence;
    # such a checkpoint is deliberately not resumable.
    $checkpoint['rebootBootSessionUtc'] = if (Test-FreshWinCheckpointRequiresReboot -Checkpoint $checkpoint) {
        Get-FreshWinBootSessionMarker -BootSessionProvider $BootSessionProvider
    } else { $null }
    return $checkpoint
}

function Test-FreshWinCheckpointRequiresReboot {
    [CmdletBinding()]
    param([AllowNull()][object]$Checkpoint)

    if ($null -eq $Checkpoint) { return $false }
    foreach ($item in @(Get-FreshWinPropertyValue -InputObject $Checkpoint -Name 'items' -Default @())) {
        if (-not [bool](Get-FreshWinPropertyValue -InputObject $item -Name 'restartRequired' -Default $false)) { continue }
        $state = [string](Get-FreshWinPropertyValue -InputObject $item -Name 'state' -Default '')
        $result = Get-FreshWinPropertyValue -InputObject $item -Name 'result' -Default $null
        $outcome = [string](Get-FreshWinPropertyValue -InputObject $result -Name 'outcome' -Default '')
        $resultRequiresReboot = [bool](Get-FreshWinPropertyValue -InputObject $result -Name 'rebootRequired' -Default $false)
        if ($state -eq 'SUCCEEDED' -or $outcome -eq 'ProcessSucceeded' -or $resultRequiresReboot) { return $true }
    }
    return $false
}

function Save-FreshWinExecutionCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [string]$Path = (Get-FreshWinDefaultCheckpointPath),
        [switch]$PassThruMetadata,
        [scriptblock]$BootSessionProvider
    )

    if (-not (Test-FreshWinLocalCheckpointPath -Path $Path)) {
        throw 'Execution checkpoint path must be an absolute local path.'
    }
    $validation = Test-FreshWinInstallPlan -Plan $Plan
    if (-not $validation.Valid) { throw "Execution checkpoint cannot be saved: $($validation.Errors -join ' ')" }
    $checkpoint = ConvertTo-FreshWinCheckpoint -Plan $Plan -BootSessionProvider $BootSessionProvider
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $temporaryPath = Join-Path $directory ('.checkpoint-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $checkpoint | ConvertTo-Json -Depth 12
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
        $bytes = $encoding.GetBytes($json)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try { $contentHash = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $sha256.Dispose() }
        [System.IO.File]::WriteAllBytes($temporaryPath, $bytes)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    if ($PassThruMetadata) {
        # This digest is computed from the exact bytes before atomic publish.
        # Reopening a user-writable checkpoint to hash it would allow a
        # same-user process to substitute a different approved plan.
        return [pscustomobject]@{ Path = [IO.Path]::GetFullPath($Path); Sha256 = $contentHash; Length = $bytes.Length }
    }
    return $Path
}

function Get-FreshWinExecutionCheckpoint {
    [CmdletBinding()]
    param(
        [string]$Path = (Get-FreshWinDefaultCheckpointPath),
        [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256
    )

    if (-not (Test-FreshWinLocalCheckpointPath -Path $Path)) {
        throw 'Execution checkpoint path must be an absolute local path.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $checkpointFile = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (($checkpointFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Execution checkpoint cannot be a reparse point.' }
    if ($checkpointFile.Length -gt 2MB) { throw 'Execution checkpoint exceeds the 2 MB safety limit.' }
    $checkpointBytes = [System.IO.File]::ReadAllBytes($checkpointFile.FullName)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try { $actualHash = ([BitConverter]::ToString($sha256.ComputeHash($checkpointBytes))).Replace('-', '').ToLowerInvariant() }
        finally { $sha256.Dispose() }
        if ($actualHash -ne $ExpectedSha256.ToLowerInvariant()) { throw 'Execution checkpoint integrity validation failed.' }
    }
    try { $checkpointJson = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($checkpointBytes) }
    catch { throw 'Execution checkpoint is not valid UTF-8.' }
    $checkpoint = ConvertFrom-Json -InputObject $checkpointJson -ErrorAction Stop
    if ([int](Get-FreshWinPropertyValue -InputObject $checkpoint -Name 'schemaVersion' -Default 0) -ne 1) { throw 'Unsupported execution checkpoint schema.' }
    if ([string](Get-FreshWinPropertyValue -InputObject $checkpoint -Name 'planId' -Default '') -notmatch '^[a-f0-9]{32}$') { throw 'Execution checkpoint plan ID is invalid.' }
    $packageIds = @(Get-FreshWinPropertyValue -InputObject $checkpoint -Name 'requestedPackageIds' -Default @())
    if ($packageIds.Count -eq 0 -or @($packageIds | Where-Object { ([string]$_) -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' }).Count -gt 0) {
        throw 'Execution checkpoint package IDs are invalid.'
    }
    if ($packageIds.Count -gt 200 -or @($packageIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
        throw 'Execution checkpoint contains too many or duplicate package IDs.'
    }
    $updatePolicy = [string](Get-FreshWinPropertyValue -InputObject $checkpoint -Name 'updatePolicy' -Default '')
    if ($updatePolicy -notin @('missing-only', 'include-updates')) { throw 'Execution checkpoint update policy is invalid.' }
    if ((Get-FreshWinPropertyValue -InputObject $checkpoint -Name 'dryRun' -Default $null) -isnot [bool]) { throw 'Execution checkpoint dry-run flag is invalid.' }
    $checkpointStatus = [string](Get-FreshWinPropertyValue -InputObject $checkpoint -Name 'status' -Default '')
    if ($checkpointStatus -notin @('PLANNED', 'RESUMED', 'EXECUTING', 'INCOMPLETE', 'FAILED', 'CANCELLED', 'COMPLETED', 'COMPLETED_WITH_ISSUES', 'REBOOT_REQUIRED', 'DRY_RUN_COMPLETE')) { throw 'Execution checkpoint status is invalid.' }
    $savedAt = ConvertTo-FreshWinDateTimeOffset -Value (Get-FreshWinPropertyValue -InputObject $checkpoint -Name 'savedAtUtc' -Default $null)
    if ($null -eq $savedAt) { throw 'Execution checkpoint timestamp is invalid.' }
    $bootSessionMarker = Get-FreshWinPropertyValue -InputObject $checkpoint -Name 'rebootBootSessionUtc' -Default $null
    if ($null -ne $bootSessionMarker) {
        $markerWasString = $bootSessionMarker -is [string]
        if ($markerWasString -and ([string]$bootSessionMarker -cne ([string]$bootSessionMarker).Trim())) {
            throw 'Execution checkpoint boot-session marker is invalid.'
        }
        if (-not $markerWasString -and $bootSessionMarker -isnot [DateTime] -and $bootSessionMarker -isnot [DateTimeOffset]) {
            throw 'Execution checkpoint boot-session marker is invalid.'
        }
        try { $normalizedBootSessionMarker = ConvertTo-FreshWinBootSessionMarker -Value $bootSessionMarker }
        catch { throw 'Execution checkpoint boot-session marker is invalid.' }
        if ($markerWasString -and [string]$bootSessionMarker -cne $normalizedBootSessionMarker) {
            throw 'Execution checkpoint boot-session marker is not canonical UTC.'
        }
        # PowerShell 7.6 may deserialize ISO JSON strings as DateTime values;
        # normalize that safe representation back to the schema's string form.
        $checkpoint.rebootBootSessionUtc = $normalizedBootSessionMarker
    }
    $items = @(Get-FreshWinPropertyValue -InputObject $checkpoint -Name 'items' -Default @())
    if ($items.Count -eq 0 -or $items.Count -gt 250) { throw 'Execution checkpoint contains no items or too many items.' }
    $checkpointItemIds = @($items | ForEach-Object { [string](Get-FreshWinPropertyValue -InputObject $_ -Name 'packageId' -Default '') })
    if (@($checkpointItemIds | Group-Object | Where-Object Count -gt 1).Count -gt 0 -or @($packageIds | Where-Object { $checkpointItemIds -notcontains [string]$_ }).Count -gt 0) { throw 'Execution checkpoint item package IDs are incomplete or duplicated.' }
    foreach ($item in $items) {
        $itemPackageId = [string](Get-FreshWinPropertyValue -InputObject $item -Name 'packageId' -Default '')
        $itemAction = [string](Get-FreshWinPropertyValue -InputObject $item -Name 'action' -Default '')
        $itemState = [string](Get-FreshWinPropertyValue -InputObject $item -Name 'state' -Default '')
        if ($itemPackageId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
            $itemAction -notin @('INSTALL', 'UPDATE', 'REPAIR', 'SKIP', 'MANUAL', 'BLOCKED') -or
            $itemState -notin @('PENDING', 'RUNNING', 'SUCCEEDED', 'FAILED', 'SKIP', 'MANUAL', 'BLOCKED', 'ELEVATION_REQUIRED', 'UNKNOWN_VERIFICATION', 'VALIDATED')) {
            throw 'Execution checkpoint contains an invalid item.'
        }
        if ((Get-FreshWinPropertyValue -InputObject $item -Name 'restartRequired' -Default $null) -isnot [bool]) {
            throw 'Execution checkpoint contains an invalid restart-required flag.'
        }
    }
    return $checkpoint
}

function Restore-FreshWinPlanFromCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Checkpoint,
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][object]$SystemInfo,
        [AllowNull()][object]$Inventory,
        [string]$WingetPath,
        [scriptblock]$SourceResolver,
        [scriptblock]$BootSessionProvider
    )

    if (Test-FreshWinCheckpointRequiresReboot -Checkpoint $Checkpoint) {
        $savedBootSession = Get-FreshWinPropertyValue -InputObject $Checkpoint -Name 'rebootBootSessionUtc' -Default $null
        if ($savedBootSession -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$savedBootSession)) {
            throw 'This reboot-required checkpoint does not contain a trustworthy Windows boot-session marker. Rebuild and review the plan.'
        }
        $rawSavedBootSession = [string]$savedBootSession
        try { $savedBootSession = ConvertTo-FreshWinBootSessionMarker -Value $rawSavedBootSession }
        catch { throw 'This reboot-required checkpoint contains an invalid Windows boot-session marker. Rebuild and review the plan.' }
        if ($rawSavedBootSession -cne [string]$savedBootSession) {
            throw 'This reboot-required checkpoint contains a non-canonical Windows boot-session marker. Rebuild and review the plan.'
        }
        $currentBootSession = Get-FreshWinBootSessionMarker -BootSessionProvider $BootSessionProvider
        if ([string]::IsNullOrWhiteSpace([string]$currentBootSession)) {
            throw 'The current Windows boot session could not be verified. Resume is blocked until reboot evidence is available.'
        }
        if ([string]$currentBootSession -ceq [string]$savedBootSession) {
            throw 'Windows has not restarted since this checkpoint requested a reboot. Restart Windows before resuming.'
        }
    }

    # Rebuild from the current trusted catalog and current inventory. Executable/source
    # fields from a persisted checkpoint are deliberately never trusted on resume.
    $plan = New-FreshWinInstallPlan -PackageIds @($Checkpoint.requestedPackageIds) -Catalog $Catalog -SystemInfo $SystemInfo -Inventory $Inventory -UpdatePolicy ([string]$Checkpoint.updatePolicy) -DryRun:([bool]$Checkpoint.dryRun) -WingetPath $WingetPath -SourceResolver $SourceResolver
    $plan.Id = [string]$Checkpoint.planId
    $plan.Status = 'RESUMED'

    $savedItems = @(Get-FreshWinPropertyValue -InputObject $Checkpoint -Name 'items' -Default @())
    foreach ($item in @($plan.Items)) {
        $saved = @($savedItems | Where-Object { [string]$_.packageId -eq [string]$item.PackageId } | Select-Object -First 1)
        if ($saved.Count -ne 1) { continue }
        $item.Attempts = [Math]::Max(0, [int](Get-FreshWinPropertyValue -InputObject $saved[0] -Name 'attempts' -Default 0))
        $savedState = [string](Get-FreshWinPropertyValue -InputObject $saved[0] -Name 'state' -Default '')
        if ($savedState -eq 'SUCCEEDED' -and (
            $item.Detection.State -eq 'Installed' -or
            ($item.Detection.State -eq 'UpdateAvailable' -and $plan.UpdatePolicy -eq 'missing-only')
        )) {
            $item.Action = 'SKIP'
            $item.State = 'SKIP'
            $item.Reason = 'Previously completed and still detected after resume.'
        }
        elseif ($savedState -eq 'VALIDATED' -and [bool]$plan.DryRun) {
            $item.State = 'VALIDATED'
        }
    }
    return $plan
}

function Remove-FreshWinExecutionCheckpoint {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Path = (Get-FreshWinDefaultCheckpointPath))

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ($PSCmdlet.ShouldProcess($Path, 'Remove FreshWin execution checkpoint')) {
            Remove-Item -LiteralPath $Path -Force
        }
    }
}

function Register-FreshWinResume {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$EntryScriptPath,
        [Parameter(Mandatory = $true)][string]$CheckpointPath
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Resume registration is only supported on Windows.' }
    foreach ($path in @($EntryScriptPath, $CheckpointPath)) {
        if ($path -match '[%"]' -or -not (Test-FreshWinLocalCheckpointPath -Path $path)) {
            throw 'Resume paths must be absolute local paths and contain no unsafe command-line characters.'
        }
    }
    if (-not (Test-Path -LiteralPath $EntryScriptPath -PathType Leaf) -or [System.IO.Path]::GetExtension($EntryScriptPath) -ne '.ps1') { throw 'FreshWin entry script was not found.' }
    if (-not (Test-Path -LiteralPath $CheckpointPath -PathType Leaf)) { throw 'FreshWin checkpoint was not found.' }
    if ($null -eq (Get-Command -Name Test-FreshWinElevationSourceTrust -ErrorAction SilentlyContinue)) {
        throw 'FreshWin source-trust validation is not loaded.'
    }
    $sourceTrust = Test-FreshWinElevationSourceTrust -EntryScriptPath $EntryScriptPath
    if (-not $sourceTrust.Trusted) { throw "Resume registration refused an unprotected FreshWin source: $($sourceTrust.Reason)" }
    $checkpointHash = Get-FreshWinFileSha256 -Path $CheckpointPath

    $powerShellPath = Get-FreshWinTrustedPowerShellPath
    # Registration is an explicit user choice. Preserve that choice in the
    # one-shot command so a second confirmed reboot can register the next
    # hash-bound RunOnce entry instead of silently losing continuation.
    $commandLine = '"{0}" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{1}" --resume "{2}" --checkpoint-hash {3} --register-resume' -f $powerShellPath, $EntryScriptPath, $CheckpointPath, $checkpointHash
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    $registered = $false
    if ($PSCmdlet.ShouldProcess($key, 'Register a one-time, visible FreshWin resume entry')) {
        if (-not (Test-Path -LiteralPath $key)) { [void](New-Item -Path $key -Force) }
        [void](New-ItemProperty -Path $key -Name 'FreshWinResume' -Value $commandLine -PropertyType String -Force)
        $registered = $true
    }
    return [pscustomobject]@{ Registered = $registered; RegistryPath = $key; Name = 'FreshWinResume'; Command = $commandLine; CheckpointSha256 = $checkpointHash; SourceTrust = $sourceTrust }
}

function Unregister-FreshWinResume {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $false }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if ($PSCmdlet.ShouldProcess($key, 'Remove the FreshWin resume entry')) {
        Remove-ItemProperty -Path $key -Name 'FreshWinResume' -ErrorAction SilentlyContinue
    }
    return $true
}
