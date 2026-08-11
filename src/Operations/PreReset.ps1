Set-StrictMode -Version Latest

function Get-FreshWinPreResetObservations {
    [CmdletBinding()]
    param(
        [AllowNull()][scriptblock]$BitLockerProvider,
        [AllowNull()][scriptblock]$StorageProvider,
        [AllowNull()][scriptblock]$PowerProvider,
        [AllowNull()][scriptblock]$RestartProvider
    )

    $providerSupplied = $null -ne $BitLockerProvider -or $null -ne $StorageProvider -or $null -ne $PowerProvider -or $null -ne $RestartProvider
    $windowsHost = Test-FreshWinOperationsWindows
    if (-not $windowsHost -and -not $providerSupplied) {
        $unsupported = New-FreshWinOperationUnsupportedResult -Component 'PreResetObservations'
        $unsupported | Add-Member -NotePropertyName BitLockerVolumes -NotePropertyValue @()
        $unsupported | Add-Member -NotePropertyName Storage -NotePropertyValue @()
        $unsupported | Add-Member -NotePropertyName Power -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName RestartPending -NotePropertyValue $null
        return $unsupported
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $bitLockerVolumes = New-Object System.Collections.Generic.List[object]
    try {
        if ($null -ne $BitLockerProvider) { $rawBitLocker = @(& $BitLockerProvider) }
        elseif ($windowsHost) {
            $command = Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue
            if ($null -eq $command) { throw 'Get-BitLockerVolume is unavailable.' }
            $rawBitLocker = @(Get-BitLockerVolume -ErrorAction Stop)
        }
        else { $rawBitLocker = @() }
        foreach ($volume in $rawBitLocker) {
            if ($null -eq $volume) { continue }
            $keyProtectorTypes = New-Object System.Collections.Generic.List[string]
            foreach ($protector in @((Get-FreshWinPropertyValue -InputObject $volume -Name 'KeyProtector' -Default @()))) {
                $type = [string](Get-FreshWinPropertyValue -InputObject $protector -Name 'KeyProtectorType')
                if (-not [string]::IsNullOrWhiteSpace($type) -and $keyProtectorTypes -notcontains $type) { $keyProtectorTypes.Add($type) }
            }
            foreach ($type in @((Get-FreshWinPropertyValue -InputObject $volume -Name 'KeyProtectorTypes' -Default @()))) {
                if (-not [string]::IsNullOrWhiteSpace([string]$type) -and $keyProtectorTypes -notcontains [string]$type) { $keyProtectorTypes.Add([string]$type) }
            }
            $bitLockerVolumes.Add([pscustomobject][ordered]@{
                    MountPoint          = Get-FreshWinPropertyValue -InputObject $volume -Name 'MountPoint'
                    VolumeStatus        = Get-FreshWinPropertyValue -InputObject $volume -Name 'VolumeStatus'
                    ProtectionStatus    = Get-FreshWinPropertyValue -InputObject $volume -Name 'ProtectionStatus'
                    EncryptionPercentage = Get-FreshWinPropertyValue -InputObject $volume -Name 'EncryptionPercentage'
                    KeyProtectorTypes   = $keyProtectorTypes.ToArray()
                    RecoverySecretRead  = $false
                })
        }
    }
    catch { $errors.Add("BitLocker: $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)") }

    $storage = New-Object System.Collections.Generic.List[object]
    try {
        if ($null -ne $StorageProvider) { $rawStorage = @(& $StorageProvider) }
        elseif ($windowsHost) {
            $command = Get-Command -Name Get-Volume -ErrorAction SilentlyContinue
            if ($null -eq $command) { throw 'Get-Volume is unavailable.' }
            $rawStorage = @(Get-Volume -ErrorAction Stop)
        }
        else { $rawStorage = @() }
        foreach ($volume in $rawStorage) {
            if ($null -eq $volume) { continue }
            $storage.Add([pscustomobject][ordered]@{
                    DriveLetter   = Get-FreshWinPropertyValue -InputObject $volume -Name 'DriveLetter'
                    FileSystem    = Get-FreshWinPropertyValue -InputObject $volume -Name 'FileSystem'
                    HealthStatus  = Get-FreshWinPropertyValue -InputObject $volume -Name 'HealthStatus'
                    OperationalStatus = Get-FreshWinPropertyValue -InputObject $volume -Name 'OperationalStatus'
                    Size          = Get-FreshWinPropertyValue -InputObject $volume -Name 'Size'
                    SizeRemaining = Get-FreshWinPropertyValue -InputObject $volume -Name 'SizeRemaining'
                })
        }
    }
    catch { $errors.Add("Storage: $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)") }

    $power = $null
    try {
        if ($null -ne $PowerProvider) { $rawPower = & $PowerProvider }
        elseif ($windowsHost) {
            $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
            $rawPower = [pscustomobject]@{
                BatteryPresent  = $batteries.Count -gt 0
                MinimumCharge   = $(if ($batteries.Count -gt 0) { ($batteries | Measure-Object -Property EstimatedChargeRemaining -Minimum).Minimum } else { $null })
                AcPowerReported = $(if ($batteries.Count -gt 0) { @($batteries | Where-Object { $_.BatteryStatus -in @(2, 6, 7, 8, 9, 11) }).Count -gt 0 } else { $null })
            }
        }
        else { $rawPower = $null }
        if ($null -ne $rawPower) {
            $power = [pscustomobject][ordered]@{
                BatteryPresent  = Get-FreshWinPropertyValue -InputObject $rawPower -Name 'BatteryPresent'
                MinimumCharge   = Get-FreshWinPropertyValue -InputObject $rawPower -Name 'MinimumCharge'
                AcPowerReported = Get-FreshWinPropertyValue -InputObject $rawPower -Name 'AcPowerReported'
            }
        }
    }
    catch { $errors.Add("Power: $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)") }

    $restartPending = $null
    try {
        if ($null -ne $RestartProvider) { $restartPending = & $RestartProvider }
        elseif ($windowsHost) { $restartPending = Test-FreshWinRestartPending }
    }
    catch { $errors.Add("Restart state: $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)") }

    return [pscustomobject][ordered]@{
        Component         = 'PreResetObservations'
        Status            = $(if ($errors.Count -eq 0) { if ($windowsHost -and -not $providerSupplied) { 'LiveObserved' } else { 'FixtureObserved' } } else { 'Partial' })
        IsLive            = ($windowsHost -and -not $providerSupplied)
        MutationPerformed = $false
        BitLockerVolumes  = $bitLockerVolumes.ToArray()
        Storage           = $storage.ToArray()
        Power             = $power
        RestartPending    = $restartPending
        Errors            = $errors.ToArray()
        SecretPolicy      = 'Recovery passwords, recovery keys, and key material are never queried or retained.'
    }
}

function New-FreshWinPreResetChecklistItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Description,
        [bool]$Required = $true,
        [ValidateSet('Confirmed', 'Unconfirmed', 'NotReady', 'Unknown')][string]$Status = 'Unconfirmed',
        [string]$Evidence
    )

    return [pscustomobject][ordered]@{
        Id          = $Id
        Description = $Description
        Required    = $Required
        Status      = $Status
        Evidence    = Protect-FreshWinPrivacyText -Text $Evidence
        ConfirmedAtUtc = $null
    }
}

