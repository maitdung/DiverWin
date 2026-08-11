Set-StrictMode -Version Latest

function Test-FreshWinOfficialDriverSourceUri {
    [CmdletBinding()]
    param([AllowNull()][string]$Uri)

    if ([string]::IsNullOrWhiteSpace($Uri)) { return $false }
    try { $parsed = New-Object System.Uri($Uri) } catch { return $false }
    if ($parsed.Scheme -ne 'https') { return $false }
    $hostName = $parsed.DnsSafeHost.ToLowerInvariant()
    $allowedDomains = @(
        'nvidia.com', 'amd.com', 'intel.com', 'dell.com', 'hp.com',
        'lenovo.com', 'asus.com', 'msi.com', 'acer.com', 'microsoft.com'
    )
    foreach ($domain in $allowedDomains) {
        if ($hostName -eq $domain -or $hostName.EndsWith(".$domain", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-FreshWinDduReplacementArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Artifact,
        [AllowNull()][scriptblock]$SignatureProvider
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $path = [string](Get-FreshWinPropertyValue -InputObject $Artifact -Name 'Path')
    $expectedHash = [string](Get-FreshWinPropertyValue -InputObject $Artifact -Name 'Sha256')
    $sourceUri = [string](Get-FreshWinPropertyValue -InputObject $Artifact -Name 'SourceUri')
    $fullPath = $null
    $actualHash = $null
    if ([string]::IsNullOrWhiteSpace($path)) { $errors.Add('A local replacement-driver path is required.') }
    else {
        try { $fullPath = [System.IO.Path]::GetFullPath($path) } catch { $errors.Add('The replacement-driver path is invalid.') }
        if ($null -ne $fullPath -and -not [System.IO.File]::Exists($fullPath)) { $errors.Add('The replacement-driver artifact does not exist.') }
        elseif ($null -ne $fullPath) {
            if (([System.IO.File]::GetAttributes($fullPath) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $errors.Add('The replacement-driver artifact is a reparse point.') }
            else { $actualHash = Get-FreshWinOperationFileSha256 -Path $fullPath }
        }
    }
    if ($expectedHash -notmatch '^[a-fA-F0-9]{64}$') { $errors.Add('A SHA-256 digest is required.') }
    elseif ($null -ne $actualHash -and -not [string]::Equals($expectedHash, $actualHash, [System.StringComparison]::OrdinalIgnoreCase)) { $errors.Add('The replacement-driver SHA-256 digest does not match the file.') }
    if (-not (Test-FreshWinOfficialDriverSourceUri -Uri $sourceUri)) { $errors.Add('The replacement driver must record a recognized official HTTPS source.') }

    $windowsHost = Test-FreshWinOperationsWindows
    $signatureValid = $false
    $signatureStatus = 'NotChecked'
    $signatureIsLive = $false
    try {
        if ($null -ne $SignatureProvider) {
            $signature = & $SignatureProvider $fullPath
            $signatureValid = [bool](Get-FreshWinPropertyValue -InputObject $signature -Name 'Valid' -Default $false)
            $signatureStatus = [string](Get-FreshWinPropertyValue -InputObject $signature -Name 'Status' -Default 'Fixture')
        }
        elseif ($windowsHost -and $null -ne $fullPath) {
            $command = Get-Command -Name Get-AuthenticodeSignature -ErrorAction SilentlyContinue
            if ($null -eq $command) { throw 'Get-AuthenticodeSignature is unavailable.' }
            $signature = Get-AuthenticodeSignature -LiteralPath $fullPath -ErrorAction Stop
            $signatureStatus = [string]$signature.Status
            $signatureValid = $signature.Status -eq 'Valid'
            $signatureIsLive = $true
        }
    }
    catch { $errors.Add("Signature validation failed: $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)") }
    if (-not $signatureValid) { $errors.Add('The replacement-driver signature was not validated.') }

    $valid = $errors.Count -eq 0
    return [pscustomobject][ordered]@{
        Component                = 'DduReplacementArtifactValidation'
        Status                   = $(if ($valid) { if ($signatureIsLive) { 'Valid' } else { 'FixtureValid' } } else { 'Invalid' })
        Valid                    = $valid
        IsLive                   = $signatureIsLive
        WindowsSignatureVerified = $signatureIsLive -and $signatureValid
        Path                     = $fullPath
        FileName                 = $(if ($null -ne $fullPath) { [System.IO.Path]::GetFileName($fullPath) } else { $null })
        Sha256                   = $actualHash
        SourceUri                = $sourceUri
        SignatureStatus          = $signatureStatus
        Errors                   = $errors.ToArray()
    }
}

function ConvertTo-FreshWinDduGpuRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Gpu)

    $name = [string](Get-FreshWinPropertyValue -InputObject $Gpu -Name 'Name' -Default 'Unknown GPU')
    $instanceId = [string](Get-FreshWinPropertyValue -InputObject $Gpu -Name 'InstanceId' -Default (Get-FreshWinPropertyValue -InputObject $Gpu -Name 'PnpDeviceId'))
    $compatibility = [string](Get-FreshWinPropertyValue -InputObject $Gpu -Name 'AdapterCompatibility' -Default (Get-FreshWinPropertyValue -InputObject $Gpu -Name 'Manufacturer'))
    return [pscustomobject][ordered]@{
        Name          = $name
        Vendor        = Get-FreshWinPropertyValue -InputObject $Gpu -Name 'Vendor' -Default (Resolve-FreshWinGpuVendor -Name $name -PnpDeviceId $instanceId -AdapterCompatibility $compatibility)
        DriverVersion = Get-FreshWinPropertyValue -InputObject $Gpu -Name 'DriverVersion'
        Status        = Get-FreshWinPropertyValue -InputObject $Gpu -Name 'Status' -Default 'Unknown'
    }
}

function Add-FreshWinDduHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$FromState,
        [Parameter(Mandatory = $true)][string]$ToState,
        [string]$Note
    )

    $entry = [pscustomobject][ordered]@{
        AtUtc     = [DateTimeOffset]::UtcNow.ToString('o')
        Action    = $Action
        FromState = $FromState
        ToState   = $ToState
        Note      = Protect-FreshWinPrivacyText -Text $Note
    }
    $Plan.History = @($Plan.History) + @($entry)
}

