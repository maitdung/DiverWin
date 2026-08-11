function Resolve-FreshWinGpuVendor {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Name,

        [AllowNull()]
        [string]$PnpDeviceId,

        [AllowNull()]
        [string]$AdapterCompatibility
    )

    $identity = @($Name, $PnpDeviceId, $AdapterCompatibility) -join ' '
    if ($identity -match '(?i)(VEN_10DE|NVIDIA)') { return 'NVIDIA' }
    if ($identity -match '(?i)(VEN_1002|VEN_1022|AMD|ATI|Advanced Micro Devices)') { return 'AMD' }
    if ($identity -match '(?i)(VEN_8086|Intel)') { return 'Intel' }
    if ([string]::IsNullOrWhiteSpace($identity)) { return 'Unknown' }
    return 'Other'
}

function ConvertTo-FreshWinGpuRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VideoController
    )

    $name = [string](Get-FreshWinObjectProperty -InputObject $VideoController -Name @('Name', 'Caption') -Default 'Unknown GPU')
    $deviceId = [string](Get-FreshWinObjectProperty -InputObject $VideoController -Name @('PNPDeviceID', 'InstanceId', 'DeviceId'))
    $compatibility = [string](Get-FreshWinObjectProperty -InputObject $VideoController -Name @('AdapterCompatibility', 'Manufacturer'))
    $memoryBytes = Get-FreshWinObjectProperty -InputObject $VideoController -Name @('AdapterRAM')
    $memoryGB = $null
    if ($null -ne $memoryBytes) {
        try { $memoryGB = [Math]::Round(([double]$memoryBytes / 1GB), 2) } catch { $memoryGB = $null }
    }

    return [pscustomobject][ordered]@{
        Name                 = $name
        Vendor               = Resolve-FreshWinGpuVendor -Name $name -PnpDeviceId $deviceId -AdapterCompatibility $compatibility
        PnpDeviceId          = $deviceId
        AdapterCompatibility = $compatibility
        DriverVersion        = Get-FreshWinObjectProperty -InputObject $VideoController -Name @('DriverVersion')
        DriverDate           = Get-FreshWinObjectProperty -InputObject $VideoController -Name @('DriverDate')
        MemoryGB             = $memoryGB
        Status               = [string](Get-FreshWinObjectProperty -InputObject $VideoController -Name @('Status') -Default 'Unknown')
    }
}

