function Get-FreshWinDeviceCategory {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$PnpClass,
        [AllowNull()]
        [string]$Name,
        [AllowNull()]
        [string]$InstanceId
    )

    $identity = @($PnpClass, $Name, $InstanceId) -join ' '
    if ($identity -match '(?i)(Bluetooth|BTHENUM|BTHUSB)') { return 'Bluetooth' }
    if ($PnpClass -match '(?i)^(Display|Monitor)$' -or $identity -match '(?i)(NVIDIA|Radeon|Graphics|Display Adapter)') { return 'Graphics' }
    if ($PnpClass -match '(?i)^Net$' -or $identity -match '(?i)(Network|Ethernet|Wireless|Wi[ -]?Fi|WLAN|GbE)') {
        if ($identity -match '(?i)(Wireless|Wi[ -]?Fi|WLAN|802\.11)') { return 'Wi-Fi' }
        return 'Ethernet'
    }
    if ($PnpClass -match '(?i)^(MEDIA|AudioEndpoint|Sound)$' -or $identity -match '(?i)(Audio|Sound|Realtek.*Audio)') { return 'Audio' }
    if ($PnpClass -match '(?i)^(HDC|SCSIAdapter|DiskDrive|StorageVolume|Volume)$' -or $identity -match '(?i)(NVMe|SATA|Storage Controller|RAID)') { return 'Storage' }
    if ($PnpClass -match '(?i)^USB$' -or $identity -match '(?i)(^|\\)USB|USB Controller') { return 'USB' }
    if ($PnpClass -match '(?i)^(System|Processor|Firmware)$' -or $identity -match '(?i)(Chipset|SMBus|PCI Express Root)') { return 'Chipset' }
    if ([string]::IsNullOrWhiteSpace($PnpClass) -or $PnpClass -match '(?i)Unknown') { return 'Unknown Devices' }
    return 'Other'
}

function Get-FreshWinDeviceHealth {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ProblemCode,
        [AllowNull()]
        [string]$Status,
        [AllowNull()]
        [string]$DriverVersion
    )

    $code = $null
    if ($null -ne $ProblemCode) {
        $parsedCode = 0
        if ([int]::TryParse([string]$ProblemCode, [ref]$parsedCode)) { $code = $parsedCode }
    }
    if ($code -eq 0 -and $Status -match '(?i)^(OK|Started|Running|Unknown)?$') {
        return [pscustomobject]@{ Health = 'Healthy'; Badge = '[OK]'; Priority = 'Healthy'; Reason = 'Device reports no problem.' }
    }
    if ($code -eq 28) {
        return [pscustomobject]@{ Health = 'MissingDriver'; Badge = '[!!]'; Priority = 'Required'; Reason = 'Windows reports that no driver is installed (Code 28).' }
    }
    if ($code -eq 22) {
        return [pscustomobject]@{ Health = 'Disabled'; Badge = '[!!]'; Priority = 'Optional'; Reason = 'The device is disabled (Code 22); FreshWin will not enable it automatically.' }
    }
    if ($null -ne $code -and $code -ne 0) {
        return [pscustomobject]@{ Health = 'Problem'; Badge = '[!!]'; Priority = 'Required'; Reason = "Windows reports device problem code $code." }
    }
    if ($Status -match '(?i)(Error|Problem|Degraded|Unknown)') {
        return [pscustomobject]@{ Health = 'Unknown'; Badge = '[??]'; Priority = 'Recommended'; Reason = "Device state is '$Status' and needs review." }
    }
    if ([string]::IsNullOrWhiteSpace($Status)) {
        return [pscustomobject]@{ Health = 'Unknown'; Badge = '[??]'; Priority = 'Recommended'; Reason = 'Windows did not report device health.' }
    }
    if ([string]::IsNullOrWhiteSpace($DriverVersion)) {
        return [pscustomobject]@{ Health = 'Unknown'; Badge = '[??]'; Priority = 'Recommended'; Reason = 'A working state was reported, but driver metadata is unavailable.' }
    }
    return [pscustomobject]@{ Health = 'Healthy'; Badge = '[OK]'; Priority = 'Healthy'; Reason = 'Device reports no problem.' }
}

