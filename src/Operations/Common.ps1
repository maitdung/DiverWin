Set-StrictMode -Version Latest

function Test-FreshWinOperationsWindows {
    [CmdletBinding()]
    param()

    if ($null -ne (Get-Command -Name Test-FreshWinWindows -ErrorAction SilentlyContinue)) {
        return [bool](Test-FreshWinWindows)
    }
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function New-FreshWinOperationUnsupportedResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Component,

        [string]$Reason
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        $Reason = "$Component requires a live Windows host or an explicit test provider."
    }

    return [pscustomobject][ordered]@{
        Component         = $Component
        Status            = 'Unsupported'
        Succeeded         = $false
        IsSupported       = $false
        PlatformSupported = $false
        IsLive            = $false
        Platform          = $(if ($null -ne (Get-Command -Name Get-FreshWinPlatformName -ErrorAction SilentlyContinue)) { Get-FreshWinPlatformName } else { [System.Environment]::OSVersion.Platform.ToString() })
        Reason            = $Reason
        Errors            = @()
    }
}

function Resolve-FreshWinTrustedWindowsExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('pnputil.exe')]
        [string]$Name
    )

    if (-not (Test-FreshWinOperationsWindows)) {
        throw "Trusted Windows executable '$Name' cannot be resolved on a non-Windows host."
    }
    $systemDirectory = [Environment]::SystemDirectory
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) { throw 'The Windows system directory is unavailable.' }
    $systemDirectory = [System.IO.Path]::GetFullPath($systemDirectory)
    $root = [System.IO.Directory]::GetParent($systemDirectory).FullName
    $rootPrefix = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $candidates = New-Object System.Collections.Generic.List[string]

    # A 32-bit PowerShell process uses Sysnative to reach the native system
    # directory.  It is harmless to omit when the alias is not present.
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        $candidates.Add((Join-Path (Join-Path $root 'Sysnative') $Name))
    }
    $candidates.Add((Join-Path $systemDirectory $Name))

    foreach ($candidate in $candidates) {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
        if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ([System.IO.File]::Exists($fullPath)) {
            $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            return $fullPath
        }
    }

    throw "Trusted Windows executable '$Name' was not found below '$root'."
}

function Assert-FreshWinSafeOutputRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if ($Path -match '[\x00\r\n]' -or -not [System.IO.Path]::IsPathRooted($Path)) {
        throw 'Operation output directories must be absolute local paths without control characters.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\') -or $fullPath.StartsWith('//')) {
        throw 'Operation output directories must be local paths; network and device paths are not accepted.'
    }
    if (Test-FreshWinOperationsWindows) {
        $operationRoot = [System.IO.Path]::GetPathRoot($fullPath)
        try {
            if ((New-Object System.IO.DriveInfo($operationRoot)).DriveType -eq [System.IO.DriveType]::Network) {
                throw 'Operation output directories cannot use mapped network drives.'
            }
        }
        catch {
            if ($_.Exception.Message -eq 'Operation output directories cannot use mapped network drives.') { throw }
            throw 'The operation output drive could not be validated as a local filesystem.'
        }
        $operationDrive = Get-PSDrive -Name $operationRoot.Substring(0, 1) -PSProvider FileSystem -ErrorAction SilentlyContinue
        $operationDisplayRoot = if ($null -ne $operationDrive -and $null -ne $operationDrive.PSObject.Properties['DisplayRoot']) { [string]$operationDrive.DisplayRoot } else { '' }
        if ($null -eq $operationDrive -or $operationDisplayRoot.StartsWith('\\') -or $operationDisplayRoot.StartsWith('//') -or
            ([string]$operationDrive.Root).StartsWith('\\') -or ([string]$operationDrive.Root).StartsWith('//')) {
            throw 'Operation output directories must resolve to a local filesystem drive.'
        }

        $existingAncestor = $fullPath
        while (-not [System.IO.Directory]::Exists($existingAncestor)) {
            $parent = [System.IO.Path]::GetDirectoryName($existingAncestor)
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $existingAncestor) {
                throw 'The operation output directory ancestry could not be validated.'
            }
            $existingAncestor = $parent
        }
        $ancestor = Get-Item -LiteralPath $existingAncestor -Force -ErrorAction Stop
        while ($null -ne $ancestor) {
            if (($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Operation output directories cannot traverse reparse point '$($ancestor.FullName)'."
            }
            if ([string]::Equals($ancestor.FullName.TrimEnd([char]'\', [char]'/'), $operationRoot.TrimEnd([char]'\', [char]'/'), [StringComparison]::OrdinalIgnoreCase)) { break }
            $ancestor = $ancestor.Parent
        }
    }
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals(
            $fullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar),
            $pathRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar),
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use filesystem root '$fullPath' as an operation output directory."
    }

    if ([System.IO.Directory]::Exists($fullPath)) {
        $attributes = [System.IO.File]::GetAttributes($fullPath)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to use reparse-point output directory '$fullPath'."
        }
    }

    return $fullPath
}

