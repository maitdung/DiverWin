function Get-FreshWinTestJsonFiles {
    return @(Get-ChildItem (Join-Path $script:FreshWinTestContext.ProjectRoot 'catalog/apps') -Filter '*.json' -File | Sort-Object Name)
}

function Get-FreshWinTestCatalogRecords {
    return @(Get-FreshWinTestJsonFiles | ForEach-Object {
        Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    })
}

function Get-FreshWinTestLeafMap {
    param([AllowNull()][object]$Value, [string]$Prefix = '')
    $map = [ordered]@{}
    if ($null -eq $Value) { return $map }
    $properties = @($Value.PSObject.Properties)
    foreach ($property in $properties) {
        $key = if ($Prefix) { "$Prefix.$($property.Name)" } else { $property.Name }
        $nestedProperties = @(if ($null -eq $property.Value -or $property.Value -is [string] -or $property.Value -is [ValueType]) {
            @()
        } else { @($property.Value.PSObject.Properties) })
        if ($nestedProperties.Count -gt 0) {
            $nested = Get-FreshWinTestLeafMap -Value $property.Value -Prefix $key
            foreach ($nestedKey in $nested.Keys) { $map[$nestedKey] = $nested[$nestedKey] }
        }
        else { $map[$key] = $property.Value }
    }
    return $map
}

function Find-FreshWinTestForbiddenManifestProperty {
    param([AllowNull()][object]$Value, [string]$Path = '$', [int]$Depth = 0)
    if ($null -eq $Value -or $Depth -gt 30 -or $Value -is [string] -or $Value -is [ValueType]) { return @() }
    $forbidden = @('command', 'commandline', 'script', 'powershell', 'shell', 'invokeexpression', 'downloadandrun', 'arguments', 'executable')
    $findings = @()
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) {
        $index = 0
        foreach ($item in $Value) {
            $findings += @(Find-FreshWinTestForbiddenManifestProperty -Value $item -Path "$Path[$index]" -Depth ($Depth + 1))
            $index++
        }
        return $findings
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        $propertyPath = "$Path.$($property.Name)"
        if ($forbidden -contains $property.Name.ToLowerInvariant()) { $findings += $propertyPath }
        $findings += @(Find-FreshWinTestForbiddenManifestProperty -Value $property.Value -Path $propertyPath -Depth ($Depth + 1))
    }
    return $findings
}