function New-FreshWinPreResetPlan {
    [CmdletBinding()]
    param(
        [AllowNull()][hashtable]$Confirmations,
        [AllowNull()][object]$DriverBackup,
        [AllowNull()][object]$SoftwareInventory,
        [AllowNull()][object]$DiagnosticsExport,
        [AllowNull()][object]$Observations,
        [AllowNull()][scriptblock]$BitLockerProvider,
        [AllowNull()][scriptblock]$StorageProvider,
        [AllowNull()][scriptblock]$PowerProvider,
        [AllowNull()][scriptblock]$RestartProvider
    )

    if ($null -eq $Confirmations) { $Confirmations = @{} }
    if ($null -eq $Observations) {
        $Observations = Get-FreshWinPreResetObservations -BitLockerProvider $BitLockerProvider -StorageProvider $StorageProvider -PowerProvider $PowerProvider -RestartProvider $RestartProvider
    }
    $items = New-Object System.Collections.Generic.List[object]

    $driverBackupConfirmed = $false
    if ($null -ne $DriverBackup) {
        $driverBackupConfirmed = [bool](Get-FreshWinPropertyValue -InputObject $DriverBackup -Name 'Succeeded' -Default $false) -and
            [bool](Get-FreshWinPropertyValue -InputObject $DriverBackup -Name 'WindowsExecutionVerified' -Default $false)
    }
    $softwareCaptured = $null -ne $SoftwareInventory
    $diagnosticsCaptured = $null -ne $DiagnosticsExport -and
        [bool](Get-FreshWinPropertyValue -InputObject $DiagnosticsExport -Name 'Succeeded' -Default $false) -and
        [bool](Get-FreshWinPropertyValue -InputObject $DiagnosticsExport -Name 'Redacted' -Default $false)

    $automaticEvidence = @{
        DriverBackupVerified       = $driverBackupConfirmed
        ApplicationInventoryCaptured = $softwareCaptured
        DiagnosticsExported        = $diagnosticsCaptured
        RestartNotPending          = (Get-FreshWinPropertyValue -InputObject $Observations -Name 'RestartPending') -eq $false
    }
    $definitions = @(
        @('UserDataBackupConfirmed', 'Confirm that all required user files are backed up and independently readable.'),
        @('DriverBackupVerified', 'Create and integrity-check a live Windows driver backup.'),
        @('ApplicationInventoryCaptured', 'Capture the application inventory and license/account dependencies.'),
        @('HardwareReportCaptured', 'Capture a hardware report for post-reset driver identification.'),
        @('DiagnosticsExported', 'Export a redacted diagnostics bundle.'),
        @('BrowserSyncConfirmed', 'Confirm browser profile, bookmarks, and synchronization state.'),
        @('LicenseAccountAccessConfirmed', 'Confirm access to required accounts and license records without storing credentials in FreshWin.'),
        @('BitLockerRecoveryKeyStoredExternally', 'Confirm the BitLocker recovery key is available outside this PC; FreshWin never reads it.'),
        @('RecoveryMediaPrepared', 'Prepare trusted Windows/OEM recovery media or verify the intended recovery path.'),
        @('PowerReady', 'Connect reliable power and confirm adequate battery charge where applicable.'),
        @('StorageReady', 'Review storage health and available capacity before reset.'),
        @('RestartNotPending', 'Resolve or explicitly review any pending restart before beginning reset.')
    )
    foreach ($definition in $definitions) {
        $id = [string]$definition[0]
        $confirmed = $false
        if ($automaticEvidence.ContainsKey($id)) { $confirmed = [bool]$automaticEvidence[$id] }
        if ($Confirmations.ContainsKey($id)) { $confirmed = [bool]$Confirmations[$id] }
        $items.Add((New-FreshWinPreResetChecklistItem -Id $id -Description ([string]$definition[1]) -Status $(if ($confirmed) { 'Confirmed' } else { 'Unconfirmed' }) -Evidence $(if ($confirmed) { 'Explicit confirmation or verified FreshWin artifact.' } else { $null })))
    }

    $plan = [pscustomobject][ordered]@{
        SchemaVersion       = 'FreshWin.PreResetPlan/1'
        Component           = 'PreResetPlan'
        PlanId              = [guid]::NewGuid().ToString('D')
        CreatedAtUtc        = [DateTimeOffset]::UtcNow.ToString('o')
        Status              = 'ReviewRequired'
        IsLive              = [bool](Get-FreshWinPropertyValue -InputObject $Observations -Name 'IsLive' -Default $false)
        Observations        = Protect-FreshWinPrivacyData -InputObject $Observations
        Items               = $items.ToArray()
        ResetExecutionAllowed = $false
        AutomaticExecution  = $false
        ResetCommand        = $null
        SafetyNote          = 'FreshWin prepares and validates a checklist only. It never starts, schedules, or confirms a Windows reset.'
    }
    $validation = Test-FreshWinPreResetPlan -Plan $plan
    $plan.Status = $(if ($validation.Ready) { 'ReadyForManualResetReview' } else { 'Blocked' })
    return $plan
}

function Set-FreshWinPreResetChecklistItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z][A-Za-z0-9]{2,63}$')][string]$ItemId,
        [Parameter(Mandatory = $true)][ValidateSet('Confirmed', 'Unconfirmed', 'NotReady', 'Unknown')][string]$Status,
        [string]$Evidence
    )

    if ([string](Get-FreshWinPropertyValue -InputObject $Plan -Name 'SchemaVersion') -ne 'FreshWin.PreResetPlan/1') {
        throw 'The pre-reset plan schema is unsupported.'
    }
    $items = New-Object System.Collections.Generic.List[object]
    $found = $false
    foreach ($item in @($Plan.Items)) {
        $newItem = [pscustomobject][ordered]@{
            Id             = $item.Id
            Description    = $item.Description
            Required       = [bool]$item.Required
            Status         = $item.Status
            Evidence       = $item.Evidence
            ConfirmedAtUtc = $item.ConfirmedAtUtc
        }
        if ([string]$item.Id -eq $ItemId) {
            $found = $true
            $newItem.Status = $Status
            $newItem.Evidence = Protect-FreshWinPrivacyText -Text $Evidence
            $newItem.ConfirmedAtUtc = $(if ($Status -eq 'Confirmed') { [DateTimeOffset]::UtcNow.ToString('o') } else { $null })
        }
        $items.Add($newItem)
    }
    if (-not $found) { throw "Pre-reset checklist item '$ItemId' was not found." }

    $updated = [pscustomobject][ordered]@{
        SchemaVersion        = $Plan.SchemaVersion
        Component            = $Plan.Component
        PlanId               = $Plan.PlanId
        CreatedAtUtc         = $Plan.CreatedAtUtc
        Status               = 'ReviewRequired'
        IsLive               = [bool]$Plan.IsLive
        Observations         = $Plan.Observations
        Items                = $items.ToArray()
        ResetExecutionAllowed = $false
        AutomaticExecution   = $false
        ResetCommand         = $null
        SafetyNote           = $Plan.SafetyNote
    }
    $validation = Test-FreshWinPreResetPlan -Plan $updated
    $updated.Status = $(if ($validation.Ready) { 'ReadyForManualResetReview' } else { 'Blocked' })
    return $updated
}

