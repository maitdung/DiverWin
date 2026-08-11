Set-StrictMode -Version Latest

function ConvertTo-FreshWinDriverProfileRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Driver)

    return [pscustomobject][ordered]@{
        Name           = [string](Get-FreshWinPropertyValue -InputObject $Driver -Name 'Name' -Default 'Unknown device')
        Category       = [string](Get-FreshWinPropertyValue -InputObject $Driver -Name 'Category' -Default 'Other')
        PnpClass       = Get-FreshWinPropertyValue -InputObject $Driver -Name 'PnpClass'
        HardwareIds    = @((Get-FreshWinPropertyValue -InputObject $Driver -Name 'HardwareIds' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        DriverVersion  = Get-FreshWinPropertyValue -InputObject $Driver -Name 'DriverVersion'
        DriverDate     = Get-FreshWinPropertyValue -InputObject $Driver -Name 'DriverDate'
        DriverProvider = Get-FreshWinPropertyValue -InputObject $Driver -Name 'DriverProvider'
        InfName        = Get-FreshWinPropertyValue -InputObject $Driver -Name 'InfName'
        IsSigned       = Get-FreshWinPropertyValue -InputObject $Driver -Name 'IsSigned'
    }
}

function Get-FreshWinBackupRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$fullPath' is outside backup root '$fullRoot'."
    }
    return $fullPath.Substring($prefix.Length).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
}

function Complete-FreshWinDriverBackupOutputAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [switch]$ProtectedStaging,
        [switch]$WithholdAccess
    )

    if (-not $ProtectedStaging) {
        return [pscustomobject]@{ Succeeded = $true; UserAccessGranted = $false; AccessGrantWithheld = $false; Error = $null }
    }
    if ($WithholdAccess) {
        return [pscustomobject]@{ Succeeded = $true; UserAccessGranted = $false; AccessGrantWithheld = $true; Error = $null }
    }
    try {
        [void](Grant-FreshWinProtectedOperationDirectoryAccess -Path $BackupPath)
        return [pscustomobject]@{ Succeeded = $true; UserAccessGranted = $true; AccessGrantWithheld = $false; Error = $null }
    }
    catch {
        return [pscustomobject]@{
            Succeeded = $false
            UserAccessGranted = $false
            AccessGrantWithheld = $false
            Error = Protect-FreshWinSensitiveText -Text $_.Exception.Message
        }
    }
}

