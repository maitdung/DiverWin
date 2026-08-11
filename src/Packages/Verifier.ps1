Set-StrictMode -Version 2.0

function New-FreshWinVerificationMethodResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][ValidateSet('Matched', 'NotMatched', 'Unknown', 'PendingReboot')][string]$Status,
        [string]$Detail,
        [AllowNull()][object]$Evidence = $null
    )

    return [pscustomobject]@{
        Method   = $Method
        Status   = $Status
        Matched  = $Status -eq 'Matched'
        Detail   = $Detail
        Evidence = $Evidence
    }
}

function Test-FreshWinVerificationWindows {
    [CmdletBinding()]
    param()

    if ($null -ne (Get-Command -Name Test-FreshWinIsWindows -ErrorAction SilentlyContinue)) {
        return [bool](Test-FreshWinIsWindows)
    }
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Get-FreshWinVerificationInventoryRecords {
    [CmdletBinding()]
    param([AllowNull()][object]$Inventory)

    if ($null -eq $Inventory) { return @() }
    if ($null -ne (Get-Command -Name Get-FreshWinInventoryRecords -ErrorAction SilentlyContinue)) {
        return @(Get-FreshWinInventoryRecords -Inventory $Inventory)
    }
    if ($Inventory -is [System.Array]) { return @($Inventory) }
    foreach ($propertyName in @('Items', 'Applications', 'Records', 'Packages')) {
        if (Test-FreshWinHasProperty -InputObject $Inventory -Name $propertyName) {
            return @(Get-FreshWinPropertyValue -InputObject $Inventory -Name $propertyName -Default @())
        }
    }
    return @($Inventory)
}

function Test-FreshWinInventoryKnown {
    [CmdletBinding()]
    param([AllowNull()][object]$Inventory)

    if ($null -eq $Inventory) { return $false }
    if (Test-FreshWinHasProperty -InputObject $Inventory -Name 'Available') {
        return [bool](Get-FreshWinPropertyValue -InputObject $Inventory -Name 'Available' -Default $false)
    }
    return $true
}

function Test-FreshWinInventoryRecordSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $sources = @(Get-FreshWinPropertyValue -InputObject $Record -Name 'DetectionSources' -Default @())
    $singleSource = [string](Get-FreshWinPropertyValue -InputObject $Record -Name 'Source' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($singleSource)) { $sources += $singleSource }
    if ($sources.Count -eq 0) { return $true }
    return @($sources | Where-Object { [string]$_ -ieq $Source }).Count -gt 0
}

