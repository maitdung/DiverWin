Set-StrictMode -Version 2.0

function Test-FreshWinAclRuleGrantsEffectiveWrite {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Rule)

    $propagationProperty = $Rule.PSObject.Properties['PropagationFlags']
    $propagation = if ($null -ne $propagationProperty) { $propagationProperty.Value } else { [Security.AccessControl.PropagationFlags]::None }
    try {
        if (([int]$propagation -band [int][Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) {
            return $false
        }
    }
    catch {
        if ([string]$propagation -match '(^|,\s*)InheritOnly(,|$)') { return $false }
        if ([string]$propagation -notmatch '^(None|NoPropagateInherit)(,\s*NoPropagateInherit)?$') {
            throw 'An ACL propagation mask could not be evaluated safely.'
        }
    }

    $rightsProperty = $Rule.PSObject.Properties['FileSystemRights']
    if ($null -eq $rightsProperty) { $rightsProperty = $Rule.PSObject.Properties['Rights'] }
    if ($null -eq $rightsProperty) { throw 'An ACL rule has no filesystem-rights mask.' }
    try { $rightsMask = ([int64]$rightsProperty.Value) -band 4294967295L }
    catch { throw 'An ACL filesystem-rights mask could not be evaluated safely.' }

    # GENERIC_ALL and GENERIC_WRITE are the only generic rights that confer
    # mutation. GENERIC_READ (signed high bit) and GENERIC_EXECUTE do not.
    if (($rightsMask -band 268435456L) -ne 0 -or ($rightsMask -band 1073741824L) -ne 0) {
        return $true
    }

    # Atomic writable rights: WriteData/CreateFiles, AppendData/CreateDirectories,
    # WriteExtendedAttributes, DeleteSubdirectoriesAndFiles, WriteAttributes,
    # Delete, ChangePermissions, and TakeOwnership.
    return (($rightsMask -band 852310L) -ne 0)
}

function Test-FreshWinProtectedSourceAclDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OwnerSid,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rules,
        [string]$Path = '<fixture>'
    )

    $trustedWriteSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
    if ($trustedWriteSids -notcontains $OwnerSid) {
        return [pscustomobject]@{ Trusted=$false; Reason="Elevation source is owned by an untrusted identity: $Path"; OffendingSid=$OwnerSid }
    }

    foreach ($rule in @($Rules)) {
        $accessTypeProperty = $rule.PSObject.Properties['AccessControlType']
        $accessType = if ($null -ne $accessTypeProperty) { [string]$accessTypeProperty.Value } else { 'Allow' }
        if ($accessType -ine 'Allow') { continue }
        try { $grantsWrite = Test-FreshWinAclRuleGrantsEffectiveWrite -Rule $rule }
        catch { return [pscustomobject]@{ Trusted=$false; Reason="Elevation source contains an unvalidated ACL: $Path"; OffendingSid=$null } }
        if (-not $grantsWrite) { continue }

        $sidProperty = $rule.PSObject.Properties['IdentitySid']
        if ($null -ne $sidProperty) {
            $sid = [string]$sidProperty.Value
        }
        else {
            try { $sid = [string]$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { return [pscustomobject]@{ Trusted=$false; Reason="Elevation source contains an unvalidated writable ACL: $Path"; OffendingSid=$null } }
        }
        if ($trustedWriteSids -notcontains $sid) {
            return [pscustomobject]@{ Trusted=$false; Reason="Elevation source is writable by an untrusted identity '$sid': $Path"; OffendingSid=$sid }
        }
    }
    return [pscustomobject]@{ Trusted=$true; Reason='The ACL owner and effective write grants are protected.'; OffendingSid=$null }
}

function Get-FreshWinPlanElevationRequirement {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    $items = @($Plan.Items | Where-Object {
        $_.RequiresAdmin -and $_.Action -in @('INSTALL', 'UPDATE', 'REPAIR') -and $_.State -notin @('SUCCEEDED', 'SKIP')
    })
    return [pscustomobject]@{
        Required = ($items.Count -gt 0)
        Items    = $items
        Reason   = if ($items.Count -gt 0) { 'One or more selected system operations require administrator approval.' } else { 'No queued operation requires elevation.' }
    }
}