function New-FreshWinDriverBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputRoot,

        [AllowNull()][object]$HardwareReport,
        [AllowNull()][object[]]$DriverInventory,

        [AllowNull()]
        [scriptblock]$ProcessInvoker
    )

    $providerSupplied = $PSBoundParameters.ContainsKey('ProcessInvoker') -and $null -ne $ProcessInvoker
    $windowsHost = Test-FreshWinOperationsWindows
    $protectedStaging = $windowsHost -and -not $providerSupplied
    if (-not $windowsHost -and -not $providerSupplied) {
        $unsupported = New-FreshWinOperationUnsupportedResult -Component 'DriverBackup'
        $unsupported | Add-Member -NotePropertyName BackupPath -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName WindowsExecutionVerified -NotePropertyValue $false
        return $unsupported
    }

    $requestedRoot = Assert-FreshWinSafeOutputRoot -Path $OutputRoot
    $root = if ($protectedStaging) { Get-FreshWinProtectedDriverBackupRoot } else { $requestedRoot }
    if (-not $PSCmdlet.ShouldProcess($root, 'Export installed third-party drivers into a new contained backup directory')) {
        return [pscustomobject][ordered]@{
            Component                = 'DriverBackup'
            Status                   = 'Preview'
            Succeeded                = $false
            IsSupported              = $windowsHost
            PlatformSupported        = $windowsHost
            IsLive                   = $false
            WindowsExecutionVerified = $false
            BackupPath               = $null
            OutputRoot               = $root
            RequestedOutputRoot      = $requestedRoot
            OutputRedirected         = $protectedStaging
            ProtectedStaging         = $protectedStaging
            UserAccessGranted        = $false
            PlannedArguments         = @('/export-driver', '*', '<new-backup>/DriverPackages')
            RequiresAdministrator    = $true
            Errors                   = @()
        }
    }

    $backupPath = $null
    $driverPackagePath = $null
    try {
        if ($protectedStaging) {
            $root = Initialize-FreshWinProtectedDriverBackupRoot
            $backupPath = New-FreshWinProtectedOperationOutputDirectory -OutputRoot $root -Prefix 'FreshWin-Drivers'
        }
        else {
            $backupPath = New-FreshWinContainedOutputDirectory -OutputRoot $root -Prefix 'FreshWin-Drivers'
        }
        $driverPackagePath = Join-Path $backupPath 'DriverPackages'
        [void][System.IO.Directory]::CreateDirectory($driverPackagePath)
        if ($protectedStaging) { [void](Assert-FreshWinProtectedOperationTree -Path $backupPath) }
    }
    catch {
        return [pscustomobject][ordered]@{
            Component                = 'DriverBackup'
            Status                   = $(if ($protectedStaging) { 'OutputProtectionFailed' } else { 'OutputPreparationFailed' })
            Succeeded                = $false
            IsSupported              = $windowsHost
            PlatformSupported        = $windowsHost
            IsLive                   = $false
            WindowsExecutionVerified = $false
            BackupPath               = $backupPath
            DriverPackagePath        = $driverPackagePath
            OutputRoot               = $root
            RequestedOutputRoot      = $requestedRoot
            OutputRedirected         = $protectedStaging
            ProtectedStaging         = $protectedStaging
            UserAccessGranted        = $false
            RequiresAdministrator    = $true
            Errors                   = @((Protect-FreshWinSensitiveText -Text $_.Exception.Message))
        }
    }
    $arguments = @('/export-driver', '*', $driverPackagePath)
    $processResult = $null

    try {
        if ($providerSupplied) {
            $processResult = & $ProcessInvoker ([pscustomobject][ordered]@{
                    FilePath       = $(if ($windowsHost) { Resolve-FreshWinTrustedWindowsExecutable -Name 'pnputil.exe' } else { 'pnputil.exe' })
                    ArgumentList   = $arguments
                    WorkingDirectory = $backupPath
                    IsFixture      = (-not $windowsHost)
                })
        }
        else {
            $pnputil = Resolve-FreshWinTrustedWindowsExecutable -Name 'pnputil.exe'
            $processResult = Invoke-FreshWinProcess -FilePath $pnputil -ArgumentList $arguments `
                -WorkingDirectory $backupPath -TimeoutSeconds 1800 -ExpectedExitCodes @(0) -LogStage 'DRIVER_BACKUP' -LogAction 'Export drivers'
        }
        if ($protectedStaging) { [void](Assert-FreshWinProtectedOperationTree -Path $backupPath) }
    }
    catch {
        $access = Complete-FreshWinDriverBackupOutputAccess -BackupPath $backupPath -ProtectedStaging:$protectedStaging
        $exportErrors = New-Object System.Collections.Generic.List[string]
        $exportErrors.Add((Protect-FreshWinSensitiveText -Text $_.Exception.Message))
        if (-not $access.Succeeded) { $exportErrors.Add([string]$access.Error) }
        return [pscustomobject][ordered]@{
            Component                = 'DriverBackup'
            Status                   = 'ExportFailed'
            Succeeded                = $false
            IsSupported              = $windowsHost
            PlatformSupported        = $windowsHost
            IsLive                   = ($windowsHost -and -not $providerSupplied)
            WindowsExecutionVerified = $false
            BackupPath               = $backupPath
            DriverPackagePath        = $driverPackagePath
            OutputRoot               = $root
            RequestedOutputRoot      = $requestedRoot
            OutputRedirected         = $protectedStaging
            ProtectedStaging         = $protectedStaging
            UserAccessGranted        = $access.UserAccessGranted
            RequiresAdministrator    = $true
            Errors                   = $exportErrors.ToArray()
        }
    }

    $processSucceeded = $false
    $processTimedOut = $false
    if ($null -ne $processResult) {
        $processTimedOut = [bool](Get-FreshWinPropertyValue -InputObject $processResult -Name 'TimedOut' -Default $false)
        if (Test-FreshWinHasProperty -InputObject $processResult -Name 'Succeeded') {
            $processSucceeded = [bool](Get-FreshWinPropertyValue -InputObject $processResult -Name 'Succeeded')
        }
        elseif (Test-FreshWinHasProperty -InputObject $processResult -Name 'ExitCode') {
            $processSucceeded = [int](Get-FreshWinPropertyValue -InputObject $processResult -Name 'ExitCode' -Default -1) -eq 0
        }
    }

    $exportedInfFiles = @(Get-ChildItem -LiteralPath $driverPackagePath -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue)
    if (-not $processSucceeded -or $exportedInfFiles.Count -eq 0) {
        $failureReason = if (-not $processSucceeded) { 'PnPUtil did not report a successful export.' } else { 'PnPUtil reported success, but no exported INF file was found.' }
        # A timed-out native process may have descendants whose termination
        # cannot be proven by the portable runner. Keep staging protected.
        $access = Complete-FreshWinDriverBackupOutputAccess -BackupPath $backupPath `
            -ProtectedStaging:$protectedStaging -WithholdAccess:$processTimedOut
        $verificationErrors = New-Object System.Collections.Generic.List[string]
        $verificationErrors.Add($failureReason)
        if (-not $access.Succeeded) { $verificationErrors.Add([string]$access.Error) }
        return [pscustomobject][ordered]@{
            Component                = 'DriverBackup'
            Status                   = 'ExportVerificationFailed'
            Succeeded                = $false
            IsSupported              = $windowsHost
            PlatformSupported        = $windowsHost
            IsLive                   = ($windowsHost -and -not $providerSupplied)
            WindowsExecutionVerified = $false
            BackupPath               = $backupPath
            DriverPackagePath        = $driverPackagePath
            OutputRoot               = $root
            RequestedOutputRoot      = $requestedRoot
            OutputRedirected         = $protectedStaging
            ProtectedStaging         = $protectedStaging
            UserAccessGranted        = $access.UserAccessGranted
            AccessGrantWithheld      = $access.AccessGrantWithheld
            ExportedInfCount         = $exportedInfFiles.Count
            RequiresAdministrator    = $true
            Process                  = Protect-FreshWinSensitiveData -InputObject $processResult
            Errors                   = $verificationErrors.ToArray()
        }
    }

    try {
        if ($null -eq $HardwareReport) {
            $HardwareReport = Get-FreshWinHardwareInfo
        }
        if ($null -eq $DriverInventory) {
            $DriverInventory = @(Get-FreshWinDriverInventory -IncludeHardwareIds -IncludeHealthy)
        }

        $safeHardware = Protect-FreshWinPrivacyData -InputObject $HardwareReport
        $profileRecords = @($DriverInventory | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-FreshWinDriverProfileRecord -Driver $_ })
        $driverProfile = [pscustomobject][ordered]@{
            SchemaVersion = 'FreshWin.DriverProfile/1'
            CreatedAtUtc  = [DateTimeOffset]::UtcNow.ToString('o')
            Devices       = @($profileRecords)
        }
        $driverProfile = Protect-FreshWinPrivacyData -InputObject $driverProfile -PreserveHardwareIds

        $hardwareReportPath = Join-Path $backupPath 'hardware-report.json'
        $driverProfilePath = Join-Path $backupPath 'driver-profile.json'
        [void](Write-FreshWinJsonFile -Path $hardwareReportPath -Value $safeHardware -Depth 30 -Atomic)
        [void](Write-FreshWinJsonFile -Path $driverProfilePath -Value $driverProfile -Depth 30 -Atomic)

        $files = New-Object System.Collections.Generic.List[object]
        foreach ($file in @(Get-ChildItem -LiteralPath $backupPath -File -Recurse -ErrorAction Stop | Sort-Object FullName)) {
            if ($file.FullName -eq (Join-Path $backupPath 'backup-manifest.json')) { continue }
            $files.Add([pscustomobject][ordered]@{
                    Path   = Get-FreshWinBackupRelativePath -Root $backupPath -Path $file.FullName
                    Length = [long]$file.Length
                    Sha256 = Get-FreshWinOperationFileSha256 -Path $file.FullName
                })
        }
        $manifest = [pscustomobject][ordered]@{
            SchemaVersion       = 'FreshWin.DriverBackup/1'
            FreshWinVersion     = $(if ($null -ne (Get-Command -Name Get-FreshWinVersion -ErrorAction SilentlyContinue)) { Get-FreshWinVersion } else { $null })
            CreatedAtUtc        = [DateTimeOffset]::UtcNow.ToString('o')
            DataSource          = $(if ($windowsHost -and -not $providerSupplied) { 'WindowsPnPUtil' } else { 'ExplicitProviderFixture' })
            WindowsExecutionVerified = ($windowsHost -and -not $providerSupplied)
            DriverPackagesPath  = 'DriverPackages'
            HardwareReportPath  = 'hardware-report.json'
            DriverProfilePath   = 'driver-profile.json'
            ExportedInfCount    = $exportedInfFiles.Count
            Files               = $files.ToArray()
        }
        $manifestPath = Join-Path $backupPath 'backup-manifest.json'
        [void](Write-FreshWinJsonFile -Path $manifestPath -Value $manifest -Depth 30 -Atomic)

        if ($protectedStaging) { [void](Assert-FreshWinProtectedOperationTree -Path $backupPath) }
        $access = Complete-FreshWinDriverBackupOutputAccess -BackupPath $backupPath -ProtectedStaging:$protectedStaging
        if (-not $access.Succeeded) {
            return [pscustomobject][ordered]@{
                Component                = 'DriverBackup'
                Status                   = 'OutputAccessGrantFailed'
                Succeeded                = $false
                IsSupported              = $windowsHost
                PlatformSupported        = $windowsHost
                IsLive                   = $protectedStaging
                WindowsExecutionVerified = $false
                BackupPath               = $backupPath
                DriverPackagePath        = $driverPackagePath
                ManifestPath             = $manifestPath
                HardwareReportPath       = $hardwareReportPath
                DriverProfilePath        = $driverProfilePath
                OutputRoot               = $root
                RequestedOutputRoot      = $requestedRoot
                OutputRedirected         = $protectedStaging
                ProtectedStaging         = $protectedStaging
                UserAccessGranted        = $false
                ExportedInfCount         = $exportedInfFiles.Count
                RequiresAdministrator    = $true
                Process                  = Protect-FreshWinSensitiveData -InputObject $processResult
                Errors                   = @([string]$access.Error)
            }
        }

        return [pscustomobject][ordered]@{
            Component                = 'DriverBackup'
            Status                   = $(if ($windowsHost -and -not $providerSupplied) { 'Completed' } else { 'FixtureVerified' })
            Succeeded                = $true
            IsSupported              = $windowsHost
            PlatformSupported        = $windowsHost
            IsLive                   = ($windowsHost -and -not $providerSupplied)
            WindowsExecutionVerified = ($windowsHost -and -not $providerSupplied)
            BackupPath               = $backupPath
            DriverPackagePath        = $driverPackagePath
            ManifestPath             = $manifestPath
            HardwareReportPath       = $hardwareReportPath
            DriverProfilePath        = $driverProfilePath
            OutputRoot               = $root
            RequestedOutputRoot      = $requestedRoot
            OutputRedirected         = $protectedStaging
            ProtectedStaging         = $protectedStaging
            UserAccessGranted        = $access.UserAccessGranted
            ExportedInfCount         = $exportedInfFiles.Count
            RequiresAdministrator    = $true
            Process                  = Protect-FreshWinSensitiveData -InputObject $processResult
            Errors                   = @()
        }
    }
    catch {
        $access = Complete-FreshWinDriverBackupOutputAccess -BackupPath $backupPath -ProtectedStaging:$protectedStaging
        $reportErrors = New-Object System.Collections.Generic.List[string]
        $reportErrors.Add((Protect-FreshWinSensitiveText -Text $_.Exception.Message))
        if (-not $access.Succeeded) { $reportErrors.Add([string]$access.Error) }
        return [pscustomobject][ordered]@{
            Component                = 'DriverBackup'
            Status                   = 'ReportGenerationFailed'
            Succeeded                = $false
            IsSupported              = $windowsHost
            PlatformSupported        = $windowsHost
            IsLive                   = ($windowsHost -and -not $providerSupplied)
            WindowsExecutionVerified = $false
            BackupPath               = $backupPath
            DriverPackagePath        = $driverPackagePath
            OutputRoot               = $root
            RequestedOutputRoot      = $requestedRoot
            OutputRedirected         = $protectedStaging
            ProtectedStaging         = $protectedStaging
            UserAccessGranted        = $access.UserAccessGranted
            ExportedInfCount         = $exportedInfFiles.Count
            RequiresAdministrator    = $true
            Errors                   = $reportErrors.ToArray()
        }
    }
}