function ConvertTo-FreshWinDriverRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Device,
        [AllowNull()]
        [object]$SignedDriver,
        [AllowNull()]
        [object[]]$HardwareIds
    )

    $name = [string](Get-FreshWinObjectProperty -InputObject $Device -Name @('FriendlyName', 'Name', 'Caption') -Default 'Unknown device')
    $instanceId = [string](Get-FreshWinObjectProperty -InputObject $Device -Name @('InstanceId', 'PNPDeviceID', 'DeviceID'))
    $pnpClass = [string](Get-FreshWinObjectProperty -InputObject $Device -Name @('Class', 'PnpClass', 'PNPClass'))
    $status = [string](Get-FreshWinObjectProperty -InputObject $Device -Name @('Status') -Default 'Unknown')
    $problemCode = Get-FreshWinObjectProperty -InputObject $Device -Name @('ProblemCode', 'ConfigManagerErrorCode')
    $driverVersion = Get-FreshWinObjectProperty -InputObject $SignedDriver -Name @('DriverVersion') -Default (Get-FreshWinObjectProperty -InputObject $Device -Name @('DriverVersion'))
    $health = Get-FreshWinDeviceHealth -ProblemCode $problemCode -Status $status -DriverVersion ([string]$driverVersion)
    if ($null -eq $HardwareIds) { $HardwareIds = @((Get-FreshWinObjectProperty -InputObject $Device -Name @('HardwareIds', 'HardwareID') -Default @())) }

    return [pscustomobject][ordered]@{
        Name           = $name
        InstanceId     = $instanceId
        PnpClass       = $pnpClass
        Category       = Get-FreshWinDeviceCategory -PnpClass $pnpClass -Name $name -InstanceId $instanceId
        Status         = $status
        ProblemCode    = $problemCode
        Health         = $health.Health
        Badge          = $health.Badge
        Priority       = $health.Priority
        Reason         = $health.Reason
        HardwareIds    = @($HardwareIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        DriverVersion  = $driverVersion
        DriverDate     = Get-FreshWinObjectProperty -InputObject $SignedDriver -Name @('DriverDate') -Default (Get-FreshWinObjectProperty -InputObject $Device -Name @('DriverDate'))
        DriverProvider = Get-FreshWinObjectProperty -InputObject $SignedDriver -Name @('DriverProviderName', 'Manufacturer') -Default (Get-FreshWinObjectProperty -InputObject $Device -Name @('Manufacturer'))
        InfName        = Get-FreshWinObjectProperty -InputObject $SignedDriver -Name @('InfName')
        IsSigned       = Get-FreshWinObjectProperty -InputObject $SignedDriver -Name @('IsSigned')
        Manufacturer   = Get-FreshWinObjectProperty -InputObject $Device -Name @('Manufacturer')
    }
}