function New-FreshWinContainedOutputDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$')]
        [string]$Prefix
    )

    $root = Assert-FreshWinSafeOutputRoot -Path $OutputRoot
    if (-not [System.IO.Directory]::Exists($root)) {
        [void][System.IO.Directory]::CreateDirectory($root)
    }
    $rootAttributes = [System.IO.File]::GetAttributes($root)
    if (($rootAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to create operation output below reparse point '$root'."
    }

    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $leaf = '{0}-{1}-{2}' -f $Prefix, [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N').Substring(0, 8)
        $candidate = Join-Path $root $leaf
        if (-not [System.IO.Directory]::Exists($candidate) -and -not [System.IO.File]::Exists($candidate)) {
            [void][System.IO.Directory]::CreateDirectory($candidate)
            return $candidate
        }
    }

    throw "Unable to allocate a unique output directory below '$root'."
}

function Get-FreshWinProtectedDriverBackupRoot {
    [CmdletBinding()]
    param([string]$CommonApplicationDataPath)

    if ([string]::IsNullOrWhiteSpace($CommonApplicationDataPath)) {
        if (-not (Test-FreshWinOperationsWindows)) {
            throw 'The protected driver-backup staging root can be resolved only on Windows.'
        }
        $CommonApplicationDataPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    }
    if ([string]::IsNullOrWhiteSpace($CommonApplicationDataPath)) {
        throw 'Windows common application data is unavailable.'
    }

    $commonData = Assert-FreshWinSafeOutputRoot -Path $CommonApplicationDataPath
    return [System.IO.Path]::GetFullPath((Join-Path (Join-Path $commonData 'FreshWin') 'DriverBackups'))
}