function Get-FreshWinDriverBackupInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupPath,

        [switch]$IncludeUnmanifested
    )

    $root = [System.IO.Path]::GetFullPath($BackupPath)
    if (-not [System.IO.Directory]::Exists($root)) {
        throw "Driver backup directory was not found: $root"
    }
    $manifestPath = Join-Path $root 'backup-manifest.json'
    if (-not [System.IO.File]::Exists($manifestPath)) {
        $infs = @()
        if ($IncludeUnmanifested) {
            $infs = @(Get-ChildItem -LiteralPath $root -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                    [pscustomobject]@{ Path = Get-FreshWinBackupRelativePath -Root $root -Path $_.FullName; FullPath = $_.FullName; Verified = $false }
                })
        }
        return [pscustomobject][ordered]@{
            Component      = 'DriverBackupInventory'
            Status         = 'Unmanifested'
            Valid          = $false
            IsRestorable   = $false
            BackupPath     = $root
            ManifestPath   = $null
            DriverProfile  = $null
            Packages       = @($infs)
            Errors         = @('backup-manifest.json is missing; unmanifested drivers are review-only.')
        }
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $packages = New-Object System.Collections.Generic.List[object]
    $manifest = $null
    try { $manifest = Read-FreshWinJsonFile -Path $manifestPath }
    catch { $errors.Add($_.Exception.Message) }

    if ($null -ne $manifest) {
        if ([string](Get-FreshWinPropertyValue -InputObject $manifest -Name 'SchemaVersion') -ne 'FreshWin.DriverBackup/1') {
            $errors.Add('The driver backup manifest schema is unsupported.')
        }
        $manifestFiles = @((Get-FreshWinPropertyValue -InputObject $manifest -Name 'Files' -Default @()))
        if ($manifestFiles.Count -eq 0) { $errors.Add('The driver backup manifest contains no files.') }
        foreach ($entry in $manifestFiles) {
            $relativePath = [string](Get-FreshWinPropertyValue -InputObject $entry -Name 'Path')
            if (-not (Test-FreshWinContainedRelativePath -Root $root -RelativePath $relativePath)) {
                $errors.Add("Manifest file path is unsafe: '$relativePath'.")
                continue
            }
            $fullPath = [System.IO.Path]::GetFullPath((Join-Path $root $relativePath))
            if (-not [System.IO.File]::Exists($fullPath)) {
                $errors.Add("Manifest file is missing: '$relativePath'.")
                continue
            }
            $attributes = [System.IO.File]::GetAttributes($fullPath)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $errors.Add("Manifest file is a reparse point: '$relativePath'.")
                continue
            }
            $expectedHash = [string](Get-FreshWinPropertyValue -InputObject $entry -Name 'Sha256')
            $actualHash = Get-FreshWinOperationFileSha256 -Path $fullPath
            $verified = $expectedHash -match '^[a-fA-F0-9]{64}$' -and [string]::Equals($expectedHash, $actualHash, [System.StringComparison]::OrdinalIgnoreCase)
            if (-not $verified) { $errors.Add("Manifest hash mismatch: '$relativePath'.") }
            if ([System.IO.Path]::GetExtension($fullPath) -ieq '.inf') {
                $packages.Add([pscustomobject][ordered]@{
                        Path     = $relativePath
                        FullPath = $fullPath
                        Sha256   = $actualHash
                        Verified = $verified
                    })
            }
        }
    }

    $driverProfile = $null
    if ($null -ne $manifest) {
        $profileRelative = [string](Get-FreshWinPropertyValue -InputObject $manifest -Name 'DriverProfilePath' -Default 'driver-profile.json')
        if (Test-FreshWinContainedRelativePath -Root $root -RelativePath $profileRelative) {
            $profileFull = [System.IO.Path]::GetFullPath((Join-Path $root $profileRelative))
            $profileManifestEntry = @((Get-FreshWinPropertyValue -InputObject $manifest -Name 'Files' -Default @()) | Where-Object { [string]$_.Path -eq $profileRelative })
            if ($profileManifestEntry.Count -eq 1 -and [System.IO.File]::Exists($profileFull)) {
                try { $driverProfile = Read-FreshWinJsonFile -Path $profileFull }
                catch { $errors.Add($_.Exception.Message) }
            }
            else { $errors.Add('The driver profile is not uniquely represented in the manifest.') }
        }
        else { $errors.Add('The driver profile path is unsafe.') }
    }

    if ($packages.Count -eq 0) { $errors.Add('No manifested INF driver package was found.') }
    $valid = $errors.Count -eq 0 -and $packages.Count -gt 0
    return [pscustomobject][ordered]@{
        Component      = 'DriverBackupInventory'
        Status         = $(if ($valid) { 'Verified' } else { 'Invalid' })
        Valid          = $valid
        IsRestorable   = $valid
        BackupPath     = $root
        ManifestPath   = $manifestPath
        Manifest       = $manifest
        DriverProfile  = $driverProfile
        Packages       = $packages.ToArray()
        Errors         = $errors.ToArray()
    }
}

