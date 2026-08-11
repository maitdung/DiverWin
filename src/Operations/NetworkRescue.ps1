Set-StrictMode -Version Latest

function Get-FreshWinSafeInfFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [ValidateRange(1, 5000)][int]$MaximumFiles = 500,
        [ValidateRange(1024, 10485760)][long]$MaximumFileBytes = 2097152
    )

    $root = [System.IO.Path]::GetFullPath($Folder)
    if (-not [System.IO.Directory]::Exists($root)) {
        throw "Local driver folder was not found: $root"
    }
    if (([System.IO.File]::GetAttributes($root) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to scan reparse-point driver folder '$root'."
    }

    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($root)
    $results = New-Object System.Collections.Generic.List[object]
    while ($queue.Count -gt 0 -and $results.Count -lt $MaximumFiles) {
        $directory = $queue.Dequeue()
        try {
            foreach ($subdirectory in [System.IO.Directory]::EnumerateDirectories($directory)) {
                try {
                    $attributes = [System.IO.File]::GetAttributes($subdirectory)
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $queue.Enqueue($subdirectory)
                    }
                }
                catch { }
            }
            foreach ($filePath in [System.IO.Directory]::EnumerateFiles($directory, '*.inf')) {
                if ($results.Count -ge $MaximumFiles) { break }
                try {
                    $file = New-Object System.IO.FileInfo($filePath)
                    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    if ($file.Length -gt $MaximumFileBytes) { continue }
                    $results.Add($file)
                }
                catch { }
            }
        }
        catch { }
    }
    return $results.ToArray()
}

function Get-FreshWinInfDriverMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string[]]$HardwareIds = @(),
        [ValidateRange(1024, 10485760)][long]$MaximumFileBytes = 2097152
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($fullPath)) { throw "INF file was not found: $fullPath" }
    $file = New-Object System.IO.FileInfo($fullPath)
    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to inspect reparse-point INF '$fullPath'." }
    if ($file.Length -gt $MaximumFileBytes) { throw "INF file exceeds the $MaximumFileBytes-byte scan limit." }

    $content = [System.IO.File]::ReadAllText($fullPath)
    $class = $null
    $provider = $null
    $driverVersion = $null
    $catalogFile = $null
    $declaredIds = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($content -split "`r?`n")) {
        $clean = ($line -replace ';.*$', '').Trim()
        if ($clean -match '(?i)^Class\s*=\s*(.+)$') { $class = $matches[1].Trim(' ', '"') }
        elseif ($clean -match '(?i)^Provider\s*=\s*(.+)$') { $provider = $matches[1].Trim(' ', '"') }
        elseif ($clean -match '(?i)^DriverVer\s*=\s*(.+)$') { $driverVersion = $matches[1].Trim(' ', '"') }
        elseif ($clean -match '(?i)^CatalogFile(?:\.[^=]+)?\s*=\s*(.+)$') { $catalogFile = $matches[1].Trim(' ', '"') }

        foreach ($identifierMatch in [regex]::Matches($clean, '(?i)(?:PCI|USB|HDAUDIO|ACPI|BTHENUM|BTH|ROOT|HID|SWD)\\[^,\s\"]+')) {
            $identifier = $identifierMatch.Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($identifier) -and $declaredIds -notcontains $identifier) {
                $declaredIds.Add($identifier)
            }
        }
    }

    $matchedIds = New-Object System.Collections.Generic.List[string]
    $matchType = 'None'
    foreach ($requestedId in @($HardwareIds)) {
        if ([string]::IsNullOrWhiteSpace([string]$requestedId)) { continue }
        foreach ($declaredId in $declaredIds) {
            if ([string]::Equals([string]$requestedId, [string]$declaredId, [System.StringComparison]::OrdinalIgnoreCase)) {
                if ($matchedIds -notcontains [string]$requestedId) { $matchedIds.Add([string]$requestedId) }
                $matchType = 'Exact'
            }
            elseif ($matchType -ne 'Exact' -and
                ([string]$requestedId).StartsWith([string]$declaredId, [System.StringComparison]::OrdinalIgnoreCase)) {
                if ($matchedIds -notcontains [string]$requestedId) { $matchedIds.Add([string]$requestedId) }
                $matchType = 'CompatiblePrefixReview'
            }
        }
    }

    return [pscustomobject][ordered]@{
        Path                = $fullPath
        FileName            = $file.Name
        Length              = [long]$file.Length
        Sha256              = Get-FreshWinOperationFileSha256 -Path $fullPath
        Class               = $class
        Provider            = $provider
        DriverVersion       = $driverVersion
        CatalogFile         = $catalogFile
        DeclaredHardwareIds = $declaredIds.ToArray()
        MatchedHardwareIds  = $matchedIds.ToArray()
        MatchType           = $matchType
        IsNetworkClass      = ([string]$class -match '(?i)^Net$')
        AutomaticExecution  = $false
    }
}

