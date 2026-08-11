Set-StrictMode -Version Latest

function Test-FreshWinHttpsUri {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    try {
        $uri = New-Object System.Uri -ArgumentList $Value
        return $uri.IsAbsoluteUri -and $uri.Scheme -eq 'https' -and -not [string]::IsNullOrWhiteSpace($uri.DnsSafeHost)
    }
    catch {
        return $false
    }
}

function Add-FreshWinUnknownPropertyErrors {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][object]$Errors
    )

    if ($null -eq $InputObject) { return }
    $names = if ($InputObject -is [System.Collections.IDictionary]) {
        @($InputObject.Keys | ForEach-Object { [string]$_ })
    } else {
        @($InputObject.PSObject.Properties | ForEach-Object { [string]$_.Name })
    }
    foreach ($name in $names) {
        if ($Allowed -notcontains $name) {
            $Errors.Add("Unsupported property '$Context.$name'.")
        }
    }
}

function Add-FreshWinRequiredPropertyErrors {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][object]$Errors
    )

    foreach ($name in $Required) {
        if ($null -eq $InputObject -or -not (Test-FreshWinHasProperty -InputObject $InputObject -Name $name)) {
            $Errors.Add("Missing required property '$Context.$name'.")
        }
    }
}

function Test-FreshWinManifestArray {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    return $null -ne $Value -and $Value -isnot [string] -and
        $Value -isnot [System.Collections.IDictionary] -and
        $Value -is [System.Collections.IEnumerable]
}

function Test-FreshWinManifestPropertyArray {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-FreshWinHasProperty -InputObject $InputObject -Name $Name)) { return $false }
    $value = $null
    if ($InputObject -is [System.Collections.IDictionary]) {
        $value = $InputObject[$Name]
    } else {
        $value = $InputObject.PSObject.Properties[$Name].Value
    }
    return Test-FreshWinManifestArray -Value $value
}