function New-FreshWinDriverRestorePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
        [string]$BackupPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Inventory')]
        [object]$BackupInventory,

        [AllowNull()][object[]]$ProblemDevices
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $BackupInventory = Get-FreshWinDriverBackupInventory -BackupPath $BackupPath
    }
    else {
        # An inventory object is only a prior observation. Re-read the manifest and
        # hashes immediately before planning so a forged object or later file change
        # cannot become restore authority.
        $observedBackupPath = [string](Get-FreshWinPropertyValue -InputObject $BackupInventory -Name 'BackupPath')
        if (-not [string]::IsNullOrWhiteSpace($observedBackupPath) -and [System.IO.Directory]::Exists($observedBackupPath)) {
            $BackupInventory = Get-FreshWinDriverBackupInventory -BackupPath $observedBackupPath
        }
    }
    if (-not [bool](Get-FreshWinPropertyValue -InputObject $BackupInventory -Name 'IsRestorable' -Default $false)) {
        return [pscustomobject][ordered]@{
            Component              = 'DriverRestorePlan'
            Status                 = 'Blocked'
            Ready                  = $false
            ExecutionAllowed       = $false
            RequiresAdministrator  = $true
            Items                  = @()
            UnmatchedDevices       = @()
            Errors                 = @('The backup must pass manifest and hash validation before a restore plan can be created.')
        }
    }

    $provided = $PSBoundParameters.ContainsKey('ProblemDevices')
    if (-not $provided -and -not (Test-FreshWinOperationsWindows)) {
        $unsupported = New-FreshWinOperationUnsupportedResult -Component 'DriverRestorePlan' -Reason 'A problem-device fixture is required when planning off Windows.'
        $unsupported | Add-Member -NotePropertyName Ready -NotePropertyValue $false
        $unsupported | Add-Member -NotePropertyName ExecutionAllowed -NotePropertyValue $false
        $unsupported | Add-Member -NotePropertyName Items -NotePropertyValue @()
        return $unsupported
    }
    if (-not $provided) {
        $ProblemDevices = @(Get-FreshWinDriverInventory -IncludeHardwareIds -IncludeHealthy:$false)
    }

    $profile = Get-FreshWinPropertyValue -InputObject $BackupInventory -Name 'DriverProfile'
    $profileDevices = @((Get-FreshWinPropertyValue -InputObject $profile -Name 'Devices' -Default @()))
    $packages = @((Get-FreshWinPropertyValue -InputObject $BackupInventory -Name 'Packages' -Default @()))
    $items = New-Object System.Collections.Generic.List[object]
    $unmatched = New-Object System.Collections.Generic.List[object]

    foreach ($device in @($ProblemDevices)) {
        if ($null -eq $device) { continue }
        $hardwareIds = @((Get-FreshWinPropertyValue -InputObject $device -Name 'HardwareIds' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $matches = @($profileDevices | Where-Object {
                $candidateIds = @((Get-FreshWinPropertyValue -InputObject $_ -Name 'HardwareIds' -Default @()))
                $found = $false
                foreach ($hardwareId in $hardwareIds) {
                    foreach ($candidateId in $candidateIds) {
                        if ([string]::Equals([string]$hardwareId, [string]$candidateId, [System.StringComparison]::OrdinalIgnoreCase)) { $found = $true; break }
                    }
                    if ($found) { break }
                }
                $found
            })
        if ($matches.Count -eq 0) {
            $unmatched.Add([pscustomobject]@{
                    Name = Get-FreshWinPropertyValue -InputObject $device -Name 'Name' -Default 'Unknown device'
                    HardwareIds = @($hardwareIds)
                    Reason = 'No exact hardware-ID match exists in the verified backup profile.'
                })
            continue
        }

        foreach ($match in $matches) {
            $infName = [string](Get-FreshWinPropertyValue -InputObject $match -Name 'InfName')
            $matchingPackages = @($packages | Where-Object {
                    [System.IO.Path]::GetFileName([string]$_.Path) -ieq $infName -or
                    [string]$_.Path -match ('(?i)(^|/)' + [regex]::Escape($infName) + '$')
                })
            if ($matchingPackages.Count -eq 0 -and $null -ne (Get-Command -Name Get-FreshWinInfDriverMetadata -ErrorAction SilentlyContinue)) {
                # Windows inventory often reports a published oem*.inf name while
                # PnPUtil exports the original filename.  In that case, require the
                # exported INF itself to declare an exact matching hardware ID.
                $matchingPackages = @($packages | Where-Object {
                        try {
                            $metadata = Get-FreshWinInfDriverMetadata -Path $_.FullPath -HardwareIds $hardwareIds
                            $metadata.MatchType -eq 'Exact'
                        }
                        catch { $false }
                    })
            }
            foreach ($package in $matchingPackages) {
                $items.Add([pscustomobject][ordered]@{
                        DeviceName            = Get-FreshWinPropertyValue -InputObject $device -Name 'Name' -Default 'Unknown device'
                        HardwareIds           = @($hardwareIds)
                        ProfileDeviceName     = Get-FreshWinPropertyValue -InputObject $match -Name 'Name'
                        InfPath               = $package.FullPath
                        InfSha256             = $package.Sha256
                        MatchType             = 'ExactHardwareId'
                        Action                = 'ReviewAndInstallVerifiedDriver'
                        Executable            = 'pnputil.exe'
                        ArgumentList          = @('/add-driver', $package.FullPath, '/install')
                        RequiresAdministrator = $true
                        AutomaticExecution    = $false
                        VerificationRequired  = $true
                    })
            }
        }
    }

    return [pscustomobject][ordered]@{
        Component             = 'DriverRestorePlan'
        Status                = $(if ($items.Count -gt 0) { 'ReviewRequired' } else { 'NoMatch' })
        Ready                 = ($items.Count -gt 0)
        ExecutionAllowed      = $false
        RequiresAdministrator = $true
        Items                 = $items.ToArray()
        UnmatchedDevices      = $unmatched.ToArray()
        Errors                = @()
        SafetyNote            = 'FreshWin creates a review plan only. Driver installation requires explicit elevation, confirmation, and post-install device verification.'
    }
}
