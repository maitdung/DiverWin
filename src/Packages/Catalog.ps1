Set-StrictMode -Version 2.0

function Get-FreshWinProjectRoot {
    [CmdletBinding()]
    param()

    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Test-FreshWinPackageRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [string]$Path = '<memory>'
    )

    if ($null -ne (Get-Command -Name Test-FreshWinPackageManifest -ErrorAction SilentlyContinue)) {
        $validation = Test-FreshWinPackageManifest -Manifest $Manifest -SourcePath $Path
        return [pscustomobject]@{
            Path     = $Path
            Id       = $validation.PackageId
            Valid    = $validation.IsValid
            IsValid  = $validation.IsValid
            Errors   = @($validation.Errors)
            Warnings = @($validation.Warnings)
        }
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $required = @(
        'schemaVersion', 'id', 'name', 'descriptionKey', 'category',
        'subcategory', 'publisher', 'officialWebsite', 'source',
        'compatibility', 'detection', 'install', 'verification',
        'restart', 'riskLevel', 'license'
    )

    foreach ($field in $required) {
        if ($null -eq $Manifest.PSObject.Properties[$field]) {
            $errors.Add("Missing required field '$field'.")
        }
    }

    $id = [string](Get-FreshWinPropertyValue -InputObject $Manifest -Name 'id' -Default '')
    if ($id -notmatch '^[a-z0-9][a-z0-9._-]{1,79}$') {
        $errors.Add("Package id '$id' is invalid.")
    }

    $website = [string](Get-FreshWinPropertyValue -InputObject $Manifest -Name 'officialWebsite' -Default '')
    if ($website -notmatch '^https://') {
        $errors.Add('officialWebsite must use HTTPS.')
    }

    $source = Get-FreshWinPropertyValue -InputObject $Manifest -Name 'source'
    $sourceType = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'type' -Default '')
    $allowedSourceTypes = @('winget', 'manual', 'official', 'windows-feature', 'msstore')
    if ($allowedSourceTypes -notcontains $sourceType) {
        $errors.Add("Source type '$sourceType' is not allowed.")
    }

    if ($sourceType -eq 'winget') {
        $packageId = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'packageId' -Default '')
        if ($packageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{1,255}$') {
            $errors.Add("WinGet packageId '$packageId' is invalid.")
        }
    }

    if ($sourceType -in @('manual', 'official')) {
        $manualUrl = [string](Get-FreshWinPropertyValue -InputObject $source -Name 'manualUrl' -Default $website)
        if ($manualUrl -notmatch '^https://') {
            $errors.Add('Manual/official workflows require an HTTPS URL.')
        }
    }

    $compatibility = Get-FreshWinPropertyValue -InputObject $Manifest -Name 'compatibility'
    $architectures = @(Get-FreshWinPropertyValue -InputObject $compatibility -Name 'architectures' -Default @())
    foreach ($architecture in $architectures) {
        if (@('x86', 'x64', 'arm64') -notcontains ([string]$architecture).ToLowerInvariant()) {
            $errors.Add("Unsupported architecture token '$architecture'.")
        }
    }

    $operatingSystems = @(Get-FreshWinPropertyValue -InputObject $compatibility -Name 'os' -Default @())
    foreach ($operatingSystem in $operatingSystems) {
        if (@('windows10', 'windows11') -notcontains ([string]$operatingSystem).ToLowerInvariant()) {
            $errors.Add("Unsupported operating system token '$operatingSystem'.")
        }
    }

    $risk = [string](Get-FreshWinPropertyValue -InputObject $Manifest -Name 'riskLevel' -Default '')
    if (@('SAFE', 'SYSTEM', 'ADVANCED') -notcontains $risk.ToUpperInvariant()) {
        $errors.Add("Risk level '$risk' is invalid.")
    }

    $forbiddenFields = @('command', 'script', 'shell', 'powershell', 'invokeExpression', 'downloadAndRun')
    foreach ($field in $forbiddenFields) {
        if ($null -ne $Manifest.PSObject.Properties[$field]) {
            $errors.Add("Executable manifest field '$field' is forbidden.")
        }
    }

    return [pscustomobject]@{
        Path     = $Path
        Id       = $id
        Valid    = ($errors.Count -eq 0)
        IsValid  = ($errors.Count -eq 0)
        Errors   = $errors.ToArray()
        Warnings = @()
    }
}

function ConvertTo-FreshWinPackageRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$ManifestPath
    )

    $Manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $ManifestPath -Force
    $Manifest | Add-Member -NotePropertyName CatalogStatus -NotePropertyValue 'Valid' -Force
    return $Manifest
}