function Get-FreshWinHardwareInfo {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ComputerSystem,

        [AllowNull()]
        [object[]]$Processors,

        [AllowNull()]
        [object[]]$VideoControllers,

        [AllowNull()]
        [object[]]$DiskDrives,

        [AllowNull()]
        [object[]]$Enclosures,

        [AllowNull()]
        [object]$Tpm,

        [AllowNull()]
        [string]$TpmSpecVersion,

        [AllowNull()]
        [Nullable[bool]]$SecureBootEnabled,

        [ValidateSet('UEFI', 'BIOS', 'Unknown')]
        [string]$FirmwareType = 'Unknown'
    )

    $provided = $PSBoundParameters.ContainsKey('ComputerSystem') -or
        $PSBoundParameters.ContainsKey('Processors') -or
        $PSBoundParameters.ContainsKey('VideoControllers') -or
        $PSBoundParameters.ContainsKey('DiskDrives') -or
        $PSBoundParameters.ContainsKey('Enclosures') -or
        $PSBoundParameters.ContainsKey('Tpm') -or
        $PSBoundParameters.ContainsKey('TpmSpecVersion') -or
        $PSBoundParameters.ContainsKey('SecureBootEnabled')
    $onWindows = Test-FreshWinWindows

    if (-not $onWindows -and -not $provided) {
        $unsupported = New-FreshWinUnsupportedResult -Component 'HardwareScanner'
        $unsupported | Add-Member -NotePropertyName CPUs -NotePropertyValue @()
        $unsupported | Add-Member -NotePropertyName GPUs -NotePropertyValue @()
        $unsupported | Add-Member -NotePropertyName Storage -NotePropertyValue @()
        return $unsupported
    }

    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $provided) {
        try { $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { $errors.Add($_.Exception.Message) }
        try { $Processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop) } catch { $errors.Add($_.Exception.Message); $Processors = @() }
        try { $VideoControllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop) } catch { $errors.Add($_.Exception.Message); $VideoControllers = @() }
        try { $DiskDrives = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop) } catch { $errors.Add($_.Exception.Message); $DiskDrives = @() }
        try { $Enclosures = @(Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop) } catch { $Enclosures = @() }

        $getTpmCommand = Get-Command -Name Get-Tpm -ErrorAction SilentlyContinue
        if ($null -ne $getTpmCommand) {
            try { $Tpm = Get-Tpm -ErrorAction Stop } catch { $errors.Add($_.Exception.Message) }
        }
        try {
            $tpmCim = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop |
                Select-Object -First 1
            if ($null -ne $tpmCim) {
                $reportedSpecVersion = Get-FreshWinObjectProperty -InputObject $tpmCim -Name @('SpecVersion')
                if (-not [string]::IsNullOrWhiteSpace([string]$reportedSpecVersion)) {
                    $TpmSpecVersion = [string]$reportedSpecVersion
                }
            }
        }
        catch {
            # TPM presence can still be reported by Get-Tpm.  A missing CIM
            # spec version remains Unknown instead of being guessed.
        }

        try {
            $SecureBootEnabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
            $FirmwareType = 'UEFI'
        }
        catch {
            try {
                $firmwareValue = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction Stop
                if ([int]$firmwareValue -eq 2) { $FirmwareType = 'UEFI' }
                elseif ([int]$firmwareValue -eq 1) { $FirmwareType = 'BIOS' }
            }
            catch { }
        }
    }

    $cpuRecords = @()
    foreach ($processor in @($Processors)) {
        if ($null -eq $processor) { continue }
        $cpuRecords += [pscustomobject][ordered]@{
            Name                          = [string](Get-FreshWinObjectProperty -InputObject $processor -Name @('Name') -Default 'Unknown CPU')
            Manufacturer                  = Get-FreshWinObjectProperty -InputObject $processor -Name @('Manufacturer')
            Cores                         = Get-FreshWinObjectProperty -InputObject $processor -Name @('NumberOfCores')
            LogicalProcessors             = Get-FreshWinObjectProperty -InputObject $processor -Name @('NumberOfLogicalProcessors')
            MaxClockMHz                   = Get-FreshWinObjectProperty -InputObject $processor -Name @('MaxClockSpeed')
            Architecture                  = Get-FreshWinObjectProperty -InputObject $processor -Name @('Architecture')
            VirtualizationFirmwareEnabled = Get-FreshWinObjectProperty -InputObject $processor -Name @('VirtualizationFirmwareEnabled')
            SecondLevelAddressTranslation = Get-FreshWinObjectProperty -InputObject $processor -Name @('SecondLevelAddressTranslationExtensions')
        }
    }

    $gpuRecords = @()
    foreach ($videoController in @($VideoControllers)) {
        if ($null -ne $videoController) { $gpuRecords += ConvertTo-FreshWinGpuRecord -VideoController $videoController }
    }

    $storageRecords = @()
    foreach ($disk in @($DiskDrives)) {
        if ($null -eq $disk) { continue }
        $sizeGB = $null
        $size = Get-FreshWinObjectProperty -InputObject $disk -Name @('Size')
        if ($null -ne $size) {
            try { $sizeGB = [Math]::Round(([double]$size / 1GB), 1) } catch { $sizeGB = $null }
        }
        $storageRecords += [pscustomobject][ordered]@{
            Model         = [string](Get-FreshWinObjectProperty -InputObject $disk -Name @('Model', 'Caption') -Default 'Unknown storage')
            DeviceId      = Get-FreshWinObjectProperty -InputObject $disk -Name @('DeviceID', 'Index')
            SizeGB        = $sizeGB
            InterfaceType = Get-FreshWinObjectProperty -InputObject $disk -Name @('InterfaceType')
            MediaType     = Get-FreshWinObjectProperty -InputObject $disk -Name @('MediaType')
            Status        = Get-FreshWinObjectProperty -InputObject $disk -Name @('Status') -Default 'Unknown'
        }
    }

    $memoryGB = $null
    $memoryBytes = Get-FreshWinObjectProperty -InputObject $ComputerSystem -Name @('TotalPhysicalMemory')
    if ($null -ne $memoryBytes) {
        try { $memoryGB = [Math]::Round(([double]$memoryBytes / 1GB), 1) } catch { $memoryGB = $null }
    }

    $pcSystemType = Get-FreshWinObjectProperty -InputObject $ComputerSystem -Name @('PCSystemType')
    $chassisTypes = @()
    foreach ($enclosure in @($Enclosures)) {
        $chassisTypes += @(Get-FreshWinObjectProperty -InputObject $enclosure -Name @('ChassisTypes') -Default @())
    }
    $formFactor = 'Unknown'
    if ($pcSystemType -eq 2 -or @($chassisTypes | Where-Object { $_ -in @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32) }).Count -gt 0) {
        $formFactor = 'Laptop'
    }
    elseif ($pcSystemType -in @(1, 3, 4, 5, 6, 7) -or @($chassisTypes | Where-Object { $_ -in @(3, 4, 5, 6, 7, 15, 16, 24, 35, 36) }).Count -gt 0) {
        $formFactor = 'Desktop'
    }

    $virtualizationValues = @($cpuRecords | ForEach-Object { $_.VirtualizationFirmwareEnabled } | Where-Object { $null -ne $_ })
    $virtualizationEnabled = $null
    if ($virtualizationValues.Count -gt 0) {
        $virtualizationEnabled = @($virtualizationValues | Where-Object { [bool]$_ }).Count -gt 0
    }
    $hypervisorPresent = Get-FreshWinObjectProperty -InputObject $ComputerSystem -Name @('HypervisorPresent')
    if ($hypervisorPresent -eq $true) { $virtualizationEnabled = $true }

    $tpmPresent = Get-FreshWinObjectProperty -InputObject $Tpm -Name @('TpmPresent')
    $tpmReady = Get-FreshWinObjectProperty -InputObject $Tpm -Name @('TpmReady')
    if ([string]::IsNullOrWhiteSpace($TpmSpecVersion)) {
        $TpmSpecVersion = [string](Get-FreshWinObjectProperty -InputObject $Tpm -Name @('SpecVersion'))
    }
    $tpmManufacturerVersion = Get-FreshWinObjectProperty -InputObject $Tpm -Name @('ManufacturerVersion', 'ManufacturerVersionFull20')

    $status = 'Ready'
    if ($provided) { $status = 'Fixture' }
    elseif ($errors.Count -gt 0) { $status = 'Partial' }

    return [pscustomobject][ordered]@{
        Component             = 'HardwareScanner'
        IsSupported           = $onWindows
        Supported             = $onWindows
        IsLive                = ($onWindows -and -not $provided)
        Status                = $status
        Platform              = Get-FreshWinPlatformName
        DataSource            = $(if ($provided) { 'Provided' } else { 'CIM' })
        Manufacturer          = Get-FreshWinObjectProperty -InputObject $ComputerSystem -Name @('Manufacturer')
        Model                 = Get-FreshWinObjectProperty -InputObject $ComputerSystem -Name @('Model')
        FormFactor            = $formFactor
        MemoryGB              = $memoryGB
        CPUs                  = $cpuRecords
        GPUs                  = $gpuRecords
        Storage               = $storageRecords
        VirtualizationEnabled = $virtualizationEnabled
        HypervisorPresent     = $hypervisorPresent
        FirmwareType          = $FirmwareType
        SecureBootEnabled     = $(if ($PSBoundParameters.ContainsKey('SecureBootEnabled') -or $null -ne $SecureBootEnabled) { $SecureBootEnabled } else { $null })
        Tpm                   = [pscustomobject][ordered]@{
            Present     = $tpmPresent
            Ready       = $tpmReady
            SpecVersion = $(if ([string]::IsNullOrWhiteSpace($TpmSpecVersion)) { $null } else { $TpmSpecVersion })
            ManufacturerVersion = $tpmManufacturerVersion
        }
        Errors                = $errors.ToArray()
    }
}
