Set-StrictMode -Version 2.0

function Resolve-FreshWinPlanPackageIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$PackageIds,
        [Parameter(Mandatory = $true)][object]$Catalog
    )

    $known = @{}
    foreach ($package in @($Catalog.Packages)) { $known[([string]$package.id).ToLowerInvariant()] = $package }
    $ordered = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.Queue[string]
    foreach ($id in $PackageIds) { $pending.Enqueue(([string]$id).Trim().ToLowerInvariant()) }

    $guard = 0
    while ($pending.Count -gt 0) {
        $guard++
        if ($guard -gt 1000) { throw 'Dependency expansion exceeded its safety limit.' }
        $id = $pending.Dequeue()
        if ([string]::IsNullOrWhiteSpace($id) -or $ordered -contains $id) { continue }
        if (-not $known.ContainsKey($id)) { throw "Package '$id' was not found in the catalog." }
        foreach ($dependency in @(Get-FreshWinPropertyValue -InputObject $known[$id] -Name 'dependencies' -Default @())) {
            $dependencyId = ([string]$dependency).ToLowerInvariant()
            if (-not $known.ContainsKey($dependencyId)) { throw "Package '$id' references missing dependency '$dependencyId'." }
            if ($ordered -notcontains $dependencyId) { $pending.Enqueue($dependencyId) }
        }
        $ordered.Add($id)
    }

    # Stable dependency-first ordering without evaluating manifest-provided code.
    $remaining = $ordered.ToArray()
    $sorted = New-Object System.Collections.Generic.List[string]
    $pass = 0
    while ($remaining.Count -gt 0) {
        $pass++
        if ($pass -gt ($ordered.Count + 1)) {
            throw "A dependency cycle exists among: $($remaining -join ', ')."
        }
        $progress = $false
        foreach ($id in @($remaining)) {
            $dependencies = @((Get-FreshWinPropertyValue -InputObject $known[$id] -Name 'dependencies' -Default @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $unresolved = @($dependencies | Where-Object { $sorted -notcontains $_ })
            if ($unresolved.Count -eq 0) {
                $sorted.Add($id)
                $remaining = @($remaining | Where-Object { $_ -ne $id })
                $progress = $true
            }
        }
        if (-not $progress -and $remaining.Count -gt 0) {
            throw "A dependency cycle exists among: $($remaining -join ', ')."
        }
    }
    return $sorted.ToArray()
}

function Get-FreshWinDependencyProvidedFeatures {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [Parameter(Mandatory = $true)][object]$Catalog
    )

    $features = New-Object System.Collections.Generic.List[string]
    $visited = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $pending = New-Object System.Collections.Generic.Queue[string]
    foreach ($dependencyId in @(Get-FreshWinPropertyValue -InputObject $Package -Name 'dependencies' -Default @())) {
        $pending.Enqueue(([string]$dependencyId).ToLowerInvariant())
    }
    while ($pending.Count -gt 0) {
        if ($visited.Count -gt 250) { throw 'Dependency capability expansion exceeded its safety limit.' }
        $dependencyId = $pending.Dequeue()
        if (-not $visited.Add($dependencyId)) { continue }
        $dependency = Get-FreshWinPackage -Catalog $Catalog -Id $dependencyId
        if ($null -eq $dependency) { throw "Package '$([string]$Package.id)' references missing dependency '$dependencyId'." }
        $compatibility = Get-FreshWinPropertyValue -InputObject $dependency -Name 'compatibility' -Default $null
        foreach ($feature in @(Get-FreshWinPropertyValue -InputObject $compatibility -Name 'providesFeatures' -Default @())) {
            $normalized = ([string]$feature).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($normalized) -and -not $features.Contains($normalized)) { $features.Add($normalized) }
        }
        foreach ($transitiveId in @(Get-FreshWinPropertyValue -InputObject $dependency -Name 'dependencies' -Default @())) {
            $pending.Enqueue(([string]$transitiveId).ToLowerInvariant())
        }
    }
    return $features.ToArray()
}

function Test-FreshWinPackageUpdateCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [AllowNull()][object]$Inventory
    )

    if ($null -eq $Inventory -or -not [bool](Get-FreshWinPropertyValue -InputObject $Inventory -Name 'UpdatesScanned' -Default $false)) {
        return $false
    }
    $sourceType = ([string](Get-FreshWinPropertyValue -InputObject (Get-FreshWinPropertyValue -InputObject $Package -Name 'source' -Default $null) -Name 'type' -Default '')).ToLowerInvariant()
    $coverageProperty = $Inventory.PSObject.Properties['UpdateSourcesScanned']
    $coveredSources = if ($null -eq $coverageProperty) {
        # Compatibility for explicit unit fixtures created before source-aware
        # snapshots. Live FreshWin snapshots always declare exact coverage.
        @('winget')
    } else {
        @($coverageProperty.Value | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    }
    return $coveredSources -contains $sourceType
}