function ConvertTo-FreshWinOperationAclDescriptor {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-FreshWinOperationsWindows)) {
        throw 'Windows ACL descriptors can be read only on Windows.'
    }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    try {
        $ownerSid = (New-Object Security.Principal.NTAccount -ArgumentList ([string]$acl.Owner)).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    }
    catch {
        try { $ownerSid = (New-Object Security.Principal.SecurityIdentifier -ArgumentList ([string]$acl.Owner)).Value }
        catch { throw "The owner of protected operation directory '$Path' could not be resolved to a SID." }
    }

    $rules = New-Object System.Collections.Generic.List[object]
    foreach ($rule in @($acl.Access)) {
        try { $identitySid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { throw "An access rule on protected operation directory '$Path' could not be resolved to a SID." }
        $rules.Add([pscustomobject][ordered]@{
                IdentitySid      = $identitySid
                AccessControlType = [string]$rule.AccessControlType
                Rights           = [int64]$rule.FileSystemRights
                IsInherited      = [bool]$rule.IsInherited
                AppliesToCurrent = (($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0)
            })
    }

    return [pscustomobject][ordered]@{
        OwnerSid               = $ownerSid
        AreAccessRulesProtected = [bool]$acl.AreAccessRulesProtected
        Rules                  = $rules.ToArray()
    }
}

function Test-FreshWinProtectedOperationAclDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [switch]$RequireRestrictedAcl,
        [switch]$RequireStableParent,
        [string]$AllowedModifySid
    )

    $administratorsSid = 'S-1-5-32-544'
    $systemSid = 'S-1-5-18'
    $trustedInstallerSid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    $strictSids = @($administratorsSid, $systemSid)
    $trustedOwnerSids = @($administratorsSid, $systemSid, $trustedInstallerSid)
    $trustedWriteSids = @($administratorsSid, $systemSid, $trustedInstallerSid)
    $ownerSid = [string](Get-FreshWinPropertyValue -InputObject $Descriptor -Name 'OwnerSid' -Default '')
    if ($RequireRestrictedAcl) {
        if ($strictSids -notcontains $ownerSid -or
            -not [bool](Get-FreshWinPropertyValue -InputObject $Descriptor -Name 'AreAccessRulesProtected' -Default $false)) {
            return $false
        }
    }
    elseif ($trustedOwnerSids -notcontains $ownerSid) {
        return $false
    }

    $readOnlyRights = [int64]([Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
        [Security.AccessControl.FileSystemRights]::Read -bor
        [Security.AccessControl.FileSystemRights]::ReadPermissions -bor
        [Security.AccessControl.FileSystemRights]::Synchronize)
    $modifyRights = [int64][Security.AccessControl.FileSystemRights]::Modify
    $allowedUserRights = [int64]($modifyRights -bor [int64][Security.AccessControl.FileSystemRights]::Synchronize)
    $fullControl = [int64][Security.AccessControl.FileSystemRights]::FullControl
    $stableParentForbiddenRights = [int64]([Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership)
    $adminFullControl = $false
    $systemFullControl = $false
    $userModify = [string]::IsNullOrWhiteSpace($AllowedModifySid)

    foreach ($rule in @((Get-FreshWinPropertyValue -InputObject $Descriptor -Name 'Rules' -Default @()))) {
        $sid = [string](Get-FreshWinPropertyValue -InputObject $rule -Name 'IdentitySid' -Default '')
        $accessType = [string](Get-FreshWinPropertyValue -InputObject $rule -Name 'AccessControlType' -Default '')
        $rights = [int64](Get-FreshWinPropertyValue -InputObject $rule -Name 'Rights' -Default 0)
        $inherited = [bool](Get-FreshWinPropertyValue -InputObject $rule -Name 'IsInherited' -Default $false)
        $appliesToCurrent = [bool](Get-FreshWinPropertyValue -InputObject $rule -Name 'AppliesToCurrent' -Default $true)

        if ($RequireRestrictedAcl) {
            if ($inherited -or $accessType -cne 'Allow') { return $false }
            if ($strictSids -notcontains $sid -and
                ([string]::IsNullOrWhiteSpace($AllowedModifySid) -or $sid -cne $AllowedModifySid)) {
                return $false
            }
        }

        if (-not $RequireRestrictedAcl -and -not $appliesToCurrent) { continue }
        if ($accessType -cne 'Allow') { continue }
        if ($sid -ceq $administratorsSid -and ($rights -band $fullControl) -eq $fullControl) {
            $adminFullControl = $true
        }
        if ($sid -ceq $systemSid -and ($rights -band $fullControl) -eq $fullControl) {
            $systemFullControl = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($AllowedModifySid) -and $sid -ceq $AllowedModifySid) {
            if (($rights -band $modifyRights) -eq $modifyRights -and
                ($rights -band (-bnot $allowedUserRights)) -eq 0) {
                $userModify = $true
            }
            else { return $false }
        }
        elseif ($trustedWriteSids -notcontains $sid) {
            if ($RequireStableParent) {
                if (($rights -band $stableParentForbiddenRights) -ne 0 -or
                    ($rights -band (-bnot $fullControl)) -ne 0) {
                    return $false
                }
            }
            elseif (($rights -band (-bnot $readOnlyRights)) -ne 0) {
                return $false
            }
        }
    }

    if ($RequireRestrictedAcl -and (-not $adminFullControl -or -not $systemFullControl -or -not $userModify)) {
        return $false
    }
    return $true
}

function New-FreshWinRestrictedOperationDirectorySecurity {
    [CmdletBinding()]
    param()

    $administratorsSid = New-Object Security.Principal.SecurityIdentifier -ArgumentList (
        [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null
    )
    $systemSid = New-Object Security.Principal.SecurityIdentifier -ArgumentList (
        [Security.Principal.WellKnownSidType]::LocalSystemSid, $null
    )
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($administratorsSid)
    foreach ($sid in @($administratorsSid, $systemSid)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList @(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    return $acl
}

function Assert-FreshWinOperationDirectorySecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireRestrictedAcl,
        [switch]$RequireStableParent,
        [string]$AllowedModifySid
    )

    $fullPath = Assert-FreshWinSafeOutputRoot -Path $Path
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Protected operation path is not a regular directory: $fullPath"
    }
    $descriptor = ConvertTo-FreshWinOperationAclDescriptor -Path $fullPath
    if (-not (Test-FreshWinProtectedOperationAclDescriptor -Descriptor $descriptor `
            -RequireRestrictedAcl:$RequireRestrictedAcl -RequireStableParent:$RequireStableParent `
            -AllowedModifySid $AllowedModifySid)) {
        throw "Protected operation directory has an unsafe owner or writable ACL: $fullPath"
    }
    return $fullPath
}

function New-FreshWinRestrictedOperationDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-FreshWinOperationsWindows)) {
        throw 'Restricted operation directories can be created only on Windows.'
    }
    $fullPath = Assert-FreshWinSafeOutputRoot -Path $Path
    if ([System.IO.File]::Exists($fullPath)) {
        throw "A file already occupies protected operation directory '$fullPath'."
    }
    if (-not [System.IO.Directory]::Exists($fullPath)) {
        $parent = [System.IO.Path]::GetDirectoryName($fullPath)
        if ([string]::IsNullOrWhiteSpace($parent) -or -not [System.IO.Directory]::Exists($parent)) {
            throw "The protected operation parent directory does not exist: $parent"
        }
        $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
        if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Protected operation directories cannot be created below reparse point '$parent'."
        }

        # DirectoryInfo.Create(DirectorySecurity) applies the non-inherited ACL
        # as part of directory creation on Windows PowerShell 5.1. PowerShell 7
        # exposes the equivalent operation through FileSystemAclExtensions. If
        # another process wins the name race, the strict postcondition below
        # fails closed.
        $directory = New-Object System.IO.DirectoryInfo -ArgumentList $fullPath
        $security = New-FreshWinRestrictedOperationDirectorySecurity
        $instanceCreate = $directory.GetType().GetMethod(
            'Create',
            [type[]]@([Security.AccessControl.DirectorySecurity])
        )
        if ($null -ne $instanceCreate) {
            [void]$instanceCreate.Invoke($directory, [object[]]@($security))
        }
        else {
            $extensionsType = 'System.IO.FileSystemAclExtensions' -as [type]
            if ($null -eq $extensionsType) {
                throw 'This PowerShell runtime cannot create a directory with an atomic Windows ACL.'
            }
            $extensionCreate = $extensionsType.GetMethod(
                'Create',
                [type[]]@([System.IO.DirectoryInfo], [Security.AccessControl.DirectorySecurity])
            )
            if ($null -eq $extensionCreate) {
                throw 'This PowerShell runtime does not expose the secure directory-creation API.'
            }
            [void]$extensionCreate.Invoke($null, [object[]]@($directory, $security))
        }
    }
    return Assert-FreshWinOperationDirectorySecurity -Path $fullPath -RequireRestrictedAcl
}

