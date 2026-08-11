Set-StrictMode -Version Latest

function Get-FreshWinInstalledReleaseEndpoint {
    [CmdletBinding()]
    param()
    try {
        $manifestPath = Join-Path (Get-FreshWinProjectRoot) 'install-manifest.json'
        if (-not [IO.File]::Exists($manifestPath)) { return $null }
        $manifest = Read-FreshWinJsonFile -Path $manifestPath
        $value = [string](Get-FreshWinPropertyValue -InputObject $manifest -Name 'ReleaseMetadataUri' -Default '')
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }
        $uri = [Uri]$value
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.DnsSafeHost.ToLowerInvariant() -cne 'github.com' -or
            $uri.AbsolutePath -notmatch '^/[^/]+/[^/]+/releases/latest/download/FreshWin-stable\.release\.json$') { return $null }
        return $uri
    }
    catch { return $null }
}

function Get-FreshWinUpdateMetadataText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)][string[]]$AllowedHosts,
        [ValidateRange(1,60)][int]$TimeoutSeconds = 15
    )
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $allowed = @($AllowedHosts | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object Net.Http.HttpClient -ArgumentList (, $handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $current = $Uri
    try {
        for ($redirect = 0; $redirect -le 5; $redirect++) {
            if (-not $current.IsAbsoluteUri -or $current.Scheme -cne 'https' -or $allowed -notcontains $current.DnsSafeHost.ToLowerInvariant()) { throw 'Update metadata URI or redirect is not allowlisted.' }
            $response = $client.GetAsync($current).GetAwaiter().GetResult()
            try {
                $status = [int]$response.StatusCode
                if ($status -in @(301,302,303,307,308)) {
                    if ($redirect -eq 5 -or $null -eq $response.Headers.Location) { throw 'Update metadata exceeded its redirect limit.' }
                    $current = if ($response.Headers.Location.IsAbsoluteUri) { $response.Headers.Location } else { New-Object Uri -ArgumentList $current, $response.Headers.Location }
                    continue
                }
                if (-not $response.IsSuccessStatusCode) { throw "Update metadata request failed with HTTP status $status." }
                $length = $response.Content.Headers.ContentLength
                if ($null -ne $length -and ([long]$length -le 0 -or [long]$length -gt 1MB)) { throw 'Update metadata exceeds the 1 MB limit.' }
                $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 1MB) { throw 'Update metadata is empty or exceeds the 1 MB limit.' }
                return $text
            }
            finally { $response.Dispose() }
        }
    }
    finally { $client.Dispose(); $handler.Dispose() }
}

function Get-FreshWinUpdatePackageBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Uri]$Uri, [ValidateRange(1,600)][int]$TimeoutSeconds = 60)
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $allowed = @($Uri.DnsSafeHost.ToLowerInvariant())
    if ($Uri.DnsSafeHost.ToLowerInvariant() -eq 'github.com') { $allowed += @('objects.githubusercontent.com','release-assets.githubusercontent.com') }
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object Net.Http.HttpClient -ArgumentList (, $handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $current = $Uri
    try {
        for ($redirect = 0; $redirect -le 5; $redirect++) {
            if (-not $current.IsAbsoluteUri -or $current.Scheme -cne 'https' -or $allowed -notcontains $current.DnsSafeHost.ToLowerInvariant()) { throw 'Update package URI or redirect is not allowlisted.' }
            $response = $client.GetAsync($current).GetAwaiter().GetResult()
            try {
                $status = [int]$response.StatusCode
                if ($status -in @(301,302,303,307,308)) {
                    if ($redirect -eq 5 -or $null -eq $response.Headers.Location) { throw 'Update package exceeded its redirect limit.' }
                    $current = if ($response.Headers.Location.IsAbsoluteUri) { $response.Headers.Location } else { New-Object Uri -ArgumentList $current, $response.Headers.Location }
                    continue
                }
                if (-not $response.IsSuccessStatusCode) { throw "Update package request failed with HTTP status $status." }
                $length = $response.Content.Headers.ContentLength
                if ($null -ne $length -and ([long]$length -le 0 -or [long]$length -gt 100MB)) { throw 'Update package size is outside the allowed limit.' }
                $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                if ($bytes.Length -le 0 -or $bytes.Length -gt 100MB) { throw 'Update package is empty or exceeds the 100 MB safety limit.' }
                return $bytes
            }
            finally { $response.Dispose() }
        }
    }
    finally { $client.Dispose(); $handler.Dispose() }
}