function Get-FreshWinDriverInventory {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Devices,
        [AllowNull()]
        [object[]]$SignedDrivers,
        [switch]$IncludeHardwareIds,
        [switch]$IncludeHealthy = $true
    )

    $provided = $PSBoundParameters.ContainsKey('Devices') -or $PSBoundParameters.ContainsKey('SignedDrivers')
    $onWindows = Test-FreshWinWindows
    if (-not $onWindows -and -not $provided) {
        $unsupported = New-FreshWinUnsupportedResult -Component 'DriverScanner'
        $unsupported | Add-Member -NotePropertyName Name -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName Category -NotePropertyValue 'Unsupported'
        $unsupported | Add-Member -NotePropertyName Health -NotePropertyValue 'Unsupported'
        $unsupported | Add-Member -NotePropertyName Priority -NotePropertyValue 'Unknown'
        return @($unsupported)
    }

    $scanErrors = New-Object System.Collections.Generic.List[string]

    if (-not $PSBoundParameters.ContainsKey('Devices')) {
        $pnpCommand = Get-Command -Name Get-PnpDevice -ErrorAction SilentlyContinue
        if ($null -ne $pnpCommand) {
            try { $Devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop) }
            catch {
                $scanErrors.Add("Get-PnpDevice failed: $($_.Exception.Message)")
                try { $Devices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop) }
                catch {
                    $scanErrors.Add("Win32_PnPEntity fallback failed: $($_.Exception.Message)")
                    $Devices = @()
                }
            }
        }
        else {
            try { $Devices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop) }
            catch {
                $scanErrors.Add("Win32_PnPEntity scan failed: $($_.Exception.Message)")
                $Devices = @()
            }
        }
    }
    if (-not $PSBoundParameters.ContainsKey('SignedDrivers')) {
        try { $SignedDrivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop) }
        catch {
            $scanErrors.Add("Win32_PnPSignedDriver scan failed: $($_.Exception.Message)")
            $SignedDrivers = @()
        }
    }

    $signedById = @{}
    foreach ($signedDriver in @($SignedDrivers)) {
        if ($null -eq $signedDriver) { continue }
        $deviceId = [string](Get-FreshWinObjectProperty -InputObject $signedDriver -Name @('DeviceID', 'DeviceId'))
        if (-not [string]::IsNullOrWhiteSpace($deviceId)) { $signedById[$deviceId] = $signedDriver }
    }

    $records = @()
    foreach ($device in @($Devices)) {
        if ($null -eq $device) { continue }
        $instanceId = [string](Get-FreshWinObjectProperty -InputObject $device -Name @('InstanceId', 'PNPDeviceID', 'DeviceID'))
        $signedDriver = $null
        if ($signedById.ContainsKey($instanceId)) { $signedDriver = $signedById[$instanceId] }
        $hardwareIds = @((Get-FreshWinObjectProperty -InputObject $device -Name @('HardwareIds', 'HardwareID') -Default @()))
        $problemCode = Get-FreshWinObjectProperty -InputObject $device -Name @('ProblemCode', 'ConfigManagerErrorCode')
        if ($onWindows -and ($IncludeHardwareIds -or ($null -ne $problemCode -and [int]$problemCode -ne 0)) -and $hardwareIds.Count -eq 0) {
            $propertyCommand = Get-Command -Name Get-PnpDeviceProperty -ErrorAction SilentlyContinue
            if ($null -ne $propertyCommand -and -not [string]::IsNullOrWhiteSpace($instanceId)) {
                try {
                    $property = Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop
                    $hardwareIds = @($property.Data)
                }
                catch { }
            }
        }
        $record = ConvertTo-FreshWinDriverRecord -Device $device -SignedDriver $signedDriver -HardwareIds $hardwareIds
        $record | Add-Member -NotePropertyName IsLive -NotePropertyValue ($onWindows -and -not $provided)
        $record | Add-Member -NotePropertyName PlatformSupported -NotePropertyValue $onWindows
        $record | Add-Member -NotePropertyName ScanErrors -NotePropertyValue $scanErrors.ToArray()
        if ($IncludeHealthy -or $record.Health -ne 'Healthy') { $records += $record }
    }
    if ($records.Count -eq 0 -and $scanErrors.Count -gt 0) {
        $records += [pscustomobject][ordered]@{
            Component         = 'DriverScannerDiagnostic'
            Name              = $null
            InstanceId        = $null
            PnpClass          = $null
            Category          = 'Scanner'
            Status            = 'ScanFailed'
            ProblemCode       = $null
            Health            = 'Unknown'
            Badge             = '[??]'
            Priority          = 'Unknown'
            Reason            = 'Driver inventory could not be queried.'
            HardwareIds       = @()
            DriverVersion     = $null
            DriverDate        = $null
            DriverProvider    = $null
            InfName           = $null
            IsSigned          = $null
            Manufacturer      = $null
            IsLive            = ($onWindows -and -not $provided)
            PlatformSupported = $onWindows
            ScanErrors        = $scanErrors.ToArray()
        }
    }
    return @($records | Sort-Object @{ Expression = { switch ($_.Priority) { 'Required' { 0 } 'Recommended' { 1 } 'Optional' { 2 } default { 3 } } } }, Category, Name)
}