function New-FreshWinInstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$PackageIds,
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][object]$SystemInfo,
        [AllowNull()][object]$Inventory,
        [ValidateSet('missing-only', 'include-updates')][string]$UpdatePolicy = 'missing-only',
        [string]$WingetPath,
        [scriptblock]$SourceResolver,
        [scriptblock]$FeatureVerifier,
        [switch]$DryRun
    )

    $requested = @($PackageIds | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    if ($requested.Count -eq 0) { throw 'At least one package must be selected.' }
    $expanded = @(Resolve-FreshWinPlanPackageIds -PackageIds $requested -Catalog $Catalog)

    $conflicts = @($expanded | ForEach-Object {
        $package = Get-FreshWinPackage -Catalog $Catalog -Id $_
        $recommendation = Get-FreshWinPropertyValue -InputObject $package -Name 'recommendation' -Default $null
        $group = [string](Get-FreshWinPropertyValue -InputObject $recommendation -Name 'conflictGroup' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($group)) {
            [pscustomobject]@{ Group = $group; PackageId = [string]$package.id }
        }
    } | Group-Object Group | Where-Object Count -gt 1)
    if ($conflicts.Count -gt 0) {
        $details = @($conflicts | ForEach-Object { "$($_.Name): $(@($_.Group.PackageId) -join ', ')" }) -join '; '
        throw "Selected packages contain mutually exclusive choices: $details."
    }

    $items = New-Object System.Collections.Generic.List[object]

    foreach ($id in $expanded) {
        $package = Get-FreshWinPackage -Catalog $Catalog -Id $id
        $provisionableFeatures = @(Get-FreshWinDependencyProvidedFeatures -Package $package -Catalog $Catalog)
        $compatibility = Get-FreshWinPackageCompatibility -Package $package -SystemInfo $SystemInfo -ProvisionableFeatures $provisionableFeatures
        $detection = Get-FreshWinPackageDetection -Package $package -Inventory $Inventory -Compatibility $compatibility -FeatureVerifier $FeatureVerifier
        $resolved = if ($null -ne $SourceResolver) { & $SourceResolver $package } else {
            Resolve-FreshWinPackageSource -Package $package -WingetPath $WingetPath
        }
        $installMetadata = Get-FreshWinPropertyValue -InputObject $package -Name 'install' -Default $null
        $installMode = ([string](Get-FreshWinPropertyValue -InputObject $installMetadata -Name 'mode' -Default 'silent')).ToLowerInvariant()
        $action = 'BLOCKED'
        $reason = ''

        if ($compatibility.Status -in @('Blocked', 'NotApplicable')) {
            $action = 'BLOCKED'
            $reason = $compatibility.Reasons -join ' '
        }
        elseif ($detection.State -eq 'Installed' -and $UpdatePolicy -eq 'include-updates' -and
            ([string]$package.source.type) -in @('winget', 'msstore') -and
            -not (Test-FreshWinPackageUpdateCoverage -Package $package -Inventory $Inventory)) {
            $action = 'BLOCKED'
            $reason = "Update state for source '$([string]$package.source.type)' could not be verified; FreshWin will not report this package as current."
        }
        elseif ($detection.State -eq 'Installed') {
            $action = 'SKIP'
            $reason = 'Already installed and ready.'
        }
        elseif ($detection.State -eq 'UpdateAvailable') {
            if ($UpdatePolicy -eq 'include-updates') {
                $action = 'UPDATE'
                $reason = 'An update is available and the selected policy includes updates.'
            } else {
                $action = 'SKIP'
                $reason = 'Update available; the current policy installs missing packages only.'
            }
        }
        elseif ($detection.State -eq 'Broken') {
            $action = 'REPAIR'
            $reason = 'The existing installation appears incomplete or broken.'
        }
        elseif ($detection.State -eq 'Unknown' -and ([string](Get-FreshWinPropertyValue -InputObject $package.source -Name 'type' -Default '')) -eq 'windows-feature') {
            $action = 'INSTALL'
            $reason = 'Windows feature state could not be read without elevation; the reviewed feature set will be rechecked before any system change.'
        }
        elseif ($detection.State -eq 'Unknown') {
            $action = 'BLOCKED'
            $reason = 'Installed state could not be determined; FreshWin will not install blindly.'
        }
        elseif ($installMode -eq 'interactive') {
            $action = 'MANUAL'
            $reason = 'This package requires an interactive vendor workflow and will not be started unattended.'
        }
        elseif ($resolved.Status -eq 'Manual') {
            $action = 'MANUAL'
            $reason = $resolved.Reason
        }
        elseif ($resolved.Status -ne 'Resolved') {
            $action = 'BLOCKED'
            $reason = $resolved.Reason
        }
        else {
            $action = 'INSTALL'
            $reason = if ($requested -contains $id) { 'Selected and not installed.' } else { 'Required dependency and not installed.' }
        }
        $compatibilityWarnings = @((Get-FreshWinPropertyValue -InputObject $compatibility -Name 'Warnings' -Default @()) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        if ($compatibilityWarnings.Count -gt 0) {
            $reason = (($reason.TrimEnd() + ' Compatibility warning: ' + ($compatibilityWarnings -join ' '))).Trim()
        }

        $install = Get-FreshWinPropertyValue -InputObject $package -Name 'install' -Default ([pscustomobject]@{})
        $restart = Get-FreshWinRestartBehavior -PackageOrRestart $package
        $dependencyIds = @((Get-FreshWinPropertyValue -InputObject $package -Name 'dependencies' -Default @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $items.Add([pscustomobject]@{
            Id                 = [guid]::NewGuid().ToString('N')
            PackageId          = $id
            Package            = $package
            Requested          = ($requested -contains $id)
            Action             = $action
            Reason             = $reason
            SafetyLevel        = ([string](Get-FreshWinPropertyValue -InputObject $package -Name 'riskLevel' -Default 'SAFE')).ToUpperInvariant()
            RequiresAdmin      = [bool](Get-FreshWinPropertyValue -InputObject $install -Name 'requiresAdmin' -Default $false)
            RestartImpact      = $restart
            RestartRequired    = ($restart -eq 'required')
            DependencyIds      = $dependencyIds
            Compatibility      = $compatibility
            Detection          = $detection
            ResolvedSource     = $resolved
            State              = if ($action -in @('SKIP', 'MANUAL', 'BLOCKED')) { $action } else { 'PENDING' }
            Attempts           = 0
            Result             = $null
            Verification       = $null
        })
    }

    $counts = [ordered]@{}
    foreach ($actionName in @('INSTALL', 'UPDATE', 'REPAIR', 'SKIP', 'MANUAL', 'BLOCKED')) {
        $counts[$actionName] = @($items | Where-Object Action -eq $actionName).Count
    }
    return [pscustomobject]@{
        SchemaVersion = 1
        Id            = [guid]::NewGuid().ToString('N')
        CreatedAtUtc  = [DateTimeOffset]::UtcNow.ToString('o')
        FreshWinVersion = $(if (Get-Command Get-FreshWinVersion -ErrorAction SilentlyContinue) { Get-FreshWinVersion } else { '0.1.0' })
        DryRun        = [bool]$DryRun
        UpdatePolicy  = $UpdatePolicy
        Status        = 'PLANNED'
        RequestedPackageIds = $requested
        Items         = $items.ToArray()
        Counts        = [pscustomobject]$counts
        RebootLikely  = (@($items | Where-Object { $_.RestartRequired -and $_.Action -in @('INSTALL', 'UPDATE', 'REPAIR') }).Count -gt 0)
    }
}

function Test-FreshWinInstallPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    $errors = New-Object System.Collections.Generic.List[string]
    if ([int](Get-FreshWinPropertyValue -InputObject $Plan -Name 'SchemaVersion' -Default 0) -ne 1) { $errors.Add('Plan schema version is invalid.') }
    if ([string](Get-FreshWinPropertyValue -InputObject $Plan -Name 'Id' -Default '') -notmatch '^[a-f0-9]{32}$') { $errors.Add('Plan ID is invalid.') }
    if ((Get-FreshWinPropertyValue -InputObject $Plan -Name 'DryRun' -Default $null) -isnot [bool]) { $errors.Add('Plan DryRun must be boolean.') }
    if ([string](Get-FreshWinPropertyValue -InputObject $Plan -Name 'UpdatePolicy' -Default '') -notin @('missing-only', 'include-updates')) { $errors.Add('Plan update policy is invalid.') }
    if ([string](Get-FreshWinPropertyValue -InputObject $Plan -Name 'Status' -Default '') -notin @('PLANNED', 'RESUMED', 'EXECUTING', 'INCOMPLETE', 'FAILED', 'CANCELLED', 'COMPLETED', 'COMPLETED_WITH_ISSUES', 'REBOOT_REQUIRED', 'DRY_RUN_COMPLETE')) { $errors.Add('Plan status is invalid.') }
    $requestedPackageIds = @(Get-FreshWinPropertyValue -InputObject $Plan -Name 'RequestedPackageIds' -Default @())
    if ($requestedPackageIds.Count -eq 0 -or $requestedPackageIds.Count -gt 200) { $errors.Add('Plan requested package IDs are missing or excessive.') }
    if (@($requestedPackageIds | Where-Object { [string]$_ -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' }).Count -gt 0) { $errors.Add('Plan contains an invalid requested package ID.') }
    if (@($requestedPackageIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) { $errors.Add('Plan contains duplicate requested package IDs.') }
    $items = @(Get-FreshWinPropertyValue -InputObject $Plan -Name 'Items' -Default @())
    if ($items.Count -eq 0) { $errors.Add('Plan contains no items.') }
    if ($items.Count -gt 250) { $errors.Add('Plan contains too many items.') }
    $itemIds = @()
    $packageIds = @()
    foreach ($item in $items) {
        $itemId = [string](Get-FreshWinPropertyValue -InputObject $item -Name 'Id' -Default '')
        $packageId = [string](Get-FreshWinPropertyValue -InputObject $item -Name 'PackageId' -Default '')
        foreach ($requiredItemProperty in @(
            'Id', 'PackageId', 'Package', 'Requested', 'Action', 'Reason', 'SafetyLevel',
            'RequiresAdmin', 'RestartImpact', 'RestartRequired', 'DependencyIds',
            'Compatibility', 'Detection', 'ResolvedSource', 'State', 'Attempts', 'Result',
            'Verification'
        )) {
            if (-not (Test-FreshWinHasProperty -InputObject $item -Name $requiredItemProperty)) {
                $errors.Add("Plan item '$packageId' is missing runtime property '$requiredItemProperty'.")
            }
        }
        if ($itemId -notmatch '^[a-f0-9]{32}$') { $errors.Add("Plan item '$packageId' has an invalid ID.") }
        if ($packageId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { $errors.Add("Plan item package ID '$packageId' is invalid.") }
        $itemIds += $itemId
        $packageIds += $packageId
        if (@('INSTALL', 'UPDATE', 'REPAIR', 'SKIP', 'MANUAL', 'BLOCKED') -notcontains ([string]$item.Action)) {
            $errors.Add("Plan item '$($item.PackageId)' has an invalid action.")
        }
        if (@('SAFE', 'SYSTEM', 'ADVANCED') -notcontains ([string]$item.SafetyLevel)) {
            $errors.Add("Plan item '$($item.PackageId)' has an invalid safety level.")
        }
        if ((Get-FreshWinPropertyValue -InputObject $item -Name 'Requested' -Default $null) -isnot [bool]) { $errors.Add("Plan item '$packageId' has an invalid Requested flag.") }
        if ((Get-FreshWinPropertyValue -InputObject $item -Name 'RequiresAdmin' -Default $null) -isnot [bool]) { $errors.Add("Plan item '$packageId' has an invalid RequiresAdmin flag.") }
        if ([string](Get-FreshWinPropertyValue -InputObject $item -Name 'State' -Default '') -notin @('PENDING', 'RUNNING', 'SUCCEEDED', 'FAILED', 'SKIP', 'MANUAL', 'BLOCKED', 'ELEVATION_REQUIRED', 'UNKNOWN_VERIFICATION', 'VALIDATED')) { $errors.Add("Plan item '$packageId' has an invalid state.") }
    }
    foreach ($duplicate in @($itemIds | Group-Object | Where-Object Count -gt 1)) { $errors.Add("Duplicate plan item ID '$($duplicate.Name)'.") }
    foreach ($duplicate in @($packageIds | Group-Object | Where-Object Count -gt 1)) { $errors.Add("Duplicate plan package ID '$($duplicate.Name)'.") }
    foreach ($requestedId in $requestedPackageIds) {
        $requestedItems = @($items | Where-Object { [string]$_.PackageId -eq [string]$requestedId -and [bool]$_.Requested })
        if ($requestedItems.Count -ne 1) { $errors.Add("Requested package '$requestedId' does not map to exactly one requested plan item.") }
    }
    return [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

function Save-FreshWinInstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $validation = Test-FreshWinInstallPlan -Plan $Plan
    if (-not $validation.Valid) { throw ($validation.Errors -join ' ') }
    $parent = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($parent)) { $parent = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Plan directory '$parent' does not exist." }
    $json = $Plan | ConvertTo-Json -Depth 30
    [void](Write-FreshWinUtf8File -Path $Path -Content $json -CreateNew)
    return $Path
}
