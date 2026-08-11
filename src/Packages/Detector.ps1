Set-StrictMode -Version 2.0

function Get-FreshWinInventoryRecords {
    [CmdletBinding()]
    param([AllowNull()][object]$Inventory)

    if ($null -eq $Inventory) { return @() }
    if ($Inventory -is [System.Array]) { return @($Inventory) }

    foreach ($propertyName in @('Items', 'Applications', 'Records', 'Packages')) {
        $property = $Inventory.PSObject.Properties[$propertyName]
        if ($null -ne $property) { return @($property.Value) }
    }

    if ($null -ne $Inventory.PSObject.Properties['Name'] -or
        $null -ne $Inventory.PSObject.Properties['DisplayName']) {
        return @($Inventory)
    }

    return @()
}

function Expand-FreshWinKnownPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][hashtable]$Environment
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 2048 -or
        $Path -match '[\x00\r\n*?\[\]]') {
        return $null
    }

    $segments = @($Path -split '[\\/]')
    if (@($segments | Where-Object { $_ -eq '..' }).Count -gt 0) {
        return $null
    }

    $allowedVariables = @(
        'LOCALAPPDATA', 'APPDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)', 'PROGRAMDATA',
        'SYSTEMROOT', 'WINDIR', 'SYSTEMDRIVE', 'USERPROFILE'
    )
    $matches = [regex]::Matches($Path, '%([^%]+)%')
    $expanded = $Path
    foreach ($match in $matches) {
        $variableName = $match.Groups[1].Value.ToUpperInvariant()
        if ($allowedVariables -notcontains $variableName) {
            return $null
        }

        $variableValue = $null
        if ($null -ne $Environment) {
            foreach ($key in $Environment.Keys) {
                if ([string]$key -ieq $variableName) {
                    $variableValue = [string]$Environment[$key]
                    break
                }
            }
        }
        else {
            $variableValue = [Environment]::GetEnvironmentVariable($variableName)
        }
        if ([string]::IsNullOrWhiteSpace($variableValue)) {
            return $null
        }
        $expanded = $expanded.Replace($match.Value, $variableValue)
    }

    $expandedSegments = @($expanded -split '[\\/]')
    if ($expanded -match '%[^%]+%' -or $expanded -match '[\x00\r\n*?\[\]]' -or
        @($expandedSegments | Where-Object { $_ -eq '..' }).Count -gt 0) {
        return $null
    }
    try {
        if (-not [System.IO.Path]::IsPathRooted($expanded)) {
            return $null
        }
        return [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        return $null
    }
}

function Test-FreshWinKnownPathLeaf {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not [System.IO.File]::Exists($Path)) { return $false }
        $attributes = [System.IO.File]::GetAttributes($Path)
        if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0 -or
            ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        return $true
    }
    catch { return $false }
}

function ConvertTo-FreshWinWindowsFeatureState {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'Unknown' }
    if ($Value -is [bool]) {
        return $(if ([bool]$Value) { 'Enabled' } else { 'Disabled' })
    }

    $stateValue = $Value
    $stateProperty = $Value.PSObject.Properties['State']
    if ($null -ne $stateProperty) { $stateValue = $stateProperty.Value }
    $state = ([string]$stateValue).Trim()
    if ([string]::IsNullOrWhiteSpace($state)) { return 'Unknown' }

    switch -Regex ($state) {
        '^(?i:enabled)$' { return 'Enabled' }
        '^(?i:enablepending)$' { return 'EnablePending' }
        '^(?i:disabled|disabledwithpayloadremoved|disablepending)$' { return 'Disabled' }
        default { return 'Unknown' }
    }
}

