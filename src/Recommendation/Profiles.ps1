Set-StrictMode -Version 2.0

function Import-FreshWinProfiles {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path (Get-FreshWinProjectRoot) 'profiles'),
        [AllowNull()][object]$Catalog
    )

    $profiles = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{ Profiles = @(); Errors = @([pscustomobject]@{ Path = $Path; Error = 'Profiles directory was not found.' }) }
    }

    $knownIds = if ($null -ne $Catalog) { @($Catalog.Packages | ForEach-Object { [string]$_.id }) } else { @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File | Sort-Object Name)) {
        try {
            $profile = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop) -ErrorAction Stop
            $allowedProperties = @('schemaVersion', 'id', 'name', 'nameKey', 'descriptionKey', 'packageIds', 'updatePolicy', 'notes')
            foreach ($property in @($profile.PSObject.Properties)) {
                if ($allowedProperties -notcontains [string]$property.Name) { throw "Unsupported profile property '$($property.Name)'." }
            }
            foreach ($requiredProperty in @('schemaVersion', 'id', 'name', 'nameKey', 'descriptionKey', 'packageIds', 'updatePolicy')) {
                if (-not (Test-FreshWinHasProperty -InputObject $profile -Name $requiredProperty)) { throw "Missing profile property '$requiredProperty'." }
            }
            if ([string]$profile.schemaVersion -ne '1.0') { throw "Unsupported profile schemaVersion '$($profile.schemaVersion)'." }
            $id = [string](Get-FreshWinPropertyValue -InputObject $profile -Name 'id' -Default '')
            $packageProperty = $profile.PSObject.Properties['packageIds']
            if ($null -eq $packageProperty -or $packageProperty.Value -is [string] -or $packageProperty.Value -isnot [System.Collections.IEnumerable]) { throw 'profile.packageIds must be an array.' }
            $packageIds = @($packageProperty.Value)
            if ($id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $id.Length -gt 64) { throw "Invalid profile id '$id'." }
            if ([string]::IsNullOrWhiteSpace([string]$profile.name) -or [string]$profile.name -match '[\x00\r\n]') { throw 'Profile name must be a non-empty single-line string.' }
            if ([string]$profile.nameKey -ne "profiles.$id.name" -or [string]$profile.descriptionKey -ne "profiles.$id.description") { throw "Profile localization keys must match profile id '$id'." }
            if ([string]$profile.updatePolicy -notin @('missing-only', 'include-updates')) { throw "Invalid profile updatePolicy '$($profile.updatePolicy)'." }
            if ($packageIds.Count -eq 0 -and $id -ne 'custom') { throw 'Profile does not contain package IDs.' }
            if ($packageIds.Count -gt 200 -or @($packageIds | Where-Object { [string]$_ -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' }).Count -gt 0) { throw 'Profile contains invalid or excessive package IDs.' }
            $duplicates = @($packageIds | Group-Object | Where-Object Count -gt 1)
            if ($duplicates.Count -gt 0) { throw "Profile contains duplicate package IDs: $($duplicates.Name -join ', ')." }
            if ($knownIds.Count -gt 0) {
                $unknown = @($packageIds | Where-Object { $knownIds -notcontains ([string]$_) })
                if ($unknown.Count -gt 0) { throw "Profile references unknown packages: $($unknown -join ', ')." }
            }
            $profile | Add-Member -NotePropertyName NormalizedPackageIds -NotePropertyValue @($packageIds | ForEach-Object { [string]$_ }) -Force
            $profile | Add-Member -NotePropertyName ProfilePath -NotePropertyValue $file.FullName -Force
            $profiles.Add($profile)
        }
        catch {
            $errors.Add([pscustomobject]@{ Path = $file.FullName; Error = $_.Exception.Message })
        }
    }
    return [pscustomobject]@{ Profiles = $profiles.ToArray(); Errors = $errors.ToArray() }
}

function Get-FreshWinProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Profiles,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $items = if ($null -ne $Profiles.PSObject.Properties['Profiles']) { @($Profiles.Profiles) } else { @($Profiles) }
    return @($items | Where-Object { ([string]$_.id) -ieq $Id }) | Select-Object -First 1
}

function Assert-FreshWinPortableProfileDirectoryChain {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $current = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($current -isnot [System.IO.DirectoryInfo]) { throw "Profile parent '$Path' is not a directory." }
    while ($null -ne $current) {
        if (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Portable profile paths cannot traverse reparse point '$($current.FullName)'."
        }
        $current = $current.Parent
    }
}