Add-FreshWinTest -Name 'Catalog and schema files contain valid JSON' -Category 'Catalog' -ScriptBlock {
    $files = @(Get-FreshWinTestJsonFiles) + @(Get-Item (Join-Path $script:FreshWinTestContext.ProjectRoot 'catalog/package.schema.json'))
    $failures = @()
    foreach ($file in $files) {
        try { $null = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
        catch { $failures += "$($file.Name): $($_.Exception.Message)" }
    }
    Assert-FreshWinCount 0 $failures ($failures -join '; ')
}

Add-FreshWinTest -Name 'Every package satisfies the canonical JSON schema' -Category 'Catalog' -ScriptBlock {
    $schemaPath = Join-Path $script:FreshWinTestContext.ProjectRoot 'catalog/package.schema.json'
    $testJson = Get-Command Test-Json -ErrorAction SilentlyContinue
    if ($null -eq $testJson -or -not $testJson.Parameters.ContainsKey('SchemaFile')) {
        Skip-FreshWinTest 'this PowerShell host has no JSON Schema validator; runtime semantic validation still runs separately'
    }
    $failures = @()
    foreach ($file in Get-FreshWinTestJsonFiles) {
        $errors = @()
        $valid = Test-Json -LiteralPath $file.FullName -SchemaFile $schemaPath -ErrorAction SilentlyContinue -ErrorVariable errors
        if (-not $valid) { $failures += "$($file.Name): $(@($errors).Exception.Message -join ' | ')" }
    }
    Assert-FreshWinCount 0 $failures ($failures -join [Environment]::NewLine)
}

Add-FreshWinTest -Name 'Runtime manifest validation accepts every package' -Category 'Catalog' -ScriptBlock {
    $failures = @()
    foreach ($file in Get-FreshWinTestJsonFiles) {
        $manifest = Read-FreshWinJsonFile $file.FullName
        $result = Test-FreshWinPackageManifest -Manifest $manifest -SourcePath $file.FullName
        if (-not $result.IsValid) { $failures += "$($file.Name): $($result.Errors -join ' | ')" }
    }
    Assert-FreshWinCount 0 $failures ($failures -join [Environment]::NewLine)
}

Add-FreshWinTest -Name 'Catalog importer excludes schemas and reports no rejected records' -Category 'Catalog' -ScriptBlock {
    $catalog = Import-FreshWinPackageCatalog -Path (Join-Path $script:FreshWinTestContext.ProjectRoot 'catalog')
    Assert-FreshWinCount 0 $catalog.Errors (@($catalog.Errors | ForEach-Object { $_.Error }) -join [Environment]::NewLine)
    Assert-FreshWinTrue $catalog.IsValid
    Assert-FreshWinTrue ($catalog.Packages.Count -gt 0)
    Assert-FreshWinFalse (@($catalog.Packages.id) -contains '')
}

Add-FreshWinTest -Name 'Catalog IDs, filenames, and description keys are one-to-one' -Category 'Catalog' -ScriptBlock {
    $ids = @()
    $failures = @()
    foreach ($file in Get-FreshWinTestJsonFiles) {
        $manifest = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $ids += [string]$manifest.id
        if ($manifest.id -cne $baseName) { $failures += "$($file.Name): id '$($manifest.id)' does not match filename" }
        if ($manifest.descriptionKey -cne "packages.$baseName.description") { $failures += "$($file.Name): unexpected descriptionKey '$($manifest.descriptionKey)'" }
    }
    $duplicates = @($ids | Group-Object | Where-Object Count -gt 1)
    $failures += @($duplicates | ForEach-Object { "duplicate id '$($_.Name)'" })
    Assert-FreshWinCount 0 $failures ($failures -join '; ')
}

Add-FreshWinTest -Name 'All package dependencies exist and dependency graph is acyclic' -Category 'Catalog' -ScriptBlock {
    $records = @(Get-FreshWinTestCatalogRecords)
    $byId = @{}
    foreach ($record in $records) { $byId[[string]$record.id] = $record }
    $missing = @()
    foreach ($record in $records) {
        foreach ($dependency in @($record.dependencies)) {
            if (-not $byId.ContainsKey([string]$dependency)) { $missing += "$($record.id) -> $dependency" }
        }
    }
    Assert-FreshWinCount 0 $missing ("Missing dependencies: " + ($missing -join ', '))

    $visiting = @{}
    $visited = @{}
    $cycles = @()
    function Visit-FreshWinTestDependency([string]$Id, [string[]]$Path) {
        if ($visiting.ContainsKey($Id)) { $script:FreshWinDependencyCycles += (($Path + $Id) -join ' -> '); return }
        if ($visited.ContainsKey($Id)) { return }
        $visiting[$Id] = $true
        foreach ($dependency in @($byId[$Id].dependencies)) { Visit-FreshWinTestDependency ([string]$dependency) ($Path + $Id) }
        [void]$visiting.Remove($Id)
        $visited[$Id] = $true
    }
    $script:FreshWinDependencyCycles = @()
    foreach ($id in @($byId.Keys)) { Visit-FreshWinTestDependency $id @() }
    $cycles = @($script:FreshWinDependencyCycles)
    Remove-Variable FreshWinDependencyCycles -Scope Script -ErrorAction SilentlyContinue
    Assert-FreshWinCount 0 $cycles ("Dependency cycles: " + ($cycles -join '; '))
}

Add-FreshWinTest -Name 'Versioned runtime registry names use bounded architecture-aware prefixes' -Category 'Catalog' -ScriptBlock {
    $catalog = Import-FreshWinPackageCatalog -Path (Join-Path $script:FreshWinTestContext.ProjectRoot 'catalog')
    $cases = @(
        [pscustomobject]@{ Id = 'vcpp-x64'; DisplayName = 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.51.36247' },
        [pscustomobject]@{ Id = 'vcpp-x86'; DisplayName = 'Microsoft Visual C++ 2015-2022 Redistributable (x86) - 14.51.36247' },
        [pscustomobject]@{ Id = 'dotnet-runtime'; DisplayName = 'Microsoft .NET Runtime - 10.0.10 (x64)' },
        [pscustomobject]@{ Id = 'dotnet-desktop-runtime'; DisplayName = 'Microsoft Windows Desktop Runtime 10.0.10 (x64)' },
        [pscustomobject]@{ Id = 'dotnet-sdk'; DisplayName = 'Microsoft .NET SDK 10.0.302 (x64)' }
    )
    foreach ($case in $cases) {
        $package = Get-FreshWinPackage -Catalog $catalog -Id $case.Id
        $inventory = [pscustomobject]@{
            Available = $true
            Items = @([pscustomobject]@{ DisplayName = $case.DisplayName; Version = 'fixture' })
        }
        $result = Get-FreshWinPackageDetection -Package $package -Inventory $inventory
        Assert-FreshWinEqual 'Installed' $result.State "Expected versioned registry detection for $($case.Id)."
        Assert-FreshWinContains $result.Evidence 'registry-prefix' "Expected prefix evidence for $($case.Id)."
    }

    $x86Package = Get-FreshWinPackage -Catalog $catalog -Id 'vcpp-x86'
    $x64OnlyInventory = [pscustomobject]@{
        Available = $true
        Items = @([pscustomobject]@{ DisplayName = 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.51.36247' })
    }
    Assert-FreshWinEqual 'NotInstalled' (Get-FreshWinPackageDetection -Package $x86Package -Inventory $x64OnlyInventory).State `
        'The x86 runtime must not match an x64 registry entry.'

    $desktopRuntime = Get-FreshWinPackage -Catalog $catalog -Id 'dotnet-desktop-runtime'
    $olderMajorInventory = [pscustomobject]@{
        Available = $true
        Items = @([pscustomobject]@{ DisplayName = 'Microsoft Windows Desktop Runtime 9.0.13 (x64)' })
    }
    Assert-FreshWinEqual 'NotInstalled' (Get-FreshWinPackageDetection -Package $desktopRuntime -Inventory $olderMajorInventory).State `
        'The .NET 10 runtime must not match an older major version.'

    $dotnetSdk = Get-FreshWinPackage -Catalog $catalog -Id 'dotnet-sdk'
    Assert-FreshWinEqual 'NotInstalled' (Get-FreshWinPackageDetection -Package $dotnetSdk -Inventory $olderMajorInventory).State `
        'A runtime-only record must not be mistaken for the .NET SDK.'

    $baseRuntime = Get-FreshWinPackage -Catalog $catalog -Id 'dotnet-runtime'
    $desktopOnlyInventory = [pscustomobject]@{
        Available = $true
        Items = @([pscustomobject]@{ DisplayName = 'Microsoft Windows Desktop Runtime 10.0.10 (x64)' })
    }
    Assert-FreshWinEqual 'NotInstalled' (Get-FreshWinPackageDetection -Package $baseRuntime -Inventory $desktopOnlyInventory).State `
        'The base .NET Runtime record must not treat a Desktop Runtime registry entry as its own evidence.'
}

Add-FreshWinTest -Name 'Microsoft runtime records use reviewed exact package identities' -Category 'Catalog' -ScriptBlock {
    $catalog = Import-FreshWinPackageCatalog -Path (Join-Path $script:FreshWinTestContext.ProjectRoot 'catalog')
    $expected = [ordered]@{
        'dotnet-runtime' = 'Microsoft.DotNet.Runtime.10'
        'edge-webview2-runtime' = 'Microsoft.EdgeWebView2Runtime'
        'directx-legacy-runtime' = 'Microsoft.DirectX'
    }
    foreach ($id in $expected.Keys) {
        $package = Get-FreshWinPackage -Catalog $catalog -Id $id
        Assert-FreshWinTrue ($null -ne $package) "Missing reviewed runtime '$id'."
        Assert-FreshWinEqual 'winget' ([string]$package.source.type)
        Assert-FreshWinEqual 'winget' ([string]$package.source.sourceName)
        Assert-FreshWinEqual $expected[$id] ([string]$package.source.packageId)
        Assert-FreshWinContains @($package.detection.wingetIds) $expected[$id]
    }

    $directX = Get-FreshWinPackage -Catalog $catalog -Id 'directx-legacy-runtime'
    Assert-FreshWinFalse (@($directX.compatibility.architectures) -contains 'arm64') `
        'ARM64 was intentionally left unsupported until the current legacy installer flow is live-validated.'
    Assert-FreshWinContains @($directX.verification.methods) 'appx'
    Assert-FreshWinContains @($directX.detection.appxPackageNames) 'Microsoft.DirectXRuntime'
}

Add-FreshWinTest -Name 'WSL detection never treats the inbox launcher as an installed distribution runtime' -Category 'Catalog' -ScriptBlock {
    $catalog = Import-FreshWinPackageCatalog
    $wsl = Get-FreshWinPackage -Catalog $catalog -Id 'wsl2'
    Assert-FreshWinTrue ($null -ne $wsl)
    Assert-FreshWinFalse (@($wsl.detection.knownPaths) -contains '%SystemRoot%\System32\wsl.exe') `
        -Because 'wsl.exe can exist before WSL is configured and cannot authorize a SKIP.'
    Assert-FreshWinFalse (@($wsl.verification.methods) -contains 'path') `
        -Because 'Launcher presence alone cannot independently verify a WSL installation.'
    Assert-FreshWinTrue (@($wsl.detection.wingetIds) -contains 'Microsoft.WSL')
}

Add-FreshWinTest -Name 'Catalog data contains no executable command fields' -Category 'Security' -ScriptBlock {
    $findings = @()
    foreach ($file in Get-FreshWinTestJsonFiles) {
        $record = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $findings += @(Find-FreshWinTestForbiddenManifestProperty -Value $record -Path $file.Name)
    }
    Assert-FreshWinCount 0 $findings ("Forbidden manifest fields: " + ($findings -join ', '))
}

Add-FreshWinTest -Name 'Catalog URLs and known-path variables follow safety policy' -Category 'Security' -ScriptBlock {
    $allowedVariables = @('LOCALAPPDATA', 'APPDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)', 'PROGRAMDATA', 'SYSTEMROOT', 'SYSTEMDRIVE', 'USERPROFILE')
    $failures = @()
    foreach ($record in Get-FreshWinTestCatalogRecords) {
        $manualUrl = Get-FreshWinPropertyValue -InputObject $record.source -Name 'manualUrl' -Default $null
        foreach ($url in @($record.officialWebsite, $manualUrl)) {
            if ($url -and [string]$url -notmatch '^https://[^\s]+$') { $failures += "$($record.id): insecure URL '$url'" }
        }
        foreach ($path in @($record.detection.knownPaths)) {
            if ([string]$path -match '\.\.|[?*\x00-\x1f]') { $failures += "$($record.id): unsafe path '$path'" }
            foreach ($match in [regex]::Matches([string]$path, '%([^%]+)%')) {
                if ($allowedVariables -notcontains $match.Groups[1].Value.ToUpperInvariant()) {
                    $failures += "$($record.id): unknown variable '$($match.Value)'"
                }
            }
        }
    }
    Assert-FreshWinCount 0 $failures ($failures -join '; ')
}

Add-FreshWinTest -Name 'Every supported locale exists and has exact key and placeholder parity' -Category 'Localization' -ScriptBlock {
    $localeRoot = Join-Path $script:FreshWinTestContext.ProjectRoot 'locales'
    $locales = @(Get-FreshWinSupportedLocale)
    $missing = @($locales | Where-Object { -not [System.IO.File]::Exists((Join-Path $localeRoot "$_.json")) })
    Assert-FreshWinCount 0 $missing ("Missing locale files: " + ($missing -join ', '))
    $english = Get-FreshWinTestLeafMap (Read-FreshWinJsonFile (Join-Path $localeRoot 'en-US.json'))
    Assert-FreshWinTrue ($english.Count -gt 0) -Because 'Canonical English locale is empty.'
    foreach ($locale in $locales) {
        $map = Get-FreshWinTestLeafMap (Read-FreshWinJsonFile (Join-Path $localeRoot "$locale.json"))
        Assert-FreshWinSetEqual -Expected $english.Keys -Actual $map.Keys -Because "Locale $locale key set differs from en-US."
        foreach ($key in $english.Keys) {
            Assert-FreshWinFalse ([string]::IsNullOrWhiteSpace([string]$map[$key])) "Empty localization value for $locale key $key."
            $expectedPlaceholders = @([regex]::Matches([string]$english[$key], '\{\d+(?::[^}]*)?\}') | ForEach-Object Value | Sort-Object -Unique)
            $actualPlaceholders = @([regex]::Matches([string]$map[$key], '\{\d+(?::[^}]*)?\}') | ForEach-Object Value | Sort-Object -Unique)
            Assert-FreshWinSetEqual $expectedPlaceholders $actualPlaceholders "Placeholder mismatch for $locale key $key."
        }
    }
}

Add-FreshWinTest -Name 'Every terminal localization key referenced by source exists in every locale' -Category 'Localization' -ScriptBlock {
    $terminalPath = Join-Path $script:FreshWinTestContext.ProjectRoot 'src/UI/Terminal.ps1'
    $terminalSource = [IO.File]::ReadAllText($terminalPath)
    $keys = @([regex]::Matches($terminalSource, "Get-FreshWinTerminalString(?:\s+-Key)?\s+'([^']+)'") |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-FreshWinTrue ($keys.Count -gt 0) 'Terminal source does not reference localization keys.'
    foreach ($locale in @(Get-FreshWinSupportedLocale)) {
        $localePath = Join-Path (Join-Path $script:FreshWinTestContext.ProjectRoot 'locales') "$locale.json"
        $map = Get-FreshWinTestLeafMap (Read-FreshWinJsonFile $localePath)
        $missing = @($keys | Where-Object { -not $map.Contains($_) })
        Assert-FreshWinCount 0 $missing "Terminal keys missing from ${locale}: $($missing -join ', ')"
    }
}

Add-FreshWinTest -Name 'Every package description resolves in every locale' -Category 'Localization' -ScriptBlock {
    $localeRoot = Join-Path $script:FreshWinTestContext.ProjectRoot 'locales'
    foreach ($locale in @(Get-FreshWinSupportedLocale)) {
        $context = Initialize-FreshWinLocalization -Locale $locale -LocalesPath $localeRoot
        foreach ($record in Get-FreshWinTestCatalogRecords) {
            $value = Get-FreshWinString -Key $record.descriptionKey -Context $context
            Assert-FreshWinFalse ([string]::IsNullOrWhiteSpace($value)) "Empty description for $($record.id) in $locale."
            Assert-FreshWinFalse ($value -ceq $record.descriptionKey) "Unresolved description for $($record.id) in $locale."
        }
    }
}

Add-FreshWinTest -Name 'Profiles parse cleanly and reference existing packages' -Category 'Profiles' -ScriptBlock {
    $profileRoot = Join-Path $script:FreshWinTestContext.ProjectRoot 'profiles'
    Assert-FreshWinTrue ([System.IO.Directory]::Exists($profileRoot)) -Because 'profiles directory is missing.'
    $catalog = [pscustomobject]@{ Packages = @(Get-FreshWinTestCatalogRecords) }
    $profiles = Import-FreshWinProfiles -Path $profileRoot -Catalog $catalog
    Assert-FreshWinCount 0 $profiles.Errors (@($profiles.Errors | ForEach-Object { $_.Error }) -join '; ')
    Assert-FreshWinTrue ($profiles.Profiles.Count -gt 0) -Because 'No profiles were loaded.'
    $duplicates = @($profiles.Profiles.id | Group-Object | Where-Object Count -gt 1)
    Assert-FreshWinCount 0 $duplicates 'Profile IDs must be unique.'

    $profileById = @{}
    foreach ($profile in @($profiles.Profiles)) { $profileById[[string]$profile.id] = $profile }
    $baselineIds = @('essential', 'work', 'gaming', 'developer')
    foreach ($requiredId in @($baselineIds + 'full-recommended')) {
        Assert-FreshWinTrue ($profileById.ContainsKey($requiredId)) "Missing built-in profile '$requiredId'."
    }
    $expectedFull = @($baselineIds | ForEach-Object { @($profileById[$_].packageIds) } | Sort-Object -Unique)
    Assert-FreshWinSetEqual -Expected $expectedFull -Actual @($profileById['full-recommended'].packageIds) `
        -Because 'full-recommended must remain the exact union of the four focused profiles.'

    foreach ($developerProfileId in @('web-developer', 'full-stack', 'dotnet-developer', 'python-developer', 'devops', 'ai-developer')) {
        Assert-FreshWinTrue ($profileById.ContainsKey($developerProfileId)) "Missing developer profile '$developerProfileId'."
        $profile = $profileById[$developerProfileId]
        Assert-FreshWinEqual 'missing-only' ([string]$profile.updatePolicy)
        Assert-FreshWinTrue (@($profile.packageIds).Count -ge 5) "Developer profile '$developerProfileId' is unexpectedly empty or too narrow."
        Assert-FreshWinTrue (@($profile.packageIds).Count -le 20) "Developer profile '$developerProfileId' must remain bounded."
        Assert-FreshWinCount 0 @($profile.packageIds | Group-Object | Where-Object Count -gt 1) `
            "Developer profile '$developerProfileId' contains duplicate packages."
    }
}