function Test-FreshWinPreResetPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    $errors = New-Object System.Collections.Generic.List[string]
    if ([string](Get-FreshWinPropertyValue -InputObject $Plan -Name 'SchemaVersion') -ne 'FreshWin.PreResetPlan/1') { $errors.Add('Unsupported plan schema.') }
    if ([bool](Get-FreshWinPropertyValue -InputObject $Plan -Name 'ResetExecutionAllowed' -Default $true)) { $errors.Add('Reset execution must remain disabled.') }
    if ([bool](Get-FreshWinPropertyValue -InputObject $Plan -Name 'AutomaticExecution' -Default $true)) { $errors.Add('Automatic execution must remain disabled.') }
    if ($null -ne (Get-FreshWinPropertyValue -InputObject $Plan -Name 'ResetCommand')) { $errors.Add('A reset command must not be stored in the plan.') }
    $items = @((Get-FreshWinPropertyValue -InputObject $Plan -Name 'Items' -Default @()))
    $blockers = @($items | Where-Object { [bool]$_.Required -and [string]$_.Status -ne 'Confirmed' })
    if ($items.Count -eq 0) { $errors.Add('The pre-reset checklist is empty.') }

    return [pscustomobject][ordered]@{
        Component       = 'PreResetPlanValidation'
        Valid           = $errors.Count -eq 0
        Ready           = $errors.Count -eq 0 -and $blockers.Count -eq 0
        ConfirmedCount  = @($items | Where-Object { $_.Status -eq 'Confirmed' }).Count
        BlockerCount    = $blockers.Count
        Blockers        = @($blockers | ForEach-Object { $_.Id })
        Errors          = $errors.ToArray()
        ResetExecutionAllowed = $false
    }
}