function Find-FreshWinLocalNetworkDriver {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [AllowNull()][string[]]$HardwareIds = @(),
        [ValidateRange(1, 5000)][int]$MaximumFiles = 500,
        [ValidateRange(1024, 10485760)][long]$MaximumFileBytes = 2097152,
        [switch]$IncludeNonNetworkClass
    )

    $results = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $files = @(Get-FreshWinSafeInfFile -Folder $Folder -MaximumFiles $MaximumFiles -MaximumFileBytes $MaximumFileBytes)
    foreach ($file in $files) {
        try {
            $metadata = Get-FreshWinInfDriverMetadata -Path $file.FullName -HardwareIds $HardwareIds -MaximumFileBytes $MaximumFileBytes
            if (($IncludeNonNetworkClass -or $metadata.IsNetworkClass) -and
                (@($HardwareIds).Count -eq 0 -or $metadata.MatchType -ne 'None')) {
                $results.Add($metadata)
            }
        }
        catch { $errors.Add((Protect-FreshWinSensitiveText -Text $_.Exception.Message)) }
    }

    return [pscustomobject][ordered]@{
        Component       = 'LocalNetworkDriverScan'
        Status          = $(if ($errors.Count -gt 0) { 'Partial' } else { 'Completed' })
        Folder          = [System.IO.Path]::GetFullPath($Folder)
        InspectedCount  = $files.Count
        Truncated       = ($files.Count -ge $MaximumFiles)
        HardwareIds     = @($HardwareIds)
        Matches         = $results.ToArray()
        Errors          = $errors.ToArray()
        AutomaticInstall = $false
    }
}

function Get-FreshWinNetworkDeviceHardwareIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Devices,
        [AllowNull()][scriptblock]$HardwareIdProvider
    )

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($device in @($Devices)) {
        if ($null -eq $device) { continue }
        $instanceId = [string](Get-FreshWinPropertyValue -InputObject $device -Name 'InstanceId' -Default (Get-FreshWinPropertyValue -InputObject $device -Name 'PNPDeviceID'))
        $hardwareIds = @((Get-FreshWinPropertyValue -InputObject $device -Name 'HardwareIds' -Default @()))
        if ($hardwareIds.Count -eq 0 -and $null -ne $HardwareIdProvider) {
            try { $hardwareIds = @(& $HardwareIdProvider $device) } catch { $hardwareIds = @() }
        }
        elseif ($hardwareIds.Count -eq 0 -and (Test-FreshWinOperationsWindows) -and -not [string]::IsNullOrWhiteSpace($instanceId)) {
            $propertyCommand = Get-Command -Name Get-PnpDeviceProperty -ErrorAction SilentlyContinue
            if ($null -ne $propertyCommand) {
                try {
                    $property = Get-PnpDeviceProperty -InstanceId $instanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop
                    $hardwareIds = @($property.Data)
                }
                catch { $hardwareIds = @() }
            }
        }
        $records.Add([pscustomobject][ordered]@{
                Name        = Get-FreshWinPropertyValue -InputObject $device -Name 'Name' -Default (Get-FreshWinPropertyValue -InputObject $device -Name 'FriendlyName' -Default 'Unknown network device')
                InstanceId  = $instanceId
                Status      = Get-FreshWinPropertyValue -InputObject $device -Name 'Status' -Default 'Problem'
                ProblemCode = Get-FreshWinPropertyValue -InputObject $device -Name 'ProblemCode' -Default (Get-FreshWinPropertyValue -InputObject $device -Name 'ConfigManagerErrorCode')
                HardwareIds = @($hardwareIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
            })
    }
    return $records.ToArray()
}

