Set-StrictMode -Version 2.0

function ConvertTo-FreshWinArchitectureToken {
    [CmdletBinding()]
    param([AllowNull()][object]$Architecture)

    $value = ([string]$Architecture).Trim().ToLowerInvariant()
    switch -Regex ($value) {
        '^(amd64|x86_64|x64)$' { return 'x64' }
        '^(arm64|aarch64)$' { return 'arm64' }
        '^(x86|i[3-6]86)$' { return 'x86' }
        default { return $value }
    }
}

function ConvertTo-FreshWinOsToken {
    [CmdletBinding()]
    param([AllowNull()][object]$SystemInfo)

    $family = [string](Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'OSFamily' -Default '')
    if ($family -match '(?i)windows\s*11|windows11') { return 'windows11' }
    if ($family -match '(?i)windows\s*10|windows10') { return 'windows10' }

    $name = [string](Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'OSName' -Default '')
    if ($name -match '(?i)windows\s*11') { return 'windows11' }
    if ($name -match '(?i)windows\s*10') { return 'windows10' }

    $build = 0
    [void][int]::TryParse([string](Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'BuildNumber' -Default 0), [ref]$build)
    if ($build -ge 22000) { return 'windows11' }
    if ($build -ge 10240) { return 'windows10' }
    return 'unknown'
}

function Get-FreshWinGpuVendors {
    [CmdletBinding()]
    param([AllowNull()][object]$SystemInfo)

    $values = New-Object System.Collections.Generic.List[string]
    $gpus = @(Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'GPUs' -Default @())
    if ($gpus.Count -eq 0) {
        $singleGpu = Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'GPU' -Default $null
        if ($null -ne $singleGpu) { $gpus = @($singleGpu) }
    }

    foreach ($gpu in $gpus) {
        $name = if ($gpu -is [string]) { $gpu } else {
            [string](Get-FreshWinPropertyValue -InputObject $gpu -Name 'Name' -Default (Get-FreshWinPropertyValue -InputObject $gpu -Name 'Model' -Default ''))
        }
        if ($name -match '(?i)nvidia|geforce|quadro') { $values.Add('nvidia'); continue }
        if ($name -match '(?i)amd|radeon') { $values.Add('amd'); continue }
        if ($name -match '(?i)intel|arc|iris|uhd graphics') { $values.Add('intel'); continue }
    }

    return @($values | Select-Object -Unique)
}

function Test-FreshWinFeatureState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Feature,
        [AllowNull()][object]$SystemInfo
    )

    switch ($Feature.ToLowerInvariant()) {
        'virtualization' {
            return Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'VirtualizationEnabled' -Default $null
        }
        'internet' {
            return Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'InternetAvailable' -Default $null
        }
        'tpm2' {
            $tpm = Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'TPM' -Default $null
            return [bool](Get-FreshWinPropertyValue -InputObject $tpm -Name 'Present' -Default $false)
        }
        'wsl' {
            return Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'WslAvailable' -Default $null
        }
        'microsoftstore' {
            return Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'MicrosoftStoreAvailable' -Default $null
        }
        default { return $null }
    }
}

function Get-FreshWinRequiredFeatures {
    [CmdletBinding()]
    param([AllowNull()][object]$Features)

    if ($null -eq $Features) { return @() }
    if ($Features -is [System.Collections.IDictionary]) {
        return @($Features.Keys | Where-Object { [bool]$Features[$_] } | ForEach-Object { [string]$_ })
    }

    $properties = @($Features.PSObject.Properties)
    if ($properties.Count -gt 0 -and $Features -isnot [string]) {
        return @($properties | Where-Object { [bool]$_.Value } | ForEach-Object { [string]$_.Name })
    }
    return @($Features | ForEach-Object { [string]$_ })
}