function Get-FreshWinWindowsFeatureDetection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [scriptblock]$FeatureVerifier
    )

    $source = Get-FreshWinPropertyValue -InputObject $Package -Name 'source' -Default $null
    $detection = Get-FreshWinPropertyValue -InputObject $Package -Name 'detection' -Default $null
    $featureNames = @((Get-FreshWinPropertyValue -InputObject $detection -Name 'windowsFeatures' -Default `
        (Get-FreshWinPropertyValue -InputObject $source -Name 'featureNames' -Default @())) | ForEach-Object { [string]$_ })
    if ($featureNames.Count -eq 0) { return $null }

    $disabled = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.List[string]
    $unknown = New-Object System.Collections.Generic.List[string]
    foreach ($featureName in $featureNames) {
        if ($featureName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$') {
            $unknown.Add($featureName)
            continue
        }
        try {
            $featureState = if ($null -ne $FeatureVerifier) {
                ConvertTo-FreshWinWindowsFeatureState -Value (& $FeatureVerifier $featureName)
            }
            elseif ((Test-FreshWinWindows) -and $null -ne (Get-Command -Name Get-WindowsOptionalFeature -ErrorAction SilentlyContinue)) {
                $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
                ConvertTo-FreshWinWindowsFeatureState -Value $feature
            }
            else { 'Unknown' }
            switch ($featureState) {
                'Disabled' { $disabled.Add($featureName) }
                'EnablePending' { $pending.Add($featureName) }
                'Unknown' { $unknown.Add($featureName) }
            }
        }
        catch { $unknown.Add($featureName) }
    }

    $state = if ($disabled.Count -gt 0) { 'NotInstalled' }
        elseif ($unknown.Count -gt 0 -or $pending.Count -gt 0) { 'Unknown' }
        else { 'Installed' }
    return [pscustomobject]@{
        PackageId         = [string]$Package.id
        State             = $state
        Badge             = if ($state -eq 'Installed') { '[OK]' } elseif ($state -eq 'NotInstalled') { '[--]' } else { '[??]' }
        Installed         = $state -eq 'Installed'
        UpdateAvailable   = $false
        InstalledVersion  = $null
        AvailableVersion  = $null
        Evidence          = if ($pending.Count -gt 0) { @('windows-feature', 'pending-reboot') } else { @('windows-feature') }
        Record            = [pscustomobject]@{
            FeatureNames=$featureNames
            Disabled=$disabled.ToArray()
            PendingReboot=$pending.ToArray()
            Unknown=$unknown.ToArray()
        }
    }
}

function Get-FreshWinPackageDetection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [AllowNull()][object]$Inventory,
        [AllowNull()][object]$Compatibility,
        [scriptblock]$FeatureVerifier
    )

    if ($null -ne $Compatibility -and
        ([string](Get-FreshWinPropertyValue -InputObject $Compatibility -Name 'Status' -Default '')) -in @('Blocked', 'NotApplicable')) {
        return [pscustomobject]@{
            PackageId       = [string]$Package.id
            State           = 'NotCompatible'
            Badge           = '[NA]'
            Installed       = $false
            UpdateAvailable = $false
            InstalledVersion = $null
            AvailableVersion = $null
            Evidence        = @('compatibility')
            Record          = $null
        }
    }

    $detection = Get-FreshWinPropertyValue -InputObject $Package -Name 'detection' -Default ([pscustomobject]@{})
    $source = Get-FreshWinPropertyValue -InputObject $Package -Name 'source' -Default ([pscustomobject]@{})
    if (([string](Get-FreshWinPropertyValue -InputObject $source -Name 'type' -Default '')) -eq 'windows-feature') {
        $featureDetection = Get-FreshWinWindowsFeatureDetection -Package $Package -FeatureVerifier $FeatureVerifier
        if ($null -ne $featureDetection) { return $featureDetection }
    }
    $wingetIds = @((Get-FreshWinPropertyValue -InputObject $detection -Name 'wingetIds' -Default @()) | ForEach-Object { [string]$_ })
    $sourcePackageId = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'packageId' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($sourcePackageId) -and $wingetIds -notcontains $sourcePackageId) {
        $wingetIds += $sourcePackageId
    }
    $registryNames = @((Get-FreshWinPropertyValue -InputObject $detection -Name 'registryDisplayNames' -Default @()) | ForEach-Object { [string]$_ })
    $registryPrefixes = @((Get-FreshWinPropertyValue -InputObject $detection -Name 'registryDisplayNamePrefixes' -Default @()) | ForEach-Object { [string]$_ })
    $appxPackageNames = @((Get-FreshWinPropertyValue -InputObject $detection -Name 'appxPackageNames' -Default @()) | ForEach-Object { [string]$_ })
    $records = @(Get-FreshWinInventoryRecords -Inventory $Inventory)

    $matchedRecord = $null
    $evidence = New-Object System.Collections.Generic.List[string]
    foreach ($record in $records) {
        $recordWingetId = [string](Get-FreshWinPropertyValue -InputObject $record -Name 'WingetId' -Default (Get-FreshWinPropertyValue -InputObject $record -Name 'PackageId' -Default (Get-FreshWinPropertyValue -InputObject $record -Name 'Id' -Default '')))
        if (-not [string]::IsNullOrWhiteSpace($recordWingetId) -and $wingetIds -icontains $recordWingetId) {
            $matchedRecord = $record
            $evidence.Add('winget')
            break
        }

        $recordAppxName = [string](Get-FreshWinPropertyValue -InputObject $record -Name 'AppxName' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($recordAppxName) -and $appxPackageNames -icontains $recordAppxName) {
            $matchedRecord = $record
            $evidence.Add('appx')
            break
        }

        $recordName = [string](Get-FreshWinPropertyValue -InputObject $record -Name 'DisplayName' -Default (Get-FreshWinPropertyValue -InputObject $record -Name 'Name' -Default ''))
        foreach ($registryName in $registryNames) {
            if (-not [string]::IsNullOrWhiteSpace($recordName) -and
                [string]::Equals($recordName, $registryName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matchedRecord = $record
                $evidence.Add('registry')
                break
            }
        }
        if ($null -eq $matchedRecord) {
            foreach ($registryPrefix in $registryPrefixes) {
                if (-not [string]::IsNullOrWhiteSpace($registryPrefix) -and
                    $recordName.StartsWith($registryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $matchedRecord = $record
                    $evidence.Add('registry-prefix')
                    break
                }
            }
        }
        if ($null -ne $matchedRecord) { break }
    }

    $knownPathFound = $false
    foreach ($knownPath in @(Get-FreshWinPropertyValue -InputObject $detection -Name 'knownPaths' -Default @())) {
        $expanded = Expand-FreshWinKnownPath -Path ([string]$knownPath)
        if ($null -ne $expanded -and (Test-FreshWinKnownPathLeaf -Path $expanded)) {
            $knownPathFound = $true
            $evidence.Add('known-path')
            break
        }
    }

    if ($null -ne $matchedRecord -or $knownPathFound) {
        $broken = if ($null -ne $matchedRecord) {
            [bool](Get-FreshWinPropertyValue -InputObject $matchedRecord -Name 'Broken' -Default $false)
        } else { $false }
        $update = if ($null -ne $matchedRecord) {
            [bool](Get-FreshWinPropertyValue -InputObject $matchedRecord -Name 'UpdateAvailable' -Default $false)
        } else { $false }
        $state = if ($broken) { 'Broken' } elseif ($update) { 'UpdateAvailable' } else { 'Installed' }
        $badge = switch ($state) {
            'Broken' { '[!!]' }
            'UpdateAvailable' { '[UP]' }
            default { '[OK]' }
        }
        return [pscustomobject]@{
            PackageId         = [string]$Package.id
            State             = $state
            Badge             = $badge
            Installed         = $true
            UpdateAvailable   = $update
            InstalledVersion  = if ($null -ne $matchedRecord) { Get-FreshWinPropertyValue -InputObject $matchedRecord -Name 'Version' } else { $null }
            AvailableVersion  = if ($null -ne $matchedRecord) { Get-FreshWinPropertyValue -InputObject $matchedRecord -Name 'AvailableVersion' } else { $null }
            Evidence          = @($evidence)
            Record            = $matchedRecord
        }
    }

    $inventoryAvailable = $null -ne $Inventory
    if ($null -ne $Inventory -and $null -ne $Inventory.PSObject.Properties['Available']) {
        $inventoryAvailable = [bool]$Inventory.Available
    }
    $sourceType = ([string](Get-FreshWinPropertyValue -InputObject $source -Name 'type' -Default '')).ToLowerInvariant()
    if ($sourceType -eq 'msstore' -and $appxPackageNames.Count -gt 0) {
        $appxAvailabilityProperty = if ($null -ne $Inventory) { $Inventory.PSObject.Properties['AppxAvailable'] } else { $null }
        $inventoryAvailable = $null -ne $appxAvailabilityProperty -and [bool]$appxAvailabilityProperty.Value
    }
    $state = if ($inventoryAvailable) { 'NotInstalled' } else { 'Unknown' }
    return [pscustomobject]@{
        PackageId         = [string]$Package.id
        State             = $state
        Badge             = if ($state -eq 'Unknown') { '[??]' } else { '[--]' }
        Installed         = $false
        UpdateAvailable   = $false
        InstalledVersion  = $null
        AvailableVersion  = $null
        Evidence          = @()
        Record            = $null
    }
}

function Get-FreshWinCatalogState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][object]$SystemInfo,
        [AllowNull()][object]$Inventory,
        [scriptblock]$FeatureVerifier
    )

    $states = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($Catalog.Packages)) {
        $compatibility = Get-FreshWinPackageCompatibility -Package $package -SystemInfo $SystemInfo
        $detection = Get-FreshWinPackageDetection -Package $package -Inventory $Inventory -Compatibility $compatibility -FeatureVerifier $FeatureVerifier
        $states.Add([pscustomobject]@{
            Package       = $package
            Compatibility = $compatibility
            Detection     = $detection
        })
    }
    return $states.ToArray()
}
