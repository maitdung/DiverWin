Set-StrictMode -Version 2.0

$script:FreshWinAllowedWindowsFeatures = @(
    'Microsoft-Windows-Subsystem-Linux',
    'VirtualMachinePlatform',
    'HypervisorPlatform',
    'Containers-DisposableClientVM'
)

function Test-FreshWinResolverWindows {
    [CmdletBinding()]
    param([scriptblock]$WindowsProvider)

    if ($null -ne $WindowsProvider) {
        return [bool](& $WindowsProvider)
    }

    if ($null -ne (Get-Command -Name Test-FreshWinIsWindows -ErrorAction SilentlyContinue)) {
        return [bool](Test-FreshWinIsWindows)
    }
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Get-FreshWinDesktopAppInstallerPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string]$Scope,

        [scriptblock]$PackageProvider
    )

    try {
        $packages = if ($null -ne $PackageProvider) {
            @(& $PackageProvider $Scope 'Microsoft.DesktopAppInstaller')
        }
        else {
            $getAppxPackage = Get-Command -Name Get-AppxPackage -CommandType Cmdlet -ErrorAction Stop |
                Select-Object -First 1
            if ($Scope -ceq 'AllUsers') {
                @(& $getAppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction Stop)
            }
            else {
                @(& $getAppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop)
            }
        }

        return @($packages | Where-Object { $null -ne $_ } | Sort-Object Version -Descending)
    }
    catch {
        # App Installer enumeration is part of the trust boundary. Callers may
        # try the elevated all-users scope, but never substitute a PATH lookup.
        return @()
    }
}

function Test-FreshWinPathWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ) + [System.IO.Path]::DirectorySeparatorChar
        return $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Test-FreshWinTrustedAppInstallerIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Package)

    $name = [string](Get-FreshWinPropertyValue -InputObject $Package -Name 'Name' -Default '')
    $familyName = [string](Get-FreshWinPropertyValue -InputObject $Package -Name 'PackageFamilyName' -Default '')
    $publisherId = [string](Get-FreshWinPropertyValue -InputObject $Package -Name 'PublisherId' -Default '')
    $signatureKind = [string](Get-FreshWinPropertyValue -InputObject $Package -Name 'SignatureKind' -Default '')

    return $name -ceq 'Microsoft.DesktopAppInstaller' -and
        $familyName -ceq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -and
        $publisherId -ceq '8wekyb3d8bbwe' -and
        $signatureKind -in @('Store', 'System')
}

function Test-FreshWinTrustedMicrosoftExecutableSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [scriptblock]$SignatureProvider
    )

    try {
        $signature = if ($null -ne $SignatureProvider) {
            & $SignatureProvider $Path
        }
        else {
            $signatureCommand = Get-Command -Name Get-AuthenticodeSignature -CommandType Cmdlet -ErrorAction Stop |
                Select-Object -First 1
            & $signatureCommand -LiteralPath $Path -ErrorAction Stop
        }
        if ($null -eq $signature -or [string]$signature.Status -cne 'Valid') { return $false }
        $certificate = Get-FreshWinPropertyValue -InputObject $signature -Name 'SignerCertificate' -Default $null
        if ($null -eq $certificate) { return $false }
        $subject = [string](Get-FreshWinPropertyValue -InputObject $certificate -Name 'Subject' -Default '')
        return $subject -match '(?i)(^|,\s*)O=Microsoft Corporation(,|$)'
    }
    catch {
        return $false
    }
}