function Get-FreshWinPackageCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [Parameter(Mandatory = $true)][object]$SystemInfo,
        [string[]]$ProvisionableFeatures = @()
    )

    $blocking = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $notApplicable = New-Object System.Collections.Generic.List[string]
    $compatibility = Get-FreshWinPropertyValue -InputObject $Package -Name 'compatibility' -Default ([pscustomobject]@{})

    $isSupported = [bool](Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'IsSupported' -Default $true)
    if (-not $isSupported) {
        $blocking.Add('FreshWin only supports Windows 10 and Windows 11.')
    }

    $os = ConvertTo-FreshWinOsToken -SystemInfo $SystemInfo
    $allowedOs = @((Get-FreshWinPropertyValue -InputObject $compatibility -Name 'os' -Default @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ($allowedOs.Count -gt 0 -and $allowedOs -notcontains $os) {
        $blocking.Add("This package does not support $os.")
    }

    $architecture = ConvertTo-FreshWinArchitectureToken (Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'Architecture' -Default '')
    $allowedArchitectures = @((Get-FreshWinPropertyValue -InputObject $compatibility -Name 'architectures' -Default @()) | ForEach-Object { ConvertTo-FreshWinArchitectureToken $_ })
    if ($allowedArchitectures.Count -gt 0 -and $allowedArchitectures -notcontains $architecture) {
        $blocking.Add("Architecture $architecture is not supported.")
    }

    $build = 0
    [void][int]::TryParse([string](Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'BuildNumber' -Default 0), [ref]$build)
    $minimumBuild = 0
    [void][int]::TryParse([string](Get-FreshWinPropertyValue -InputObject $compatibility -Name 'minimumBuild' -Default 0), [ref]$minimumBuild)
    if ($minimumBuild -gt 0 -and $build -lt $minimumBuild) {
        $blocking.Add("Windows build $minimumBuild or newer is required.")
    }

    $memory = 0.0
    [void][double]::TryParse([string](Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'MemoryGB' -Default 0), [ref]$memory)
    $minimumRam = 0.0
    [void][double]::TryParse([string](Get-FreshWinPropertyValue -InputObject $compatibility -Name 'minimumRamGB' -Default 0), [ref]$minimumRam)
    if ($minimumRam -gt 0 -and $memory -gt 0 -and $memory -lt $minimumRam) {
        $warnings.Add("$minimumRam GB RAM is recommended; this PC reports $memory GB.")
    }

    $hardware = Get-FreshWinPropertyValue -InputObject $compatibility -Name 'hardware' -Default $null
    if ($null -ne $hardware) {
        $requiredGpuVendors = @((Get-FreshWinPropertyValue -InputObject $hardware -Name 'gpuVendors' -Default @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
        if ($requiredGpuVendors.Count -gt 0) {
            $actualGpuVendors = @(Get-FreshWinGpuVendors -SystemInfo $SystemInfo)
            if (@($requiredGpuVendors | Where-Object { $actualGpuVendors -contains $_ }).Count -eq 0) {
                $notApplicable.Add("Requires a $($requiredGpuVendors -join '/') GPU.")
            }
        }

        $manufacturers = @((Get-FreshWinPropertyValue -InputObject $hardware -Name 'oemVendors' -Default (Get-FreshWinPropertyValue -InputObject $hardware -Name 'manufacturers' -Default @())) | ForEach-Object { ([string]$_).ToLowerInvariant() })
        if ($manufacturers.Count -gt 0) {
            $manufacturer = ([string](Get-FreshWinPropertyValue -InputObject $SystemInfo -Name 'Manufacturer' -Default '')).ToLowerInvariant()
            if (@($manufacturers | Where-Object { $manufacturer.Contains($_) }).Count -eq 0) {
                $notApplicable.Add('This package is intended for different hardware or an OEM family.')
            }
        }
    }

    $features = @(Get-FreshWinRequiredFeatures -Features (Get-FreshWinPropertyValue -InputObject $compatibility -Name 'features' -Default $null))
    foreach ($feature in $features) {
        $featureState = Test-FreshWinFeatureState -Feature ([string]$feature) -SystemInfo $SystemInfo
        if ($featureState -eq $false -and $ProvisionableFeatures -icontains [string]$feature) {
            $warnings.Add("Required feature '$feature' is expected from a reviewed dependency and will be rechecked before execution.")
        }
        elseif ($featureState -eq $false) {
            if (([string]$feature) -ieq 'virtualization') {
                $blocking.Add('Hardware virtualization must be enabled before this package can be used.')
            }
            elseif (([string]$feature) -ieq 'internet') {
                $blocking.Add('An internet connection is required for automatic installation.')
            }
            else {
                $blocking.Add("Required feature '$feature' is unavailable.")
            }
        }
        elseif ($null -eq $featureState) {
            $warnings.Add("Required feature '$feature' could not be verified.")
        }
    }

    $status = 'Compatible'
    if ($notApplicable.Count -gt 0) { $status = 'NotApplicable' }
    elseif ($blocking.Count -gt 0) { $status = 'Blocked' }
    elseif ($warnings.Count -gt 0) { $status = 'Warning' }

    return [pscustomobject]@{
        PackageId              = [string]$Package.id
        Status                 = $status
        IsApplicable           = ($notApplicable.Count -eq 0)
        IsTechnicallyCompatible = ($blocking.Count -eq 0 -and $notApplicable.Count -eq 0)
        OverrideAllowed        = ($warnings.Count -gt 0 -and $blocking.Count -eq 0 -and $notApplicable.Count -eq 0)
        ProvisionableFeatures  = @($ProvisionableFeatures)
        BlockingReasons        = $blocking.ToArray()
        Warnings               = $warnings.ToArray()
        NotApplicableReasons   = $notApplicable.ToArray()
        Reasons                = $notApplicable.ToArray() + $blocking.ToArray() + $warnings.ToArray()
    }
}