function Resolve-FreshWinPortableProfilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Import', 'Export')][string]$Purpose,
        [switch]$AllowMissingParent
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 4096 -or $Path -match '[\x00\r\n]' -or
        -not [System.IO.Path]::IsPathRooted($Path)) {
        throw 'A portable profile path must be an absolute local .json path.'
    }
    if ($Path.StartsWith('\\') -or $Path.StartsWith('//') -or
        $Path -match '^(?i:\\(?:Device|GLOBALROOT|\?\?)[\\/])') {
        throw 'Network and device paths are not accepted for portable profiles.'
    }

    try { $fullPath = [System.IO.Path]::GetFullPath($Path) }
    catch { throw "Portable profile path is invalid: $($_.Exception.Message)" }
    if ($fullPath.StartsWith('\\') -or $fullPath.StartsWith('//') -or
        [System.IO.Path]::GetExtension($fullPath) -ine '.json') {
        throw 'A portable profile path must be an absolute local .json path.'
    }
    if ([string]::IsNullOrWhiteSpace([System.IO.Path]::GetFileNameWithoutExtension($fullPath))) {
        throw 'A portable profile filename is required.'
    }

    $isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if ($isWindowsHost) {
        $root = [System.IO.Path]::GetPathRoot($fullPath)
        if ([string]::IsNullOrWhiteSpace($root) -or $root -notmatch '^[A-Za-z]:[\\/]$') {
            throw 'Portable profiles require a local filesystem drive.'
        }
    }
    elseif (-not $fullPath.StartsWith('/') -or $fullPath -eq '/dev' -or $fullPath.StartsWith('/dev/')) {
        throw 'Network and device paths are not accepted for portable profiles.'
    }

    $matchingDrive = @([System.IO.DriveInfo]::GetDrives() | Where-Object {
        $drivePath = [System.IO.Path]::GetFullPath($_.Name)
        $drivePrefix = if ($drivePath -eq [System.IO.Path]::GetPathRoot($drivePath)) {
            $drivePath
        } else {
            $drivePath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        }
        $fullPath -eq $drivePath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) -or
            $fullPath.StartsWith($drivePrefix, [System.StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object { $_.Name.Length } -Descending | Select-Object -First 1)
    if ($matchingDrive.Count -eq 0 -or $matchingDrive[0].DriveType -in @(
            [System.IO.DriveType]::Network,
            [System.IO.DriveType]::NoRootDirectory,
            [System.IO.DriveType]::Unknown
        )) {
        throw 'Portable profiles require a local filesystem drive.'
    }

    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw 'The portable profile parent directory does not exist.'
    }
    $existingParent = $parent
    while (-not [System.IO.Directory]::Exists($existingParent)) {
        if (-not $AllowMissingParent) { throw 'The portable profile parent directory does not exist.' }
        $nextParent = [System.IO.Path]::GetDirectoryName($existingParent)
        if ([string]::IsNullOrWhiteSpace($nextParent) -or $nextParent -eq $existingParent) {
            throw 'The portable profile parent directory ancestry could not be validated.'
        }
        $existingParent = $nextParent
    }
    Assert-FreshWinPortableProfileDirectoryChain -Path $existingParent

    if ($Purpose -eq 'Export') {
        if ([System.IO.File]::Exists($fullPath) -or [System.IO.Directory]::Exists($fullPath)) {
            throw "Refusing to overwrite existing profile '$fullPath'."
        }
    }
    else {
        if (-not [System.IO.File]::Exists($fullPath)) { throw "Profile '$fullPath' was not found." }
        $file = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if ($file -isnot [System.IO.FileInfo] -or
            ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Portable profile input must be a regular file, not a directory or reparse point.'
        }
    }
    return $fullPath
}

function Get-FreshWinPortableProfileCatalogIds {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Catalog)

    $catalogErrors = @(Get-FreshWinPropertyValue -InputObject $Catalog -Name 'Errors' -Default @())
    if ($catalogErrors.Count -gt 0) { throw 'A valid package catalog is required for portable profiles.' }
    $packagesValue = if ($Catalog -is [System.Collections.IDictionary]) {
        if ($Catalog.Contains('Packages')) { $Catalog['Packages'] } else { $null }
    }
    else {
        $packagesProperty = $Catalog.PSObject.Properties['Packages']
        if ($null -ne $packagesProperty) { $packagesProperty.Value } else { $null }
    }
    if ($null -eq $packagesValue -or $packagesValue -is [string] -or
        $packagesValue -isnot [System.Collections.IEnumerable]) {
        throw 'A valid package catalog is required for portable profiles.'
    }
    $packages = @($packagesValue)
    if ($packages.Count -eq 0 -or $packages.Count -gt 10000) {
        throw 'A valid, bounded package catalog is required for portable profiles.'
    }

    $ids = @($packages | ForEach-Object { Get-FreshWinPropertyValue -InputObject $_ -Name 'id' -Default $null })
    if (@($ids | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $_.Length -gt 64 }).Count -gt 0) {
        throw 'The package catalog contains an invalid package ID.'
    }
    $duplicates = @($ids | Group-Object | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) { throw 'The package catalog contains duplicate package IDs.' }
    return @($ids)
}