function New-FreshWinDduRecoveryPlan {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$GPUs,
        [AllowNull()][string]$Manufacturer,
        [AllowNull()][string]$Model,
        [switch]$AcknowledgeAdvancedRisk,
        [AllowNull()][object]$ReplacementArtifact,
        [AllowNull()][scriptblock]$SignatureProvider,
        [switch]$ChoosePostCleanupOfficialAcquisition,
        [switch]$ConfirmSafetyCheckpoint
    )

    $provided = $PSBoundParameters.ContainsKey('GPUs')
    $windowsHost = Test-FreshWinOperationsWindows
    if (-not $provided -and -not $windowsHost) {
        $unsupported = New-FreshWinOperationUnsupportedResult -Component 'DduRecoveryPlan' -Reason 'GPU fixture data is required to create a DDU plan off Windows.'
        $unsupported | Add-Member -NotePropertyName State -NotePropertyValue 'Unsupported'
        $unsupported | Add-Member -NotePropertyName AutomaticCleanup -NotePropertyValue $false
        return $unsupported
    }
    if (-not $provided) {
        $hardware = Get-FreshWinHardwareInfo
        $GPUs = @($hardware.GPUs)
        $Manufacturer = [string]$hardware.Manufacturer
        $Model = [string]$hardware.Model
    }
    $gpuRecords = @($GPUs | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-FreshWinDduGpuRecord -Gpu $_ })
    $recommendations = @()
    if ($gpuRecords.Count -gt 0) {
        try { $recommendations = @(Get-FreshWinGpuDriverRecommendation -GPUs $GPUs -Manufacturer $Manufacturer -Model $Model) } catch { $recommendations = @() }
    }

    $initialState = if ($gpuRecords.Count -gt 0) { 'RiskAcknowledgementRequired' } else { 'GpuDetectionRequired' }
    $plan = [pscustomobject][ordered]@{
        SchemaVersion            = 'FreshWin.DduRecoveryPlan/1'
        Component                = 'DduRecoveryPlan'
        PlanId                   = [guid]::NewGuid().ToString('D')
        CreatedAtUtc             = [DateTimeOffset]::UtcNow.ToString('o')
        UpdatedAtUtc             = [DateTimeOffset]::UtcNow.ToString('o')
        Status                   = $(if ($windowsHost -and -not $provided) { 'LivePlan' } else { 'FixturePlan' })
        State                    = $initialState
        IsLive                   = ($windowsHost -and -not $provided)
        DetectedGPUs             = $gpuRecords
        DriverRecommendations    = $recommendations
        RiskAcknowledged         = $false
        Warning                  = 'DDU is an advanced repair tool, not a routine updater. Incorrect use can leave the PC without a usable display or network path.'
        ReplacementStrategy      = 'Unselected'
        ReplacementArtifact      = $null
        SafetyCheckpointConfirmed = $false
        ManualCleanupConfirmed   = $false
        RebootResumeRequired     = $false
        ReplacementInstalled     = $false
        Verification             = $null
        AutomaticCleanup         = $false
        AutomaticDownload        = $false
        AutomaticExecution       = $false
        CleanupExecutable        = $null
        CleanupArguments         = @()
        ResumeState              = $null
        History                  = @([pscustomobject]@{ AtUtc = [DateTimeOffset]::UtcNow.ToString('o'); Action = 'CreatePlan'; FromState = $null; ToState = $initialState; Note = 'No cleanup or download was executed.' })
    }

    if ($AcknowledgeAdvancedRisk -and $plan.State -eq 'RiskAcknowledgementRequired') {
        $plan = Move-FreshWinDduRecoveryPlan -Plan $plan -Action AcknowledgeAdvancedRisk -ManualConfirmation
    }
    if ($null -ne $ReplacementArtifact -and $plan.State -eq 'ReplacementPreparationRequired') {
        $plan = Move-FreshWinDduRecoveryPlan -Plan $plan -Action RecordReplacementPrepared -ReplacementArtifact $ReplacementArtifact -SignatureProvider $SignatureProvider
    }
    elseif ($ChoosePostCleanupOfficialAcquisition -and $plan.State -eq 'ReplacementPreparationRequired') {
        $plan = Move-FreshWinDduRecoveryPlan -Plan $plan -Action ChoosePostCleanupOfficialAcquisition -ManualConfirmation
    }
    if ($ConfirmSafetyCheckpoint -and $plan.State -eq 'SafetyCheckpointRequired') {
        $plan = Move-FreshWinDduRecoveryPlan -Plan $plan -Action ConfirmSafetyCheckpoint -ManualConfirmation
    }
    return $plan
}