function Import-FreshWinPackageCatalog {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path (Get-FreshWinProjectRoot) 'catalog')
    )

    $packages = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{
            Path     = $Path
            Packages = @()
            Errors   = @([pscustomobject]@{ Path = $Path; Error = 'Catalog directory was not found.' })
            LoadedAt = [DateTimeOffset]::UtcNow
        }
    }

    $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '(?i)(^schema\.json$|\.schema\.json$)' } |
        Sort-Object FullName)

    foreach ($file in $files) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            $parsed = ConvertFrom-Json -InputObject $content -ErrorAction Stop
            $records = if ($parsed -is [System.Array]) { @($parsed) } else { @($parsed) }

            foreach ($record in $records) {
                $validation = Test-FreshWinPackageRecord -Manifest $record -Path $file.FullName
                if (-not $validation.Valid) {
                    $errors.Add([pscustomobject]@{
                        Path   = $file.FullName
                        Id     = $validation.Id
                        Error  = ($validation.Errors -join ' ')
                    })
                    continue
                }

                $packages.Add((ConvertTo-FreshWinPackageRecord -Manifest $record -ManifestPath $file.FullName))
            }
        }
        catch {
            $errors.Add([pscustomobject]@{
                Path  = $file.FullName
                Id    = $null
                Error = $_.Exception.Message
            })
        }
    }

    $duplicateGroups = @($packages | Group-Object id | Where-Object Count -gt 1)
    foreach ($group in $duplicateGroups) {
        $errors.Add([pscustomobject]@{
            Path  = $Path
            Id    = $group.Name
            Error = "Duplicate package id '$($group.Name)' was isolated."
        })
    }
    if ($duplicateGroups.Count -gt 0) {
        $duplicates = @($duplicateGroups | ForEach-Object { $_.Name })
        $packages = @($packages | Where-Object { $duplicates -notcontains $_.id })
    }

    $knownIds = @($packages | ForEach-Object { ([string]$_.id).ToLowerInvariant() })
    $invalidDependencyIds = @()
    foreach ($package in $packages) {
        foreach ($dependency in @(Get-FreshWinPropertyValue -InputObject $package -Name 'dependencies' -Default @())) {
            $dependencyId = ([string]$dependency).ToLowerInvariant()
            if ($knownIds -notcontains $dependencyId) {
                $errors.Add([pscustomobject]@{
                    Path  = [string]$package.ManifestPath
                    Id    = [string]$package.id
                    Error = "Package '$($package.id)' references missing dependency '$dependencyId'."
                })
                $invalidDependencyIds += [string]$package.id
            }
        }
    }
    if ($invalidDependencyIds.Count -gt 0) {
        $packages = @($packages | Where-Object { $invalidDependencyIds -notcontains [string]$_.id })
    }

    return [pscustomobject]@{
        Path     = $Path
        Packages = if ($packages -is [System.Array]) { $packages } else { $packages.ToArray() }
        Errors   = $errors.ToArray()
        LoadedAt = [DateTimeOffset]::UtcNow
        IsValid  = $errors.Count -eq 0
    }
}

function Get-FreshWinPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Catalog,

        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    return @($Catalog.Packages | Where-Object { ([string]$_.id) -ieq $Id }) | Select-Object -First 1
}

function Find-FreshWinPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Catalog,

        [string]$Query,

        [string[]]$Category,

        [string[]]$Subcategory
    )

    if ($null -ne $Query) {
        if ($Query.Length -gt 128) {
            throw 'Package search text must not exceed 128 characters.'
        }
        foreach ($character in $Query.ToCharArray()) {
            if ([char]::IsControl($character)) {
                throw 'Package search text must not contain control characters.'
            }
        }
    }

    $results = @($Catalog.Packages)

    if ($Category -and $Category.Count -gt 0) {
        $results = @($results | Where-Object { $Category -icontains ([string]$_.category) })
    }
    if ($Subcategory -and $Subcategory.Count -gt 0) {
        $results = @($results | Where-Object { $Subcategory -icontains ([string]$_.subcategory) })
    }
    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        $needle = $Query.Trim().ToLowerInvariant()
        $results = @($results | Where-Object {
            $haystack = @(
                [string]$_.id,
                [string]$_.name,
                [string]$_.publisher,
                [string]$_.category,
                [string]$_.subcategory,
                (@(Get-FreshWinPropertyValue -InputObject $_ -Name 'tags' -Default @()) -join ' ')
            ) -join ' '
            $haystack.ToLowerInvariant().Contains($needle)
        })
    }

    return @($results | Sort-Object category, subcategory, name)
}