function Test-FreshWinPackageManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest,

        [string]$SourcePath
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Manifest) {
        $errors.Add('Manifest is null.')
        return [PSCustomObject]@{
            IsValid   = $false
            Errors    = $errors.ToArray()
            Warnings  = $warnings.ToArray()
            SourcePath = $SourcePath
        }
    }

    $requiredProperties = @(
        'schemaVersion', 'id', 'name', 'descriptionKey', 'category', 'subcategory',
        'publisher', 'officialWebsite', 'source', 'compatibility', 'versionPolicy',
        'detection', 'dependencies', 'install', 'verification', 'restart', 'riskLevel',
        'license', 'recommendation', 'tags'
    )
    Add-FreshWinUnknownPropertyErrors -InputObject $Manifest -Allowed $requiredProperties -Context 'manifest' -Errors $errors
    foreach ($propertyName in $requiredProperties) {
        if (-not (Test-FreshWinHasProperty -InputObject $Manifest -Name $propertyName)) {
            $errors.Add("Missing required property '$propertyName'.")
        }
    }
    foreach ($objectProperty in @('source', 'compatibility', 'versionPolicy', 'detection', 'install', 'verification', 'restart', 'license', 'recommendation')) {
        $objectValue = Get-FreshWinPropertyValue -InputObject $Manifest -Name $objectProperty -Default $null
        if ($null -eq $objectValue -or $objectValue -is [string] -or $objectValue -is [ValueType] -or
            (Test-FreshWinManifestArray -Value $objectValue)) {
            $errors.Add("Property '$objectProperty' must be a non-null object.")
        }
    }

    $schemaVersion = [string](Get-FreshWinPropertyValue -InputObject $Manifest -Name 'schemaVersion' -Default '')
    if ($schemaVersion -ne '1.0') {
        $errors.Add("Unsupported schemaVersion '$schemaVersion'.")
    }

    $id = [string](Get-FreshWinPropertyValue -InputObject $Manifest -Name 'id' -Default '')
    if ($id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $id.Length -gt 64) {
        $errors.Add("Package id '$id' must be a lower-case, hyphen-separated catalog identifier.")
    }

    foreach ($textProperty in @('name', 'descriptionKey', 'category', 'subcategory', 'publisher')) {
        $value = [string](Get-FreshWinPropertyValue -InputObject $Manifest -Name $textProperty -Default '')
        if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[\r\n\x00]') {
            $errors.Add("Property '$textProperty' must be a non-empty single-line string.")
        }
    }

    $descriptionKey = [string](Get-FreshWinPropertyValue -InputObject $Manifest -Name 'descriptionKey' -Default '')
    if ($descriptionKey -ne "packages.$id.description") {
        $errors.Add("descriptionKey must be 'packages.$id.description'.")
    }
    $category = [string](Get-FreshWinPropertyValue -InputObject $Manifest -Name 'category' -Default '')
    if (@('essential', 'communication', 'gaming', 'developer', 'creator', 'security', 'runtime', 'driver', 'tool') -notcontains $category) {
        $errors.Add("Unsupported category '$category'.")
    }

    $officialWebsite = [string](Get-FreshWinPropertyValue -InputObject $Manifest -Name 'officialWebsite' -Default '')
    if (-not (Test-FreshWinHttpsUri -Value $officialWebsite)) {
        $errors.Add('officialWebsite must be an absolute HTTPS URL.')
    }

    $sourceType = ''
    $source = Get-FreshWinPropertyValue -InputObject $Manifest -Name 'source' -Default $null
    if ($null -ne $source) {
        Add-FreshWinUnknownPropertyErrors -InputObject $source -Allowed @('type', 'packageId', 'sourceName', 'manualUrl', 'reason', 'featureNames') -Context 'source' -Errors $errors
        Add-FreshWinRequiredPropertyErrors -InputObject $source -Required @('type') -Context 'source' -Errors $errors
        $sourceType = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'type' -Default '')
        $allowedSourceTypes = @('winget', 'msstore', 'official', 'manual', 'windows-feature')
        if ($allowedSourceTypes -notcontains $sourceType) {
            $errors.Add("Unsupported source.type '$sourceType'.")
        }
        elseif ($sourceType -in @('winget', 'msstore')) {
            Add-FreshWinRequiredPropertyErrors -InputObject $source -Required @('packageId', 'sourceName') -Context 'source' -Errors $errors
            $packageId = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'packageId' -Default '')
            if ($packageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{1,255}$') {
                $errors.Add("source.packageId is invalid for source type '$sourceType'.")
            }
            $sourceName = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'sourceName' -Default $sourceType)
            if ($sourceName -ne $sourceType) {
                $errors.Add("source.sourceName '$sourceName' is inconsistent with source.type '$sourceType'.")
            }
        }
        elseif ($sourceType -in @('official', 'manual')) {
            Add-FreshWinRequiredPropertyErrors -InputObject $source -Required @('manualUrl', 'reason') -Context 'source' -Errors $errors
            $manualUrl = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'manualUrl' -Default '')
            if (-not (Test-FreshWinHttpsUri -Value $manualUrl)) {
                $errors.Add("source.manualUrl must be an absolute HTTPS URL for source type '$sourceType'.")
            }
            $reason = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'reason' -Default '')
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $errors.Add("source.reason is required for source type '$sourceType'.")
            }
        }
        elseif ($sourceType -eq 'windows-feature') {
            Add-FreshWinRequiredPropertyErrors -InputObject $source -Required @('featureNames') -Context 'source' -Errors $errors
            $rawFeatureNames = Get-FreshWinPropertyValue -InputObject $source -Name 'featureNames' -Default $null
            if (-not (Test-FreshWinManifestPropertyArray -InputObject $source -Name 'featureNames')) { $errors.Add('source.featureNames must be an array.') }
            $featureNames = @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $source -Name 'featureNames' -Default @()))
            if ($featureNames.Count -eq 0) {
                $errors.Add('A windows-feature source requires at least one featureNames entry.')
            }
            foreach ($featureName in $featureNames) {
                if ([string]$featureName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$') {
                    $errors.Add("Invalid Windows feature name '$featureName'.")
                }
            }
        }
    }

    $compatibility = Get-FreshWinPropertyValue -InputObject $Manifest -Name 'compatibility' -Default $null
    if ($null -ne $compatibility) {
        Add-FreshWinUnknownPropertyErrors -InputObject $compatibility -Allowed @('os', 'minimumBuild', 'architectures', 'minimumRamGB', 'hardware', 'features', 'providesFeatures') -Context 'compatibility' -Errors $errors
        Add-FreshWinRequiredPropertyErrors -InputObject $compatibility -Required @('os', 'minimumBuild', 'architectures', 'minimumRamGB', 'hardware', 'features') -Context 'compatibility' -Errors $errors
        foreach ($arrayName in @('os', 'architectures')) {
            if (-not (Test-FreshWinManifestPropertyArray -InputObject $compatibility -Name $arrayName)) {
                $errors.Add("compatibility.$arrayName must be an array.")
            }
        }
        $operatingSystems = @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $compatibility -Name 'os' -Default @()))
        if ($operatingSystems.Count -eq 0) {
            $errors.Add('compatibility.os must contain at least one supported Windows version.')
        }
        foreach ($operatingSystem in $operatingSystems) {
            if (@('windows10', 'windows11') -notcontains [string]$operatingSystem) {
                $errors.Add("Unsupported compatibility.os value '$operatingSystem'.")
            }
        }

        $architectures = @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $compatibility -Name 'architectures' -Default @()))
        if ($architectures.Count -eq 0) {
            $errors.Add('compatibility.architectures must not be empty.')
        }
        foreach ($architecture in $architectures) {
            if (@('x64', 'arm64', 'x86') -notcontains [string]$architecture) {
                $errors.Add("Unsupported architecture '$architecture'.")
            }
        }

        $minimumBuild = Get-FreshWinPropertyValue -InputObject $compatibility -Name 'minimumBuild' -Default 0
        $parsedBuild = 0
        if ($null -eq $minimumBuild -or
            -not [int]::TryParse([string]$minimumBuild, [ref]$parsedBuild) -or $parsedBuild -lt 10240) {
            $errors.Add('compatibility.minimumBuild must be an integer of at least 10240.')
        }

        $minimumRam = Get-FreshWinPropertyValue -InputObject $compatibility -Name 'minimumRamGB' -Default 0
        $parsedRam = 0.0
        if ($null -eq $minimumRam -or
            -not [double]::TryParse(
                [string]$minimumRam,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsedRam
            ) -or $parsedRam -lt 0) {
            $errors.Add('compatibility.minimumRamGB must be a non-negative number.')
        }

        $hardware = Get-FreshWinPropertyValue -InputObject $compatibility -Name 'hardware' -Default $null
        if ($null -eq $hardware -or $hardware -is [string] -or (Test-FreshWinManifestArray -Value $hardware)) { $errors.Add('compatibility.hardware must be an object.') }
        Add-FreshWinUnknownPropertyErrors -InputObject $hardware -Allowed @('gpuVendors', 'oemVendors', 'deviceClasses') -Context 'compatibility.hardware' -Errors $errors
        foreach ($arrayName in @('gpuVendors', 'oemVendors', 'deviceClasses')) {
            if (Test-FreshWinHasProperty -InputObject $hardware -Name $arrayName) {
                if (-not (Test-FreshWinManifestPropertyArray -InputObject $hardware -Name $arrayName)) {
                    $errors.Add("compatibility.hardware.$arrayName must be an array.")
                }
            }
        }
        foreach ($gpuVendor in @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $hardware -Name 'gpuVendors' -Default @()))) {
            if (@('NVIDIA', 'AMD', 'Intel') -notcontains [string]$gpuVendor) { $errors.Add("Unsupported GPU vendor '$gpuVendor'.") }
        }
        foreach ($oemVendor in @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $hardware -Name 'oemVendors' -Default @()))) {
            if (@('Dell', 'HP', 'Lenovo', 'ASUS', 'MSI', 'Acer') -notcontains [string]$oemVendor) { $errors.Add("Unsupported OEM vendor '$oemVendor'.") }
        }

        $features = Get-FreshWinPropertyValue -InputObject $compatibility -Name 'features' -Default $null
        if ($null -eq $features -or $features -is [string] -or (Test-FreshWinManifestArray -Value $features)) { $errors.Add('compatibility.features must be an object.') }
        Add-FreshWinUnknownPropertyErrors -InputObject $features -Allowed @('virtualization', 'wsl', 'microsoftStore', 'internet') -Context 'compatibility.features' -Errors $errors
        if ($null -ne $features) {
            foreach ($property in @($features.PSObject.Properties)) {
                if ($property.Value -isnot [bool]) { $errors.Add("compatibility.features.$($property.Name) must be boolean.") }
            }
        }
        if (Test-FreshWinHasProperty -InputObject $compatibility -Name 'providesFeatures') {
            if (-not (Test-FreshWinManifestPropertyArray -InputObject $compatibility -Name 'providesFeatures')) {
                $errors.Add('compatibility.providesFeatures must be an array.')
            }
            $providedFeatures = @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $compatibility -Name 'providesFeatures' -Default @()))
            if (@($providedFeatures | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
                $errors.Add('compatibility.providesFeatures must not contain duplicates.')
            }
            foreach ($providedFeature in $providedFeatures) {
                if (@('wsl') -notcontains ([string]$providedFeature).ToLowerInvariant()) {
                    $errors.Add("Unsupported compatibility.providesFeatures value '$providedFeature'.")
                }
            }
        }
    }

    $versionPolicy = Get-FreshWinPropertyValue -InputObject $Manifest -Name 'versionPolicy' -Default $null
    if ($null -ne $versionPolicy) {
        Add-FreshWinUnknownPropertyErrors -InputObject $versionPolicy -Allowed @('strategy', 'channel', 'major', 'notes') -Context 'versionPolicy' -Errors $errors
        Add-FreshWinRequiredPropertyErrors -InputObject $versionPolicy -Required @('strategy', 'channel') -Context 'versionPolicy' -Errors $errors
        $strategy = [string](Get-FreshWinPropertyValue -InputObject $versionPolicy -Name 'strategy' -Default '')
        if (@('latest-compatible', 'lts', 'vendor-recommended', 'windows-managed', 'manual-choice') -notcontains $strategy) { $errors.Add("Unsupported versionPolicy.strategy '$strategy'.") }
        if ([string]::IsNullOrWhiteSpace([string](Get-FreshWinPropertyValue -InputObject $versionPolicy -Name 'channel' -Default ''))) { $errors.Add('versionPolicy.channel is required.') }
    }

    $dependencies = @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $Manifest -Name 'dependencies' -Default @()))
    if (-not (Test-FreshWinManifestPropertyArray -InputObject $Manifest -Name 'dependencies')) { $errors.Add('dependencies must be an array.') }
    if (@($dependencies | Group-Object | Where-Object Count -gt 1).Count -gt 0) { $errors.Add('dependencies must not contain duplicates.') }
    foreach ($dependency in $dependencies) {
        if ([string]$dependency -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$') {
            $errors.Add("Invalid dependency package id '$dependency'.")
        }
        if ([string]$dependency -eq $id) {
            $errors.Add('A package cannot depend on itself.')
        }
    }

    $install = Get-FreshWinPropertyValue -InputObject $Manifest -Name 'install' -Default $null
    if ($null -ne $install) {
        Add-FreshWinUnknownPropertyErrors -InputObject $install -Allowed @('mode', 'requiresAdmin', 'silent', 'scope', 'notes') -Context 'install' -Errors $errors
        Add-FreshWinRequiredPropertyErrors -InputObject $install -Required @('mode', 'requiresAdmin', 'silent') -Context 'install' -Errors $errors
        $mode = [string](Get-FreshWinPropertyValue -InputObject $install -Name 'mode' -Default '')
        if (@('silent', 'interactive', 'manual') -notcontains $mode) {
            $errors.Add("Unsupported install.mode '$mode'.")
        }
        $silent = Get-FreshWinPropertyValue -InputObject $install -Name 'silent' -Default $null
        if ($silent -isnot [bool]) { $errors.Add('install.silent must be boolean.') }
        $requiresAdmin = Get-FreshWinPropertyValue -InputObject $install -Name 'requiresAdmin' -Default $null
        if ($requiresAdmin -isnot [bool]) { $errors.Add('install.requiresAdmin must be boolean.') }
        elseif (($mode -eq 'silent') -ne [bool]$silent) { $errors.Add("install.mode '$mode' is inconsistent with install.silent '$silent'.") }
        $installScope = [string](Get-FreshWinPropertyValue -InputObject $install -Name 'scope' -Default 'either')
        if (@('user', 'machine', 'either', 'system') -notcontains $installScope) {
            $errors.Add("Unsupported install.scope '$installScope'.")
        }
        if ($mode -eq 'manual' -and $sourceType -notin @('manual', 'official')) { $errors.Add('install.mode manual requires a manual or official source.') }
        if ($sourceType -in @('manual', 'official') -and $mode -ne 'manual') { $errors.Add("source.type '$sourceType' requires install.mode manual.") }
        foreach ($unsafeProperty in @('command', 'commandLine', 'script', 'powershell')) {
            if (Test-FreshWinHasProperty -InputObject $install -Name $unsafeProperty) {
                $errors.Add("Manifest install property '$unsafeProperty' is forbidden; executors accept typed argument arrays only.")
            }
        }
    }

    $riskLevel = [string](Get-FreshWinPropertyValue -InputObject $Manifest -Name 'riskLevel' -Default 'SAFE')
    if (@('SAFE', 'SYSTEM', 'ADVANCED') -notcontains $riskLevel.ToUpperInvariant()) {
        $errors.Add("Unsupported riskLevel '$riskLevel'.")
    }

    $restart = Get-FreshWinPropertyValue -InputObject $Manifest -Name 'restart' -Default $null
    if ($null -ne $restart) {
        Add-FreshWinUnknownPropertyErrors -InputObject $restart -Allowed @('required', 'behavior') -Context 'restart' -Errors $errors
        Add-FreshWinRequiredPropertyErrors -InputObject $restart -Required @('required', 'behavior') -Context 'restart' -Errors $errors
        $restartRequired = Get-FreshWinPropertyValue -InputObject $restart -Name 'required' -Default $null
        $restartBehavior = [string](Get-FreshWinPropertyValue -InputObject $restart -Name 'behavior' -Default '')
        if ($restartRequired -isnot [bool]) { $errors.Add('restart.required must be boolean.') }
        if (@('none', 'possible', 'required') -notcontains $restartBehavior) { $errors.Add("Unsupported restart.behavior '$restartBehavior'.") }
        if ($restartRequired -is [bool] -and ([bool]$restartRequired -ne ($restartBehavior -eq 'required'))) { $errors.Add('restart.required must be true exactly when restart.behavior is required.') }
    }

    $detection = Get-FreshWinPropertyValue -InputObject $Manifest -Name 'detection' -Default $null
    if ($null -ne $detection) {
        Add-FreshWinUnknownPropertyErrors -InputObject $detection -Allowed @('wingetIds', 'registryDisplayNames', 'registryDisplayNamePrefixes', 'knownPaths', 'windowsFeatures', 'appxPackageNames', 'services', 'deviceClass') -Context 'detection' -Errors $errors
        Add-FreshWinRequiredPropertyErrors -InputObject $detection -Required @('wingetIds', 'registryDisplayNames', 'knownPaths') -Context 'detection' -Errors $errors
        $detectionSignals = 0
        foreach ($name in @('wingetIds', 'registryDisplayNames', 'registryDisplayNamePrefixes', 'knownPaths', 'windowsFeatures', 'appxPackageNames', 'services')) {
            $rawValues = Get-FreshWinPropertyValue -InputObject $detection -Name $name -Default $null
            if (Test-FreshWinHasProperty -InputObject $detection -Name $name) {
                if (-not (Test-FreshWinManifestPropertyArray -InputObject $detection -Name $name)) { $errors.Add("detection.$name must be an array.") }
            }
            $values = @(ConvertTo-FreshWinArray $rawValues)
            $detectionSignals += $values.Count
            if (@($values | Group-Object | Where-Object Count -gt 1).Count -gt 0) { $errors.Add("detection.$name must not contain duplicates.") }
        }
        foreach ($wingetId in @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $detection -Name 'wingetIds' -Default @()))) {
            if ([string]$wingetId -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{1,255}$') {
                $errors.Add("Invalid detection.wingetIds value '$wingetId'.")
            }
        }
        foreach ($registryName in @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $detection -Name 'registryDisplayNames' -Default @()))) {
            if ([string]::IsNullOrWhiteSpace([string]$registryName) -or ([string]$registryName).Length -gt 512 -or [string]$registryName -match '[\x00\r\n]') {
                $errors.Add('detection.registryDisplayNames entries must be bounded non-empty single-line strings.')
            }
        }
        foreach ($registryPrefix in @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $detection -Name 'registryDisplayNamePrefixes' -Default @()))) {
            if ([string]::IsNullOrWhiteSpace([string]$registryPrefix) -or ([string]$registryPrefix).Length -lt 2 -or
                ([string]$registryPrefix).Length -gt 512 -or [string]$registryPrefix -match '[\x00\r\n]') {
                $errors.Add('detection.registryDisplayNamePrefixes entries must contain 2-512 single-line characters.')
            }
        }
        foreach ($knownPath in @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $detection -Name 'knownPaths' -Default @()))) {
            if ([string]::IsNullOrWhiteSpace([string]$knownPath) -or ([string]$knownPath).Length -gt 2048 -or
                [string]$knownPath -match '[\x00\r\n*?\[\]]' -or
                @(([string]$knownPath -split '[\\/]') | Where-Object { $_ -eq '..' }).Count -gt 0) {
                $errors.Add("Unsafe detection.knownPaths value '$knownPath'.")
            }
        }
        foreach ($featureName in @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $detection -Name 'windowsFeatures' -Default @()))) {
            if ([string]$featureName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$') { $errors.Add("Invalid detection.windowsFeatures value '$featureName'.") }
        }
        foreach ($serviceName in @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $detection -Name 'services' -Default @()))) {
            if ([string]$serviceName -notmatch '^[A-Za-z0-9_.-]{1,256}$') { $errors.Add("Invalid detection.services value '$serviceName'.") }
        }
        if (Test-FreshWinHasProperty -InputObject $detection -Name 'deviceClass') {
            $deviceClass = [string](Get-FreshWinPropertyValue -InputObject $detection -Name 'deviceClass' -Default '')
            if ($deviceClass -notmatch '^[A-Za-z0-9_.-]{1,128}$') { $errors.Add("Invalid detection.deviceClass value '$deviceClass'.") }
        }
        if ($detectionSignals -eq 0) {
            $warnings.Add('No automatic detection signal is configured; verification may require manual confirmation.')
        }
    }

    $verification = Get-FreshWinPropertyValue -InputObject $Manifest -Name 'verification' -Default $null
    if ($null -ne $verification) {
        Add-FreshWinUnknownPropertyErrors -InputObject $verification -Allowed @('methods', 'minimumMatches', 'notes') -Context 'verification' -Errors $errors
        Add-FreshWinRequiredPropertyErrors -InputObject $verification -Required @('methods', 'minimumMatches') -Context 'verification' -Errors $errors
        if (-not (Test-FreshWinManifestPropertyArray -InputObject $verification -Name 'methods')) { $errors.Add('verification.methods must be an array.') }
        $methods = @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $verification -Name 'methods' -Default @()))
        $allowedMethods = @('winget', 'registry', 'path', 'windows-feature', 'appx', 'service', 'device-status', 'manual')
        foreach ($method in $methods) { if ($allowedMethods -notcontains [string]$method) { $errors.Add("Unsupported verification method '$method'.") } }
        if (@($methods | Group-Object | Where-Object Count -gt 1).Count -gt 0) { $errors.Add('verification.methods must not contain duplicates.') }
        $minimumMatches = -1
        if (-not [int]::TryParse([string](Get-FreshWinPropertyValue -InputObject $verification -Name 'minimumMatches' -Default -1), [ref]$minimumMatches) -or $minimumMatches -lt 0 -or $minimumMatches -gt $methods.Count) {
            $errors.Add('verification.minimumMatches must be between zero and the number of methods.')
        }
        elseif ($minimumMatches -eq 0) { $warnings.Add('Verification permits zero automatic matches; completion must not be claimed automatically.') }
    }

    $license = Get-FreshWinPropertyValue -InputObject $Manifest -Name 'license' -Default $null
    if ($null -ne $license) {
        Add-FreshWinUnknownPropertyErrors -InputObject $license -Allowed @('type', 'cost', 'notes') -Context 'license' -Errors $errors
        Add-FreshWinRequiredPropertyErrors -InputObject $license -Required @('type', 'cost') -Context 'license' -Errors $errors
        if (@('open-source', 'freeware', 'freemium', 'trial', 'paid', 'subscription', 'windows-component', 'mixed') -notcontains [string](Get-FreshWinPropertyValue -InputObject $license -Name 'type' -Default '')) { $errors.Add('Unsupported license.type.') }
        if (@('free', 'trial', 'paid', 'mixed', 'included-with-windows') -notcontains [string](Get-FreshWinPropertyValue -InputObject $license -Name 'cost' -Default '')) { $errors.Add('Unsupported license.cost.') }
    }

    $recommendation = Get-FreshWinPropertyValue -InputObject $Manifest -Name 'recommendation' -Default $null
    if ($null -ne $recommendation) {
        Add-FreshWinUnknownPropertyErrors -InputObject $recommendation -Allowed @('profiles', 'default', 'conditions', 'conflictGroup', 'notes') -Context 'recommendation' -Errors $errors
        Add-FreshWinRequiredPropertyErrors -InputObject $recommendation -Required @('profiles', 'default', 'conditions') -Context 'recommendation' -Errors $errors
        foreach ($arrayName in @('profiles', 'conditions')) {
            if (-not (Test-FreshWinManifestPropertyArray -InputObject $recommendation -Name $arrayName)) {
                $errors.Add("recommendation.$arrayName must be an array.")
            }
            $arrayValues = @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $recommendation -Name $arrayName -Default @()))
            if (@($arrayValues | Group-Object | Where-Object Count -gt 1).Count -gt 0) { $errors.Add("recommendation.$arrayName must not contain duplicates.") }
        }
        if ((Get-FreshWinPropertyValue -InputObject $recommendation -Name 'default' -Default $null) -isnot [bool]) { $errors.Add('recommendation.default must be boolean.') }
    }

    $tags = @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $Manifest -Name 'tags' -Default @()))
    if (-not (Test-FreshWinManifestPropertyArray -InputObject $Manifest -Name 'tags')) { $errors.Add('tags must be an array.') }
    if (@($tags | Group-Object | Where-Object Count -gt 1).Count -gt 0) { $errors.Add('tags must not contain duplicates.') }
    foreach ($tag in $tags) { if ([string]::IsNullOrWhiteSpace([string]$tag)) { $errors.Add('tags must contain non-empty strings.') } }

    return [PSCustomObject]@{
        IsValid    = $errors.Count -eq 0
        Errors     = $errors.ToArray()
        Warnings   = $warnings.ToArray()
        SourcePath = $SourcePath
        PackageId  = $id
    }
}