function Resolve-FreshWinTrustedWingetFromAppInstallerPackages {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Packages,
        [string]$CandidatePath,
        [scriptblock]$SignatureProvider
    )

    $trustedRoots = New-Object System.Collections.Generic.List[string]
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($CandidatePath)) {
        $candidates.Add($CandidatePath)
    }

    foreach ($desktopInstaller in @($Packages)) {
        if ($null -eq $desktopInstaller -or
            -not (Test-FreshWinTrustedAppInstallerIdentity -Package $desktopInstaller)) {
            continue
        }

        try {
            $installLocation = [string](Get-FreshWinPropertyValue -InputObject $desktopInstaller -Name 'InstallLocation' -Default '')
            if ([string]::IsNullOrWhiteSpace($installLocation) -or
                -not [System.IO.Directory]::Exists($installLocation)) {
                continue
            }

            $installItem = Get-Item -LiteralPath $installLocation -Force -ErrorAction Stop
            if (($installItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $trustedRoot = [System.IO.Path]::GetFullPath([string]$installItem.FullName)
            $trustedRoots.Add($trustedRoot)

            $packagedWinget = Join-Path $trustedRoot 'winget.exe'
            if (-not [System.IO.File]::Exists($packagedWinget)) { continue }
            $wingetItem = Get-Item -LiteralPath $packagedWinget -Force -ErrorAction Stop
            if (($wingetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                $candidates.Add([string]$wingetItem.FullName)
            }
        }
        catch {
            continue
        }
    }

    foreach ($candidate in $candidates) {
        try {
            if ($candidate -match '[\x00\r\n]') { continue }
            $fullPath = [System.IO.Path]::GetFullPath($candidate)
            if (-not [System.IO.File]::Exists($fullPath)) { continue }
            if ([System.IO.Path]::GetFileName($fullPath) -notin @('winget', 'winget.exe')) { continue }
            $candidateItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if (($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

            $trusted = $false
            foreach ($root in $trustedRoots) {
                if (Test-FreshWinPathWithinRoot -Path $fullPath -Root $root) {
                    $trusted = $true
                    break
                }
            }
            if ($trusted -and
                (Test-FreshWinTrustedMicrosoftExecutableSignature -Path $fullPath -SignatureProvider $SignatureProvider)) {
                return $fullPath
            }
        }
        catch {
            continue
        }
    }

    return $null
}

function Resolve-FreshWinTrustedWingetPath {
    [CmdletBinding()]
    param(
        [string]$CandidatePath,
        [scriptblock]$WindowsProvider,
        [scriptblock]$AdministratorProvider,
        [scriptblock]$AppxPackageProvider,
        [scriptblock]$SignatureProvider
    )

    $onWindows = Test-FreshWinResolverWindows -WindowsProvider $WindowsProvider
    if (-not $onWindows) {
        # Non-Windows paths are accepted only as explicit fixture seams.
        # FreshWin never executes them as a supported live workflow.
        if ([string]::IsNullOrWhiteSpace($CandidatePath) -or $CandidatePath -match '[\x00\r\n]') { return $null }
        try {
            $fullPath = [System.IO.Path]::GetFullPath($CandidatePath)
            if (-not [System.IO.File]::Exists($fullPath)) { return $null }
            if ([System.IO.Path]::GetFileName($fullPath) -notin @('winget', 'winget.exe')) { return $null }
            $candidateItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if (($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
            return $fullPath
        }
        catch {
            return $null
        }
    }

    $currentUserPackages = @(Get-FreshWinDesktopAppInstallerPackages -Scope CurrentUser `
        -PackageProvider $AppxPackageProvider)
    $resolved = Resolve-FreshWinTrustedWingetFromAppInstallerPackages -Packages $currentUserPackages `
        -CandidatePath $CandidatePath -SignatureProvider $SignatureProvider
    if (-not [string]::IsNullOrWhiteSpace($resolved)) { return $resolved }

    $isAdministrator = if ($null -ne $AdministratorProvider) {
        [bool](& $AdministratorProvider)
    }
    elseif ($null -ne (Get-Command -Name Test-FreshWinAdministrator -ErrorAction SilentlyContinue)) {
        [bool](Test-FreshWinAdministrator)
    }
    else {
        $false
    }
    if (-not $isAdministrator) { return $null }

    # A UAC handoff may run as a different administrator account that has no
    # current-user App Installer registration. The all-users query is therefore
    # an elevated-only fallback and receives the same identity/path/signature
    # validation as the preferred current-user package.
    $allUsersPackages = @(Get-FreshWinDesktopAppInstallerPackages -Scope AllUsers `
        -PackageProvider $AppxPackageProvider)
    return Resolve-FreshWinTrustedWingetFromAppInstallerPackages -Packages $allUsersPackages `
        -CandidatePath $CandidatePath -SignatureProvider $SignatureProvider
}

function Test-FreshWinOfficialSourceEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][string]$ExpectedHost,
        [Parameter(Mandatory = $true)][string]$ExpectedPath
    )

    if ([string]::IsNullOrWhiteSpace($Endpoint) -or $Endpoint -cne $Endpoint.Trim()) { return $false }
    $canonicalEndpoint = 'https://' + $ExpectedHost + $ExpectedPath
    if ($Endpoint -cne $canonicalEndpoint) { return $false }
    if ($Endpoint -match '[\x00-\x20\x7f]' -or
        $Endpoint.IndexOf('\\') -ge 0 -or
        $Endpoint.IndexOf('?') -ge 0 -or
        $Endpoint.IndexOf('#') -ge 0) {
        return $false
    }

    try { $uri = New-Object System.Uri($Endpoint, [System.UriKind]::Absolute) }
    catch { return $false }

    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne [System.Uri]::UriSchemeHttps) { return $false }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        return $false
    }
    if ($uri.DnsSafeHost -ine $ExpectedHost -or $uri.Port -ne 443) { return $false }
    return $uri.AbsolutePath -cin @($ExpectedPath, ($ExpectedPath + '/'))
}

function Get-FreshWinWingetSourceMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('winget', 'msstore')][string]$SourceName,
        [string]$WingetPath,
        [scriptblock]$SourceProvider
    )

    # The provider seam returns either the source-export JSON or an equivalent
    # object. It exists for deterministic fixtures and is never selected by the
    # live resolver unless a caller explicitly supplies it.
    if ($null -ne $SourceProvider) {
        return & $SourceProvider $SourceName $WingetPath
    }

    if (-not (Test-FreshWinResolverWindows)) {
        throw 'Live WinGet source metadata is available only on Windows.'
    }
    if ([string]::IsNullOrWhiteSpace($WingetPath)) {
        throw 'A trusted WinGet executable is required to query source metadata.'
    }

    $processResult = Invoke-FreshWinProcess -FilePath $WingetPath `
        -ArgumentList @('source', 'export', $SourceName, '--disable-interactivity') `
        -TimeoutSeconds 30 -ExpectedExitCodes @(0) -LogStage 'SOURCE' -LogAction "Validate:$SourceName"
    if ($null -eq $processResult -or
        -not [bool](Get-FreshWinPropertyValue -InputObject $processResult -Name 'Succeeded' -Default $false)) {
        throw "WinGet could not export source metadata for '$SourceName'."
    }
    return [string](Get-FreshWinPropertyValue -InputObject $processResult -Name 'StandardOutput' -Default '')
}

function Test-FreshWinTrustedWingetSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('winget', 'msstore')][string]$SourceName,
        [string]$WingetPath,
        [scriptblock]$SourceProvider
    )

    $canonicalName = $SourceName.ToLowerInvariant()
    $expected = if ($canonicalName -ceq 'winget') {
        [pscustomobject]@{
            Host = 'cdn.winget.microsoft.com'
            Path = '/cache'
            Type = 'Microsoft.PreIndexed.Package'
            Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
        }
    }
    else {
        [pscustomobject]@{
            Host = 'storeedgefd.dsx.mp.microsoft.com'
            Path = '/v9.0'
            Type = 'Microsoft.Rest'
            Identifier = $null
        }
    }

    $validation = [ordered]@{
        Trusted = $false
        SourceName = $canonicalName
        Endpoint = $null
        SourceType = $null
        Identifier = $null
        Reason = 'WinGet source metadata could not be queried.'
    }

    try {
        $metadata = Get-FreshWinWingetSourceMetadata -SourceName $canonicalName `
            -WingetPath $WingetPath -SourceProvider $SourceProvider
    }
    catch {
        return [pscustomobject]$validation
    }

    if ($metadata -is [string]) {
        $rawMetadata = [string]$metadata
        if ([string]::IsNullOrWhiteSpace($rawMetadata) -or $rawMetadata.Length -gt 65536) {
            $validation.Reason = 'WinGet source metadata was empty or exceeded the allowed size.'
            return [pscustomobject]$validation
        }
        try { $metadata = ConvertFrom-Json -InputObject $rawMetadata -ErrorAction Stop }
        catch {
            $validation.Reason = 'WinGet source metadata was not valid JSON.'
            return [pscustomobject]$validation
        }
    }

    if ($null -eq $metadata -or $metadata -is [System.Array] -or $metadata -is [string]) {
        $validation.Reason = 'WinGet source metadata was not a single object.'
        return [pscustomobject]$validation
    }

    $actualName = Get-FreshWinPropertyValue -InputObject $metadata -Name 'Name' -Default $null
    $endpoint = Get-FreshWinPropertyValue -InputObject $metadata -Name 'Arg' -Default $null
    $sourceType = Get-FreshWinPropertyValue -InputObject $metadata -Name 'Type' -Default $null
    if ($actualName -isnot [string] -or [string]$actualName -cne $canonicalName) {
        $validation.Reason = 'WinGet source metadata reported an unexpected source name.'
        return [pscustomobject]$validation
    }
    if ($endpoint -isnot [string] -or
        -not (Test-FreshWinOfficialSourceEndpoint -Endpoint ([string]$endpoint) `
            -ExpectedHost $expected.Host -ExpectedPath $expected.Path)) {
        $validation.Reason = "The '$canonicalName' source endpoint is not the official Microsoft endpoint."
        return [pscustomobject]$validation
    }
    if ($sourceType -isnot [string] -or [string]$sourceType -cne $expected.Type) {
        $validation.Reason = "The '$canonicalName' source type did not match the official source type."
        return [pscustomobject]$validation
    }

    $identifier = Get-FreshWinPropertyValue -InputObject $metadata -Name 'Identifier' -Default $null
    if ($canonicalName -ceq 'winget') {
        $dataIdentity = Get-FreshWinPropertyValue -InputObject $metadata -Name 'Data' -Default $null
        if ($identifier -isnot [string] -or [string]$identifier -cne $expected.Identifier -or
            $dataIdentity -isnot [string] -or [string]$dataIdentity -cne $expected.Identifier) {
            $validation.Reason = 'The WinGet cache source identity did not match Microsoft App Installer.'
            return [pscustomobject]$validation
        }
    }

    $validation.Trusted = $true
    $validation.Endpoint = [string]$endpoint
    $validation.SourceType = [string]$sourceType
    $validation.Identifier = $(if ($identifier -is [string]) { [string]$identifier } else { $null })
    $validation.Reason = $null
    return [pscustomobject]$validation
}

