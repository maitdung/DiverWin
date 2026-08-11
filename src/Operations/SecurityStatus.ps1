Set-StrictMode -Version Latest

function ConvertTo-FreshWinSecurityProductRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Product,
        [Parameter(Mandatory = $true)][ValidateSet('Antivirus', 'Firewall')][string]$Type
    )

    return [pscustomobject][ordered]@{
        Type                  = $Type
        DisplayName           = Get-FreshWinPropertyValue -InputObject $Product -Name 'displayName' -Default (Get-FreshWinPropertyValue -InputObject $Product -Name 'DisplayName' -Default 'Unknown product')
        InstanceGuid          = Get-FreshWinPropertyValue -InputObject $Product -Name 'instanceGuid'
        ProductState          = Get-FreshWinPropertyValue -InputObject $Product -Name 'productState'
        PathToSignedProductExe = Get-FreshWinPropertyValue -InputObject $Product -Name 'pathToSignedProductExe'
        PathToSignedReportingExe = Get-FreshWinPropertyValue -InputObject $Product -Name 'pathToSignedReportingExe'
        StateInterpretation   = 'NotInterpreted'
    }
}

function Get-FreshWinSecurityStatus {
    [CmdletBinding()]
    param(
        [AllowNull()][scriptblock]$SecurityProductProvider,
        [AllowNull()][scriptblock]$DefenderStatusProvider,
        [AllowNull()][scriptblock]$FirewallProfileProvider
    )

    $providerSupplied = $null -ne $SecurityProductProvider -or $null -ne $DefenderStatusProvider -or $null -ne $FirewallProfileProvider
    $windowsHost = Test-FreshWinOperationsWindows
    if (-not $windowsHost -and -not $providerSupplied) {
        $unsupported = New-FreshWinOperationUnsupportedResult -Component 'SecurityStatus'
        $unsupported | Add-Member -NotePropertyName OverallHealth -NotePropertyValue 'Unsupported'
        $unsupported | Add-Member -NotePropertyName AntivirusProducts -NotePropertyValue @()
        $unsupported | Add-Member -NotePropertyName FirewallProducts -NotePropertyValue @()
        $unsupported | Add-Member -NotePropertyName FirewallProfiles -NotePropertyValue @()
        return $unsupported
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $antivirusProducts = New-Object System.Collections.Generic.List[object]
    $firewallProducts = New-Object System.Collections.Generic.List[object]
    $defender = $null
    $firewallProfiles = New-Object System.Collections.Generic.List[object]

    try {
        if ($null -ne $SecurityProductProvider) {
            $providedProducts = & $SecurityProductProvider
            $providedAntivirus = @((Get-FreshWinPropertyValue -InputObject $providedProducts -Name 'AntivirusProducts' -Default @()))
            $providedFirewalls = @((Get-FreshWinPropertyValue -InputObject $providedProducts -Name 'FirewallProducts' -Default @()))
            foreach ($product in $providedAntivirus) {
                if ($null -ne $product) { $antivirusProducts.Add((ConvertTo-FreshWinSecurityProductRecord -Product $product -Type Antivirus)) }
            }
            foreach ($product in $providedFirewalls) {
                if ($null -ne $product) { $firewallProducts.Add((ConvertTo-FreshWinSecurityProductRecord -Product $product -Type Firewall)) }
            }
        }
        elseif ($windowsHost) {
            foreach ($product in @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntivirusProduct -ErrorAction Stop)) {
                $antivirusProducts.Add((ConvertTo-FreshWinSecurityProductRecord -Product $product -Type Antivirus))
            }
            try {
                foreach ($product in @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct -ErrorAction Stop)) {
                    $firewallProducts.Add((ConvertTo-FreshWinSecurityProductRecord -Product $product -Type Firewall))
                }
            }
            catch { $errors.Add("SecurityCenter firewall products: $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)") }
        }
    }
    catch { $errors.Add("SecurityCenter products: $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)") }

    try {
        if ($null -ne $DefenderStatusProvider) { $defenderRaw = & $DefenderStatusProvider }
        elseif ($windowsHost) {
            $command = Get-Command -Name Get-MpComputerStatus -ErrorAction SilentlyContinue
            if ($null -eq $command) { throw 'Get-MpComputerStatus is unavailable.' }
            $defenderRaw = Get-MpComputerStatus -ErrorAction Stop
        }
        else { $defenderRaw = $null }

        if ($null -ne $defenderRaw) {
            $defender = [pscustomobject][ordered]@{
                AntivirusEnabled              = Get-FreshWinPropertyValue -InputObject $defenderRaw -Name 'AntivirusEnabled'
                AntispywareEnabled            = Get-FreshWinPropertyValue -InputObject $defenderRaw -Name 'AntispywareEnabled'
                AMServiceEnabled              = Get-FreshWinPropertyValue -InputObject $defenderRaw -Name 'AMServiceEnabled'
                RealTimeProtectionEnabled     = Get-FreshWinPropertyValue -InputObject $defenderRaw -Name 'RealTimeProtectionEnabled'
                BehaviorMonitorEnabled        = Get-FreshWinPropertyValue -InputObject $defenderRaw -Name 'BehaviorMonitorEnabled'
                NISEnabled                    = Get-FreshWinPropertyValue -InputObject $defenderRaw -Name 'NISEnabled'
                AntivirusSignatureAge         = Get-FreshWinPropertyValue -InputObject $defenderRaw -Name 'AntivirusSignatureAge'
                AntivirusSignatureLastUpdated = Get-FreshWinPropertyValue -InputObject $defenderRaw -Name 'AntivirusSignatureLastUpdated'
                ComputerState                 = Get-FreshWinPropertyValue -InputObject $defenderRaw -Name 'ComputerState'
            }
        }
    }
    catch { $errors.Add("Microsoft Defender: $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)") }

    try {
        if ($null -ne $FirewallProfileProvider) { $profilesRaw = @(& $FirewallProfileProvider) }
        elseif ($windowsHost) {
            $command = Get-Command -Name Get-NetFirewallProfile -ErrorAction SilentlyContinue
            if ($null -eq $command) { throw 'Get-NetFirewallProfile is unavailable.' }
            $profilesRaw = @(Get-NetFirewallProfile -ErrorAction Stop)
        }
        else { $profilesRaw = @() }

        foreach ($profile in @($profilesRaw)) {
            if ($null -eq $profile) { continue }
            $firewallProfiles.Add([pscustomobject][ordered]@{
                    Name                  = Get-FreshWinPropertyValue -InputObject $profile -Name 'Name' -Default 'Unknown'
                    Enabled               = Get-FreshWinPropertyValue -InputObject $profile -Name 'Enabled'
                    DefaultInboundAction  = Get-FreshWinPropertyValue -InputObject $profile -Name 'DefaultInboundAction'
                    DefaultOutboundAction = Get-FreshWinPropertyValue -InputObject $profile -Name 'DefaultOutboundAction'
                    NotifyOnListen        = Get-FreshWinPropertyValue -InputObject $profile -Name 'NotifyOnListen'
                })
        }
    }
    catch { $errors.Add("Windows Firewall profiles: $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)") }

    $realTimeEnabled = Get-FreshWinPropertyValue -InputObject $defender -Name 'RealTimeProtectionEnabled'
    $defenderHealth = 'Review'
    if ($realTimeEnabled -eq $true) { $defenderHealth = 'Healthy' }
    elseif ($realTimeEnabled -eq $false) { $defenderHealth = 'Attention' }

    $profileValues = @($firewallProfiles | ForEach-Object { $_.Enabled })
    $anyFirewallDisabled = @($profileValues | Where-Object { $_ -eq $false }).Count -gt 0
    $allFirewallsEnabled = $firewallProfiles.Count -gt 0 -and @($profileValues | Where-Object { $_ -ne $true }).Count -eq 0
    $firewallHealth = 'Review'
    if ($anyFirewallDisabled) { $firewallHealth = 'Attention' }
    elseif ($allFirewallsEnabled) { $firewallHealth = 'Healthy' }

    $overallHealth = 'Review'
    if ($realTimeEnabled -eq $false -or $anyFirewallDisabled) { $overallHealth = 'Attention' }
    elseif ($realTimeEnabled -eq $true -and $allFirewallsEnabled) { $overallHealth = 'Healthy' }

    return [pscustomobject][ordered]@{
        Component          = 'SecurityStatus'
        Status             = $(if ($windowsHost -and -not $providerSupplied) { 'LiveObserved' } else { 'FixtureObserved' })
        OverallHealth      = $overallHealth
        IsSupported        = $windowsHost
        PlatformSupported  = $windowsHost
        IsLive             = ($windowsHost -and -not $providerSupplied)
        MutationPerformed  = $false
        AntivirusProducts  = $antivirusProducts.ToArray()
        FirewallProducts   = $firewallProducts.ToArray()
        Defender           = $defender
        DefenderHealth     = $defenderHealth
        FirewallProfiles   = $firewallProfiles.ToArray()
        FirewallHealth     = $firewallHealth
        Errors             = $errors.ToArray()
        ProductStateNotice = 'SecurityCenter2 productState is preserved as raw provider data because its bit layout is undocumented and is not treated as a FreshWin health verdict.'
    }
}