function Get-FreshWinPnpDeviceInventory {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Devices,
        [AllowNull()][object[]]$SignedDrivers,
        [switch]$IncludeHardwareIds,
        [switch]$IncludeHealthy = $true
    )
    return Get-FreshWinDriverInventory @PSBoundParameters
}

function Get-FreshWinDriverSummary {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Drivers
    )

    if (-not $PSBoundParameters.ContainsKey('Drivers')) { $Drivers = @(Get-FreshWinDriverInventory) }
    $unsupported = @($Drivers).Count -eq 1 -and
        [string](Get-FreshWinObjectProperty -InputObject $Drivers[0] -Name @('Status')) -eq 'Unsupported'
    if ($unsupported) {
        $result = New-FreshWinUnsupportedResult -Component 'DriverSummary'
        $result | Add-Member -NotePropertyName Total -NotePropertyValue 0
        $result | Add-Member -NotePropertyName Required -NotePropertyValue 0
        $result | Add-Member -NotePropertyName Recommended -NotePropertyValue 0
        $result | Add-Member -NotePropertyName Healthy -NotePropertyValue 0
        $result | Add-Member -NotePropertyName Categories -NotePropertyValue @()
        return $result
    }

    $scanErrors = @($Drivers | ForEach-Object {
        @(Get-FreshWinObjectProperty -InputObject $_ -Name @('ScanErrors') -Default @())
    } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    $deviceDrivers = @($Drivers | Where-Object {
        [string](Get-FreshWinObjectProperty -InputObject $_ -Name @('Component')) -ne 'DriverScannerDiagnostic'
    })

    $categories = @()
    foreach ($group in @($deviceDrivers | Group-Object Category | Sort-Object Name)) {
        $categories += [pscustomobject][ordered]@{
            Category    = $group.Name
            Total       = $group.Count
            Required    = @($group.Group | Where-Object { $_.Priority -eq 'Required' }).Count
            Recommended = @($group.Group | Where-Object { $_.Priority -eq 'Recommended' }).Count
            Healthy     = @($group.Group | Where-Object { $_.Health -eq 'Healthy' }).Count
        }
    }
    $required = @($deviceDrivers | Where-Object { $_.Priority -eq 'Required' }).Count
    $recommended = @($deviceDrivers | Where-Object { $_.Priority -eq 'Recommended' }).Count
    $summaryStatus = if ($scanErrors.Count -gt 0 -and $deviceDrivers.Count -eq 0) { 'Unknown' }
        elseif ($scanErrors.Count -gt 0) { 'Partial' }
        elseif ($required -gt 0) { 'Attention' }
        elseif ($recommended -gt 0) { 'Review' }
        elseif (Test-FreshWinWindows) { 'Ready' }
        else { 'Fixture' }
    return [pscustomobject][ordered]@{
        Component       = 'DriverSummary'
        IsSupported     = Test-FreshWinWindows
        Supported       = Test-FreshWinWindows
        IsLive          = @($Drivers | Where-Object {
            [bool](Get-FreshWinObjectProperty -InputObject $_ -Name @('IsLive') -Default $false)
        }).Count -gt 0
        Status          = $summaryStatus
        Platform        = Get-FreshWinPlatformName
        Total           = $deviceDrivers.Count
        Required        = $required
        Recommended     = $recommended
        Optional        = @($deviceDrivers | Where-Object { $_.Priority -eq 'Optional' }).Count
        Healthy         = @($deviceDrivers | Where-Object { $_.Health -eq 'Healthy' }).Count
        Unknown         = @($deviceDrivers | Where-Object { $_.Health -eq 'Unknown' }).Count
        ProblemDevices  = @($deviceDrivers | Where-Object { $_.Health -ne 'Healthy' })
        Categories      = $categories
        Errors          = $scanErrors
    }
}

function Get-FreshWinMissingDrivers {
    [CmdletBinding()]
    param([AllowNull()][object[]]$Drivers)
    if (-not $PSBoundParameters.ContainsKey('Drivers')) { $Drivers = @(Get-FreshWinDriverInventory) }
    return @($Drivers | Where-Object { $_.Health -eq 'MissingDriver' -or ($_.Priority -eq 'Required' -and $_.ProblemCode -eq 28) })
}