function Test-FreshWinUpdateMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Metadata,
        [Parameter(Mandatory = $true)][string[]]$AllowedHosts,
        [ValidateSet('stable', 'preview')][string]$Channel = 'stable'
    )

    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Metadata) {
        $errors.Add('Update metadata is null.')
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray(); PackageUri = $null }
    }
    $allowedProperties = @('schemaVersion', 'channel', 'version', 'publishedAtUtc', 'packageUri', 'sha256', 'minimumPowerShellVersion', 'notes')
    foreach ($property in @($Metadata.PSObject.Properties)) {
        if ($allowedProperties -notcontains [string]$property.Name) { $errors.Add("Unsupported update metadata property '$($property.Name)'.") }
    }
    foreach ($required in @('schemaVersion', 'channel', 'version', 'publishedAtUtc', 'packageUri', 'sha256')) {
        if (-not (Test-FreshWinHasProperty -InputObject $Metadata -Name $required)) { $errors.Add("Missing update metadata property '$required'.") }
    }
    if ([int](Get-FreshWinPropertyValue -InputObject $Metadata -Name 'schemaVersion' -Default 0) -ne 1) { $errors.Add('Update metadata schemaVersion must be 1.') }
    $metadataChannel = [string](Get-FreshWinPropertyValue -InputObject $Metadata -Name 'channel' -Default '')
    if ($metadataChannel -notin @('stable', 'preview') -or $metadataChannel -ne $Channel) { $errors.Add("Update metadata channel '$metadataChannel' does not match '$Channel'.") }
    $versionText = [string](Get-FreshWinPropertyValue -InputObject $Metadata -Name 'version' -Default '')
    $parsedVersion = $null
    if ($versionText -notmatch '^\d+\.\d+\.\d+$' -or -not [version]::TryParse($versionText, [ref]$parsedVersion)) { $errors.Add('Update metadata version must be a three-part numeric version.') }
    $published = ConvertTo-FreshWinDateTimeOffset -Value (Get-FreshWinPropertyValue -InputObject $Metadata -Name 'publishedAtUtc' -Default $null)
    if ($null -eq $published) { $errors.Add('Update metadata publishedAtUtc is invalid.') }
    $sha256 = [string](Get-FreshWinPropertyValue -InputObject $Metadata -Name 'sha256' -Default '')
    if ($sha256 -notmatch '^[a-fA-F0-9]{64}$') { $errors.Add('Update package SHA-256 is invalid.') }

    $uri = $null
    try { $uri = [Uri]([string](Get-FreshWinPropertyValue -InputObject $Metadata -Name 'packageUri' -Default '')) } catch { }
    $normalizedHosts = @($AllowedHosts | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ($null -eq $uri -or -not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $normalizedHosts -notcontains $uri.DnsSafeHost.ToLowerInvariant()) {
        $errors.Add('Update packageUri must use HTTPS on an explicitly allowed host.')
    }
    $minimumText = [string](Get-FreshWinPropertyValue -InputObject $Metadata -Name 'minimumPowerShellVersion' -Default '5.1')
    $minimumVersion = $null
    if (-not [version]::TryParse($minimumText, [ref]$minimumVersion) -or $minimumVersion -lt [version]'5.1') { $errors.Add('minimumPowerShellVersion is invalid.') }

    return [pscustomobject]@{
        IsValid = $errors.Count -eq 0
        Errors = $errors.ToArray()
        Channel = $metadataChannel
        Version = $parsedVersion
        PackageUri = $uri
        Sha256 = $sha256.ToLowerInvariant()
        PublishedAtUtc = $published
        MinimumPowerShellVersion = $minimumVersion
    }
}

