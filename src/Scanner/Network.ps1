function Get-FreshWinNetworkAdapterType {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Name,

        [AllowNull()]
        [string]$Description,

        [AllowNull()]
        [string]$MediaType
    )

    $text = @($Name, $Description, $MediaType) -join ' '
    if ($text -match '(?i)Bluetooth') { return 'Bluetooth' }
    if ($text -match '(?i)(Wi[ -]?Fi|Wireless|802\.11|WLAN)') { return 'Wi-Fi' }
    if ($text -match '(?i)(Ethernet|Gigabit|GbE|LAN|802\.3)') { return 'Ethernet' }
    if ($text -match '(?i)(WWAN|Cellular|Mobile Broadband)') { return 'Cellular' }
    if ($text -match '(?i)(VPN|Tunnel|TAP|Virtual|Hyper-V|Loopback)') { return 'Virtual' }
    return 'Other'
}

function Test-FreshWinInternetProbeEvidence {
    [CmdletBinding()]
    param(
        [int]$StatusCode,
        [AllowNull()][string]$ResponseUri,
        [AllowNull()][string]$Content
    )

    return $StatusCode -eq 200 -and
        [string]::Equals($ResponseUri, 'http://www.msftconnecttest.com/connecttest.txt', [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($Content, 'Microsoft Connect Test', [StringComparison]::Ordinal)
}

function Invoke-FreshWinInternetProbe {
    [CmdletBinding()]
    param(
        [int]$TimeoutMilliseconds = 3500
    )

    try {
        $request = [Net.HttpWebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
        $request.Method = 'GET'
        $request.Timeout = $TimeoutMilliseconds
        $request.ReadWriteTimeout = $TimeoutMilliseconds
        # This is the Windows NCSI-compatible clear-text probe.  Do not follow
        # redirects or accept a status code alone: captive portals commonly
        # return a successful HTML page that is not Internet reachability.
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'FreshWin-Connectivity-Check/0.1'
        $response = $request.GetResponse()
        try {
            $statusCode = [int]$response.StatusCode
            $reader = New-Object IO.StreamReader -ArgumentList @($response.GetResponseStream(), [Text.Encoding]::UTF8, $true, 128, $false)
            try {
                $buffer = New-Object char[] 64
                $read = $reader.ReadBlock($buffer, 0, $buffer.Length)
                if ($read -eq $buffer.Length -and $reader.Peek() -ne -1) { return $false }
                $content = if ($read -gt 0) { -join $buffer[0..($read - 1)] } else { '' }
            }
            finally { $reader.Dispose() }
            return Test-FreshWinInternetProbeEvidence -StatusCode $statusCode `
                -ResponseUri ([string]$response.ResponseUri.AbsoluteUri) -Content $content
        }
        finally {
            $response.Close()
        }
    }
    catch {
        return $false
    }
}

function Get-FreshWinNetworkState {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Adapters,

        [AllowNull()]
        [object[]]$ProblemDevices,

        [switch]$SkipInternetProbe,

        [AllowNull()]
        [scriptblock]$InternetProbe
    )

    $provided = $PSBoundParameters.ContainsKey('Adapters') -or
        $PSBoundParameters.ContainsKey('ProblemDevices') -or
        $PSBoundParameters.ContainsKey('InternetProbe')
    $onWindows = Test-FreshWinWindows
    if (-not $onWindows -and -not $provided) {
        $unsupported = New-FreshWinUnsupportedResult -Component 'NetworkScanner'
        $unsupported | Add-Member -NotePropertyName InternetAvailable -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName LinkAvailable -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName Adapters -NotePropertyValue @()
        $unsupported | Add-Member -NotePropertyName ProblemDevices -NotePropertyValue @()
        return $unsupported
    }

    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $PSBoundParameters.ContainsKey('Adapters')) {
        $getNetAdapter = Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue
        if ($null -ne $getNetAdapter) {
            try { $Adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop) } catch { $errors.Add($_.Exception.Message); $Adapters = @() }
        }
        else {
            try { $Adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop | Where-Object { $_.PhysicalAdapter -or $_.NetConnectionID }) } catch { $errors.Add($_.Exception.Message); $Adapters = @() }
        }
    }

    if (-not $PSBoundParameters.ContainsKey('ProblemDevices') -and $onWindows) {
        try {
            $pnpCommand = Get-Command -Name Get-PnpDevice -ErrorAction SilentlyContinue
            if ($null -ne $pnpCommand) {
                $ProblemDevices = @(Get-PnpDevice -Class Net -ErrorAction Stop | Where-Object { $_.Status -notin @('OK', 'Unknown') })
            }
            else {
                $ProblemDevices = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass='Net'" -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
            }
        }
        catch { $errors.Add($_.Exception.Message); $ProblemDevices = @() }
    }

    $adapterRecords = @()
    foreach ($adapter in @($Adapters)) {
        if ($null -eq $adapter) { continue }
        $name = [string](Get-FreshWinObjectProperty -InputObject $adapter -Name @('Name', 'NetConnectionID', 'InterfaceAlias') -Default 'Unnamed adapter')
        $description = [string](Get-FreshWinObjectProperty -InputObject $adapter -Name @('InterfaceDescription', 'Description', 'ProductName'))
        $statusRaw = [string](Get-FreshWinObjectProperty -InputObject $adapter -Name @('Status', 'NetConnectionStatus', 'MediaConnectionState') -Default 'Unknown')
        $up = $false
        if ($statusRaw -match '(?i)^(Up|Connected|2)$') { $up = $true }
        $hardwareInterface = Get-FreshWinObjectProperty -InputObject $adapter -Name @('HardwareInterface', 'PhysicalAdapter') -Default $true
        $adapterRecords += [pscustomobject][ordered]@{
            Name              = $name
            Description       = $description
            Type              = Get-FreshWinNetworkAdapterType -Name $name -Description $description -MediaType ([string](Get-FreshWinObjectProperty -InputObject $adapter -Name @('MediaType', 'NdisPhysicalMedium')))
            Status            = $(if ($up) { 'Up' } elseif ($statusRaw -match '(?i)Disabled') { 'Disabled' } elseif ([string]::IsNullOrWhiteSpace($statusRaw)) { 'Unknown' } else { $statusRaw })
            IsUp              = $up
            HardwareInterface = [bool]$hardwareInterface
            LinkSpeed         = Get-FreshWinObjectProperty -InputObject $adapter -Name @('LinkSpeed', 'Speed')
            MacAddress        = Get-FreshWinObjectProperty -InputObject $adapter -Name @('MacAddress', 'MACAddress')
            InterfaceIndex    = Get-FreshWinObjectProperty -InputObject $adapter -Name @('ifIndex', 'InterfaceIndex', 'DeviceID')
        }
    }

    $problemRecords = @()
    foreach ($device in @($ProblemDevices)) {
        if ($null -eq $device) { continue }
        $problemRecords += [pscustomobject][ordered]@{
            Name        = [string](Get-FreshWinObjectProperty -InputObject $device -Name @('FriendlyName', 'Name') -Default 'Unknown network device')
            InstanceId  = Get-FreshWinObjectProperty -InputObject $device -Name @('InstanceId', 'PNPDeviceID', 'DeviceID')
            Status      = Get-FreshWinObjectProperty -InputObject $device -Name @('Status') -Default 'Problem'
            ProblemCode = Get-FreshWinObjectProperty -InputObject $device -Name @('ProblemCode', 'ConfigManagerErrorCode')
            HardwareIds = @((Get-FreshWinObjectProperty -InputObject $device -Name @('HardwareIds', 'HardwareID') -Default @()))
        }
    }

    $physicalUp = @($adapterRecords | Where-Object { $_.IsUp -and $_.HardwareInterface -and $_.Type -ne 'Virtual' })
    $linkAvailable = $physicalUp.Count -gt 0
    $internetAvailable = $null
    if ($SkipInternetProbe) {
        $internetAvailable = $null
    }
    elseif ($null -ne $InternetProbe) {
        try { $internetAvailable = [bool](& $InternetProbe) } catch { $errors.Add($_.Exception.Message); $internetAvailable = $null }
    }
    elseif ($linkAvailable -and $onWindows) {
        $internetAvailable = Invoke-FreshWinInternetProbe
    }
    elseif (-not $linkAvailable) {
        $internetAvailable = $false
    }

    $status = 'Unknown'
    if ($internetAvailable -eq $true) { $status = 'Online' }
    elseif ($internetAvailable -eq $false) { $status = 'Offline' }
    elseif ($linkAvailable) { $status = 'LinkOnly' }
    elseif (-not $onWindows) { $status = 'Fixture' }

    return [pscustomobject][ordered]@{
        Component         = 'NetworkScanner'
        IsSupported       = $onWindows
        Supported         = $onWindows
        IsLive            = ($onWindows -and -not $provided)
        Status            = $status
        Platform          = Get-FreshWinPlatformName
        InternetAvailable = $internetAvailable
        LinkAvailable     = $linkAvailable
        Adapters          = $adapterRecords
        ProblemDevices    = $problemRecords
        Errors            = $errors.ToArray()
    }
}