function Move-FreshWinDduRecoveryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)]
        [ValidateSet('AcknowledgeAdvancedRisk', 'RecordReplacementPrepared', 'ChoosePostCleanupOfficialAcquisition', 'ConfirmSafetyCheckpoint', 'RecordManualCleanupComplete', 'PrepareRebootResume', 'ConfirmResumedAfterReboot', 'RecordOfficialReplacementAcquired', 'RecordManualReplacementInstalled', 'RecordVerification', 'Cancel')]
        [string]$Action,
        [AllowNull()][object]$ReplacementArtifact,
        [AllowNull()][scriptblock]$SignatureProvider,
        [AllowNull()][object]$Observation,
        [AllowNull()][scriptblock]$VerificationProvider,
        [switch]$ManualConfirmation,
        [string]$Note
    )

    $validation = Test-FreshWinDduRecoveryPlan -Plan $Plan
    if (-not $validation.Valid) { throw "The DDU recovery plan is invalid: $($validation.Errors -join '; ')" }
    $copy = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Plan -Depth 40)
    $fromState = [string]$copy.State
    $toState = $null

    switch ($Action) {
        'AcknowledgeAdvancedRisk' {
            if ($fromState -ne 'RiskAcknowledgementRequired') { throw "Action '$Action' is invalid from state '$fromState'." }
            if (-not $ManualConfirmation) { throw 'Explicit manual risk acknowledgement is required.' }
            $copy.RiskAcknowledged = $true
            $toState = 'ReplacementPreparationRequired'
        }
        'RecordReplacementPrepared' {
            if ($fromState -notin @('ReplacementPreparationRequired', 'ReplacementAcquisitionRequired')) { throw "Action '$Action' is invalid from state '$fromState'." }
            if ($null -eq $ReplacementArtifact) { throw 'ReplacementArtifact is required.' }
            $artifactValidation = Test-FreshWinDduReplacementArtifact -Artifact $ReplacementArtifact -SignatureProvider $SignatureProvider
            if (-not $artifactValidation.Valid) { throw "Replacement artifact validation failed: $($artifactValidation.Errors -join '; ')" }
            $copy.ReplacementArtifact = $artifactValidation
            $copy.ReplacementStrategy = $(if ($fromState -eq 'ReplacementAcquisitionRequired') { 'OfficialAcquisitionAfterCleanup' } else { 'PreparedBeforeCleanup' })
            $toState = $(if ($fromState -eq 'ReplacementAcquisitionRequired') { 'ReplacementInstallationRequired' } else { 'SafetyCheckpointRequired' })
        }
        'ChoosePostCleanupOfficialAcquisition' {
            if ($fromState -ne 'ReplacementPreparationRequired') { throw "Action '$Action' is invalid from state '$fromState'." }
            if (-not $ManualConfirmation) { throw 'Explicit acknowledgement of post-cleanup acquisition risk is required.' }
            $copy.ReplacementStrategy = 'OfficialAcquisitionAfterCleanup'
            $toState = 'SafetyCheckpointRequired'
        }
        'ConfirmSafetyCheckpoint' {
            if ($fromState -ne 'SafetyCheckpointRequired') { throw "Action '$Action' is invalid from state '$fromState'." }
            if (-not $ManualConfirmation) { throw 'Explicit confirmation of an external safety checkpoint is required.' }
            $copy.SafetyCheckpointConfirmed = $true
            $toState = 'ReadyForManualCleanup'
        }
        'RecordManualCleanupComplete' {
            if ($fromState -ne 'ReadyForManualCleanup') { throw "Action '$Action' is invalid from state '$fromState'." }
            if (-not $ManualConfirmation) { throw 'FreshWin requires explicit confirmation that cleanup was completed outside FreshWin.' }
            $copy.ManualCleanupConfirmed = $true
            $toState = 'RebootRequired'
        }
        'PrepareRebootResume' {
            if ($fromState -ne 'RebootRequired') { throw "Action '$Action' is invalid from state '$fromState'." }
            if (-not $ManualConfirmation) { throw 'Explicit confirmation is required before recording a reboot/resume checkpoint.' }
            $copy.RebootResumeRequired = $true
            $copy.ResumeState = 'ResumeAfterReboot'
            $toState = 'ResumeAfterReboot'
        }
        'ConfirmResumedAfterReboot' {
            if ($fromState -ne 'ResumeAfterReboot') { throw "Action '$Action' is invalid from state '$fromState'." }
            if ($null -eq $Observation -or (Get-FreshWinPropertyValue -InputObject $Observation -Name 'RebootObserved') -ne $true) { throw 'An explicit post-reboot observation is required.' }
            $copy.RebootResumeRequired = $false
            $copy.ResumeState = $null
            $toState = $(if ($copy.ReplacementStrategy -eq 'PreparedBeforeCleanup') { 'ReplacementInstallationRequired' } else { 'ReplacementAcquisitionRequired' })
        }
        'RecordOfficialReplacementAcquired' {
            if ($fromState -ne 'ReplacementAcquisitionRequired') { throw "Action '$Action' is invalid from state '$fromState'." }
            if ($null -eq $ReplacementArtifact) { throw 'ReplacementArtifact is required.' }
            $artifactValidation = Test-FreshWinDduReplacementArtifact -Artifact $ReplacementArtifact -SignatureProvider $SignatureProvider
            if (-not $artifactValidation.Valid) { throw "Replacement artifact validation failed: $($artifactValidation.Errors -join '; ')" }
            $copy.ReplacementArtifact = $artifactValidation
            $toState = 'ReplacementInstallationRequired'
        }
        'RecordManualReplacementInstalled' {
            if ($fromState -ne 'ReplacementInstallationRequired') { throw "Action '$Action' is invalid from state '$fromState'." }
            if (-not $ManualConfirmation) { throw 'Explicit confirmation of the external driver installation is required.' }
            $copy.ReplacementInstalled = $true
            $toState = 'VerificationRequired'
        }
        'RecordVerification' {
            if ($fromState -ne 'VerificationRequired') { throw "Action '$Action' is invalid from state '$fromState'." }
            $verificationIsLive = $false
            if ($null -ne $VerificationProvider) { $verification = & $VerificationProvider $copy.DetectedGPUs }
            elseif ($null -ne $Observation) { $verification = $Observation }
            elseif (Test-FreshWinOperationsWindows) {
                $hardware = Get-FreshWinHardwareInfo
                $driverInventory = @(Get-FreshWinDriverInventory -IncludeHardwareIds -IncludeHealthy)
                $graphicsProblems = @($driverInventory | Where-Object { $_.Category -eq 'Graphics' -and $_.Health -ne 'Healthy' })
                $verification = [pscustomobject]@{
                    GpuPresent    = @($hardware.GPUs).Count -gt 0
                    DriverVersion = $(if (@($hardware.GPUs).Count -gt 0) { $hardware.GPUs[0].DriverVersion } else { $null })
                    DeviceHealth  = $(if ($graphicsProblems.Count -eq 0 -and @($hardware.GPUs).Count -gt 0) { 'Healthy' } else { 'Problem' })
                }
                $verificationIsLive = $true
            }
            else { throw 'A verification fixture/provider is required off Windows.' }
            $gpuPresent = (Get-FreshWinPropertyValue -InputObject $verification -Name 'GpuPresent') -eq $true
            $driverVersion = [string](Get-FreshWinPropertyValue -InputObject $verification -Name 'DriverVersion')
            $deviceHealth = [string](Get-FreshWinPropertyValue -InputObject $verification -Name 'DeviceHealth' -Default 'Unknown')
            $verified = $gpuPresent -and -not [string]::IsNullOrWhiteSpace($driverVersion) -and $deviceHealth -match '(?i)^(Healthy|OK)$'
            $copy.Verification = [pscustomobject][ordered]@{
                Verified      = $verified
                GpuPresent    = $gpuPresent
                DriverVersion = $driverVersion
                DeviceHealth  = $deviceHealth
                # Values supplied through Observation or VerificationProvider are
                # fixtures even if they contain an IsLive property. Only FreshWin's
                # own guarded Windows query can establish live verification.
                IsLive        = $verificationIsLive
                ObservedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            }
            $toState = $(if ($verified) { 'Completed' } else { 'VerificationRequired' })
        }
        'Cancel' {
            if ($fromState -eq 'Completed') { throw 'A completed DDU recovery plan cannot be cancelled.' }
            $toState = 'Cancelled'
        }
    }

    $copy.State = $toState
    $copy.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    if ($toState -eq 'Completed') {
        $artifactLive = $null -ne $copy.ReplacementArtifact -and
            [bool](Get-FreshWinPropertyValue -InputObject $copy.ReplacementArtifact -Name 'WindowsSignatureVerified' -Default $false)
        $copy.Status = $(if ($copy.IsLive -and $artifactLive -and $copy.Verification.IsLive) { 'Completed' } else { 'FixtureCompleted' })
    }
    elseif ($toState -eq 'Cancelled') { $copy.Status = 'Cancelled' }
    Add-FreshWinDduHistory -Plan $copy -Action $Action -FromState $fromState -ToState $toState -Note $Note
    return $copy
}

function Test-FreshWinDduRecoveryPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    $errors = New-Object System.Collections.Generic.List[string]
    if ([string](Get-FreshWinPropertyValue -InputObject $Plan -Name 'SchemaVersion') -ne 'FreshWin.DduRecoveryPlan/1') { $errors.Add('Unsupported DDU plan schema.') }
    if ([bool](Get-FreshWinPropertyValue -InputObject $Plan -Name 'AutomaticCleanup' -Default $true)) { $errors.Add('Automatic cleanup must remain disabled.') }
    if ([bool](Get-FreshWinPropertyValue -InputObject $Plan -Name 'AutomaticDownload' -Default $true)) { $errors.Add('Automatic download must remain disabled.') }
    if ([bool](Get-FreshWinPropertyValue -InputObject $Plan -Name 'AutomaticExecution' -Default $true)) { $errors.Add('Automatic execution must remain disabled.') }
    if ($null -ne (Get-FreshWinPropertyValue -InputObject $Plan -Name 'CleanupExecutable')) { $errors.Add('A cleanup executable must not be stored.') }
    if (@((Get-FreshWinPropertyValue -InputObject $Plan -Name 'CleanupArguments' -Default @())).Count -gt 0) { $errors.Add('Cleanup arguments must remain empty.') }
    $allowedStates = @('GpuDetectionRequired', 'RiskAcknowledgementRequired', 'ReplacementPreparationRequired', 'SafetyCheckpointRequired', 'ReadyForManualCleanup', 'RebootRequired', 'ResumeAfterReboot', 'ReplacementAcquisitionRequired', 'ReplacementInstallationRequired', 'VerificationRequired', 'Completed', 'Cancelled')
    if ($allowedStates -notcontains [string](Get-FreshWinPropertyValue -InputObject $Plan -Name 'State')) { $errors.Add('The DDU plan state is invalid.') }
    if ([string](Get-FreshWinPropertyValue -InputObject $Plan -Name 'State') -eq 'Completed') {
        $verification = Get-FreshWinPropertyValue -InputObject $Plan -Name 'Verification'
        if ((Get-FreshWinPropertyValue -InputObject $verification -Name 'Verified') -ne $true) { $errors.Add('Completed state requires successful verification evidence.') }
        if ((Get-FreshWinPropertyValue -InputObject $Plan -Name 'RiskAcknowledged') -ne $true) { $errors.Add('Completed state requires risk acknowledgement.') }
        if ((Get-FreshWinPropertyValue -InputObject $Plan -Name 'SafetyCheckpointConfirmed') -ne $true) { $errors.Add('Completed state requires a safety checkpoint.') }
        if ((Get-FreshWinPropertyValue -InputObject $Plan -Name 'ManualCleanupConfirmed') -ne $true) { $errors.Add('Completed state requires manual cleanup confirmation.') }
        if ((Get-FreshWinPropertyValue -InputObject $Plan -Name 'ReplacementInstalled') -ne $true) { $errors.Add('Completed state requires replacement installation confirmation.') }
        $artifact = Get-FreshWinPropertyValue -InputObject $Plan -Name 'ReplacementArtifact'
        if ((Get-FreshWinPropertyValue -InputObject $artifact -Name 'Valid') -ne $true) { $errors.Add('Completed state requires a validated replacement artifact.') }
    }
    return [pscustomobject][ordered]@{
        Component = 'DduRecoveryPlanValidation'
        Valid     = $errors.Count -eq 0
        State     = Get-FreshWinPropertyValue -InputObject $Plan -Name 'State'
        Errors    = $errors.ToArray()
        ExecutableCleanupAllowed = $false
    }
}

function Save-FreshWinDduRecoveryCheckpoint {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $validation = Test-FreshWinDduRecoveryPlan -Plan $Plan
    if (-not $validation.Valid) { throw "Cannot save invalid DDU plan: $($validation.Errors -join '; ')" }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ([System.IO.Path]::GetExtension($fullPath) -ine '.json') { throw 'DDU checkpoint paths must use a .json extension.' }
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    [void](Assert-FreshWinSafeOutputRoot -Path $parent)
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Write DDU recovery state checkpoint')) { return $null }
    [void](Write-FreshWinJsonFile -Path $fullPath -Value (Protect-FreshWinSensitiveData -InputObject $Plan) -Depth 40 -Atomic)
    return $fullPath
}

function Get-FreshWinDduRecoveryCheckpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $plan = Read-FreshWinJsonFile -Path $Path
    $validation = Test-FreshWinDduRecoveryPlan -Plan $plan
    if (-not $validation.Valid) { throw "The DDU checkpoint is invalid: $($validation.Errors -join '; ')" }
    return $plan
}
