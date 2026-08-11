Set-StrictMode -Version 2.0

function Test-FreshWinRecommendationMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [Parameter(Mandatory = $true)][string]$ProfileId
    )

    $metadata = Get-FreshWinPropertyValue -InputObject $Package -Name 'recommendation' -Default $null
    if ($null -eq $metadata) { return $false }

    $profiles = @((Get-FreshWinPropertyValue -InputObject $metadata -Name 'profiles' -Default @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $default = [bool](Get-FreshWinPropertyValue -InputObject $metadata -Name 'default' -Default $false)
    $profile = $ProfileId.ToLowerInvariant()
    if ($profile -eq 'full-recommended') { return ($default -or $profiles.Count -gt 0) }
    if ($profile -eq 'essential') { return ($default -or $profiles -contains 'essential') }
    return ($profiles -contains $profile)
}

function Get-FreshWinRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][object]$SystemInfo,
        [AllowNull()][object]$Inventory,
        [string]$ProfileId = 'essential',
        [AllowNull()][object]$Profiles
    )

    $profilePackageIds = @()
    if ($null -ne $Profiles) {
        $profile = Get-FreshWinProfile -Profiles $Profiles -Id $ProfileId
        if ($null -ne $profile) { $profilePackageIds = @(Get-FreshWinPropertyValue -InputObject $profile -Name 'NormalizedPackageIds' -Default (Get-FreshWinPropertyValue -InputObject $profile -Name 'packageIds' -Default @())) }
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($Catalog.Packages)) {
        $recommendedByProfile = if ($profilePackageIds.Count -gt 0) {
            $profilePackageIds -icontains ([string]$package.id)
        } else {
            Test-FreshWinRecommendationMetadata -Package $package -ProfileId $ProfileId
        }
        if (-not $recommendedByProfile) { continue }

        $compatibility = Get-FreshWinPackageCompatibility -Package $package -SystemInfo $SystemInfo
        $detection = Get-FreshWinPackageDetection -Package $package -Inventory $Inventory -Compatibility $compatibility
        $selected = $compatibility.IsTechnicallyCompatible -and $detection.State -in @('NotInstalled', 'Broken')
        $reason = switch ([string]$detection.State) {
            'Installed' { 'Already installed and ready.' }
            'UpdateAvailable' { 'An update is available; it is not selected by the missing-only policy.' }
            'NotInstalled' { 'Recommended for this profile and missing.' }
            'Broken' { 'Recommended software needs repair.' }
            'NotCompatible' { ($compatibility.Reasons -join ' ') }
            default { 'Installed state could not be determined.' }
        }
        $items.Add([pscustomobject]@{
            Package       = $package
            PackageId     = [string]$package.id
            Compatibility = $compatibility
            Detection     = $detection
            Recommended   = $true
            Selected      = $selected
            Reason        = $reason
        })
    }

    return @($items.ToArray() | Sort-Object { [string]$_.Package.category }, { [string]$_.Package.name })
}

function Get-FreshWinMissingRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Recommendations,
        [switch]$IncludeUpdates
    )

    $states = @('NotInstalled', 'Broken')
    if ($IncludeUpdates) { $states += 'UpdateAvailable' }
    return @($Recommendations | Where-Object {
        $_.Compatibility.IsTechnicallyCompatible -and $states -contains ([string]$_.Detection.State)
    })
}