function Get-FreshWinUpdateStatus {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Config,
        [AllowNull()][object]$Metadata,
        [scriptblock]$MetadataProvider,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 15
    )

    if ($null -eq $Config) { $Config = Get-FreshWinConfig }
    $Config = ConvertTo-FreshWinConfig -InputObject $Config
    $uriText = [string]$Config.updates.metadataUri
    $allowedHosts = @($Config.updates.allowedHosts)
    if ([string]::IsNullOrWhiteSpace($uriText)) {
        $installedEndpoint = Get-FreshWinInstalledReleaseEndpoint
        if ($null -ne $installedEndpoint) {
            $uriText = $installedEndpoint.AbsoluteUri
            $allowedHosts = @('github.com','objects.githubusercontent.com','release-assets.githubusercontent.com')
        }
    }
    if ($null -eq $Metadata -and [string]::IsNullOrWhiteSpace($uriText)) {
        return [pscustomobject]@{ Status = 'NotConfigured'; UpdateAvailable = $false; CurrentVersion = Get-FreshWinVersion; AvailableVersion = $null; Metadata = $null; Validation = $null; MutationPerformed = $false; Reason = 'No trusted update metadata endpoint is configured.' }
    }

    try {
        if ($null -eq $Metadata) {
            if ($null -ne $MetadataProvider) { $Metadata = & $MetadataProvider ([Uri]$uriText) }
            else {
                $text = Get-FreshWinUpdateMetadataText -Uri ([Uri]$uriText) -AllowedHosts $allowedHosts -TimeoutSeconds $TimeoutSeconds
                $Metadata = ConvertFrom-Json -InputObject $text -ErrorAction Stop
            }
            if ($Metadata -is [string]) { $Metadata = ConvertFrom-Json -InputObject ([string]$Metadata) -ErrorAction Stop }
        }
        $validation = Test-FreshWinUpdateMetadata -Metadata $Metadata -AllowedHosts $allowedHosts -Channel ([string]$Config.updates.channel)
        if (-not $validation.IsValid) {
            return [pscustomobject]@{ Status = 'Invalid'; UpdateAvailable = $false; CurrentVersion = Get-FreshWinVersion; AvailableVersion = $null; Metadata = $null; Validation = $validation; MutationPerformed = $false; Reason = ($validation.Errors -join ' ') }
        }
        $current = [version](Get-FreshWinVersion)
        $available = [version]$validation.Version
        $status = if ($available -gt $current) { 'Available' } elseif ($available -eq $current) { 'Current' } else { 'LocalNewer' }
        return [pscustomobject]@{ Status = $status; UpdateAvailable = $available -gt $current; CurrentVersion = $current.ToString(); AvailableVersion = $available.ToString(); Metadata = $Metadata; Validation = $validation; MutationPerformed = $false; Reason = 'Update metadata was validated; no package was downloaded or executed.' }
    }
    catch {
        return [pscustomobject]@{ Status = 'Unavailable'; UpdateAvailable = $false; CurrentVersion = Get-FreshWinVersion; AvailableVersion = $null; Metadata = $null; Validation = $null; MutationPerformed = $false; Reason = (Protect-FreshWinSensitiveText -Text $_.Exception.Message) }
    }
}

function Get-FreshWinUpdateStagingIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$UpdateStatus)

    $validation = Get-FreshWinPropertyValue -InputObject $UpdateStatus -Name 'Validation' -Default $null
    $metadata = Get-FreshWinPropertyValue -InputObject $UpdateStatus -Name 'Metadata' -Default $null
    if ($null -eq $validation -or -not [bool](Get-FreshWinPropertyValue -InputObject $validation -Name 'IsValid' -Default $false) -or
        $null -eq $metadata) {
        throw 'Validated update metadata identity is required before staging or reusing an archive.'
    }

    $packageUri = Get-FreshWinPropertyValue -InputObject $validation -Name 'PackageUri' -Default $null
    $published = Get-FreshWinPropertyValue -InputObject $validation -Name 'PublishedAtUtc' -Default $null
    if ($null -eq $packageUri -or $null -eq $published) {
        throw 'Validated update metadata does not contain a complete package identity.'
    }
    $metadataVersion = [string](Get-FreshWinPropertyValue -InputObject $metadata -Name 'version' -Default '')
    $metadataChannel = [string](Get-FreshWinPropertyValue -InputObject $metadata -Name 'channel' -Default '')
    $validatedChannel = [string](Get-FreshWinPropertyValue -InputObject $validation -Name 'Channel' -Default '')
    $validatedVersion = Get-FreshWinPropertyValue -InputObject $validation -Name 'Version' -Default $null
    $metadataPublished = ConvertTo-FreshWinDateTimeOffset -Value (Get-FreshWinPropertyValue -InputObject $metadata -Name 'publishedAtUtc' -Default $null)
    $metadataPackageUri = $null
    try { $metadataPackageUri = [Uri]([string](Get-FreshWinPropertyValue -InputObject $metadata -Name 'packageUri' -Default '')) } catch { }
    $metadataSha256 = ([string](Get-FreshWinPropertyValue -InputObject $metadata -Name 'sha256' -Default '')).ToLowerInvariant()
    if ($metadataChannel -cne $validatedChannel -or $validatedChannel -notin @('stable','preview') -or
        $null -eq $validatedVersion -or $metadataVersion -cne ([version]$validatedVersion).ToString() -or
        $null -eq $metadataPublished -or $metadataPublished.UtcDateTime.Ticks -ne ([DateTimeOffset]$published).UtcDateTime.Ticks -or
        $null -eq $metadataPackageUri -or $metadataPackageUri.AbsoluteUri -cne ([Uri]$packageUri).AbsoluteUri -or
        $metadataSha256 -cne ([string](Get-FreshWinPropertyValue -InputObject $validation -Name 'Sha256' -Default '')).ToLowerInvariant()) {
        throw 'Update metadata no longer matches its validated package identity.'
    }
    $minimumPowerShellVersion = Get-FreshWinPropertyValue -InputObject $validation -Name 'MinimumPowerShellVersion' -Default $null
    if ($null -eq $minimumPowerShellVersion) { throw 'Validated update metadata does not contain its minimum PowerShell version.' }

    return [pscustomobject][ordered]@{
        schemaVersion  = 1
        channel        = $validatedChannel
        version        = [string](Get-FreshWinPropertyValue -InputObject $metadata -Name 'version' -Default '')
        publishedAtUtc = ([DateTimeOffset]$published).ToUniversalTime().ToString('o')
        packageUri     = ([Uri]$packageUri).AbsoluteUri
        sha256         = ([string](Get-FreshWinPropertyValue -InputObject $validation -Name 'Sha256' -Default '')).ToLowerInvariant()
        minimumPowerShellVersion = ([version]$minimumPowerShellVersion).ToString()
    }
}

