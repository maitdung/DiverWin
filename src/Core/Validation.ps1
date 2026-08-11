Set-StrictMode -Version Latest

function Get-FreshWinLocalizationLeafMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$InputObject,
        [string]$Prefix = ''
    )

    $result = @{}
    if ($null -eq $InputObject) { return $result }

    $properties = if ($InputObject -is [System.Collections.IDictionary]) {
        @($InputObject.Keys | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_; Value = $InputObject[$_] }
        })
    } else {
        @($InputObject.PSObject.Properties | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Value = $_.Value }
        })
    }

    foreach ($property in $properties) {
        $key = if ([string]::IsNullOrWhiteSpace($Prefix)) { $property.Name } else { "$Prefix.$($property.Name)" }
        $value = $property.Value
        if ($null -ne $value -and $value -isnot [string] -and $value -isnot [ValueType] -and
            ($value -is [System.Collections.IDictionary] -or @($value.PSObject.Properties).Count -gt 0)) {
            $nested = Get-FreshWinLocalizationLeafMap -InputObject $value -Prefix $key
            foreach ($nestedKey in $nested.Keys) { $result[$nestedKey] = $nested[$nestedKey] }
        }
        else {
            $result[$key] = $value
        }
    }
    return $result
}

function Get-FreshWinFormatPlaceholderSet {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return @() }
    return @([regex]::Matches($Text, '(?<!\{)\{(\d+)(?:,[^}:]+)?(?::[^}]+)?\}(?!\})') |
        ForEach-Object { [string]$_.Groups[1].Value } | Sort-Object -Unique)
}

function Test-FreshWinLocalizationResources {
    [CmdletBinding()]
    param(
        [string]$LocalesPath = (Get-FreshWinDefaultLocalesPath),
        [AllowNull()][object]$Catalog = $null
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $localeMaps = @{}
    $locales = @(Get-FreshWinSupportedLocale)

    foreach ($locale in $locales) {
        $path = Join-Path $LocalesPath "$locale.json"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $errors.Add("Locale file is missing: $path")
            continue
        }
        try {
            $localeData = Read-FreshWinJsonFile -Path $path
            $map = Get-FreshWinLocalizationLeafMap -InputObject $localeData
            if ($map.Count -eq 0) { $errors.Add("Locale '$locale' contains no strings.") }
            foreach ($key in $map.Keys) {
                if ($map[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$map[$key])) {
                    $errors.Add("Locale '$locale' key '$key' must contain a non-empty string.")
                }
            }
            $localeMaps[$locale] = $map
        }
        catch {
            $errors.Add("Locale '$locale' could not be read: $($_.Exception.Message)")
        }
    }

    if ($localeMaps.ContainsKey('en-US')) {
        $canonical = $localeMaps['en-US']
        foreach ($locale in $locales | Where-Object { $_ -ne 'en-US' -and $localeMaps.ContainsKey($_) }) {
            $map = $localeMaps[$locale]
            foreach ($key in $canonical.Keys) {
                if (-not $map.ContainsKey($key)) {
                    $errors.Add("Locale '$locale' is missing key '$key'.")
                    continue
                }
                $expectedPlaceholders = @(Get-FreshWinFormatPlaceholderSet -Text ([string]$canonical[$key]))
                $actualPlaceholders = @(Get-FreshWinFormatPlaceholderSet -Text ([string]$map[$key]))
                if (($expectedPlaceholders -join ',') -ne ($actualPlaceholders -join ',')) {
                    $errors.Add("Locale '$locale' key '$key' has different format placeholders than en-US.")
                }
            }
            foreach ($key in $map.Keys) {
                if (-not $canonical.ContainsKey($key)) { $errors.Add("Locale '$locale' has unknown key '$key'.") }
            }
        }

        if ($null -ne $Catalog) {
            foreach ($package in @($Catalog.Packages)) {
                $descriptionKey = [string](Get-FreshWinPropertyValue -InputObject $package -Name 'descriptionKey' -Default '')
                if (-not $canonical.ContainsKey($descriptionKey)) {
                    $errors.Add("Package '$($package.id)' references missing localization key '$descriptionKey'.")
                }
            }
        }
    }

    return [pscustomobject]@{
        IsValid   = $errors.Count -eq 0
        Errors    = $errors.ToArray()
        Warnings  = $warnings.ToArray()
        Locales   = $locales
        KeyCounts = [pscustomobject]@{ enUS = if ($localeMaps.ContainsKey('en-US')) { $localeMaps['en-US'].Count } else { 0 } }
    }
}