function Test-FreshWinElevationSourceTrust {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$EntryScriptPath)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return [pscustomobject]@{ Trusted = $false; Reason = 'Elevation source trust can be evaluated only on Windows.' }
    }
    $entryPath = [System.IO.Path]::GetFullPath($EntryScriptPath)
    $projectRoot = Split-Path -Parent $entryPath
    $trustedRoots = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { [System.IO.Path]::GetFullPath([string]$_).TrimEnd([char]'\', [char]'/') + [IO.Path]::DirectorySeparatorChar }
    if (@($trustedRoots | Where-Object { $entryPath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
        return [pscustomobject]@{ Trusted = $false; Reason = 'Automatic elevation requires FreshWin to be installed below a protected Program Files directory.' }
    }

    $paths = @($projectRoot) + @(Get-ChildItem -LiteralPath $projectRoot -Recurse -Force -ErrorAction Stop |
        Where-Object { $_.PSIsContainer -or $_.Extension -in @('.ps1', '.psm1', '.psd1', '.json', '.cmd') } |
        ForEach-Object { $_.FullName })
    foreach ($path in $paths) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ Trusted = $false; Reason = "Elevation source contains a reparse point: $path" }
        }
        $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
        try { $ownerSid = (New-Object Security.Principal.NTAccount($acl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { return [pscustomobject]@{ Trusted = $false; Reason = "Elevation source owner could not be validated: $path" } }
        try { $accessRules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) }
        catch { return [pscustomobject]@{ Trusted = $false; Reason = "Elevation source ACL could not be evaluated: $path" } }
        $descriptorTrust = Test-FreshWinProtectedSourceAclDescriptor -OwnerSid $ownerSid -Rules $accessRules -Path $path
        if (-not $descriptorTrust.Trusted) { return $descriptorTrust }
    }
    return [pscustomobject]@{ Trusted = $true; Reason = 'FreshWin source is installed in a protected location with no unprivileged write access.' }
}

function Invoke-FreshWinElevatedResume {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$EntryScriptPath,
        [string]$CheckpointPath = (Get-FreshWinDefaultCheckpointPath),
        [string]$CallerSid,
        [switch]$RegisterResume,
        [switch]$Wait
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Elevation is only supported on Windows.' }
    foreach ($path in @($EntryScriptPath, $CheckpointPath)) {
        if ($path -match '[%"]' -or -not (Test-FreshWinLocalCheckpointPath -Path $path)) {
            throw 'Elevation paths must be safe absolute local paths.'
        }
    }
    if (-not (Test-Path -LiteralPath $EntryScriptPath -PathType Leaf) -or
        [System.IO.Path]::GetExtension($EntryScriptPath) -ne '.ps1') { throw 'FreshWin entry script was not found or is not a PowerShell script.' }
    $sourceTrust = Test-FreshWinElevationSourceTrust -EntryScriptPath $EntryScriptPath
    if (-not $sourceTrust.Trusted) { throw $sourceTrust.Reason }
    $checkpointWrite = Save-FreshWinExecutionCheckpoint -Plan $Plan -Path $CheckpointPath -PassThruMetadata
    $checkpointHash = [string]$checkpointWrite.Sha256

    if ([string]::IsNullOrWhiteSpace($CallerSid)) {
        $CallerSid = [string]([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
    if ($CallerSid.Length -gt 184 -or $CallerSid -notmatch '^S-\d-\d+(?:-\d+){1,15}$') {
        throw 'The invoking Windows identity SID is invalid.'
    }
    if ($RegisterResume -and -not $Wait) {
        throw 'Resume registration requires waiting for the controlled elevation helper.'
    }

    $powerShellPath = Get-FreshWinTrustedPowerShellPath
    $commonDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($commonDataRoot)) { throw 'Windows common application data is unavailable.' }
    $protectedCheckpointPath = [IO.Path]::Combine($commonDataRoot, 'FreshWin', 'state', 'execution-checkpoint.json')
    $handoffId = [guid]::NewGuid().ToString('N')
    $protectedResultPath = Get-FreshWinProtectedExecutionResultPath -HandoffId $handoffId
    # freshwin.cmd deliberately uses a process-scoped execution-policy bypass.
    # Without the same flag, a Restricted user policy rejects FreshWin.ps1
    # before the controlled child can validate the hash-bound checkpoint.
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" --resume "{1}" --checkpoint-hash {2} --caller-sid {3} --handoff-id {4} --elevated-helper' -f $EntryScriptPath, $CheckpointPath, $checkpointHash, $CallerSid, $handoffId
    if ($PSCmdlet.ShouldProcess('FreshWin system-operation helper', 'Request administrator approval')) {
        $startParameters = @{
            FilePath     = $powerShellPath
            ArgumentList = $arguments
            Verb         = 'RunAs'
            PassThru     = $true
        }
        if ($Wait) { $startParameters['Wait'] = $true }
        $process = Start-Process @startParameters
        $childResult = $null
        $childResultError = $null
        if ($Wait) {
            try { $childResult = Get-FreshWinElevatedExecutionResult -HandoffId $handoffId }
            catch { $childResultError = Protect-FreshWinSensitiveText -Text $_.Exception.Message }
        }
        $resumeRegistration = $null
        if ($Wait -and $RegisterResume -and [int]$process.ExitCode -eq 0 -and
            [IO.File]::Exists($protectedCheckpointPath)) {
            $protectedCheckpoint = Get-FreshWinExecutionCheckpoint -Path $protectedCheckpointPath
            if (Test-FreshWinCheckpointRequiresReboot -Checkpoint $protectedCheckpoint) {
                # This function is still running in the invoking user's token;
                # registration therefore targets that user's HKCU even when a
                # different administrator credential approved the UAC prompt.
                $resumeRegistration = Register-FreshWinResume -EntryScriptPath $EntryScriptPath -CheckpointPath $protectedCheckpointPath -Confirm:$false
            }
        }
        return [pscustomobject]@{
            Started = $true; ProcessId = $process.Id; CheckpointPath = $CheckpointPath
            ProtectedCheckpointPath = $protectedCheckpointPath
            CheckpointSha256 = $checkpointHash; SourceTrust = $sourceTrust
            CallerSid = $CallerSid; ResumeRegistration = $resumeRegistration
            ProcessExitCode = $(if ($Wait) { [int]$process.ExitCode } else { $null })
            HandoffId = $handoffId; ProtectedResultPath = $protectedResultPath
            ChildResult = $childResult; ChildResultError = $childResultError
        }
    }
    return [pscustomobject]@{ Started = $false; ProcessId = $null; CheckpointPath = $CheckpointPath; ProtectedCheckpointPath = $protectedCheckpointPath; CheckpointSha256 = $checkpointHash; SourceTrust = $sourceTrust; CallerSid = $CallerSid; ResumeRegistration = $null; ProcessExitCode = $null; HandoffId = $handoffId; ProtectedResultPath = $protectedResultPath; ChildResult = $null; ChildResultError = $null }
}
