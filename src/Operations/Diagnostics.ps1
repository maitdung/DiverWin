Set-StrictMode -Version Latest

function New-FreshWinDiagnosticErrorResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Source = 'Unknown'
    )

    return [pscustomobject][ordered]@{
        Component         = $Component
        Status            = 'Error'
        IsLive            = $false
        Source            = $Source
        MutationPerformed = $false
        Errors            = @((Protect-FreshWinSensitiveText -Text $Message))
    }
}

function Invoke-FreshWinDiagnosticQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][scriptblock]$Provider,
        [Parameter(Mandatory = $true)][scriptblock]$LiveQuery,
        [bool]$AllowLiveQuery
    )

    try {
        if ($null -ne $Provider) {
            return [pscustomobject]@{
                Name   = $Name
                Source = 'ExplicitProviderFixture'
                Value  = (& $Provider)
                Error  = $null
            }
        }
        if ($AllowLiveQuery) {
            return [pscustomobject]@{
                Name   = $Name
                Source = 'LiveWindowsQuery'
                Value  = (& $LiveQuery)
                Error  = $null
            }
        }
        return [pscustomobject]@{
            Name   = $Name
            Source = 'UnsupportedPlatform'
            Value  = (New-FreshWinOperationUnsupportedResult -Component $Name)
            Error  = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Name   = $Name
            Source = $(if ($null -ne $Provider) { 'ExplicitProviderFixture' } else { 'LiveWindowsQuery' })
            Value  = (New-FreshWinDiagnosticErrorResult -Component $Name -Message $_.Exception.Message)
            Error  = Protect-FreshWinSensitiveText -Text $_.Exception.Message
        }
    }
}

function Get-FreshWinDiagnostics {
    [CmdletBinding()]
    param(
        [AllowNull()][hashtable]$Providers,
        [string]$ProjectRoot
    )

    if ($null -eq $Providers) { $Providers = @{} }
    $windowsHost = Test-FreshWinOperationsWindows
    $components = [ordered]@{}
    $sources = [ordered]@{}
    $collectionErrors = New-Object System.Collections.Generic.List[string]

    $definitions = @(
        [pscustomobject]@{ Name = 'System'; Query = { Get-FreshWinSystemInfo } },
        [pscustomobject]@{ Name = 'Hardware'; Query = { Get-FreshWinHardwareInfo } },
        [pscustomobject]@{ Name = 'Network'; Query = { Get-FreshWinNetworkRescueState } },
        [pscustomobject]@{ Name = 'Security'; Query = { Get-FreshWinSecurityStatus } },
        [pscustomobject]@{ Name = 'Drivers'; Query = { Get-FreshWinDriverSummary } },
        [pscustomobject]@{ Name = 'WindowsUpdate'; Query = { Get-FreshWinWindowsUpdateState } },
        [pscustomobject]@{ Name = 'Activation'; Query = { Get-FreshWinActivationStatus } },
        [pscustomobject]@{ Name = 'Readiness'; Query = { Get-FreshWinWindows11Readiness } }
    )
    foreach ($definition in $definitions) {
        $provider = $null
        if ($Providers.ContainsKey($definition.Name)) { $provider = [scriptblock]$Providers[$definition.Name] }
        $queryResult = Invoke-FreshWinDiagnosticQuery -Name $definition.Name -Provider $provider -LiveQuery $definition.Query -AllowLiveQuery $windowsHost
        $components[$definition.Name] = $queryResult.Value
        $sources[$definition.Name] = $queryResult.Source
        if ($queryResult.Error) { $collectionErrors.Add("$($definition.Name): $($queryResult.Error)") }
    }

    if ($Providers.ContainsKey('Project')) {
        $queryResult = Invoke-FreshWinDiagnosticQuery -Name 'Project' -Provider ([scriptblock]$Providers['Project']) -LiveQuery { $null } -AllowLiveQuery $false
        $components['Project'] = $queryResult.Value
        $sources['Project'] = $queryResult.Source
        if ($queryResult.Error) { $collectionErrors.Add("Project: $($queryResult.Error)") }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        try {
            $components['Project'] = Test-FreshWinProject -ProjectRoot $ProjectRoot
            $sources['Project'] = 'LocalProjectValidation'
        }
        catch {
            $components['Project'] = New-FreshWinDiagnosticErrorResult -Component 'Project' -Message $_.Exception.Message -Source 'LocalProjectValidation'
            $sources['Project'] = 'LocalProjectValidation'
            $collectionErrors.Add("Project: $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)")
        }
    }

    $allLive = $windowsHost -and $Providers.Count -eq 0
    return [pscustomobject][ordered]@{
        SchemaVersion       = 'FreshWin.Diagnostics/1'
        Component           = 'Diagnostics'
        Status              = $(if ($collectionErrors.Count -eq 0) { if ($allLive) { 'LiveObserved' } else { 'FixtureOrPortableObserved' } } else { 'Partial' })
        CollectedAtUtc      = [DateTimeOffset]::UtcNow.ToString('o')
        IsLive              = $allLive
        PlatformSupported   = $windowsHost
        MutationPerformed   = $false
        Sources             = [pscustomobject]$sources
        Components          = [pscustomobject]$components
        Errors              = $collectionErrors.ToArray()
    }
}