function Assert-FreshWinPortableProfileObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][string[]]$KnownPackageIds
    )

    if ($Profile -is [string] -or $Profile -is [ValueType] -or $Profile -is [System.Array] -or
        $Profile -is [System.Collections.IDictionary]) {
        throw 'A portable profile must be a JSON object.'
    }
    $allowedProperties = @('schemaVersion', 'id', 'name', 'descriptionKey', 'packageIds', 'updatePolicy', 'exportedAtUtc')
    $propertyNames = @($Profile.PSObject.Properties | ForEach-Object { [string]$_.Name })
    foreach ($propertyName in $propertyNames) {
        if ($allowedProperties -cnotcontains $propertyName) { throw "Unsupported portable profile property '$propertyName'." }
    }
    foreach ($requiredProperty in $allowedProperties) {
        if ($propertyNames -cnotcontains $requiredProperty) { throw "Missing portable profile property '$requiredProperty'." }
    }

    $schemaVersion = Get-FreshWinPropertyValue -InputObject $Profile -Name 'schemaVersion'
    if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [long]$schemaVersion -ne 1) {
        throw 'Portable profile schemaVersion must be the integer 1.'
    }
    $id = Get-FreshWinPropertyValue -InputObject $Profile -Name 'id'
    if ($id -isnot [string] -or $id -cne 'custom-export') { throw "Unsupported portable profile id '$id'." }
    $descriptionKey = Get-FreshWinPropertyValue -InputObject $Profile -Name 'descriptionKey'
    if ($descriptionKey -isnot [string] -or $descriptionKey -cne 'profiles.custom.description') {
        throw 'Portable profile descriptionKey is invalid.'
    }
    $name = Get-FreshWinPropertyValue -InputObject $Profile -Name 'name'
    if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 128 -or
        $name -match '[\x00-\x1f\x7f]' -or $name -cne $name.Trim()) {
        throw 'Portable profile name must be a trimmed single-line string of 1 to 128 characters.'
    }
    $updatePolicy = Get-FreshWinPropertyValue -InputObject $Profile -Name 'updatePolicy'
    if ($updatePolicy -isnot [string] -or $updatePolicy -cnotin @('missing-only', 'include-updates')) {
        throw 'Portable profile updatePolicy is invalid.'
    }
    $exportedAtUtc = Get-FreshWinPropertyValue -InputObject $Profile -Name 'exportedAtUtc'
    $parsedTimestamp = [DateTimeOffset]::MinValue
    if ($exportedAtUtc -isnot [string] -or -not [DateTimeOffset]::TryParseExact(
            $exportedAtUtc,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsedTimestamp
        ) -or $parsedTimestamp.Offset -ne [TimeSpan]::Zero) {
        throw 'Portable profile exportedAtUtc must be an ISO 8601 UTC timestamp.'
    }

    # Read the raw property value so a one-element JSON array is not
    # pipeline-unrolled into a scalar string by PowerShell.
    $packageValue = $Profile.PSObject.Properties['packageIds'].Value
    if ($null -eq $packageValue -or $packageValue -is [string] -or
        $packageValue -isnot [System.Collections.IEnumerable]) {
        throw 'Portable profile packageIds must be an array.'
    }
    $packageIds = @($packageValue)
    if ($packageIds.Count -eq 0 -or $packageIds.Count -gt 200) {
        throw 'Portable profile packageIds must contain between 1 and 200 items.'
    }
    if (@($packageIds | Where-Object {
                $_ -isnot [string] -or $_ -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $_.Length -gt 64
            }).Count -gt 0) {
        throw 'Portable profile packageIds contains an invalid package ID.'
    }
    $duplicates = @($packageIds | Group-Object | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) {
        throw "Portable profile contains duplicate package IDs: $($duplicates.Name -join ', ')."
    }
    $unknown = @($packageIds | Where-Object { $KnownPackageIds -cnotcontains $_ })
    if ($unknown.Count -gt 0) {
        throw "Portable profile references unknown package IDs: $($unknown -join ', ')."
    }
    return @($packageIds)
}