function Test-FreshWinManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest,
        [string]$SourcePath
    )

    return Test-FreshWinPackageManifest -Manifest $Manifest -SourcePath $SourcePath
}

function Import-FreshWinPackageManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $manifest = Read-FreshWinJsonFile -Path $Path
    $validation = Test-FreshWinPackageManifest -Manifest $manifest -SourcePath $Path
    if (-not $validation.IsValid) {
        throw "Invalid package manifest '$Path': $($validation.Errors -join ' ')"
    }
    return $manifest
}

function Import-FreshWinManifestCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [switch]$Recurse
    )

    $catalogPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.Directory]::Exists($catalogPath)) {
        throw "Catalog directory was not found: $catalogPath"
    }

    $packages = New-Object System.Collections.Generic.List[object]
    $rejected = New-Object System.Collections.Generic.List[object]
    $searchOption = if ($Recurse) { [System.IO.SearchOption]::AllDirectories } else { [System.IO.SearchOption]::TopDirectoryOnly }
    $files = [System.IO.Directory]::GetFiles($catalogPath, '*.json', $searchOption) | Sort-Object

    foreach ($file in $files) {
        try {
            $content = Read-FreshWinJsonFile -Path $file
            $entries = @($content)
            foreach ($entry in $entries) {
                $validation = Test-FreshWinPackageManifest -Manifest $entry -SourcePath $file
                if ($validation.IsValid) {
                    $packages.Add($entry)
                }
                else {
                    $rejected.Add([PSCustomObject]@{
                        Path      = $file
                        PackageId = $validation.PackageId
                        Errors    = @($validation.Errors)
                    })
                }
            }
        }
        catch {
            $rejected.Add([PSCustomObject]@{
                Path      = $file
                PackageId = $null
                Errors    = @($_.Exception.Message)
            })
        }
    }

    $duplicateGroups = @($packages | Group-Object id | Where-Object { $_.Count -gt 1 })
    foreach ($group in $duplicateGroups) {
        foreach ($duplicateManifest in @($group.Group)) {
            [void]$packages.Remove($duplicateManifest)
        }
        $rejected.Add([PSCustomObject]@{
            Path      = $catalogPath
            PackageId = $group.Name
            Errors    = @("Duplicate package id '$($group.Name)'.")
        })
    }

    return [PSCustomObject]@{
        Packages = $packages.ToArray()
        Rejected = $rejected.ToArray()
        IsValid  = $rejected.Count -eq 0
    }
}