function Get-FreshWinHealthComponentResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Value
    )

    if ($null -eq $Value) {
        return [pscustomobject]@{ Component = $Name; Health = 'Review'; Reason = 'No observation was collected.' }
    }
    $status = [string](Get-FreshWinPropertyValue -InputObject $Value -Name 'Status' -Default 'Unknown')
    if ($status -eq 'Unsupported') {
        return [pscustomobject]@{ Component = $Name; Health = 'Unsupported'; Reason = 'The component is not supported on this host.' }
    }
    if ($status -in @('Error', 'Partial', 'Unknown')) {
        return [pscustomobject]@{ Component = $Name; Health = 'Review'; Reason = "The component reported '$status'." }
    }

    switch ($Name) {
        'Security' {
            $health = [string](Get-FreshWinPropertyValue -InputObject $Value -Name 'OverallHealth' -Default 'Review')
            if ($health -notin @('Healthy', 'Attention', 'Review', 'Unsupported')) { $health = 'Review' }
            return [pscustomobject]@{ Component = $Name; Health = $health; Reason = "Defender: $([string](Get-FreshWinPropertyValue -InputObject $Value -Name 'DefenderHealth' -Default 'Review')); firewall: $([string](Get-FreshWinPropertyValue -InputObject $Value -Name 'FirewallHealth' -Default 'Review'))." }
        }
        'Network' {
            $networkState = [string](Get-FreshWinPropertyValue -InputObject $Value -Name 'RescueState' -Default 'OfflineUnknown')
            $health = if ($networkState -eq 'Online') { 'Healthy' } elseif ($networkState -in @('DriverMissing', 'AdapterProblem', 'NoAdapter')) { 'Attention' } else { 'Review' }
            return [pscustomobject]@{ Component = $Name; Health = $health; Reason = "Network state: $networkState." }
        }
        'Drivers' {
            $required = Get-FreshWinPropertyValue -InputObject $Value -Name 'Required'
            $recommended = Get-FreshWinPropertyValue -InputObject $Value -Name 'Recommended'
            $health = if ($null -ne $required -and [int]$required -gt 0) { 'Attention' } elseif ($null -ne $recommended -and [int]$recommended -gt 0) { 'Review' } elseif ($null -ne $required) { 'Healthy' } else { 'Review' }
            return [pscustomobject]@{ Component = $Name; Health = $health; Reason = "Required driver issues: $required; recommended reviews: $recommended." }
        }
        'WindowsUpdate' {
            $pending = Get-FreshWinPropertyValue -InputObject $Value -Name 'PendingCount'
            $restart = Get-FreshWinPropertyValue -InputObject $Value -Name 'RestartPending'
            $health = if (($null -ne $pending -and [int]$pending -gt 0) -or $restart -eq $true) { 'Attention' } elseif ($null -ne $pending -and $restart -ne $null) { 'Healthy' } else { 'Review' }
            return [pscustomobject]@{ Component = $Name; Health = $health; Reason = "Pending updates: $pending; restart pending: $restart." }
        }
        'Activation' {
            $activated = Get-FreshWinPropertyValue -InputObject $Value -Name 'IsActivated'
            $health = if ($activated -eq $true) { 'Healthy' } elseif ($activated -eq $false) { 'Attention' } else { 'Review' }
            return [pscustomobject]@{ Component = $Name; Health = $health; Reason = "Activation state: $([string](Get-FreshWinPropertyValue -InputObject $Value -Name 'ActivationStatus' -Default 'Unknown'))." }
        }
        'Readiness' {
            $readiness = [string](Get-FreshWinPropertyValue -InputObject $Value -Name 'Readiness' -Default 'Unknown')
            $health = if ($readiness -eq 'Ready') { 'Healthy' } elseif ($readiness -eq 'NotReady') { 'Attention' } else { 'Review' }
            return [pscustomobject]@{ Component = $Name; Health = $health; Reason = "Windows 11 readiness: $readiness." }
        }
        default {
            $errorCount = @((Get-FreshWinPropertyValue -InputObject $Value -Name 'Errors' -Default @())).Count
            $health = if ($errorCount -gt 0) { 'Review' } elseif ($status -in @('Ready', 'Healthy', 'Completed', 'Fixture')) { 'Healthy' } else { 'Review' }
            return [pscustomobject]@{ Component = $Name; Health = $health; Reason = "Observation status: $status." }
        }
    }
}

