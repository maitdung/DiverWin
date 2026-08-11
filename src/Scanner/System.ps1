function Get-FreshWinWindowsFamily {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Caption,

        [AllowNull()]
        [object]$BuildNumber
    )

    $build = 0
    [void][int]::TryParse([string]$BuildNumber, [ref]$build)
    if ($Caption -match '(?i)Windows\s*11' -or $build -ge 22000) { return 'Windows11' }
    if ($Caption -match '(?i)Windows\s*10' -or $build -ge 10240) { return 'Windows10' }
    if ($Caption -match '(?i)Windows') { return 'Windows' }
    return 'Unknown'
}

function Get-FreshWinWslAvailability {
    [CmdletBinding()]
    param(
        [scriptblock]$StatusProvider,
        [scriptblock]$ProcessInvoker
    )

    if ($null -ne $StatusProvider) {
        $providedState = & $StatusProvider
        if ($providedState -is [bool]) { return [bool]$providedState }
        return $null
    }
    if (-not (Test-FreshWinWindows)) { return $null }
    try {
        $systemDirectory = [Environment]::SystemDirectory
        if ([string]::IsNullOrWhiteSpace($systemDirectory)) { return $null }
        $wslPath = [IO.Path]::Combine($systemDirectory, 'wsl.exe')
        if (-not [IO.File]::Exists($wslPath)) { return $false }
        $item = Get-Item -LiteralPath $wslPath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
        $processParameters = @{
            FilePath = $wslPath
            ArgumentList = @('--status')
            TimeoutSeconds = 15
            # Exit 50 is the real-host outcome when this optional capability is
            # absent. It is inventory evidence, not an unrelated install error.
            ExpectedExitCodes = @(0, 50)
            OutputEncoding = [System.Text.Encoding]::Unicode
            LogStage = 'PROVIDER'
            LogAction = 'WslStatus'
        }
        $result = if ($null -ne $ProcessInvoker) { & $ProcessInvoker $processParameters } else { Invoke-FreshWinProcess @processParameters }
        if ([bool]$result.TimedOut) { return $null }
        if ($null -eq $result.ExitCode) { return $null }
        if ([int]$result.ExitCode -eq 50) { return $false }
        return [int]$result.ExitCode -eq 0
    }
    catch { return $null }
}

function Get-FreshWinMicrosoftStoreAvailability {
    [CmdletBinding()]
    param([scriptblock]$PackageProvider)

    if ($null -ne $PackageProvider) {
        try {
            $packages = @(& $PackageProvider 'Microsoft.WindowsStore')
            if ($packages.Count -eq 1 -and $null -eq $packages[0]) { return $null }
            return $packages.Count -gt 0
        }
        catch { return $null }
    }
    if (-not (Test-FreshWinWindows)) { return $null }
    try {
        $command = Get-Command -Name Get-AppxPackage -CommandType Cmdlet -ErrorAction Stop | Select-Object -First 1
        $packages = @(& $command -Name 'Microsoft.WindowsStore' -ErrorAction Stop)
        return $packages.Count -gt 0
    }
    catch { return $null }
}