function Initialize-FreshWinProtectedDriverBackupRoot {
    [CmdletBinding()]
    param()

    if (-not (Test-FreshWinOperationsWindows)) {
        throw 'Protected driver-backup staging can be initialized only on Windows.'
    }
    if ($null -ne (Get-Command -Name Test-FreshWinAdministrator -ErrorAction SilentlyContinue) -and
        -not (Test-FreshWinAdministrator)) {
        throw 'Administrator rights are required to initialize protected driver-backup staging.'
    }

    $backupRoot = Get-FreshWinProtectedDriverBackupRoot
    $freshWinRoot = [System.IO.Path]::GetDirectoryName($backupRoot)
    $commonDataRoot = [System.IO.Path]::GetDirectoryName($freshWinRoot)
    [void](Assert-FreshWinOperationDirectorySecurity -Path $commonDataRoot -RequireStableParent)
    if ([System.IO.Directory]::Exists($freshWinRoot)) {
        [void](Assert-FreshWinOperationDirectorySecurity -Path $freshWinRoot)
    }
    else {
        [void](New-FreshWinRestrictedOperationDirectory -Path $freshWinRoot)
    }

    if ([System.IO.Directory]::Exists($backupRoot)) {
        [void](Assert-FreshWinOperationDirectorySecurity -Path $backupRoot -RequireRestrictedAcl)
    }
    else {
        [void](New-FreshWinRestrictedOperationDirectory -Path $backupRoot)
    }
    return $backupRoot
}

function New-FreshWinProtectedOperationOutputDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$')][string]$Prefix
    )

    $root = Assert-FreshWinOperationDirectorySecurity -Path $OutputRoot -RequireRestrictedAcl
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $leaf = '{0}-{1}-{2}' -f $Prefix, [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N')
        $candidate = Join-Path $root $leaf
        if (-not [System.IO.Directory]::Exists($candidate) -and -not [System.IO.File]::Exists($candidate)) {
            return New-FreshWinRestrictedOperationDirectory -Path $candidate
        }
    }
    throw "Unable to allocate a protected output directory below '$root'."
}

function Assert-FreshWinProtectedOperationTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 500000)][int]$MaximumItems = 200000
    )

    $root = Assert-FreshWinOperationDirectorySecurity -Path $Path -RequireRestrictedAcl
    $prefix = $root.TrimEnd([char]'\', [char]'/') + [System.IO.Path]::DirectorySeparatorChar
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($root)
    $observed = 0
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            $observed++
            if ($observed -gt $MaximumItems) {
                throw "Protected operation tree exceeded the $MaximumItems item validation limit."
            }
            $fullPath = [System.IO.Path]::GetFullPath($item.FullName)
            if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Protected operation item escaped its staging root: $fullPath"
            }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Protected operation tree contains a reparse point: $fullPath"
            }
            if ($item.PSIsContainer) { $pending.Push($fullPath) }
        }
    }
    return $root
}

function Grant-FreshWinProtectedOperationDirectoryAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = Assert-FreshWinProtectedOperationTree -Path $Path
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity -or $null -eq $identity.User) {
        throw 'The originating Windows user SID is unavailable.'
    }
    $userSid = $identity.User
    if ($userSid.Value -notin @('S-1-5-18', 'S-1-5-32-544')) {
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $rule = New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList @(
            $userSid,
            [Security.AccessControl.FileSystemRights]::Modify,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl = Get-Acl -LiteralPath $root -ErrorAction Stop
        [void]$acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $root -AclObject $acl -ErrorAction Stop
        [void](Assert-FreshWinOperationDirectorySecurity -Path $root -RequireRestrictedAcl -AllowedModifySid $userSid.Value)
    }
    return $true
}