function Resolve-FreshWinSystemDismPath {
    [CmdletBinding()]
    param()

    if (-not (Test-FreshWinResolverWindows)) { return $null }
    # SystemDirectory is obtained from the operating system API and cannot be
    # redirected merely by changing the process's SystemRoot environment value.
    $systemDirectory = [Environment]::SystemDirectory
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) { return $null }
    try {
        $systemDirectory = [System.IO.Path]::GetFullPath($systemDirectory)
        $windowsRoot = [System.IO.Directory]::GetParent($systemDirectory).FullName
    }
    catch { return $null }

    $candidateDirectories = New-Object System.Collections.Generic.List[string]
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $candidateDirectories.Add((Join-Path $windowsRoot 'Sysnative'))
    }
    $candidateDirectories.Add($systemDirectory)

    foreach ($trustedDirectory in $candidateDirectories) {
        try {
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $trustedDirectory 'dism.exe'))
            if ([System.IO.File]::Exists($candidate) -and
                (Test-FreshWinPathWithinRoot -Path $candidate -Root $trustedDirectory) -and
                [System.IO.Path]::GetFileName($candidate) -ieq 'dism.exe') {
                return $candidate
            }
        }
        catch { }
    }
    return $null
}

function Resolve-FreshWinPackageSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [string]$WingetPath,
        [scriptblock]$WingetSourceProvider
    )

    $onWindows = Test-FreshWinResolverWindows

    $source = Get-FreshWinPropertyValue -InputObject $Package -Name 'source' -Default ([pscustomobject]@{})
    $sourceType = ([string](Get-FreshWinPropertyValue -InputObject $source -Name 'type' -Default '')).ToLowerInvariant()
    $result = [ordered]@{
        PackageId      = [string]$Package.id
        SourceType     = $sourceType
        Status         = 'Unavailable'
        Trust          = 'Unverified'
        Executable     = $null
        PackageManagerId = $null
        SourceName     = $null
        SourceEndpoint = $null
        SourceIdentifier = $null
        Uri            = $null
        FeatureName    = $null
        FeatureNames   = @()
        VersionPolicy  = Get-FreshWinPropertyValue -InputObject $Package -Name 'versionPolicy'
        Reason         = $null
    }

    switch ($sourceType) {
        'winget' {
            $packageId = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'packageId' -Default '')
            $sourceName = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'sourceName' -Default 'winget')
            if ($packageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{1,255}$') {
                $result.Reason = 'The WinGet package identifier failed validation.'
                break
            }
            if ($sourceName -ne 'winget') {
                $result.Reason = "The WinGet source '$sourceName' is not trusted for this workflow."
                break
            }
            $WingetPath = Resolve-FreshWinTrustedWingetPath -CandidatePath $WingetPath
            if ([string]::IsNullOrWhiteSpace($WingetPath)) {
                $result.Reason = 'A trusted Microsoft App Installer WinGet executable is not available.'
                break
            }
            if ($onWindows) {
                $sourceValidation = Test-FreshWinTrustedWingetSource -SourceName 'winget' `
                    -WingetPath $WingetPath -SourceProvider $WingetSourceProvider
                if (-not $sourceValidation.Trusted) {
                    $result.Reason = "The configured WinGet source failed trust validation: $($sourceValidation.Reason)"
                    break
                }
                $result.SourceEndpoint = $sourceValidation.Endpoint
                $result.SourceIdentifier = $sourceValidation.Identifier
            }
            $result.Status = 'Resolved'
            $result.Trust = $(if ($onWindows) { 'VerifiedPackageManager' } else { 'FixtureExecutable' })
            $result.Executable = $WingetPath
            $result.PackageManagerId = $packageId
            $result.SourceName = 'winget'
        }
        'msstore' {
            $packageId = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'packageId' -Default '')
            $sourceName = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'sourceName' -Default 'msstore')
            if ($packageId -notmatch '^[A-Za-z0-9._+-]{2,255}$') {
                $result.Reason = 'The Microsoft Store package identifier failed validation.'
                break
            }
            if ($sourceName -ne 'msstore') {
                $result.Reason = "The Microsoft Store source '$sourceName' is not trusted for this workflow."
                break
            }
            $WingetPath = Resolve-FreshWinTrustedWingetPath -CandidatePath $WingetPath
            if ([string]::IsNullOrWhiteSpace($WingetPath)) {
                $result.Reason = 'A trusted Microsoft App Installer WinGet executable is required for the Microsoft Store workflow.'
                break
            }
            if ($onWindows) {
                $sourceValidation = Test-FreshWinTrustedWingetSource -SourceName 'msstore' `
                    -WingetPath $WingetPath -SourceProvider $WingetSourceProvider
                if (-not $sourceValidation.Trusted) {
                    $result.Reason = "The configured Microsoft Store source failed trust validation: $($sourceValidation.Reason)"
                    break
                }
                $result.SourceEndpoint = $sourceValidation.Endpoint
                $result.SourceIdentifier = $sourceValidation.Identifier
            }
            $result.Status = 'Resolved'
            $result.Trust = $(if ($onWindows) { 'MicrosoftStore' } else { 'FixtureExecutable' })
            $result.Executable = $WingetPath
            $result.PackageManagerId = $packageId
            $result.SourceName = 'msstore'
        }
        'windows-feature' {
            $featureNames = @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $source -Name 'featureNames' -Default @()))
            if ($featureNames.Count -eq 0) {
                $singleFeatureName = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'featureName' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($singleFeatureName)) { $featureNames = @($singleFeatureName) }
            }
            $featureNames = @($featureNames | ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
            if ($featureNames.Count -eq 0 -or
                @($featureNames | Where-Object { $script:FreshWinAllowedWindowsFeatures -notcontains $_ }).Count -gt 0) {
                $result.Reason = 'The requested Windows feature is not in the FreshWin allowlist.'
                break
            }
            $result.FeatureName = $featureNames[0]
            $result.FeatureNames = $featureNames
            $dismPath = Resolve-FreshWinSystemDismPath
            if ([string]::IsNullOrWhiteSpace($dismPath)) {
                $result.Reason = 'DISM is unavailable on this platform.'
                break
            }
            $result.Status = 'Resolved'
            $result.Trust = 'WindowsComponent'
            $result.Executable = $dismPath
        }
        { $_ -in @('manual', 'official') } {
            $uri = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'manualUrl' -Default (Get-FreshWinPropertyValue -InputObject $Package -Name 'officialWebsite' -Default ''))
            if ($uri -notmatch '^https://') {
                $result.Reason = 'No verifiable HTTPS official workflow is configured.'
                break
            }
            $result.Status = 'Manual'
            $result.Trust = 'OfficialGuidance'
            $result.Uri = $uri
            $result.Reason = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'reason' -Default 'Automatic installation is intentionally unavailable; use the official vendor workflow.')
        }
        default {
            $result.Reason = "Unsupported source strategy '$sourceType'."
        }
    }

    return [pscustomobject]$result
}
