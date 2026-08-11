Set-StrictMode -Version 2.0

function Write-FreshWinExecutionLog {
    [CmdletBinding()]
    param(
        [string]$Stage,
        [string]$Action,
        [string]$PackageId,
        [string]$Result,
        [Nullable[int]]$ExitCode = $null,
        [string]$Message,
        [AllowNull()][object]$Data,
        [switch]$NoWrite
    )

    if ($NoWrite) { return }
    if (-not (Get-Command 'Write-FreshWinLog' -ErrorAction SilentlyContinue)) { return }
    $loggerVariable = Get-Variable -Name FreshWinLoggerContext -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $loggerVariable -or $null -eq $loggerVariable.Value) { return }
    $logContext = $loggerVariable.Value
    $logDirectory = [string](Get-FreshWinPropertyValue -InputObject $logContext -Name 'LogDirectory' -Default '')
    if ([string]::IsNullOrWhiteSpace($logDirectory) -or -not [IO.Directory]::Exists($logDirectory)) { return }
    try {
        Write-FreshWinLog -Level $(if ($Result -in @('Failed', 'Blocked', 'FAILED', 'UNKNOWN_VERIFICATION')) { 'ERROR' } else { 'INFO' }) `
            -Stage $Stage -Action $Action -PackageId $PackageId -Result $Result -ExitCode $ExitCode -Message $Message -Data ([pscustomobject]@{
            packageId = $PackageId
            action    = $Action
            result    = $Result
            detail    = $Data
        }) -Context $logContext | Out-Null
    }
    catch {
        # Logging must never turn a recoverable package failure into an application crash.
    }
}

function Get-FreshWinExecutionSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    $items = @($Plan.Items)
    return [pscustomobject]@{
        Succeeded           = @($items | Where-Object State -eq 'SUCCEEDED').Count
        AlreadyReady        = @($items | Where-Object { $_.Action -eq 'SKIP' -and $_.Reason -match '(?i)already installed|ready' }).Count
        Updated             = @($items | Where-Object { $_.State -eq 'SUCCEEDED' -and $_.Action -eq 'UPDATE' }).Count
        Skipped             = @($items | Where-Object State -eq 'SKIP').Count
        ManualRequired      = @($items | Where-Object State -eq 'MANUAL').Count
        Blocked             = @($items | Where-Object State -in @('BLOCKED', 'ELEVATION_REQUIRED')).Count
        Failed              = @($items | Where-Object State -eq 'FAILED').Count
        UnknownVerification = @($items | Where-Object State -eq 'UNKNOWN_VERIFICATION').Count
        Validated           = @($items | Where-Object State -eq 'VALIDATED').Count
        Pending             = @($items | Where-Object State -in @('PENDING', 'RUNNING')).Count
        Deferred            = @($items | Where-Object {
            if ([string]$_.State -ne 'PENDING') { return $false }
            return [string](Get-FreshWinPropertyValue -InputObject $_.Result -Name 'Outcome' -Default '') -eq 'Deferred'
        }).Count
        RebootRequired      = @($items | Where-Object {
            if (-not [bool]$_.RestartRequired) { return $false }
            if ($_.State -eq 'SUCCEEDED') { return $true }
            if ([bool](Get-FreshWinPropertyValue -InputObject $_.Result -Name 'RebootRequired' -Default $false)) { return $true }
            $outcome = [string](Get-FreshWinPropertyValue -InputObject $_.Result -Name 'Outcome' -Default '')
            return $outcome -eq 'ProcessSucceeded'
        }).Count -gt 0
    }
}

function Test-FreshWinExecutionPrivilegeMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('All', 'AdminOnly', 'NonAdminOnly')][string]$ExecutionMode,
        [Parameter(Mandatory = $true)][bool]$RequiresAdmin
    )

    switch ($ExecutionMode) {
        'AdminOnly' { return $RequiresAdmin }
        'NonAdminOnly' { return (-not $RequiresAdmin) }
        default { return $true }
    }
}

function New-FreshWinPrivilegeDeferralResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('PrivilegePartition', 'Dependency')][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Message
    )

    return [pscustomobject]@{
        Outcome = 'Deferred'
        Stage = $Stage
        Attempts = 0
        ExitCode = $null
        Message = $Message
        DeferredBy = 'OppositePrivilege'
    }
}

function Invoke-FreshWinExecutionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][object]$SystemInfo,
        [AllowNull()][object]$Inventory,
        [scriptblock]$InventoryProvider,
        [scriptblock]$SystemInfoProvider,
        [scriptblock]$ProcessInvoker,
        [scriptblock]$SourceResolver,
        [scriptblock]$FeatureVerifier,
        [scriptblock]$ProgressCallback,
        [string]$CheckpointPath,
        [ValidateSet('All', 'AdminOnly', 'NonAdminOnly')][string]$ExecutionMode = 'All',
        [ValidateRange(1, 3)][int]$MaxAttempts = 3
    )

    $validation = Test-FreshWinInstallPlan -Plan $Plan
    if (-not $validation.Valid) { throw ($validation.Errors -join ' ') }

    $expectedPackageIds = @(Resolve-FreshWinPlanPackageIds -PackageIds @($Plan.RequestedPackageIds) -Catalog $Catalog)
    $actualPackageIds = @($Plan.Items | ForEach-Object { ([string]$_.PackageId).ToLowerInvariant() })
    $expectedPackageKey = (@($expectedPackageIds | Sort-Object) -join ',')
    $actualPackageKey = (@($actualPackageIds | Sort-Object) -join ',')
    if ($expectedPackageKey -ne $actualPackageKey) {
        throw 'Plan package closure does not match the trusted catalog dependency graph.'
    }

    $conflictSelections = @($Plan.Items | ForEach-Object {
        $trusted = Get-FreshWinPackage -Catalog $Catalog -Id ([string]$_.PackageId)
        $recommendation = Get-FreshWinPropertyValue -InputObject $trusted -Name 'recommendation' -Default $null
        $group = [string](Get-FreshWinPropertyValue -InputObject $recommendation -Name 'conflictGroup' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($group)) {
            [pscustomobject]@{ Group = $group; PackageId = [string]$trusted.id }
        }
    } | Group-Object Group | Where-Object Count -gt 1)
    if ($conflictSelections.Count -gt 0) {
        $details = @($conflictSelections | ForEach-Object { "$($_.Name): $(@($_.Group.PackageId) -join ', ')" }) -join '; '
        throw "Plan contains mutually exclusive catalog choices: $details."
    }

    $Plan.Status = 'EXECUTING'
    $liveSystemInfo = [bool](Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'IsLive' -Default $false)
    if (-not [bool]$Plan.DryRun -and $null -eq $SystemInfoProvider -and $liveSystemInfo -and (Test-FreshWinWindows)) {
        $SystemInfoProvider = { Get-FreshWinSystemInfo }
    }
    if (-not [bool]$Plan.DryRun -and $null -ne $SystemInfoProvider) {
        $refreshedSystemInfo = & $SystemInfoProvider
        if ($null -eq $refreshedSystemInfo) { throw 'The execution system-information provider returned no snapshot.' }
        $SystemInfo = $refreshedSystemInfo
    }
    if (-not [bool]$Plan.DryRun -and $null -eq $InventoryProvider -and $liveSystemInfo -and (Test-FreshWinWindows)) {
        $includeUpdatesForExecution = [string]$Plan.UpdatePolicy -eq 'include-updates'
        $InventoryProvider = { Get-FreshWinSoftwareInventorySnapshot -Refresh -IncludeUpdates:$includeUpdatesForExecution }
    }
    $checkpointWritesEnabled = -not [bool]$Plan.DryRun -and -not [string]::IsNullOrWhiteSpace($CheckpointPath)
    if (-not [bool]$Plan.DryRun -and $null -ne $InventoryProvider) {
        try {
            $freshInventory = & $InventoryProvider
            if ($null -eq $freshInventory) { throw 'The execution inventory provider returned no snapshot.' }
            $Inventory = $freshInventory
        }
        catch {
            $Inventory = [pscustomobject]@{
                Available = $false
                Status = 'Unknown'
                Items = @()
                Errors = @((Protect-FreshWinSensitiveText -Text $_.Exception.Message))
            }
        }
    }
    $isAdmin = if ($null -ne $SystemInfo) {
        [bool](Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'Admin' -Default (Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'IsAdministrator' -Default $false))
    } else { $false }
    $queueItems = @($Plan.Items)
    $progressEvents = New-Object System.Collections.Generic.List[object]
    $emitProgress = {
        param($ProgressItem, [string]$Stage, [string]$StageStatus, [string]$Detail)
        $progressSource = Get-FreshWinPropertyValue -InputObject $ProgressItem -Name 'ResolvedSource' -Default $null
        $progressResult = Get-FreshWinPropertyValue -InputObject $ProgressItem -Name 'Result' -Default $null
        $progressExitCode = Get-FreshWinPropertyValue -InputObject $progressResult -Name 'ExitCode' -Default $null
        $progressEvent = New-FreshWinProgressEvent -Item $ProgressItem -Stage $Stage -Status $StageStatus -Detail $Detail `
            -Position $position -Total $queueItems.Count -Source (Get-FreshWinExecutionSourceLabel -ResolvedSource $progressSource) `
            -ExitCode $progressExitCode
        $progressEvents.Add($progressEvent)
        if ($null -ne $ProgressCallback) { & $ProgressCallback $progressEvent }
    }
    $position = 0

    try {
        foreach ($item in @($Plan.Items)) {
            $position++
            $trustedPackage = Get-FreshWinPackage -Catalog $Catalog -Id ([string]$item.PackageId)
            if ($null -eq $trustedPackage) {
                throw "Plan package '$($item.PackageId)' is not present in the trusted catalog."
            }
            $item.Package = $trustedPackage
            $item.SafetyLevel = ([string](Get-FreshWinPropertyValue -InputObject $trustedPackage -Name 'riskLevel' -Default 'SAFE')).ToUpperInvariant()
            $trustedInstall = Get-FreshWinPropertyValue -InputObject $trustedPackage -Name 'install' -Default $null
            $item.RequiresAdmin = [bool](Get-FreshWinPropertyValue -InputObject $trustedInstall -Name 'requiresAdmin' -Default $false)
            $item.DependencyIds = @((Get-FreshWinPropertyValue -InputObject $trustedPackage -Name 'dependencies' -Default @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $item.RestartImpact = Get-FreshWinRestartBehavior -PackageOrRestart $trustedPackage
            $item.RestartRequired = $item.RestartImpact -eq 'required'
            & $emitProgress $item 'CHECKING_INSTALLED_STATE' 'InProgress' 'Reading current package state from the refreshed inventory.'
            $currentCompatibility = Get-FreshWinPackageCompatibility -Package $trustedPackage -SystemInfo $SystemInfo
            $currentDetection = Get-FreshWinPackageDetection -Package $trustedPackage -Inventory $Inventory -Compatibility $currentCompatibility -FeatureVerifier $FeatureVerifier
            $item.Compatibility = $currentCompatibility
            $item.Detection = $currentDetection
            & $emitProgress $item 'CHECKING_INSTALLED_STATE' 'Succeeded' ([string]$currentDetection.State)
            if ($currentCompatibility.Status -in @('Blocked', 'NotApplicable')) {
                $item.State = 'BLOCKED'
                $item.Result = [pscustomobject]@{ Outcome = 'Blocked'; Stage = 'Compatibility'; Attempts = 0; ExitCode = $null; Message = ($currentCompatibility.Reasons -join ' ') }
                Write-FreshWinExecutionLog -Stage 'INSTALL' -Action $item.Action -PackageId $item.PackageId -Result 'Blocked' -Message $item.Result.Message -Data $currentCompatibility -NoWrite:([bool]$Plan.DryRun)
                & $emitProgress $item 'COMPLETE' 'Failed' $item.Result.Message
                continue
            }

            if ([string]$Plan.UpdatePolicy -eq 'include-updates' -and $currentDetection.State -eq 'Installed' -and
                ([string]$trustedPackage.source.type) -in @('winget', 'msstore') -and
                -not (Test-FreshWinPackageUpdateCoverage -Package $trustedPackage -Inventory $Inventory)) {
                $item.State = 'BLOCKED'
                $item.Result = [pscustomobject]@{
                    Outcome='Blocked'; Stage='UpdateInventory'; Attempts=0; ExitCode=$null
                    Message="Update state for source '$([string]$trustedPackage.source.type)' could not be verified after refresh."
                }
                Write-FreshWinExecutionLog -Stage 'UPDATE' -Action $item.Action -PackageId $item.PackageId -Result 'Blocked' -Message $item.Result.Message -Data $currentDetection -NoWrite:([bool]$Plan.DryRun)
                & $emitProgress $item 'COMPLETE' 'Failed' $item.Result.Message
                continue
            }

            if ([string]$Plan.UpdatePolicy -eq 'include-updates' -and
                $currentDetection.State -eq 'UpdateAvailable' -and $item.Action -ne 'UPDATE') {
                # An update discovered after review is not authority to mutate.
                # It also means a previously reviewed SKIP/INSTALL/REPAIR is no
                # longer fully satisfied under include-updates policy, so keep
                # the original action visible and fail closed as a stale plan.
                if ($item.Action -in @('MANUAL', 'BLOCKED')) { continue }
                $item.State = 'BLOCKED'
                $item.Result = [pscustomobject]@{
                    Outcome='Blocked'; Stage='StalePlan'; Attempts=0; ExitCode=$null
                    Message='An update became available after plan review. Rebuild and review the plan before updating.'
                }
                Write-FreshWinExecutionLog -Stage 'UPDATE' -Action $item.Action -PackageId $item.PackageId -Result 'Blocked' `
                    -Message $item.Result.Message -Data $currentDetection -NoWrite:([bool]$Plan.DryRun)
                & $emitProgress $item 'COMPLETE' 'Failed' $item.Result.Message
                continue
            }

            # Reconcile only toward a safer non-mutating action. Another
            # installer, updater, or repair may have completed after review.
            # Never promote a previously MANUAL/BLOCKED item into execution.
            if ($currentDetection.State -eq 'Installed' -or
                ($currentDetection.State -eq 'UpdateAvailable' -and $item.Action -ne 'UPDATE')) {
                $previousAction = [string]$item.Action
                $item.Action = 'SKIP'
                $item.State = 'SKIP'
                $item.Reason = if ($currentDetection.State -eq 'Installed') {
                    "Refreshed inventory shows the requested '$previousAction' action is already satisfied."
                } else {
                    "Refreshed inventory shows the package is present; '$previousAction' was not promoted to an unreviewed update."
                }
                & $emitProgress $item 'COMPLETE' 'Skipped' $item.Reason
                continue
            }

            if ($item.Action -eq 'SKIP') {
                if ($currentDetection.State -notin @('Installed', 'UpdateAvailable')) {
                    $item.State = 'BLOCKED'
                    $item.Result = [pscustomobject]@{ Outcome = 'Blocked'; Stage = 'Detection'; Attempts = 0; ExitCode = $null; Message = "A skipped package is currently '$($currentDetection.State)' and cannot satisfy dependencies." }
                } else {
                    $item.State = 'SKIP'
                    $item.Reason = 'Current inventory confirms this package is already present.'
                }
                & $emitProgress $item 'COMPLETE' $(if ($item.State -eq 'SKIP') { 'Skipped' } else { 'Failed' }) $(if ($item.Result) { $item.Result.Message } else { $item.Reason })
                continue
            }
            if ($item.Action -in @('MANUAL', 'BLOCKED')) {
                & $emitProgress $item 'COMPLETE' $(if ($item.Action -eq 'MANUAL') { 'Manual' } else { 'Failed' }) ([string]$item.Reason)
                continue
            }
            if ($item.Action -notin @('INSTALL', 'UPDATE', 'REPAIR')) {
                $item.State = 'BLOCKED'
                & $emitProgress $item 'COMPLETE' 'Failed' "Unsupported planned action '$($item.Action)'."
                continue
            }

            $actionStateIsValid = switch ([string]$item.Action) {
                'INSTALL' { $currentDetection.State -eq 'NotInstalled' }
                'UPDATE' { $currentDetection.State -eq 'UpdateAvailable' }
                'REPAIR' { $currentDetection.State -eq 'Broken' }
                default { $false }
            }
            if (-not $actionStateIsValid) {
                if ($currentDetection.State -in @('Installed', 'UpdateAvailable') -and $item.Action -eq 'INSTALL') {
                    $item.Action = 'SKIP'
                    $item.State = 'SKIP'
                    $item.Reason = 'Current inventory shows this package is already installed.'
                    & $emitProgress $item 'COMPLETE' 'Skipped' $item.Reason
                    continue
                }
                $item.State = 'BLOCKED'
                $item.Result = [pscustomobject]@{ Outcome = 'Blocked'; Stage = 'Detection'; Attempts = 0; ExitCode = $null; Message = "Current detected state '$($currentDetection.State)' does not authorize action '$($item.Action)'." }
                Write-FreshWinExecutionLog -Stage 'INSTALL' -Action $item.Action -PackageId $item.PackageId -Result 'Blocked' -Message $item.Result.Message -Data $currentDetection -NoWrite:([bool]$Plan.DryRun)
                & $emitProgress $item 'COMPLETE' 'Failed' $item.Result.Message
                continue
            }

            if (-not (Test-FreshWinExecutionPrivilegeMatch -ExecutionMode $ExecutionMode -RequiresAdmin ([bool]$item.RequiresAdmin))) {
                $item.State = 'PENDING'
                $item.Attempts = 0
                $item.Result = New-FreshWinPrivilegeDeferralResult -Stage PrivilegePartition `
                    -Message "Action '$($item.Action)' is reserved for the opposite privilege execution phase."
                $item.Verification = $null
                if ($checkpointWritesEnabled) { Save-FreshWinExecutionCheckpoint -Plan $Plan -Path $CheckpointPath | Out-Null }
                & $emitProgress $item 'COMPLETE' 'Skipped' $item.Result.Message
                continue
            }
            $dependencyIds = @(Get-FreshWinPropertyValue -InputObject $item -Name 'DependencyIds' -Default @())
            $failedDependencies = New-Object System.Collections.Generic.List[string]
            $privilegeDeferredDependencies = New-Object System.Collections.Generic.List[string]
            foreach ($dependencyId in $dependencyIds) {
                $dependencyItem = @($Plan.Items | Where-Object PackageId -eq $dependencyId | Select-Object -First 1)
                if ($dependencyItem.Count -ne 1) {
                    $failedDependencies.Add([string]$dependencyId)
                    continue
                }
                if ([string]$dependencyItem[0].State -in @('SUCCEEDED', 'SKIP', 'VALIDATED')) { continue }

                $dependencyResult = Get-FreshWinPropertyValue -InputObject $dependencyItem[0] -Name 'Result' -Default $null
                $dependencyOutcome = [string](Get-FreshWinPropertyValue -InputObject $dependencyResult -Name 'Outcome' -Default '')
                $dependencyDeferral = [string](Get-FreshWinPropertyValue -InputObject $dependencyResult -Name 'DeferredBy' -Default '')
                if ([string]$dependencyItem[0].State -eq 'PENDING' -and
                    $dependencyOutcome -eq 'Deferred' -and $dependencyDeferral -eq 'OppositePrivilege') {
                    $privilegeDeferredDependencies.Add([string]$dependencyId)
                    continue
                }
                $failedDependencies.Add([string]$dependencyId)
            }
            if ($privilegeDeferredDependencies.Count -gt 0) {
                $item.State = 'PENDING'
                $item.Attempts = 0
                $item.Result = New-FreshWinPrivilegeDeferralResult -Stage Dependency `
                    -Message "Required dependencies are reserved for the opposite privilege execution phase: $($privilegeDeferredDependencies -join ', ')."
                $item.Verification = $null
                if ($checkpointWritesEnabled) { Save-FreshWinExecutionCheckpoint -Plan $Plan -Path $CheckpointPath | Out-Null }
                & $emitProgress $item 'COMPLETE' 'Skipped' $item.Result.Message
                continue
            }
            if ($failedDependencies.Count -gt 0) {
                $item.State = 'BLOCKED'
                $item.Result = [pscustomobject]@{
                    Outcome = 'Blocked'; Stage = 'Dependency'; Attempts = 0; ExitCode = $null
                    Message = "Required dependencies did not complete: $($failedDependencies -join ', ')."
                }
                Write-FreshWinExecutionLog -Stage 'INSTALL' -Action $item.Action -PackageId $item.PackageId -Result 'Blocked' -Message $item.Result.Message -Data $null -NoWrite:([bool]$Plan.DryRun)
                if ($checkpointWritesEnabled) { Save-FreshWinExecutionCheckpoint -Plan $Plan -Path $CheckpointPath | Out-Null }
                & $emitProgress $item 'COMPLETE' 'Failed' $item.Result.Message
                continue
            }

            & $emitProgress $item 'RESOLVING_SOURCE' 'InProgress' 'Resolving the executable and package identity through the trusted source policy.'
            try {
                $item.ResolvedSource = if ($null -ne $SourceResolver) {
                    & $SourceResolver $trustedPackage
                } else {
                    Resolve-FreshWinPackageSource -Package $trustedPackage
                }
                if ($null -eq $item.ResolvedSource) { throw 'The trusted source resolver returned no result.' }
            }
            catch {
                $item.State = 'BLOCKED'
                $item.Result = [pscustomobject]@{
                    Outcome='Blocked'; Stage='Resolve'; Attempts=0; ExitCode=$null; ProcessResult=$null
                    Message=(Protect-FreshWinSensitiveText -Text $_.Exception.Message)
                }
                & $emitProgress $item 'RESOLVING_SOURCE' 'Failed' $item.Result.Message
                & $emitProgress $item 'COMPLETE' 'Failed' $item.Result.Message
                Write-FreshWinExecutionLog -Stage 'RESOLVE' -Action $item.Action -PackageId $item.PackageId -Result 'Blocked' `
                    -Message $item.Result.Message -Data $null -NoWrite:([bool]$Plan.DryRun)
                continue
            }
            $resolvedStatus = [string](Get-FreshWinPropertyValue -InputObject $item.ResolvedSource -Name 'Status' -Default 'Unavailable')
            $resolvedReason = [string](Get-FreshWinPropertyValue -InputObject $item.ResolvedSource -Name 'Reason' -Default '')
            if ($resolvedStatus -eq 'Resolved') {
                & $emitProgress $item 'RESOLVING_SOURCE' 'Succeeded' (Get-FreshWinExecutionSourceLabel -ResolvedSource $item.ResolvedSource)
            } elseif ($resolvedStatus -eq 'Manual') {
                & $emitProgress $item 'RESOLVING_SOURCE' 'Manual' $resolvedReason
            } else {
                & $emitProgress $item 'RESOLVING_SOURCE' 'Failed' $resolvedReason
            }

            $item.State = 'RUNNING'
            if ($resolvedStatus -eq 'Resolved') {
                if ([bool]$Plan.DryRun) {
                    & $emitProgress $item 'DOWNLOADING' 'Waiting' 'Dry-run source validation completed; no download will be started.'
                } else {
                    & $emitProgress $item 'DOWNLOADING' 'InProgress' 'The trusted package manager is acquiring the package; it does not expose a reliable phase percentage.'
                }
                & $emitProgress $item 'INSTALLING' 'Waiting' 'Waiting for the trusted package manager installation phase.'
            }
            if ($checkpointWritesEnabled) { Save-FreshWinExecutionCheckpoint -Plan $Plan -Path $CheckpointPath | Out-Null }

            Write-FreshWinExecutionLog -Stage 'INSTALL' -Action $item.Action -PackageId $item.PackageId -Result 'Started' -Message "Starting $($item.Action)." -Data $null -NoWrite:([bool]$Plan.DryRun)
            $result = Invoke-FreshWinPackageInstall -Package $trustedPackage -Action $item.Action -ResolvedSource $item.ResolvedSource -DryRun:([bool]$Plan.DryRun) -IsAdministrator:$isAdmin -MaxAttempts $MaxAttempts -RetryDelaySeconds $(if ($null -ne $ProcessInvoker) { 0 } else { 2 }) -ProcessInvoker $ProcessInvoker
            $item.Attempts = $result.Attempts
            $item.Result = $result
            $item.RestartRequired = [bool]$item.RestartRequired -or [bool](Get-FreshWinPropertyValue -InputObject $result -Name 'RebootRequired' -Default $false)
            $resultStage = [string](Get-FreshWinPropertyValue -InputObject $result -Name 'Stage' -Default 'Install')
            if ($resolvedStatus -eq 'Resolved') {
                switch ([string]$result.Outcome) {
                    'ProcessSucceeded' {
                        & $emitProgress $item 'DOWNLOADING' 'Succeeded' 'The package manager completed its combined download/install operation.'
                        & $emitProgress $item 'INSTALLING' 'Succeeded' 'The installer process exited successfully; verification is still required.'
                    }
                    'DryRun' {
                        & $emitProgress $item 'DOWNLOADING' 'Skipped' 'Dry-run: no package was downloaded.'
                        & $emitProgress $item 'INSTALLING' 'Skipped' 'Dry-run: no installer was executed.'
                    }
                    default {
                        if ($resultStage -eq 'Download') {
                            & $emitProgress $item 'DOWNLOADING' 'Failed' ([string]$result.Message)
                            & $emitProgress $item 'INSTALLING' 'Skipped' 'Installation did not start because the download failed.'
                        } elseif ($resultStage -eq 'SourceAgreement') {
                            & $emitProgress $item 'DOWNLOADING' 'Manual' ([string]$result.Message)
                            & $emitProgress $item 'INSTALLING' 'Skipped' 'Installation did not start because source agreement consent is required.'
                        } else {
                            & $emitProgress $item 'DOWNLOADING' 'Unknown' 'The package manager did not expose a reliable download boundary before failing.'
                            & $emitProgress $item 'INSTALLING' 'Failed' ([string]$result.Message)
                        }
                    }
                }
            }

            switch ($result.Outcome) {
                'DryRun' {
                    $item.State = 'VALIDATED'
                    $item.Verification = [pscustomobject]@{ Status = 'NotRun'; Verified = $false; Detail = 'Dry-run never changes or verifies the installed state.' }
                    & $emitProgress $item 'VERIFYING' 'Skipped' $item.Verification.Detail
                    & $emitProgress $item 'REFRESHING_INVENTORY' 'Skipped' 'Dry-run: inventory was not changed.'
                }
                'ElevationRequired' {
                    $item.State = 'ELEVATION_REQUIRED'
                    $item.Verification = [pscustomobject]@{ Status = 'NotRun'; Verified = $false; Detail = $result.Message }
                }
                'ProcessSucceeded' {
                    & $emitProgress $item 'VERIFYING' 'InProgress' 'Running independent post-install detection.'
                    $verification = Test-FreshWinPackageVerification -Package $trustedPackage -Inventory $Inventory -SystemInfo $SystemInfo -InventoryProvider $InventoryProvider -FeatureVerifier $FeatureVerifier
                    $item.Verification = $verification
                    $refreshedInventory = Get-FreshWinPropertyValue -InputObject $verification -Name 'InventorySnapshot' -Default $null
                    if ($null -ne $refreshedInventory) { $Inventory = $refreshedInventory }
                    $postDetection = Get-FreshWinPropertyValue -InputObject $verification -Name 'Detection' -Default $null
                    if ($null -eq $postDetection) {
                        try { $postDetection = Get-FreshWinPackageDetection -Package $trustedPackage -Inventory $Inventory -Compatibility $currentCompatibility -FeatureVerifier $FeatureVerifier }
                        catch { $postDetection = $null }
                    }
                    if ($null -ne $postDetection) { $item.Detection = $postDetection }
                    $postState = [string](Get-FreshWinPropertyValue -InputObject $postDetection -Name 'State' -Default 'Unknown')

                    # A matched package identity proves presence, but it does not
                    # prove that an UPDATE or REPAIR achieved its requested state.
                    # Enforce those action-specific postconditions against the same
                    # refreshed inventory snapshot used by the verifier.
                    if ($verification.Status -eq 'Verified' -and $item.Action -eq 'UPDATE') {
                        $updatesScanned = Test-FreshWinPackageUpdateCoverage -Package $trustedPackage -Inventory $refreshedInventory
                        if ($postState -ne 'Installed') {
                            if ($postState -eq 'Unknown') {
                                $verification.Status = 'Unknown'
                                $verification.Detail = 'The package identity matched, but refreshed update state is unavailable.'
                            } else {
                                $verification.Status = 'Failed'
                                $verification.Detail = "The package identity matched, but refreshed detection is still '$postState' after UPDATE."
                            }
                            $verification.Verified = $false
                        }
                        elseif (-not $updatesScanned) {
                            $verification.Status = 'Unknown'
                            $verification.Verified = $false
                            $verification.Detail = 'The package identity matched, but the refreshed update provider did not establish that no update remains.'
                        }
                    }
                    elseif ($verification.Status -eq 'Verified' -and $item.Action -eq 'REPAIR' -and $postState -notin @('Installed', 'UpdateAvailable')) {
                        if ($postState -eq 'Unknown') {
                            $verification.Status = 'Unknown'
                            $verification.Detail = 'The package identity matched, but refreshed repair state is unavailable.'
                        } else {
                            $verification.Status = 'Failed'
                            $verification.Detail = "The package identity matched, but refreshed detection is '$postState' after REPAIR."
                        }
                        $verification.Verified = $false
                    }

                    if ($verification.Status -eq 'Verified') { $item.State = 'SUCCEEDED' }
                    elseif ($verification.Status -eq 'PendingReboot' -and [bool]$item.RestartRequired) {
                        # EnablePending is real reboot evidence, not final proof.
                        # Persist the item as pending so resume must observe the
                        # feature as Enabled before it can satisfy dependencies.
                        $item.State = 'PENDING'
                    }
                    elseif ($verification.Status -eq 'Unknown') { $item.State = 'UNKNOWN_VERIFICATION' }
                    else { $item.State = 'FAILED' }

                    if ($item.State -in @('FAILED', 'UNKNOWN_VERIFICATION')) {
                        $item.Result | Add-Member -NotePropertyName Stage -NotePropertyValue 'Verify' -Force
                        $item.Result | Add-Member -NotePropertyName Message -NotePropertyValue ([string]$verification.Detail) -Force
                    }

                    $verificationProgressStatus = if ($verification.Status -eq 'Verified') { 'Succeeded' }
                        elseif ($verification.Status -eq 'Unknown') { 'Unknown' }
                        else { 'Failed' }
                    & $emitProgress $item 'VERIFYING' $verificationProgressStatus ([string]$verification.Detail)
                    & $emitProgress $item 'REFRESHING_INVENTORY' 'InProgress' 'Applying the post-install inventory snapshot to the current session.'
                    $inventoryKnown = $null -ne $refreshedInventory -and [bool](Get-FreshWinPropertyValue -InputObject $refreshedInventory -Name 'Available' -Default $true)
                    if ($inventoryKnown) {
                        & $emitProgress $item 'REFRESHING_INVENTORY' 'Succeeded' 'The current session now uses the refreshed inventory.'
                    } else {
                        & $emitProgress $item 'REFRESHING_INVENTORY' 'Failed' 'The inventory refresh did not produce an available snapshot.'
                        if ($item.State -eq 'SUCCEEDED') {
                            $item.State = 'FAILED'
                            $item.Result | Add-Member -NotePropertyName Stage -NotePropertyValue 'RefreshInventory' -Force
                            $item.Result | Add-Member -NotePropertyName Message -NotePropertyValue 'Installation was verified, but the inventory refresh failed.' -Force
                        }
                    }
                }
                'ManualRequired' { $item.State = 'MANUAL' }
                'Blocked' { $item.State = 'BLOCKED' }
                default { $item.State = 'FAILED' }
            }

            if ($result.Outcome -eq 'ProcessSucceeded' -and -not [bool]$item.RestartRequired -and $null -ne $SystemInfoProvider) {
                $refreshedSystemInfo = & $SystemInfoProvider
                if ($null -eq $refreshedSystemInfo) { throw 'System information could not be refreshed after package execution.' }
                $SystemInfo = $refreshedSystemInfo
            }

            $executionLogDetail = [pscustomobject]@{
                Verification = $item.Verification
                ProcessResult = Get-FreshWinPropertyValue -InputObject $result -Name 'ProcessResult' -Default $null
                OutputSummary = Get-FreshWinPropertyValue -InputObject $result -Name 'OutputSummary' -Default ''
            }
            Write-FreshWinExecutionLog -Stage 'VERIFY_INSTALL' -Action $item.Action -PackageId $item.PackageId -Result $item.State `
                -ExitCode $(if ($null -ne $result.ExitCode) { [int]$result.ExitCode } else { $null }) -Message $result.Message -Data $executionLogDetail -NoWrite:([bool]$Plan.DryRun)
            if ($checkpointWritesEnabled) { Save-FreshWinExecutionCheckpoint -Plan $Plan -Path $CheckpointPath | Out-Null }
            $completionStatus = switch ([string]$item.State) {
                'SUCCEEDED' { 'Succeeded' }
                'SKIP' { 'Skipped' }
                'MANUAL' { 'Manual' }
                'VALIDATED' { 'Complete' }
                'UNKNOWN_VERIFICATION' { 'Unknown' }
                default { 'Failed' }
            }
            $completionDetail = [string](Get-FreshWinPropertyValue -InputObject $item.Verification -Name 'Detail' -Default (
                Get-FreshWinPropertyValue -InputObject $item.Result -Name 'Message' -Default $item.Reason))
            & $emitProgress $item 'COMPLETE' $completionStatus $completionDetail

            # A confirmed installer reboot is an execution boundary. Continuing
            # can make dependent detection/verification fail against pre-reboot
            # state, so remaining items stay pending for the hash-bound resume.
            if (-not [bool]$Plan.DryRun -and [bool]$item.RestartRequired -and (
                [string](Get-FreshWinPropertyValue -InputObject $result -Name 'Outcome' -Default '') -eq 'ProcessSucceeded' -or
                [bool](Get-FreshWinPropertyValue -InputObject $result -Name 'RebootRequired' -Default $false))) {
                break
            }
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        $Plan.Status = 'CANCELLED'
        if ($checkpointWritesEnabled) { Save-FreshWinExecutionCheckpoint -Plan $Plan -Path $CheckpointPath | Out-Null }
        throw
    }
    catch {
        $Plan.Status = 'FAILED'
        if ($checkpointWritesEnabled) { Save-FreshWinExecutionCheckpoint -Plan $Plan -Path $CheckpointPath | Out-Null }
        Write-FreshWinExecutionLog -Stage 'ERROR' -Action 'EXECUTION' -PackageId '' -Result 'Failed' -Message $_.Exception.Message -Data $null -NoWrite:([bool]$Plan.DryRun)
        throw
    }

    $summary = Get-FreshWinExecutionSummary -Plan $Plan
    if ($Plan.DryRun -and ($summary.Failed -gt 0 -or $summary.UnknownVerification -gt 0 -or $summary.Blocked -gt 0 -or $summary.ManualRequired -gt 0)) { $Plan.Status = 'COMPLETED_WITH_ISSUES' }
    elseif ($Plan.DryRun) { $Plan.Status = 'DRY_RUN_COMPLETE' }
    elseif ($summary.Failed -gt 0 -or $summary.UnknownVerification -gt 0 -or $summary.Blocked -gt 0 -or $summary.ManualRequired -gt 0) { $Plan.Status = 'COMPLETED_WITH_ISSUES' }
    elseif ($summary.RebootRequired) { $Plan.Status = 'REBOOT_REQUIRED' }
    elseif ($ExecutionMode -ne 'All' -and $summary.Pending -gt 0) { $Plan.Status = 'INCOMPLETE' }
    elseif ($summary.Pending -gt 0) { $Plan.Status = 'INCOMPLETE' }
    else { $Plan.Status = 'COMPLETED' }
    if ($checkpointWritesEnabled) { Save-FreshWinExecutionCheckpoint -Plan $Plan -Path $CheckpointPath | Out-Null }

    return [pscustomobject]@{ Plan = $Plan; Summary = $summary; Status = $Plan.Status; Progress = $progressEvents.ToArray() }
}