function Invoke-FreshWinPathVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$KnownPaths,
        [scriptblock]$PathVerifier,
        [AllowNull()][hashtable]$KnownPathEnvironment
    )

    if ($KnownPaths.Count -eq 0) {
        return New-FreshWinVerificationMethodResult -Method 'path' -Status Unknown -Detail 'No known path is configured.'
    }

    $unsafePaths = 0
    $checkedPaths = 0
    foreach ($knownPath in $KnownPaths) {
        $expanded = Expand-FreshWinKnownPath -Path ([string]$knownPath) -Environment $KnownPathEnvironment
        if ([string]::IsNullOrWhiteSpace($expanded)) {
            $unsafePaths++
            continue
        }
        $checkedPaths++
        try {
            $exists = if ($null -ne $PathVerifier) {
                $providerValue = & $PathVerifier $expanded
                if ($null -eq $providerValue) { $null } else { [bool]$providerValue }
            }
            else {
                [bool](Test-FreshWinKnownPathLeaf -Path $expanded)
            }
            if ($exists -eq $true) {
                return New-FreshWinVerificationMethodResult -Method 'path' -Status Matched `
                    -Detail 'A configured installation path exists.' -Evidence $expanded
            }
            if ($null -eq $exists) { $unsafePaths++ }
        }
        catch {
            $unsafePaths++
        }
    }

    if ($checkedPaths -gt 0 -and $unsafePaths -eq 0) {
        return New-FreshWinVerificationMethodResult -Method 'path' -Status NotMatched -Detail 'No configured installation path exists.'
    }
    return New-FreshWinVerificationMethodResult -Method 'path' -Status Unknown -Detail 'One or more configured paths could not be safely checked.'
}

function Invoke-FreshWinFeatureVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$FeatureNames,
        [scriptblock]$FeatureVerifier
    )

    if ($FeatureNames.Count -eq 0) {
        return New-FreshWinVerificationMethodResult -Method 'windows-feature' -Status Unknown -Detail 'No Windows feature name is configured.'
    }

    $unknown = $false
    $disabled = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.List[string]
    foreach ($featureName in $FeatureNames) {
        if ($featureName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$') {
            $unknown = $true
            continue
        }
        try {
            if ($null -ne $FeatureVerifier) {
                $featureState = ConvertTo-FreshWinWindowsFeatureState -Value (& $FeatureVerifier $featureName)
            }
            elseif ((Test-FreshWinVerificationWindows) -and
                $null -ne (Get-Command -Name Get-WindowsOptionalFeature -ErrorAction SilentlyContinue)) {
                $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
                $featureState = ConvertTo-FreshWinWindowsFeatureState -Value $feature
            }
            else {
                $featureState = 'Unknown'
            }
            switch ($featureState) {
                'Disabled' { $disabled.Add($featureName) }
                'EnablePending' { $pending.Add($featureName) }
                'Unknown' { $unknown = $true }
            }
        }
        catch {
            $unknown = $true
        }
    }

    if ($disabled.Count -gt 0) {
        return New-FreshWinVerificationMethodResult -Method 'windows-feature' -Status NotMatched `
            -Detail "Windows features are not enabled: $($disabled -join ', ')." -Evidence $disabled.ToArray()
    }
    if ($unknown) {
        return New-FreshWinVerificationMethodResult -Method 'windows-feature' -Status Unknown -Detail 'Windows feature state could not be fully determined.'
    }
    if ($pending.Count -gt 0) {
        return New-FreshWinVerificationMethodResult -Method 'windows-feature' -Status PendingReboot `
            -Detail "Windows features are pending a reboot: $($pending -join ', ')." -Evidence $pending.ToArray()
    }
    return New-FreshWinVerificationMethodResult -Method 'windows-feature' -Status Matched `
        -Detail 'All configured Windows features are enabled.' -Evidence $FeatureNames
}

function Test-FreshWinPackageVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [AllowNull()][object]$Inventory,
        [AllowNull()][object]$SystemInfo,
        [scriptblock]$InventoryProvider,
        [scriptblock]$FeatureVerifier,
        [scriptblock]$PathVerifier,
        [scriptblock]$AppxProvider,
        [scriptblock]$ServiceProvider,
        [scriptblock]$DeviceProvider,
        [AllowNull()][hashtable]$KnownPathEnvironment
    )

    $source = Get-FreshWinPropertyValue -InputObject $Package -Name 'source' -Default ([pscustomobject]@{})
    $sourceType = ([string](Get-FreshWinPropertyValue -InputObject $source -Name 'type' -Default '')).ToLowerInvariant()
    $detectionConfig = Get-FreshWinPropertyValue -InputObject $Package -Name 'detection' -Default ([pscustomobject]@{})
    $verificationConfig = Get-FreshWinPropertyValue -InputObject $Package -Name 'verification' -Default ([pscustomobject]@{})

    if ($null -ne $InventoryProvider) {
        try {
            $Inventory = & $InventoryProvider
        }
        catch {
            $Inventory = [pscustomobject]@{ Available = $false; Error = $_.Exception.Message; Items = @() }
        }
    }
    elseif ($null -eq $Inventory -and $null -ne (Get-Command -Name Get-FreshWinSoftwareInventorySnapshot -ErrorAction SilentlyContinue)) {
        try { $Inventory = Get-FreshWinSoftwareInventorySnapshot -Refresh } catch { $Inventory = $null }
    }

    $methods = @((Get-FreshWinPropertyValue -InputObject $verificationConfig -Name 'methods' -Default @()) |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    if ($methods.Count -eq 0) {
        if ($sourceType -eq 'windows-feature') { $methods = @('windows-feature') }
        elseif ($sourceType -in @('manual', 'official')) { $methods = @('manual') }
        else {
            if (@(Get-FreshWinPropertyValue -InputObject $detectionConfig -Name 'wingetIds' -Default @()).Count -gt 0) { $methods += 'winget' }
            if (@(Get-FreshWinPropertyValue -InputObject $detectionConfig -Name 'registryDisplayNames' -Default @()).Count -gt 0) { $methods += 'registry' }
            if (@(Get-FreshWinPropertyValue -InputObject $detectionConfig -Name 'knownPaths' -Default @()).Count -gt 0) { $methods += 'path' }
        }
    }

    $defaultMinimum = if ($methods -contains 'manual') { 0 } else { 1 }
    $minimumMatchesRaw = Get-FreshWinPropertyValue -InputObject $verificationConfig -Name 'minimumMatches' -Default $defaultMinimum
    $minimumMatches = -1
    if (-not [int]::TryParse([string]$minimumMatchesRaw, [ref]$minimumMatches) -or
        $minimumMatches -lt 0 -or $minimumMatches -gt $methods.Count) {
        $minimumMatches = -1
    }

    $records = @(Get-FreshWinVerificationInventoryRecords -Inventory $Inventory)
    $inventoryKnown = Test-FreshWinInventoryKnown -Inventory $Inventory
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($method in $methods) {
        switch ($method) {
            'winget' {
                $ids = @((Get-FreshWinPropertyValue -InputObject $detectionConfig -Name 'wingetIds' -Default @()) | ForEach-Object { [string]$_ })
                $sourceId = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'packageId' -Default '')
                if ($sourceId -and $ids -notcontains $sourceId) { $ids += $sourceId }
                if ($ids.Count -eq 0) {
                    $results.Add((New-FreshWinVerificationMethodResult -Method winget -Status Unknown -Detail 'No WinGet identifier is configured.'))
                    break
                }
                $match = @($records | Where-Object {
                    $record = $_
                    $recordId = [string](Get-FreshWinPropertyValue -InputObject $record -Name 'WingetId' -Default (Get-FreshWinPropertyValue -InputObject $record -Name 'PackageId' -Default ''))
                    $ids -icontains $recordId -and (Test-FreshWinInventoryRecordSource -Record $record -Source Winget)
                } | Select-Object -First 1)
                $wingetStatus = if ($match.Count -gt 0) { 'Matched' } elseif ($inventoryKnown) { 'NotMatched' } else { 'Unknown' }
                $results.Add((New-FreshWinVerificationMethodResult -Method winget `
                    -Status $wingetStatus `
                    -Detail $(if ($match.Count -gt 0) { 'The exact WinGet package identifier is installed.' } elseif ($inventoryKnown) { 'The exact WinGet package identifier was not found.' } else { 'WinGet inventory is unavailable.' }) `
                    -Evidence $(if ($match.Count -gt 0) { $match[0] } else { $null })))
            }
            'registry' {
                $names = @((Get-FreshWinPropertyValue -InputObject $detectionConfig -Name 'registryDisplayNames' -Default @()) | ForEach-Object { [string]$_ })
                $prefixes = @((Get-FreshWinPropertyValue -InputObject $detectionConfig -Name 'registryDisplayNamePrefixes' -Default @()) | ForEach-Object { [string]$_ })
                if ($names.Count -eq 0 -and $prefixes.Count -eq 0) {
                    $results.Add((New-FreshWinVerificationMethodResult -Method registry -Status Unknown -Detail 'No registry display name or explicit prefix is configured.'))
                    break
                }
                $match = @($records | Where-Object {
                    $record = $_
                    $recordName = [string](Get-FreshWinPropertyValue -InputObject $record -Name 'DisplayName' -Default (Get-FreshWinPropertyValue -InputObject $record -Name 'Name' -Default ''))
                    $exactName = @($names | Where-Object { [string]::Equals([string]$_, $recordName, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
                    $prefixName = @($prefixes | Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]$_) -and
                        $recordName.StartsWith([string]$_, [System.StringComparison]::OrdinalIgnoreCase)
                    }).Count -gt 0
                    ($exactName -or $prefixName) -and (Test-FreshWinInventoryRecordSource -Record $record -Source Registry)
                } | Select-Object -First 1)
                $registryStatus = if ($match.Count -gt 0) { 'Matched' } elseif ($inventoryKnown) { 'NotMatched' } else { 'Unknown' }
                $results.Add((New-FreshWinVerificationMethodResult -Method registry `
                    -Status $registryStatus `
                    -Detail $(if ($match.Count -gt 0) { 'A configured registry display name or explicit prefix is installed.' } elseif ($inventoryKnown) { 'No configured registry display name or explicit prefix was found.' } else { 'Registry inventory is unavailable.' }) `
                    -Evidence $(if ($match.Count -gt 0) { $match[0] } else { $null })))
            }
            'path' {
                $paths = @((Get-FreshWinPropertyValue -InputObject $detectionConfig -Name 'knownPaths' -Default @()) | ForEach-Object { [string]$_ })
                $results.Add((Invoke-FreshWinPathVerification -KnownPaths $paths -PathVerifier $PathVerifier -KnownPathEnvironment $KnownPathEnvironment))
            }
            'windows-feature' {
                $featureNames = @((Get-FreshWinPropertyValue -InputObject $detectionConfig -Name 'windowsFeatures' -Default @()) | ForEach-Object { [string]$_ })
                if ($featureNames.Count -eq 0) {
                    $featureNames = @((Get-FreshWinPropertyValue -InputObject $source -Name 'featureNames' -Default @()) | ForEach-Object { [string]$_ })
                }
                if ($featureNames.Count -eq 0) {
                    $singleFeature = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'featureName' -Default '')
                    if ($singleFeature) { $featureNames = @($singleFeature) }
                }
                $results.Add((Invoke-FreshWinFeatureVerification -FeatureNames $featureNames -FeatureVerifier $FeatureVerifier))
            }
            'appx' {
                $names = @((Get-FreshWinPropertyValue -InputObject $detectionConfig -Name 'appxPackageNames' -Default @()) | ForEach-Object { [string]$_ })
                if ($names.Count -eq 0) {
                    $results.Add((New-FreshWinVerificationMethodResult -Method appx -Status Unknown -Detail 'No AppX package name is configured.'))
                    break
                }
                try {
                    if ($null -ne $AppxProvider) {
                        $appxPackages = @(& $AppxProvider $names)
                        if ($appxPackages.Count -eq 1 -and $null -eq $appxPackages[0]) { $appxPackages = $null }
                    }
                    elseif ((Test-FreshWinVerificationWindows) -and $null -ne (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue)) { $appxPackages = @(Get-AppxPackage -ErrorAction Stop) }
                    else { $appxPackages = $null }
                    if ($null -eq $appxPackages) {
                        $results.Add((New-FreshWinVerificationMethodResult -Method appx -Status Unknown -Detail 'AppX inventory is unavailable.'))
                        break
                    }
                    $match = @($appxPackages | Where-Object {
                        $record = $_
                        if ($record -is [string]) { $recordNames = @([string]$record) }
                        else { $recordNames = @([string](Get-FreshWinPropertyValue -InputObject $record -Name 'Name' -Default ''), [string](Get-FreshWinPropertyValue -InputObject $record -Name 'PackageFamilyName' -Default '')) }
                        @($recordNames | Where-Object { $names -icontains $_ }).Count -gt 0
                    } | Select-Object -First 1)
                    $results.Add((New-FreshWinVerificationMethodResult -Method appx -Status $(if ($match.Count) { 'Matched' } else { 'NotMatched' }) -Detail $(if ($match.Count) { 'The configured AppX package is installed.' } else { 'The configured AppX package was not found.' }) -Evidence $(if ($match.Count) { $match[0] } else { $null })))
                }
                catch { $results.Add((New-FreshWinVerificationMethodResult -Method appx -Status Unknown -Detail $_.Exception.Message)) }
            }
            'service' {
                $names = @((Get-FreshWinPropertyValue -InputObject $detectionConfig -Name 'services' -Default @()) | ForEach-Object { [string]$_ })
                if ($names.Count -eq 0 -or @($names | Where-Object { $_ -notmatch '^[A-Za-z0-9_.-]{1,256}$' }).Count -gt 0) {
                    $results.Add((New-FreshWinVerificationMethodResult -Method service -Status Unknown -Detail 'No safe service name is configured.'))
                    break
                }
                try {
                    if ($null -ne $ServiceProvider) {
                        $services = @(& $ServiceProvider $names)
                        if ($services.Count -eq 1 -and $null -eq $services[0]) { $services = $null }
                    }
                    elseif (Test-FreshWinVerificationWindows) { $services = @(Get-Service -Name $names -ErrorAction SilentlyContinue) }
                    else { $services = $null }
                    if ($null -eq $services) {
                        $results.Add((New-FreshWinVerificationMethodResult -Method service -Status Unknown -Detail 'Service inventory is unavailable.'))
                        break
                    }
                    $match = @($services | Where-Object {
                        $record = $_
                        $serviceName = if ($record -is [string]) { [string]$record } else { [string](Get-FreshWinPropertyValue -InputObject $record -Name 'Name' -Default '') }
                        $names -icontains $serviceName
                    } | Select-Object -First 1)
                    $results.Add((New-FreshWinVerificationMethodResult -Method service -Status $(if ($match.Count) { 'Matched' } else { 'NotMatched' }) -Detail $(if ($match.Count) { 'The configured Windows service exists.' } else { 'The configured Windows service was not found.' }) -Evidence $(if ($match.Count) { $match[0] } else { $null })))
                }
                catch { $results.Add((New-FreshWinVerificationMethodResult -Method service -Status Unknown -Detail $_.Exception.Message)) }
            }
            'device-status' {
                $deviceClass = [string](Get-FreshWinPropertyValue -InputObject $detectionConfig -Name 'deviceClass' -Default '')
                if ($deviceClass -notmatch '^[A-Za-z0-9_.-]{1,128}$') {
                    $results.Add((New-FreshWinVerificationMethodResult -Method device-status -Status Unknown -Detail 'No safe device class is configured.'))
                    break
                }
                try {
                    if ($null -ne $DeviceProvider) {
                        $devices = @(& $DeviceProvider $deviceClass)
                        if ($devices.Count -eq 1 -and $null -eq $devices[0]) { $devices = $null }
                    }
                    elseif ((Test-FreshWinVerificationWindows) -and $null -ne (Get-Command -Name Get-PnpDevice -ErrorAction SilentlyContinue)) { $devices = @(Get-PnpDevice -Class $deviceClass -PresentOnly -ErrorAction Stop) }
                    else { $devices = $null }
                    if ($null -eq $devices) {
                        $results.Add((New-FreshWinVerificationMethodResult -Method device-status -Status Unknown -Detail 'Device inventory is unavailable.'))
                        break
                    }
                    $healthy = @($devices | Where-Object {
                        $device = $_
                        $status = [string](Get-FreshWinPropertyValue -InputObject $device -Name 'Status' -Default (Get-FreshWinPropertyValue -InputObject $device -Name 'Health' -Default ''))
                        $problemCode = Get-FreshWinPropertyValue -InputObject $device -Name 'ProblemCode' -Default (Get-FreshWinPropertyValue -InputObject $device -Name 'ConfigManagerErrorCode' -Default $null)
                        $status -match '^(OK|Healthy|Started|Running)$' -and ($null -eq $problemCode -or [int]$problemCode -eq 0)
                    } | Select-Object -First 1)
                    $results.Add((New-FreshWinVerificationMethodResult -Method device-status -Status $(if ($healthy.Count) { 'Matched' } else { 'NotMatched' }) -Detail $(if ($healthy.Count) { 'A healthy device in the configured class is present.' } else { 'No healthy device in the configured class was found.' }) -Evidence $(if ($healthy.Count) { $healthy[0] } else { $null })))
                }
                catch { $results.Add((New-FreshWinVerificationMethodResult -Method device-status -Status Unknown -Detail $_.Exception.Message)) }
            }
            'manual' {
                $results.Add((New-FreshWinVerificationMethodResult -Method manual -Status Unknown -Detail 'Manual confirmation is required; FreshWin will not claim automatic verification.'))
            }
            default {
                $results.Add((New-FreshWinVerificationMethodResult -Method $method -Status Unknown -Detail "Verification method '$method' is unsupported."))
            }
        }
    }

    $resultArray = $results.ToArray()
    $matchCount = @($resultArray | Where-Object Status -eq 'Matched').Count
    $unknownCount = @($resultArray | Where-Object Status -eq 'Unknown').Count
    $pendingRebootCount = @($resultArray | Where-Object Status -eq 'PendingReboot').Count
    $identityMethods = @('winget', 'registry', 'appx', 'service', 'windows-feature', 'device-status')
    $configuredIdentityMethods = @($methods | Where-Object { $identityMethods -contains $_ })
    $identityMatchCount = @($resultArray | Where-Object {
        $identityMethods -contains [string]$_.Method -and [string]$_.Status -eq 'Matched'
    }).Count
    $identityUnknownCount = @($resultArray | Where-Object {
        $identityMethods -contains [string]$_.Method -and [string]$_.Status -eq 'Unknown'
    }).Count
    $status = 'Unknown'
    $detail = 'Verification policy could not be satisfied.'
    if ($methods -contains 'manual' -and $sourceType -in @('manual', 'official')) {
        $status = 'Manual'
        $detail = 'The vendor workflow requires manual confirmation.'
    }
    elseif ($minimumMatches -lt 0 -or $minimumMatches -eq 0) {
        $status = 'Unknown'
        $detail = 'Verification requires at least one automatic match before FreshWin can claim success.'
    }
    elseif ($pendingRebootCount -gt 0) {
        $status = 'PendingReboot'
        $detail = 'One or more Windows features are pending a reboot; final verification is deferred until resume.'
    }
    elseif ($sourceType -in @('winget', 'msstore') -and
        ($configuredIdentityMethods.Count -eq 0 -or $identityMatchCount -eq 0)) {
        # A path is only supporting evidence: a stale or attacker-created file
        # must never independently prove that a package-manager installation
        # succeeded.  Require exact package, registry, AppX, service, feature,
        # or device identity for automatic source workflows.
        if ($configuredIdentityMethods.Count -eq 0 -or $identityUnknownCount -gt 0) {
            $status = 'Unknown'
            $detail = 'Identity-bearing verification evidence was unavailable; path evidence alone is insufficient.'
        }
        else {
            $status = 'Failed'
            $detail = 'No identity-bearing verification method matched; path evidence alone is insufficient.'
        }
    }
    elseif ($matchCount -ge $minimumMatches) {
        $status = 'Verified'
        $detail = "$matchCount verification method(s) matched; $minimumMatches required."
    }
    elseif ($unknownCount -gt 0) {
        $status = 'Unknown'
        $detail = 'One or more required verification methods were unavailable.'
    }
    else {
        $status = 'Failed'
        $detail = "$matchCount verification method(s) matched; $minimumMatches required."
    }

    $compatibility = if ($null -ne $SystemInfo) {
        try { Get-FreshWinPackageCompatibility -Package $Package -SystemInfo $SystemInfo } catch { $null }
    } else { $null }
    $detection = try {
        Get-FreshWinPackageDetection -Package $Package -Inventory $Inventory -Compatibility $compatibility -FeatureVerifier $FeatureVerifier
    } catch { $null }

    return [pscustomobject]@{
        PackageId      = [string]$Package.id
        Status         = $status
        Verified       = $status -eq 'Verified'
        Method         = $(if ($methods.Count -eq 1) { $methods[0] } else { 'configured-methods' })
        Detail         = $detail
        MatchCount     = $matchCount
        PendingRebootCount = $pendingRebootCount
        MinimumMatches = $minimumMatches
        Results        = $resultArray
        Detection      = $detection
        InventorySnapshot = $Inventory
    }
}