function Get-FreshWinUpdateFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Test-FreshWinStagedUpdatePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Identity
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $metadataPath = $fullPath + '.metadata.json'
    if (-not [IO.File]::Exists($fullPath) -or -not [IO.File]::Exists($metadataPath)) {
        return [pscustomobject]@{ IsValid=$false; Reason='Both the staged archive and its identity sidecar are required.'; Path=$fullPath; MetadataPath=$metadataPath }
    }
    foreach ($candidate in @($fullPath, $metadataPath)) {
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ IsValid=$false; Reason='A staged update artifact cannot be a reparse point.'; Path=$fullPath; MetadataPath=$metadataPath }
        }
    }
    $archive = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    $sidecar = Get-Item -LiteralPath $metadataPath -Force -ErrorAction Stop
    if ($archive.Length -le 0 -or $archive.Length -gt 100MB -or $sidecar.Length -le 0 -or $sidecar.Length -gt 64KB) {
        return [pscustomobject]@{ IsValid=$false; Reason='The staged update archive or identity sidecar has an invalid size.'; Path=$fullPath; MetadataPath=$metadataPath }
    }

    try { $saved = Read-FreshWinJsonFile -Path $metadataPath }
    catch { return [pscustomobject]@{ IsValid=$false; Reason='The staged update identity sidecar is invalid JSON.'; Path=$fullPath; MetadataPath=$metadataPath } }
    $allowed = @('schemaVersion','channel','version','publishedAtUtc','packageUri','sha256','minimumPowerShellVersion','length')
    if (@($saved.PSObject.Properties | Where-Object { $allowed -notcontains [string]$_.Name }).Count -gt 0 -or
        [int](Get-FreshWinPropertyValue -InputObject $saved -Name 'schemaVersion' -Default 0) -ne 1) {
        return [pscustomobject]@{ IsValid=$false; Reason='The staged update identity sidecar schema is invalid.'; Path=$fullPath; MetadataPath=$metadataPath }
    }
    foreach ($name in @('channel','version','packageUri','sha256','minimumPowerShellVersion')) {
        if ([string](Get-FreshWinPropertyValue -InputObject $saved -Name $name -Default '') -cne
            [string](Get-FreshWinPropertyValue -InputObject $Identity -Name $name -Default '')) {
            return [pscustomobject]@{ IsValid=$false; Reason="The staged update identity does not match '$name'."; Path=$fullPath; MetadataPath=$metadataPath }
        }
    }
    $savedPublished = ConvertTo-FreshWinDateTimeOffset -Value (Get-FreshWinPropertyValue -InputObject $saved -Name 'publishedAtUtc' -Default $null)
    $expectedPublished = ConvertTo-FreshWinDateTimeOffset -Value (Get-FreshWinPropertyValue -InputObject $Identity -Name 'publishedAtUtc' -Default $null)
    if ($null -eq $savedPublished -or $null -eq $expectedPublished -or $savedPublished.UtcDateTime.Ticks -ne $expectedPublished.UtcDateTime.Ticks) {
        return [pscustomobject]@{ IsValid=$false; Reason="The staged update identity does not match 'publishedAtUtc'."; Path=$fullPath; MetadataPath=$metadataPath }
    }
    $savedLength = Get-FreshWinPropertyValue -InputObject $saved -Name 'length' -Default $null
    if ($null -eq $savedLength -or [long]$savedLength -ne [long]$archive.Length) {
        return [pscustomobject]@{ IsValid=$false; Reason='The staged update length does not match its identity sidecar.'; Path=$fullPath; MetadataPath=$metadataPath }
    }
    $actualHash = Get-FreshWinUpdateFileSha256 -Path $fullPath
    if ($actualHash -cne [string]$Identity.sha256) {
        return [pscustomobject]@{ IsValid=$false; Reason='The staged update archive failed SHA-256 validation.'; Path=$fullPath; MetadataPath=$metadataPath }
    }
    return [pscustomobject]@{ IsValid=$true; Reason='The existing archive matches the complete validated metadata identity and SHA-256.'; Path=$fullPath; MetadataPath=$metadataPath; Sha256=$actualHash; Length=[long]$archive.Length }
}