function Test-FreshWinContainedRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '[\x00\r\n]') {
        return $false
    }

    try {
        $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $fullRoot $RelativePath))
        $prefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
        return $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Get-FreshWinOperationFileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($fullPath)) {
        throw "Cannot hash missing file '$fullPath'."
    }
    $stream = [System.IO.File]::OpenRead($fullPath)
    try {
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $algorithm.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Protect-FreshWinPrivacyText {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return $null }
    $safe = Protect-FreshWinSensitiveText -Text $Text
    $addressCandidate = $safe.Trim().Trim('[', ']')
    if ($addressCandidate -match '^(.+?)/(?:\d{1,3})$') { $addressCandidate = $matches[1] }
    $parsedAddress = $null
    if ([System.Net.IPAddress]::TryParse($addressCandidate, [ref]$parsedAddress)) { return '[REDACTED_IP]' }
    $safe = [regex]::Replace($safe, '(?i)\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b', '[REDACTED_MAC]')
    $safe = [regex]::Replace($safe, '(?<![0-9])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![0-9])', '[REDACTED_IP]')
    $safe = [regex]::Replace($safe, '(?i)(?<![0-9A-Za-z])(?:[0-9A-F]{0,4}:){2,7}[0-9A-F]{0,4}(?:/\d{1,3})?(?![0-9A-Za-z])', '[REDACTED_IP]')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b', '[REDACTED_PRODUCT_KEY]')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z]:\\Users\\[^\\\s]+', '[REDACTED_USER_HOME]')
    $safe = [regex]::Replace($safe, '(?i)(?<![A-Za-z0-9])/(?:Users|home)/[^/\s]+', '[REDACTED_USER_HOME]')
    return $safe
}

function Protect-FreshWinPrivacyData {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [ValidateRange(0, 100)][int]$Depth = 0,
        [ValidateRange(1, 100)][int]$MaximumDepth = 20,
        [switch]$PreserveHardwareIds
    )

    if ($null -eq $InputObject) { return $null }
    if ($Depth -ge $MaximumDepth) { return '[TRUNCATED]' }
    if ($InputObject -is [System.Security.SecureString] -or $InputObject -is [System.Management.Automation.PSCredential]) {
        return '[REDACTED]'
    }
    if ($InputObject -is [string]) { return Protect-FreshWinPrivacyText -Text $InputObject }
    if ($InputObject -is [datetime]) { return $InputObject.ToUniversalTime().ToString('o') }
    if ($InputObject -is [System.DateTimeOffset]) { return $InputObject.ToUniversalTime().ToString('o') }
    if ($InputObject -is [ValueType]) { return $InputObject }

    if ($PreserveHardwareIds) {
        $redactedKeyPattern = '(?i)^(?:password|passwd|pwd|(?:access|refresh)?[_-]?token|secret|credential|authorization|cookie|api.?key|private.?key|connection.?string|serial(?:number)?|uuid|product.?key|partial.?product.?key|digital.?product|mac(?:address)?|ip(?:v[46])?(?:address)?|ssid|user(?:name)?|domain)$'
    }
    else {
        $redactedKeyPattern = '(?i)^(?:password|passwd|pwd|(?:access|refresh)?[_-]?token|secret|credential|authorization|cookie|api.?key|private.?key|connection.?string|serial(?:number)?|uuid|product.?key|partial.?product.?key|digital.?product|mac(?:address)?|ip(?:v[46])?(?:address)?|ssid|user(?:name)?|domain|hardware.?ids?|instance.?id|pnp.?device.?id)$'
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $safeDictionary = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $keyText = [string]$key
            if ($keyText -match $redactedKeyPattern) {
                $safeDictionary[$keyText] = '[REDACTED]'
            }
            else {
                $safeDictionary[$keyText] = Protect-FreshWinPrivacyData -InputObject $InputObject[$key] -Depth ($Depth + 1) -MaximumDepth $MaximumDepth -PreserveHardwareIds:$PreserveHardwareIds
            }
        }
        return [pscustomobject]$safeDictionary
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $InputObject) {
            $items.Add((Protect-FreshWinPrivacyData -InputObject $item -Depth ($Depth + 1) -MaximumDepth $MaximumDepth -PreserveHardwareIds:$PreserveHardwareIds))
        }
        return ,$items.ToArray()
    }

    $safeObject = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) {
        if (-not $property.IsGettable) { continue }
        if ($property.Name -match $redactedKeyPattern) {
            $safeObject[$property.Name] = '[REDACTED]'
            continue
        }
        try {
            $safeObject[$property.Name] = Protect-FreshWinPrivacyData -InputObject $property.Value -Depth ($Depth + 1) -MaximumDepth $MaximumDepth -PreserveHardwareIds:$PreserveHardwareIds
        }
        catch {
            $safeObject[$property.Name] = '[UNREADABLE]'
        }
    }
    return [pscustomobject]$safeObject
}