function Test-FreshWinCatalogIntegrity {
    [CmdletBinding()]
    param([string]$CatalogPath = (Join-Path (Get-FreshWinProjectRoot) 'catalog'))

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $catalog = Import-FreshWinPackageCatalog -Path $CatalogPath
    foreach ($catalogError in @($catalog.Errors)) { $errors.Add([string]$catalogError.Error) }

    $schemaPath = Join-Path $CatalogPath 'package.schema.json'
    $testJson = Get-Command -Name Test-Json -ErrorAction SilentlyContinue
    if ($null -ne $testJson -and (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        foreach ($manifestPath in @(Get-ChildItem -LiteralPath (Join-Path $CatalogPath 'apps') -Filter '*.json' -File | Sort-Object Name)) {
            try {
                $valid = Get-Content -LiteralPath $manifestPath.FullName -Raw -Encoding UTF8 -ErrorAction Stop |
                    Test-Json -SchemaFile $schemaPath -ErrorAction Stop
                if (-not $valid) { $errors.Add("JSON Schema rejected '$($manifestPath.Name)'.") }
            }
            catch { $errors.Add("JSON Schema rejected '$($manifestPath.Name)': $($_.Exception.Message)") }
        }
    }
    else {
        $warnings.Add('JSON Schema validation was skipped because Test-Json or package.schema.json is unavailable.')
    }

    $packages = @($catalog.Packages)
    foreach ($duplicate in @($packages | Group-Object { ([string]$_.descriptionKey).ToLowerInvariant() } | Where-Object Count -gt 1)) {
        $errors.Add("Duplicate description key '$($duplicate.Name)'.")
    }
    foreach ($package in $packages) {
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension([string]$package.ManifestPath)
        if ($fileName -ne [string]$package.id) { $errors.Add("Manifest filename '$fileName' does not match package id '$($package.id)'.") }
    }

    if ($null -ne (Get-Command -Name Expand-FreshWinKnownPath -ErrorAction SilentlyContinue)) {
        $fixtureRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $fixtureEnvironment = @{
            LOCALAPPDATA       = (Join-Path $fixtureRoot 'freshwin-local')
            APPDATA            = (Join-Path $fixtureRoot 'freshwin-roaming')
            PROGRAMFILES       = (Join-Path $fixtureRoot 'freshwin-program-files')
            'PROGRAMFILES(X86)' = (Join-Path $fixtureRoot 'freshwin-program-files-x86')
            PROGRAMDATA        = (Join-Path $fixtureRoot 'freshwin-program-data')
            SYSTEMROOT         = (Join-Path $fixtureRoot 'freshwin-windows')
            WINDIR             = (Join-Path $fixtureRoot 'freshwin-windows')
            SYSTEMDRIVE        = [System.IO.Path]::GetPathRoot($fixtureRoot)
            USERPROFILE        = (Join-Path $fixtureRoot 'freshwin-user')
        }
        foreach ($package in $packages) {
            $detection = Get-FreshWinPropertyValue -InputObject $package -Name 'detection' -Default $null
            foreach ($knownPath in @(Get-FreshWinPropertyValue -InputObject $detection -Name 'knownPaths' -Default @())) {
                if ($null -eq (Expand-FreshWinKnownPath -Path ([string]$knownPath) -Environment $fixtureEnvironment)) {
                    $errors.Add("Package '$($package.id)' contains an unsafe or unusable known path '$knownPath'.")
                }
            }
        }
    }

    # Resolving every package exercises missing dependencies and cycle detection without executing installers.
    if ($packages.Count -gt 0) {
        try { [void](Resolve-FreshWinPlanPackageIds -PackageIds @($packages.id) -Catalog $catalog) }
        catch { $errors.Add($_.Exception.Message) }
    }

    return [pscustomobject]@{
        IsValid      = $errors.Count -eq 0
        Errors       = $errors.ToArray()
        Warnings     = $warnings.ToArray()
        PackageCount = $packages.Count
        Catalog      = $catalog
    }
}

function Test-FreshWinProfiles {
    [CmdletBinding()]
    param(
        [string]$ProfilesPath = (Join-Path (Get-FreshWinProjectRoot) 'profiles'),
        [Parameter(Mandatory = $true)][object]$Catalog
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $profiles = Import-FreshWinProfiles -Path $ProfilesPath -Catalog $Catalog
    foreach ($profileError in @($profiles.Errors)) { $errors.Add([string]$profileError.Error) }
    try {
        $english = Read-FreshWinJsonFile -Path (Join-Path (Split-Path -Parent $ProfilesPath) 'locales/en-US.json')
        $englishKeys = Get-FreshWinLocalizationLeafMap -InputObject $english
        foreach ($profile in @($profiles.Profiles)) {
            foreach ($keyName in @('nameKey', 'descriptionKey')) {
                $key = [string](Get-FreshWinPropertyValue -InputObject $profile -Name $keyName -Default '')
                if (-not $englishKeys.ContainsKey($key)) { $errors.Add("Profile '$($profile.id)' references missing localization key '$key'.") }
            }
        }
    }
    catch { $errors.Add("Profile localization validation failed: $($_.Exception.Message)") }
    foreach ($requiredId in @('essential', 'work', 'gaming', 'developer', 'full-recommended')) {
        if ($null -eq (Get-FreshWinProfile -Profiles $profiles -Id $requiredId)) {
            $errors.Add("Required profile '$requiredId' is missing.")
        }
    }
    return [pscustomobject]@{
        IsValid      = $errors.Count -eq 0
        Errors       = $errors.ToArray()
        ProfileCount = @($profiles.Profiles).Count
        Profiles     = $profiles
    }
}

function Test-FreshWinProject {
    [CmdletBinding()]
    param(
        [string]$ProjectRoot = (Get-FreshWinProjectRoot),
        [switch]$ThrowOnError
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $moduleManifestPath = Join-Path $ProjectRoot 'FreshWin.psd1'
    try {
        $moduleManifest = Test-ModuleManifest -Path $moduleManifestPath -ErrorAction Stop
        if ([string]$moduleManifest.Version -ne (Get-FreshWinVersion)) {
            $errors.Add("Module version '$($moduleManifest.Version)' does not match runtime version '$(Get-FreshWinVersion)'.")
        }
    }
    catch { $errors.Add("Module manifest is invalid: $($_.Exception.Message)") }

    $sourcePaths = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -ErrorAction Stop |
        Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') -and $_.FullName -notmatch '[\\/]\.git[\\/]' })
    foreach ($sourcePath in $sourcePaths) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($sourcePath.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($parseError in @($parseErrors)) {
            $relativePath = $sourcePath.FullName.Substring([System.IO.Path]::GetFullPath($ProjectRoot).Length).TrimStart([char[]]'\/')
            $errors.Add("PowerShell parse error in ${relativePath}:$($parseError.Extent.StartLineNumber): $($parseError.Message)")
        }
    }

    $catalogResult = Test-FreshWinCatalogIntegrity -CatalogPath (Join-Path $ProjectRoot 'catalog')
    foreach ($entry in @($catalogResult.Errors)) { $errors.Add([string]$entry) }
    foreach ($entry in @($catalogResult.Warnings)) { $warnings.Add([string]$entry) }

    $localizationResult = Test-FreshWinLocalizationResources -LocalesPath (Join-Path $ProjectRoot 'locales') -Catalog $catalogResult.Catalog
    foreach ($entry in @($localizationResult.Errors)) { $errors.Add([string]$entry) }
    foreach ($entry in @($localizationResult.Warnings)) { $warnings.Add([string]$entry) }

    $profilesResult = Test-FreshWinProfiles -ProfilesPath (Join-Path $ProjectRoot 'profiles') -Catalog $catalogResult.Catalog
    foreach ($entry in @($profilesResult.Errors)) { $errors.Add([string]$entry) }

    $result = [pscustomobject]@{
        IsValid      = $errors.Count -eq 0
        Errors       = $errors.ToArray()
        Warnings     = $warnings.ToArray()
        PackageCount = $catalogResult.PackageCount
        ProfileCount = $profilesResult.ProfileCount
        LocaleCount  = @($localizationResult.Locales).Count
    }
    if ($ThrowOnError -and -not $result.IsValid) { throw ($result.Errors -join [Environment]::NewLine) }
    return $result
}