function Write-FreshWinPortableProfileJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 8
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
    $bytes = $encoding.GetBytes($json)
    if ($bytes.Length -gt 262144) { throw 'The portable profile exceeds the 262144-byte limit.' }

    $parent = [System.IO.Path]::GetDirectoryName($Path)
    $temporaryPath = $null
    try {
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $candidate = Join-Path $parent ('.freshwin-profile-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                $stream = [System.IO.File]::Open(
                    $candidate,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None
                )
                $temporaryPath = $candidate
                try {
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                }
                finally { $stream.Dispose() }
                break
            }
            catch [System.IO.IOException] {
                if ($attempt -eq 9) { throw 'Unable to allocate an atomic profile export file.' }
            }
        }
        if ([string]::IsNullOrWhiteSpace($temporaryPath)) { throw 'Unable to allocate an atomic profile export file.' }

        Assert-FreshWinPortableProfileDirectoryChain -Path $parent
        if ([System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)) {
            throw "Refusing to overwrite existing profile '$Path'."
        }
        [System.IO.File]::Move($temporaryPath, $Path)
        $temporaryPath = $null
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($temporaryPath) -and [System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Export-FreshWinProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$PackageIds,
        [string]$Name = 'FreshWin Custom Profile',
        [ValidateSet('missing-only', 'include-updates')][string]$UpdatePolicy = 'missing-only',
        [AllowNull()][object]$Catalog
    )

    $fullPath = Resolve-FreshWinPortableProfilePath -Path $Path -Purpose Export -AllowMissingParent
    if ($null -eq $Catalog) {
        $Catalog = Import-FreshWinPackageCatalog
    }
    $knownIds = @(Get-FreshWinPortableProfileCatalogIds -Catalog $Catalog)
    $profile = [ordered]@{
        schemaVersion = 1
        id            = 'custom-export'
        name          = $Name
        descriptionKey = 'profiles.custom.description'
        packageIds    = @($PackageIds)
        updatePolicy  = $UpdatePolicy
        exportedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $validatedIds = @(Assert-FreshWinPortableProfileObject -Profile ([pscustomobject]$profile) -KnownPackageIds $knownIds)
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    # Revalidate the complete directory chain after creation and immediately
    # before the create-new write. Downloads and OneDrive locations remain
    # artifact destinations, never executable or module trust roots.
    $fullPath = Resolve-FreshWinPortableProfilePath -Path $fullPath -Purpose Export
    Write-FreshWinPortableProfileJson -Path $fullPath -Value ([pscustomobject]$profile)
    return [pscustomobject]@{ Path = $fullPath; PackageCount = $validatedIds.Count; Profile = [pscustomobject]$profile }
}

function Import-FreshWinUserProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Catalog
    )

    $fullPath = Resolve-FreshWinPortableProfilePath -Path $Path -Purpose Import
    $file = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($file.Length -eq 0 -or $file.Length -gt 262144) {
        throw 'Portable profile size must be between 1 and 262144 bytes.'
    }
    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    if ($bytes.Length -eq 0 -or $bytes.Length -gt 262144) {
        throw 'Portable profile size must be between 1 and 262144 bytes.'
    }
    $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    try {
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
        $json = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    }
    catch { throw "Portable profile is not valid UTF-8: $($_.Exception.Message)" }
    if ([string]::IsNullOrWhiteSpace($json)) { throw 'Portable profile JSON is empty.' }
    try {
        # PowerShell 7.5+ otherwise auto-converts ISO timestamps to DateTime,
        # hiding the original JSON scalar type from the strict validator.
        $convertFromJson = Get-Command ConvertFrom-Json -ErrorAction Stop
        if ($convertFromJson.Parameters.ContainsKey('DateKind')) {
            $profile = ConvertFrom-Json -InputObject $json -DateKind String -ErrorAction Stop
        }
        else {
            $profile = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        }
    }
    catch { throw "Portable profile JSON is invalid: $($_.Exception.Message)" }

    $knownIds = @(Get-FreshWinPortableProfileCatalogIds -Catalog $Catalog)
    $packageIds = @(Assert-FreshWinPortableProfileObject -Profile $profile -KnownPackageIds $knownIds)
    $profile | Add-Member -NotePropertyName NormalizedPackageIds -NotePropertyValue @($packageIds) -Force
    $profile | Add-Member -NotePropertyName ProfilePath -NotePropertyValue $fullPath -Force
    return $profile
}