function Get-FreshWinNetworkRescueState {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Adapters,
        [AllowNull()][object[]]$ProblemDevices,
        [AllowNull()][Nullable[bool]]$InternetAvailable,
        [AllowNull()][Nullable[bool]]$LinkAvailable,
        [AllowNull()][scriptblock]$StateProvider,
        [AllowNull()][scriptblock]$HardwareIdProvider,
        [string]$LocalDriverFolder
    )

    $provided = $PSBoundParameters.ContainsKey('Adapters') -or
        $PSBoundParameters.ContainsKey('ProblemDevices') -or
        $PSBoundParameters.ContainsKey('InternetAvailable') -or
        $PSBoundParameters.ContainsKey('LinkAvailable') -or
        ($null -ne $StateProvider)
    $windowsHost = Test-FreshWinOperationsWindows
    if (-not $windowsHost -and -not $provided) {
        $unsupported = New-FreshWinOperationUnsupportedResult -Component 'NetworkRescue'
        $unsupported | Add-Member -NotePropertyName RescueState -NotePropertyValue 'Unsupported'
        $unsupported | Add-Member -NotePropertyName Adapters -NotePropertyValue @()
        $unsupported | Add-Member -NotePropertyName ProblemDevices -NotePropertyValue @()
        $unsupported | Add-Member -NotePropertyName LocalDrivers -NotePropertyValue @()
        return $unsupported
    }

    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -ne $StateProvider) {
        try {
            $providerState = & $StateProvider
            $Adapters = @((Get-FreshWinPropertyValue -InputObject $providerState -Name 'Adapters' -Default @()))
            $ProblemDevices = @((Get-FreshWinPropertyValue -InputObject $providerState -Name 'ProblemDevices' -Default @()))
            $InternetAvailable = Get-FreshWinPropertyValue -InputObject $providerState -Name 'InternetAvailable'
            $LinkAvailable = Get-FreshWinPropertyValue -InputObject $providerState -Name 'LinkAvailable'
        }
        catch { $errors.Add((Protect-FreshWinSensitiveText -Text $_.Exception.Message)) }
    }
    elseif (-not $provided) {
        try {
            $network = Get-FreshWinNetworkState
            $Adapters = @($network.Adapters)
            $ProblemDevices = @($network.ProblemDevices)
            $InternetAvailable = $network.InternetAvailable
            $LinkAvailable = $network.LinkAvailable
            foreach ($errorText in @($network.Errors)) { if ($errorText) { $errors.Add([string]$errorText) } }
        }
        catch { $errors.Add((Protect-FreshWinSensitiveText -Text $_.Exception.Message)) }
    }

    $adapterRecords = New-Object System.Collections.Generic.List[object]
    foreach ($adapter in @($Adapters)) {
        if ($null -eq $adapter) { continue }
        $name = [string](Get-FreshWinPropertyValue -InputObject $adapter -Name 'Name' -Default (Get-FreshWinPropertyValue -InputObject $adapter -Name 'InterfaceAlias' -Default 'Unnamed adapter'))
        $description = [string](Get-FreshWinPropertyValue -InputObject $adapter -Name 'Description' -Default (Get-FreshWinPropertyValue -InputObject $adapter -Name 'InterfaceDescription'))
        $type = [string](Get-FreshWinPropertyValue -InputObject $adapter -Name 'Type' -Default (Get-FreshWinNetworkAdapterType -Name $name -Description $description -MediaType ([string](Get-FreshWinPropertyValue -InputObject $adapter -Name 'MediaType'))))
        $status = [string](Get-FreshWinPropertyValue -InputObject $adapter -Name 'Status' -Default 'Unknown')
        $isUp = Get-FreshWinPropertyValue -InputObject $adapter -Name 'IsUp'
        if ($null -eq $isUp) { $isUp = $status -match '(?i)^(Up|Connected|2)$' }
        $adapterRecords.Add([pscustomobject][ordered]@{
                Name              = $name
                Description       = $description
                Type              = $type
                Status            = $status
                IsUp              = [bool]$isUp
                HardwareInterface = [bool](Get-FreshWinPropertyValue -InputObject $adapter -Name 'HardwareInterface' -Default $true)
                InterfaceIndex    = Get-FreshWinPropertyValue -InputObject $adapter -Name 'InterfaceIndex' -Default (Get-FreshWinPropertyValue -InputObject $adapter -Name 'ifIndex')
            })
    }
    $problemRecords = @(Get-FreshWinNetworkDeviceHardwareIds -Devices @($ProblemDevices) -HardwareIdProvider $HardwareIdProvider)
    $physicalAdapters = @($adapterRecords | Where-Object { $_.HardwareInterface -and $_.Type -ne 'Virtual' -and $_.Type -ne 'Bluetooth' })
    if ($null -eq $LinkAvailable) { $LinkAvailable = @($physicalAdapters | Where-Object { $_.IsUp }).Count -gt 0 }

    $missingDriver = @($problemRecords | Where-Object { [string]$_.ProblemCode -eq '28' }).Count -gt 0
    $rescueState = 'OfflineUnknown'
    if ($InternetAvailable -eq $true) { $rescueState = 'Online' }
    elseif ($missingDriver) { $rescueState = 'DriverMissing' }
    elseif ($problemRecords.Count -gt 0) { $rescueState = 'AdapterProblem' }
    elseif ($physicalAdapters.Count -eq 0) { $rescueState = 'NoAdapter' }
    elseif ($LinkAvailable -eq $true) { $rescueState = 'LinkOnly' }
    elseif ($InternetAvailable -eq $false) { $rescueState = 'Offline' }

    $allHardwareIds = @($problemRecords | ForEach-Object { @($_.HardwareIds) } | Select-Object -Unique)
    $localDriverScan = $null
    if (-not [string]::IsNullOrWhiteSpace($LocalDriverFolder)) {
        try { $localDriverScan = Find-FreshWinLocalNetworkDriver -Folder $LocalDriverFolder -HardwareIds $allHardwareIds }
        catch { $errors.Add((Protect-FreshWinSensitiveText -Text $_.Exception.Message)) }
    }

    return [pscustomobject][ordered]@{
        Component         = 'NetworkRescue'
        Status            = $(if ($windowsHost -and -not $provided) { 'LiveObserved' } else { 'FixtureObserved' })
        RescueState       = $rescueState
        IsSupported       = $windowsHost
        PlatformSupported = $windowsHost
        IsLive            = ($windowsHost -and -not $provided)
        InternetAvailable = $InternetAvailable
        LinkAvailable     = $LinkAvailable
        Adapters          = $adapterRecords.ToArray()
        ProblemDevices    = @($problemRecords)
        HardwareIds       = $allHardwareIds
        LocalDriverScan   = $localDriverScan
        LocalDrivers      = $(if ($null -ne $localDriverScan) { @($localDriverScan.Matches) } else { @() })
        Errors            = $errors.ToArray()
    }
}

function New-FreshWinNetworkRescuePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$State)

    $rescueState = [string](Get-FreshWinPropertyValue -InputObject $State -Name 'RescueState' -Default 'OfflineUnknown')
    $items = New-Object System.Collections.Generic.List[object]
    $items.Add([pscustomobject][ordered]@{
            Order = 1; Action = 'CollectOfflineDiagnostics'; Risk = 'ReadOnly'; AutomaticExecution = $false
            Description = 'Collect adapter, IP, route, and DNS observations with identifiers redacted.'
        })
    if ($rescueState -in @('DriverMissing', 'AdapterProblem', 'NoAdapter')) {
        $items.Add([pscustomobject][ordered]@{
                Order = 2; Action = 'RescanDevices'; Risk = 'Low'; AutomaticExecution = $false
                Description = 'Request a Windows device rescan only after explicit user confirmation.'
            })
    }
    if (@((Get-FreshWinPropertyValue -InputObject $State -Name 'LocalDrivers' -Default @())).Count -gt 0) {
        $items.Add([pscustomobject][ordered]@{
                Order = 3; Action = 'ReviewLocalDriverMatches'; Risk = 'Elevated'; AutomaticExecution = $false
                Description = 'Review matched local INF identity, signature, and hash before any administrator installs it.'
            })
    }
    if ($rescueState -ne 'Online') {
        $items.Add([pscustomobject][ordered]@{
                Order = 4; Action = 'AcquireOfficialOemDriverOffline'; Risk = 'Manual'; AutomaticExecution = $false
                Description = 'On another trusted device, obtain the adapter driver from the PC or adapter manufacturer and transfer it securely.'
            })
        $items.Add([pscustomobject][ordered]@{
                Order = 5; Action = 'RetryReadOnlyProbe'; Risk = 'ReadOnly'; AutomaticExecution = $false
                Description = 'After an independently confirmed change, repeat bounded connectivity observations.'
            })
    }

    return [pscustomobject][ordered]@{
        Component          = 'NetworkRescuePlan'
        Status             = $(if ($rescueState -eq 'Online') { 'NoActionRequired' } else { 'ReviewRequired' })
        RescueState        = $rescueState
        AutomaticExecution = $false
        AllowsDownload     = $false
        Items              = $items.ToArray()
        SafetyNote         = 'The rescue plan never installs a driver, changes an adapter, or downloads software automatically.'
    }
}

