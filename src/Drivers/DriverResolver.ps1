function Resolve-FreshWinOemVendor {
    [CmdletBinding()]
    param([AllowNull()][string]$Manufacturer)

    if ([string]::IsNullOrWhiteSpace($Manufacturer)) { return 'Unknown' }
    switch -Regex ($Manufacturer.Trim()) {
        '(?i)^Dell|Dell Inc' { return 'Dell' }
        '(?i)(HP|Hewlett[ -]?Packard)' { return 'HP' }
        '(?i)Lenovo' { return 'Lenovo' }
        '(?i)(ASUS|ASUSTeK)' { return 'ASUS' }
        '(?i)(Micro-Star|^MSI)' { return 'MSI' }
        '(?i)Acer' { return 'Acer' }
        '(?i)(Gigabyte|To Be Filled|System manufacturer|Default string)' { return 'CustomOrUnknown' }
        default { return 'Other' }
    }
}

function Get-FreshWinOemSupportAction {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Manufacturer,
        [AllowNull()][string]$Model
    )

    $vendor = Resolve-FreshWinOemVendor -Manufacturer $Manufacturer
    $supportUri = switch ($vendor) {
        'Dell' { 'https://www.dell.com/support/home' }
        'HP' { 'https://support.hp.com/drivers' }
        'Lenovo' { 'https://pcsupport.lenovo.com/' }
        'ASUS' { 'https://www.asus.com/support/download-center/' }
        'MSI' { 'https://www.msi.com/support/download' }
        'Acer' { 'https://www.acer.com/support/drivers-and-manuals' }
        default { $null }
    }
    return [pscustomobject][ordered]@{
        Manufacturer       = $Manufacturer
        NormalizedVendor   = $vendor
        Model              = $Model
        IsRecognizedOem    = $vendor -in @('Dell', 'HP', 'Lenovo', 'ASUS', 'MSI', 'Acer')
        Resolution         = $(if ($null -ne $supportUri) { 'ManualOfficial' } else { 'IdentifyManufacturer' })
        OfficialSupportUri = $supportUri
        AutoDownload       = $false
        Reason             = $(if ($null -ne $supportUri) { 'Use the OEM support page to preserve model-specific driver customizations.' } else { 'FreshWin cannot safely resolve an OEM-specific source for this manufacturer.' })
    }
}

function Get-FreshWinGpuDriverRecommendation {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$GPUs,
        [AllowNull()][string]$Manufacturer,
        [AllowNull()][string]$Model,
        [AllowNull()][object[]]$DriverInventory
    )

    if (-not $PSBoundParameters.ContainsKey('GPUs')) {
        $hardware = Get-FreshWinHardwareInfo
        if ($hardware.Status -eq 'Unsupported') { return @($hardware) }
        $GPUs = @($hardware.GPUs)
        $Manufacturer = [string]$hardware.Manufacturer
        $Model = [string]$hardware.Model
    }
    $oem = Get-FreshWinOemSupportAction -Manufacturer $Manufacturer -Model $Model
    $recommendations = @()
    foreach ($gpu in @($GPUs)) {
        if ($null -eq $gpu) { continue }
        $name = [string](Get-FreshWinObjectProperty -InputObject $gpu -Name @('Name') -Default 'Unknown GPU')
        $instanceId = [string](Get-FreshWinObjectProperty -InputObject $gpu -Name @('PnpDeviceId', 'InstanceId', 'PNPDeviceID'))
        $vendor = [string](Get-FreshWinObjectProperty -InputObject $gpu -Name @('Vendor') -Default (Resolve-FreshWinGpuVendor -Name $name -PnpDeviceId $instanceId -AdapterCompatibility ([string]$gpu.AdapterCompatibility)))
        $driverRecord = @($DriverInventory | Where-Object { $_.InstanceId -eq $instanceId -or ($_.Category -eq 'Graphics' -and $_.Name -eq $name) } | Select-Object -First 1)
        $health = if ($driverRecord.Count -gt 0) { $driverRecord[0].Health } else { [string](Get-FreshWinObjectProperty -InputObject $gpu -Name @('Status') -Default 'Unknown') }
        $driverVersion = Get-FreshWinObjectProperty -InputObject $gpu -Name @('DriverVersion') -Default $(if ($driverRecord.Count -gt 0) { $driverRecord[0].DriverVersion } else { $null })
        $officialUri = switch ($vendor) {
            'NVIDIA' { 'https://www.nvidia.com/Download/index.aspx' }
            'AMD' { 'https://www.amd.com/en/support/download/drivers.html' }
            'Intel' { 'https://www.intel.com/content/www/us/en/support/detect.html' }
            default { $null }
        }
        $needsAttention = $health -match '(?i)(Missing|Problem|Error|Degraded)' -or [string]::IsNullOrWhiteSpace([string]$driverVersion)
        $resolution = 'None'
        $priority = 'Healthy'
        $reason = 'A graphics driver is present and no problem is reported; FreshWin will not replace it automatically.'
        if ($null -eq $officialUri) {
            $resolution = 'ManualIdentification'
            $priority = 'Unknown'
            $reason = 'The GPU vendor could not be mapped to a verified official workflow.'
        }
        elseif ($needsAttention) {
            $resolution = $(if ($oem.IsRecognizedOem) { 'ManualOfficialOemFirst' } else { 'ManualOfficialVendor' })
            $priority = 'Required'
            $reason = $(if ($oem.IsRecognizedOem) { 'The graphics device needs attention. Check the OEM model-specific package before a generic vendor driver.' } else { 'The graphics device needs attention; use the verified vendor workflow.' })
        }
        $recommendations += [pscustomobject][ordered]@{
            GPU                 = $name
            Vendor              = $vendor
            InstanceId          = $instanceId
            CurrentDriver       = $driverVersion
            Health              = $health
            Priority            = $priority
            Recommended         = $needsAttention -and $null -ne $officialUri
            Resolution          = $resolution
            OfficialVendorUri   = $officialUri
            OemSupport          = $oem
            AutoInstall         = $false
            Reason              = $reason
        }
    }
    return $recommendations
}

function Get-FreshWinDduWorkflow {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$GPUs,
        [switch]$AcknowledgeAdvancedRisk
    )

    if (-not $PSBoundParameters.ContainsKey('GPUs')) {
        $hardware = Get-FreshWinHardwareInfo
        $GPUs = @($hardware.GPUs)
    }
    return [pscustomobject][ordered]@{
        Name                = 'Display Driver Uninstaller'
        SafetyLevel         = 'ADVANCED'
        IncludedInQuickSetup = $false
        Acknowledged        = [bool]$AcknowledgeAdvancedRisk
        Status              = $(if ($AcknowledgeAdvancedRisk) { 'PlanOnly' } else { 'BlockedPendingAcknowledgement' })
        DetectedGPUs        = @($GPUs)
        OfficialGuidanceUri = 'https://www.wagnardsoft.com/'
        AutomaticDownload  = $false
        AutomaticExecution = $false
        Steps               = @(
            'Resolve and prepare the correct replacement driver from an official OEM or GPU-vendor source.',
            'Create a restore point or other safety checkpoint.',
            'Review DDU instructions and Safe Mode guidance.',
            'Run DDU only after explicit advanced confirmation.',
            'Restart Windows, install the prepared driver, and verify device health.'
        )
        Warning             = 'DDU is for graphics-driver repair, not routine updates. FreshWin does not download or execute it automatically.'
    }
}