function Get-FreshWinHealthSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Diagnostics)

    $components = Get-FreshWinPropertyValue -InputObject $Diagnostics -Name 'Components'
    if ($null -eq $components) { throw 'Diagnostics.Components is required.' }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($property in $components.PSObject.Properties) {
        $results.Add((Get-FreshWinHealthComponentResult -Name $property.Name -Value $property.Value))
    }
    $healthValues = @($results | ForEach-Object { $_.Health })
    $overall = 'Healthy'
    if ($healthValues -contains 'Attention') { $overall = 'Attention' }
    elseif ($healthValues -contains 'Review') { $overall = 'Review' }
    elseif ($healthValues.Count -eq 0 -or @($healthValues | Where-Object { $_ -ne 'Unsupported' }).Count -eq 0) { $overall = 'Unsupported' }

    return [pscustomobject][ordered]@{
        SchemaVersion     = 'FreshWin.HealthSummary/1'
        Component         = 'HealthSummary'
        GeneratedAtUtc    = [DateTimeOffset]::UtcNow.ToString('o')
        OverallHealth     = $overall
        IsLive            = [bool](Get-FreshWinPropertyValue -InputObject $Diagnostics -Name 'IsLive' -Default $false)
        NumericalScore    = $null
        Components        = $results.ToArray()
        AttentionCount    = @($healthValues | Where-Object { $_ -eq 'Attention' }).Count
        ReviewCount       = @($healthValues | Where-Object { $_ -eq 'Review' }).Count
        UnsupportedCount  = @($healthValues | Where-Object { $_ -eq 'Unsupported' }).Count
        Notice            = 'FreshWin reports evidence-based component states and does not invent a numeric health score.'
    }
}

function Export-FreshWinDiagnostics {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [AllowNull()][object]$Diagnostics,
        [AllowNull()][hashtable]$Providers,
        [string]$ProjectRoot
    )

    $root = Assert-FreshWinSafeOutputRoot -Path $OutputRoot
    if (-not $PSCmdlet.ShouldProcess($root, 'Create a new redacted FreshWin diagnostics bundle')) {
        return [pscustomobject][ordered]@{ Component = 'DiagnosticsExport'; Status = 'Preview'; Succeeded = $false; OutputPath = $null; MutationPerformed = $false }
    }
    if ($null -eq $Diagnostics) { $Diagnostics = Get-FreshWinDiagnostics -Providers $Providers -ProjectRoot $ProjectRoot }

    $safeDiagnostics = Protect-FreshWinPrivacyData -InputObject $Diagnostics
    $health = Get-FreshWinHealthSummary -Diagnostics $Diagnostics
    $safeHealth = Protect-FreshWinPrivacyData -InputObject $health
    $outputPath = New-FreshWinContainedOutputDirectory -OutputRoot $root -Prefix 'FreshWin-Diagnostics'
    $diagnosticsPath = Join-Path $outputPath 'diagnostics.json'
    $healthPath = Join-Path $outputPath 'health-summary.json'
    [void](Write-FreshWinJsonFile -Path $diagnosticsPath -Value $safeDiagnostics -Depth 40 -Atomic)
    [void](Write-FreshWinJsonFile -Path $healthPath -Value $safeHealth -Depth 30 -Atomic)

    $manifest = [pscustomobject][ordered]@{
        SchemaVersion = 'FreshWin.DiagnosticsExport/1'
        CreatedAtUtc  = [DateTimeOffset]::UtcNow.ToString('o')
        IsLive        = [bool](Get-FreshWinPropertyValue -InputObject $Diagnostics -Name 'IsLive' -Default $false)
        Redacted      = $true
        Files         = @(
            [pscustomobject]@{ Path = 'diagnostics.json'; Sha256 = Get-FreshWinOperationFileSha256 -Path $diagnosticsPath },
            [pscustomobject]@{ Path = 'health-summary.json'; Sha256 = Get-FreshWinOperationFileSha256 -Path $healthPath }
        )
    }
    $manifestPath = Join-Path $outputPath 'manifest.json'
    [void](Write-FreshWinJsonFile -Path $manifestPath -Value $manifest -Depth 20 -Atomic)

    return [pscustomobject][ordered]@{
        Component         = 'DiagnosticsExport'
        Status            = 'Completed'
        Succeeded         = $true
        IsLive            = [bool](Get-FreshWinPropertyValue -InputObject $Diagnostics -Name 'IsLive' -Default $false)
        OutputPath        = $outputPath
        DiagnosticsPath   = $diagnosticsPath
        HealthSummaryPath = $healthPath
        ManifestPath      = $manifestPath
        Redacted          = $true
        MutationPerformed = $true
    }
}