function Save-FreshWinUpdatePackage {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][object]$UpdateStatus,
        [string]$DestinationPath,
        [scriptblock]$PackageProvider,
        [scriptblock]$DownloadsKnownFolderProvider,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    if ([string](Get-FreshWinPropertyValue -InputObject $UpdateStatus -Name 'Status' -Default '') -ne 'Available') { throw 'A validated available update is required before staging.' }
    $validation = Get-FreshWinPropertyValue -InputObject $UpdateStatus -Name 'Validation' -Default $null
    if ($null -eq $validation -or -not [bool]$validation.IsValid) { throw 'Update metadata validation is missing or invalid.' }
    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        $versionName = ([version](Get-FreshWinPropertyValue -InputObject $validation -Name 'Version')).ToString()
        $DestinationPath = Get-FreshWinDefaultArtifactPath -Category Installers -FileName ("FreshWin-$versionName.zip") -KnownFolderProvider $DownloadsKnownFolderProvider
    }
    $fullPath = [IO.Path]::GetFullPath($DestinationPath)
    if ([IO.Path]::GetExtension($fullPath) -ne '.zip') { throw 'FreshWin update staging paths must use the .zip extension.' }
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    $metadataPath = $fullPath + '.metadata.json'
    if ([string]::IsNullOrWhiteSpace($directory)) { throw 'An update staging directory is required.' }
    $directoryRoot = [IO.Path]::GetPathRoot($directory)
    if ([string]::Equals($directory.TrimEnd([char]'\', [char]'/'), $directoryRoot.TrimEnd([char]'\', [char]'/'), [StringComparison]::OrdinalIgnoreCase)) { throw 'The filesystem root cannot be used as an update staging directory.' }
    if ([IO.Directory]::Exists($directory)) {
        $directoryItem = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Update staging directory cannot be a reparse point.' }
    }
    if ([IO.File]::Exists($fullPath)) {
        $identity = Get-FreshWinUpdateStagingIdentity -UpdateStatus $UpdateStatus
        $reuse = Test-FreshWinStagedUpdatePackage -Path $fullPath -Identity $identity
        if (-not $reuse.IsValid) { throw "Update staging path already exists but cannot be safely reused. $($reuse.Reason)" }
        return [pscustomobject]@{ Status='Reused'; Path=$fullPath; MetadataPath=$metadataPath; Sha256=$reuse.Sha256; Length=$reuse.Length; Executed=$false; ApplyAutomatically=$false; MutationPerformed=$false; Reused=$true }
    }
    if ([IO.File]::Exists($metadataPath)) { throw "Update staging identity path already exists without its archive: $metadataPath" }
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Download and hash-verify FreshWin update archive without executing it')) {
        return [pscustomobject]@{ Status='Preview'; Path=$fullPath; MetadataPath=$metadataPath; Executed=$false; ApplyAutomatically=$false; MutationPerformed=$false; Reused=$false }
    }

    $identity = Get-FreshWinUpdateStagingIdentity -UpdateStatus $UpdateStatus

    if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
    $directoryItem = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
    if (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Update staging directory cannot be a reparse point.' }

    $downloaded = $null
    if ($null -ne $PackageProvider) {
        $downloaded = & $PackageProvider $validation.PackageUri
    } else {
        $downloaded = Get-FreshWinUpdatePackageBytes -Uri $validation.PackageUri -TimeoutSeconds $TimeoutSeconds
    }
    try { $bytes = [byte[]]@($downloaded) }
    catch { throw 'The update package provider did not return bytes.' }
    if ($bytes.Length -eq 0 -or $bytes.Length -gt 100MB) { throw 'The update package is empty or exceeds the 100 MB safety limit.' }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $actualHash = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    if ($actualHash -ne [string]$validation.Sha256) { throw 'The staged update package failed SHA-256 validation.' }
    $temporaryBase = '.freshwin-update-' + [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $directory ($temporaryBase + '.tmp')
    $temporaryMetadataPath = Join-Path $directory ($temporaryBase + '.metadata.tmp')
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $bytes)
        $stagingIdentity = [pscustomobject][ordered]@{
            schemaVersion=$identity.schemaVersion; channel=$identity.channel; version=$identity.version
            publishedAtUtc=$identity.publishedAtUtc; packageUri=$identity.packageUri
            sha256=$identity.sha256; minimumPowerShellVersion=$identity.minimumPowerShellVersion; length=[long]$bytes.Length
        }
        [void](Write-FreshWinJsonFile -Path $temporaryMetadataPath -Value $stagingIdentity -Depth 8 -CreateNew)
        [IO.File]::Move($temporaryPath, $fullPath)
        [IO.File]::Move($temporaryMetadataPath, $metadataPath)
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        if ([IO.File]::Exists($temporaryMetadataPath)) { [IO.File]::Delete($temporaryMetadataPath) }
    }
    return [pscustomobject]@{ Status='Staged'; Path=$fullPath; MetadataPath=$metadataPath; Sha256=$actualHash; Length=$bytes.Length; Executed=$false; ApplyAutomatically=$false; MutationPerformed=$true; Reused=$false }
}

function Invoke-FreshWinCoreUpdate {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [AllowNull()][object]$UpdateStatus,
        [scriptblock]$PackageProvider,
        [scriptblock]$InstallerInvoker,
        [ValidateRange(1,600)][int]$TimeoutSeconds = 60
    )
    if ($null -eq $UpdateStatus) { $UpdateStatus = Get-FreshWinUpdateStatus }
    if ([string](Get-FreshWinPropertyValue $UpdateStatus 'Status' '') -ne 'Available' -or -not [bool](Get-FreshWinPropertyValue $UpdateStatus 'UpdateAvailable' $false)) {
        throw 'A reviewed, validated FreshWin update is required.'
    }
    $version = ([version](Get-FreshWinPropertyValue (Get-FreshWinPropertyValue $UpdateStatus 'Validation' $null) 'Version' $null)).ToString()
    if (-not $PSCmdlet.ShouldProcess("FreshWin $version", 'Download, verify, stage, and invoke the protected atomic installer')) {
        return [pscustomobject]@{ Status='Preview'; Version=$version; MutationPerformed=$false }
    }
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('FreshWin-update-' + [guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $temporaryRoot ("FreshWin-$version.zip")
    $payloadRoot = Join-Path $temporaryRoot 'payload'
    try {
        [void][IO.Directory]::CreateDirectory($temporaryRoot)
        $staged = Save-FreshWinUpdatePackage -UpdateStatus $UpdateStatus -DestinationPath $archivePath -PackageProvider $PackageProvider -TimeoutSeconds $TimeoutSeconds -Confirm:$false
        $bootstrapLibrary = Join-Path (Get-FreshWinProjectRoot) 'bootstrap.ps1'
        if (-not [IO.File]::Exists($bootstrapLibrary)) { throw 'Trusted release validation support is missing.' }
        . $bootstrapLibrary -LibraryMode
        Expand-FreshWinBootstrapArchive -ArchivePath $staged.Path -DestinationRoot $payloadRoot
        [void](Test-FreshWinBootstrapPayload -Root $payloadRoot -ExpectedVersion $version)
        $releaseEndpoint = Get-FreshWinInstalledReleaseEndpoint
        if ($null -eq $releaseEndpoint) { throw 'The protected installation has no trusted release metadata endpoint.' }
        if ($null -ne $InstallerInvoker) { $installExitCode = [int](& $InstallerInvoker $payloadRoot $releaseEndpoint.AbsoluteUri) }
        else {
            $powershell = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'powershell.exe')
            & $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $payloadRoot 'install.ps1') -SourceRoot $payloadRoot -ReleaseMetadataUri $releaseEndpoint.AbsoluteUri -UpdateCallerProcessId $PID
            $installExitCode = [int]$LASTEXITCODE
        }
        if ($installExitCode -ne 0) { throw "Protected FreshWin update failed with exit code $installExitCode." }
        return [pscustomobject]@{ Status='Installed'; Version=$version; MutationPerformed=$true; Verified=$true }
    }
    finally {
        if ([IO.Directory]::Exists($temporaryRoot)) {
            try { [IO.Directory]::Delete($temporaryRoot, $true) } catch { Write-Warning 'FreshWin could not completely remove its temporary update staging directory.' }
        }
    }
}