function Invoke-FreshWinNetworkRescueRetry {
    [CmdletBinding()]
    param(
        [AllowNull()][scriptblock]$ProbeProvider,
        [ValidateRange(1, 5)][int]$MaximumAttempts = 3,
        [ValidateRange(0, 5000)][int]$DelayMilliseconds = 0
    )

    $windowsHost = Test-FreshWinOperationsWindows
    if (-not $windowsHost -and $null -eq $ProbeProvider) {
        $unsupported = New-FreshWinOperationUnsupportedResult -Component 'NetworkRescueRetry'
        $unsupported | Add-Member -NotePropertyName Recovered -NotePropertyValue $false
        $unsupported | Add-Member -NotePropertyName Attempts -NotePropertyValue @()
        return $unsupported
    }

    $attempts = New-Object System.Collections.Generic.List[object]
    $recovered = $false
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $observation = if ($null -ne $ProbeProvider) { & $ProbeProvider $attempt } else { Get-FreshWinNetworkRescueState }
            $state = [string](Get-FreshWinPropertyValue -InputObject $observation -Name 'RescueState' -Default (Get-FreshWinPropertyValue -InputObject $observation -Name 'Status' -Default 'Unknown'))
            $online = $state -eq 'Online' -or (Get-FreshWinPropertyValue -InputObject $observation -Name 'InternetAvailable') -eq $true
            $attempts.Add([pscustomobject][ordered]@{ Attempt = $attempt; State = $state; Online = $online; Error = $null })
            if ($online) { $recovered = $true; break }
        }
        catch {
            $attempts.Add([pscustomobject][ordered]@{ Attempt = $attempt; State = 'ProbeFailed'; Online = $false; Error = Protect-FreshWinSensitiveText -Text $_.Exception.Message })
        }
        if ($DelayMilliseconds -gt 0 -and $attempt -lt $MaximumAttempts) { Start-Sleep -Milliseconds $DelayMilliseconds }
    }

    return [pscustomobject][ordered]@{
        Component                = 'NetworkRescueRetry'
        Status                   = $(if ($recovered) { if ($windowsHost -and $null -eq $ProbeProvider) { 'OnlineObserved' } else { 'FixtureOnlineObserved' } } else { 'StillOffline' })
        Recovered                = $recovered
        IsLive                   = ($windowsHost -and $null -eq $ProbeProvider)
        WindowsExecutionVerified = ($windowsHost -and $null -eq $ProbeProvider)
        MutationPerformed        = $false
        Attempts                 = $attempts.ToArray()
    }
}

function Get-FreshWinOfflineNetworkDiagnostics {
    [CmdletBinding()]
    param(
        [AllowNull()][scriptblock]$IpConfigurationProvider,
        [AllowNull()][scriptblock]$RouteProvider,
        [AllowNull()][scriptblock]$DnsProvider
    )

    $providerSupplied = $null -ne $IpConfigurationProvider -or $null -ne $RouteProvider -or $null -ne $DnsProvider
    $windowsHost = Test-FreshWinOperationsWindows
    if (-not $windowsHost -and -not $providerSupplied) {
        return New-FreshWinOperationUnsupportedResult -Component 'OfflineNetworkDiagnostics'
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $values = [ordered]@{ IpConfiguration = @(); Routes = @(); DnsServers = @() }
    $queries = @(
        [pscustomobject]@{ Name = 'IpConfiguration'; Provider = $IpConfigurationProvider; Command = 'Get-NetIPConfiguration' },
        [pscustomobject]@{ Name = 'Routes'; Provider = $RouteProvider; Command = 'Get-NetRoute' },
        [pscustomobject]@{ Name = 'DnsServers'; Provider = $DnsProvider; Command = 'Get-DnsClientServerAddress' }
    )
    foreach ($query in $queries) {
        try {
            if ($null -ne $query.Provider) { $values[$query.Name] = @(& $query.Provider) }
            elseif ($windowsHost) {
                $command = Get-Command -Name $query.Command -ErrorAction SilentlyContinue
                if ($null -eq $command) { throw "$($query.Command) is unavailable." }
                $values[$query.Name] = @(& $query.Command -ErrorAction Stop)
            }
        }
        catch { $errors.Add("$($query.Name): $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)") }
    }

    return [pscustomobject][ordered]@{
        Component         = 'OfflineNetworkDiagnostics'
        Status            = $(if ($errors.Count -eq 0) { if ($windowsHost -and -not $providerSupplied) { 'LiveObserved' } else { 'FixtureObserved' } } else { 'Partial' })
        IsLive            = ($windowsHost -and -not $providerSupplied)
        MutationPerformed = $false
        Data              = Protect-FreshWinPrivacyData -InputObject ([pscustomobject]$values)
        Errors            = $errors.ToArray()
    }
}