function Get-FreshWinSystemInfo {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$OperatingSystem,

        [AllowNull()]
        [object]$ComputerSystem,

        [AllowNull()]
        [object[]]$Processors,

        [AllowNull()]
        [object[]]$VideoControllers,

        [AllowNull()]
        [object[]]$DiskDrives,

        [AllowNull()]
        [object]$NetworkState,

        [AllowNull()]
        [object]$HardwareInfo,

        [AllowNull()]
        [object]$WslAvailable,

        [AllowNull()]
        [object]$MicrosoftStoreAvailable,

        [scriptblock]$WslStatusProvider,

        [scriptblock]$StorePackageProvider
    )

    $provided = $PSBoundParameters.ContainsKey('OperatingSystem') -or
        $PSBoundParameters.ContainsKey('ComputerSystem') -or
        $PSBoundParameters.ContainsKey('Processors') -or
        $PSBoundParameters.ContainsKey('VideoControllers') -or
        $PSBoundParameters.ContainsKey('DiskDrives') -or
        $PSBoundParameters.ContainsKey('HardwareInfo')
    $onWindows = Test-FreshWinWindows

    if (-not $onWindows -and -not $provided) {
        $unsupported = New-FreshWinUnsupportedResult -Component 'SystemScanner'
        $unsupported | Add-Member -NotePropertyName OSFamily -NotePropertyValue 'Unsupported'
        $unsupported | Add-Member -NotePropertyName BuildNumber -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName Architecture -NotePropertyValue (ConvertTo-FreshWinArchitecture -Architecture $env:PROCESSOR_ARCHITECTURE)
        $unsupported | Add-Member -NotePropertyName MemoryGB -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName GPUs -NotePropertyValue @()
        $unsupported | Add-Member -NotePropertyName Manufacturer -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName Model -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName VirtualizationEnabled -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName InternetAvailable -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName WslAvailable -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName MicrosoftStoreAvailable -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName Admin -NotePropertyValue $false
        return $unsupported
    }

    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $provided) {
        try { $OperatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { $errors.Add($_.Exception.Message) }
        try { $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { $errors.Add($_.Exception.Message) }
    }

    if ($null -eq $HardwareInfo) {
        if ($onWindows -and -not $provided) {
            # A live System scan delegates the complete hardware observation to
            # Hardware.ps1 so TPM, firmware, Secure Boot, enclosure, CPU, GPU,
            # and storage probes remain live. Passing partial CIM values would
            # incorrectly switch that scanner into fixture mode.
            $HardwareInfo = Get-FreshWinHardwareInfo
        }
        else {
            $hardwareParameters = @{
                ComputerSystem   = $ComputerSystem
                Processors       = @($Processors)
                VideoControllers = @($VideoControllers)
                DiskDrives       = @($DiskDrives)
            }
            $HardwareInfo = Get-FreshWinHardwareInfo @hardwareParameters
        }
    }

    if ($null -eq $NetworkState -and $onWindows -and -not $provided) {
        try { $NetworkState = Get-FreshWinNetworkState } catch { $errors.Add($_.Exception.Message) }
    }

    $caption = [string](Get-FreshWinObjectProperty -InputObject $OperatingSystem -Name @('Caption', 'Name') -Default 'Windows')
    $buildNumber = Get-FreshWinObjectProperty -InputObject $OperatingSystem -Name @('BuildNumber', 'Build')
    $architectureRaw = Get-FreshWinObjectProperty -InputObject $OperatingSystem -Name @('OSArchitecture') -Default $env:PROCESSOR_ARCHITECTURE
    $memoryGB = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('MemoryGB')
    if ($null -eq $memoryGB) {
        $visibleMemoryKB = Get-FreshWinObjectProperty -InputObject $OperatingSystem -Name @('TotalVisibleMemorySize')
        if ($null -ne $visibleMemoryKB) {
            try { $memoryGB = [Math]::Round(([double]$visibleMemoryKB / 1MB), 1) } catch { $memoryGB = $null }
        }
    }

    $status = 'Ready'
    if ($provided) { $status = 'Fixture' }
    elseif ($errors.Count -gt 0) { $status = 'Partial' }
    $osFamily = Get-FreshWinWindowsFamily -Caption $caption -BuildNumber $buildNumber
    $supportNotice = if ($osFamily -eq 'Windows10') {
        'Windows 10 may be outside normal support depending on edition and support program. Verify the applicable Microsoft lifecycle; FreshWin does not bypass Windows 11 requirements.'
    } else { $null }
    $wslState = if ($PSBoundParameters.ContainsKey('WslAvailable')) {
        if ($WslAvailable -is [bool]) { [bool]$WslAvailable } else { $null }
    } elseif ($null -ne $WslStatusProvider -or ($onWindows -and -not $provided)) {
        Get-FreshWinWslAvailability -StatusProvider $WslStatusProvider
    } else { $null }
    $storeState = if ($PSBoundParameters.ContainsKey('MicrosoftStoreAvailable')) {
        if ($MicrosoftStoreAvailable -is [bool]) { [bool]$MicrosoftStoreAvailable } else { $null }
    } elseif ($null -ne $StorePackageProvider -or ($onWindows -and -not $provided)) {
        Get-FreshWinMicrosoftStoreAvailability -PackageProvider $StorePackageProvider
    } else { $null }

    return [pscustomobject][ordered]@{
        Component             = 'SystemScanner'
        IsSupported           = $onWindows
        Supported             = $onWindows
        IsLive                = ($onWindows -and -not $provided)
        Status                = $status
        Platform              = Get-FreshWinPlatformName
        DataSource            = $(if ($provided) { 'Provided' } else { 'CIM' })
        OSFamily              = $osFamily
        SupportNotice         = $supportNotice
        OSName                = $caption
        Edition               = Get-FreshWinObjectProperty -InputObject $OperatingSystem -Name @('OperatingSystemSKU', 'EditionID')
        Version               = Get-FreshWinObjectProperty -InputObject $OperatingSystem -Name @('Version')
        BuildNumber           = $buildNumber
        Architecture          = ConvertTo-FreshWinArchitecture -Architecture ([string]$architectureRaw)
        CPU                   = $(if (@($HardwareInfo.CPUs).Count -gt 0) { $HardwareInfo.CPUs[0].Name } else { $null })
        CPUs                  = @($HardwareInfo.CPUs)
        MemoryGB              = $memoryGB
        GPUs                  = @($HardwareInfo.GPUs)
        Storage               = @($HardwareInfo.Storage)
        Manufacturer          = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('Manufacturer') -Default (Get-FreshWinObjectProperty -InputObject $ComputerSystem -Name @('Manufacturer'))
        Model                 = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('Model') -Default (Get-FreshWinObjectProperty -InputObject $ComputerSystem -Name @('Model'))
        FormFactor            = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('FormFactor') -Default 'Unknown'
        VirtualizationEnabled = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('VirtualizationEnabled')
        HypervisorPresent     = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('HypervisorPresent')
        Tpm                   = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('Tpm')
        FirmwareType          = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('FirmwareType') -Default 'Unknown'
        SecureBootEnabled     = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('SecureBootEnabled')
        InternetAvailable     = Get-FreshWinObjectProperty -InputObject $NetworkState -Name @('InternetAvailable')
        WslAvailable          = $wslState
        MicrosoftStoreAvailable = $storeState
        Network               = $NetworkState
        Admin                 = $(if ($onWindows) { Test-FreshWinAdministrator } else { $false })
        Errors                = $errors.ToArray()
    }
}
