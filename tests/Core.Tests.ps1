Add-FreshWinTest -Name 'Every PowerShell source file parses without errors' -Category 'Syntax' -ScriptBlock {
    $failures = @()
    foreach ($file in @(Get-ChildItem (Join-Path $script:FreshWinTestContext.ProjectRoot 'src') -Filter '*.ps1' -File -Recurse)) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        foreach ($error in @($errors)) {
            $failures += "$($file.FullName):$($error.Extent.StartLineNumber): $($error.Message)"
        }
    }
    Assert-FreshWinCount -Expected 0 -Actual $failures -Because ($failures -join [Environment]::NewLine)
}

Add-FreshWinTest -Name 'Source files do not define duplicate function names' -Category 'Module' -ScriptBlock {
    $definitions = @()
    foreach ($file in @(Get-ChildItem (Join-Path $script:FreshWinTestContext.ProjectRoot 'src') -Filter '*.ps1' -File -Recurse)) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        foreach ($functionAst in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            $definitions += [pscustomobject]@{ Name = $functionAst.Name; Path = $file.FullName }
        }
    }
    $duplicates = @($definitions | Group-Object Name | Where-Object Count -gt 1)
    Assert-FreshWinCount -Expected 0 -Actual $duplicates -Because (($duplicates | ForEach-Object { "$($_.Name): $($_.Group.Path -join ', ')" }) -join '; ')
}

Add-FreshWinTest -Name 'Stable source loader exposes the core workflow surface' -Category 'Module' -ScriptBlock {
    foreach ($command in @(
        'Import-FreshWinPackageCatalog', 'Get-FreshWinSystemInfo', 'Get-FreshWinSoftwareInventory',
        'New-FreshWinInstallPlan', 'Invoke-FreshWinExecutionPlan', 'ConvertFrom-FreshWinAssistantCommand'
    )) {
        Assert-FreshWinNotNull -Actual (Get-Command $command -CommandType Function -ErrorAction SilentlyContinue) -Because "Missing function $command."
    }
}

Add-FreshWinTest -Name 'Generic property access supports objects and dictionaries after all sources load' -Category 'Core' -ScriptBlock {
    $object = [pscustomobject]@{ value = 42 }
    $dictionary = [ordered]@{ value = 43 }
    Assert-FreshWinEqual -Expected 42 -Actual (Get-FreshWinPropertyValue -InputObject $object -Name value)
    Assert-FreshWinEqual -Expected 43 -Actual (Get-FreshWinPropertyValue -InputObject $dictionary -Name value)
    Assert-FreshWinEqual -Expected 'fallback' -Actual (Get-FreshWinPropertyValue -InputObject $null -Name value -Default 'fallback')
}

Add-FreshWinTest -Name 'Command-line parser separates options from command values' -Category 'CLI' -ScriptBlock {
    $parsed = ConvertFrom-FreshWinCommandLine -Arguments @('--dry-run', '--compact', 'install', 'git', 'vscode')
    Assert-FreshWinTrue $parsed.Valid
    Assert-FreshWinEqual 'install' $parsed.Command
    Assert-FreshWinTrue $parsed.DryRun
    Assert-FreshWinTrue $parsed.Compact
    Assert-FreshWinSetEqual -Expected @('git', 'vscode') -Actual $parsed.Values

    $invalidResume = ConvertFrom-FreshWinCommandLine -Arguments @('--resume', 'relative.json')
    Assert-FreshWinFalse $invalidResume.Valid
    Assert-FreshWinMatch $invalidResume.Error 'absolute'
}

Add-FreshWinTest -Name 'Selection parser accepts ranges and rejects malformed input' -Category 'CLI' -ScriptBlock {
    $selection = ConvertFrom-FreshWinSelection -InputText '1, 3-5;3' -AvailableIds @(1, 2, 3, 4, 5)
    Assert-FreshWinTrue $selection.Valid
    Assert-FreshWinSetEqual -Expected @(1, 3, 4, 5) -Actual $selection.Values
    $invalid = ConvertFrom-FreshWinSelection -InputText '5-2' -AvailableIds @(1, 2, 3, 4, 5)
    Assert-FreshWinFalse $invalid.Valid
    Assert-FreshWinEqual 'input.invalidRange' $invalid.ErrorKey
}

Add-FreshWinTest -Name 'Configuration round-trips as UTF-8 JSON in an isolated directory' -Category 'Core' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $path = Join-Path $temporary 'config.json'
        $config = New-FreshWinConfig -Locale 'vi-VN'
        $config.execution.maxRetries = 3
        [void](Save-FreshWinConfig -Config $config -Path $path)
        $loaded = Get-FreshWinConfig -Path $path
        Assert-FreshWinEqual 'vi-VN' $loaded.locale
        Assert-FreshWinEqual 3 $loaded.execution.maxRetries
        $bytes = [System.IO.File]::ReadAllBytes($path)
        Assert-FreshWinFalse ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -Because 'Files must be UTF-8 without BOM.'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Retained artifacts honor redirected Downloads known folders without eager creation' -Category 'Core' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    $unicodeLeaf = 'T' + [char]0x1EA3 + 'i xu' + [char]0x1ED1 + 'ng'
    $redirectedDownloads = Join-Path (Join-Path $temporary 'OneDrive - Team Space') $unicodeLeaf
    try {
        $resolved = Get-FreshWinUserDownloadsPath -KnownFolderProvider { $redirectedDownloads }
        Assert-FreshWinEqual ([IO.Path]::GetFullPath($redirectedDownloads)) $resolved
        foreach ($category in @('Installers','Drivers','Exports','Backups')) {
            $directory = Get-FreshWinRetainedArtifactDirectory -Category $category -KnownFolderProvider { $redirectedDownloads }
            Assert-FreshWinEqual ([IO.Path]::GetFullPath((Join-Path (Join-Path $redirectedDownloads 'FreshWin') $category))) $directory
            Assert-FreshWinFalse ([IO.Directory]::Exists($directory)) -Because 'Resolving a retained-artifact destination must not create it.'
        }
        $exportPath = Get-FreshWinDefaultArtifactPath -Category Exports -FileName 'FreshWin-Diagnostics.json' -KnownFolderProvider { $redirectedDownloads }
        Assert-FreshWinEqual ([IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $redirectedDownloads 'FreshWin') 'Exports') 'FreshWin-Diagnostics.json'))) $exportPath
        $explicitBackup = Get-FreshWinDefaultArtifactPath -Category Backups -FileName 'FreshWin-Profile.json' -DownloadsPath $redirectedDownloads
        Assert-FreshWinEqual ([IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $redirectedDownloads 'FreshWin') 'Backups') 'FreshWin-Profile.json'))) $explicitBackup
        Assert-FreshWinFalse ([IO.Directory]::Exists((Join-Path $redirectedDownloads 'FreshWin')))
        Assert-FreshWinThrows { Get-FreshWinUserDownloadsPath -KnownFolderProvider { '\\server\share\Downloads' } } -Pattern 'absolute local path'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Compact presentation preference persists explicitly and dry-run preview writes nothing' -Category 'Core' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $path = Join-Path $temporary 'config.json'
        $preview = Invoke-FreshWinCliCompactMode -Mode on -DryRun -ConfigPath $path
        Assert-FreshWinEqual -Expected 'Preview' -Actual $preview.Status
        Assert-FreshWinTrue -Actual $preview.CompactMode
        Assert-FreshWinFalse -Actual $preview.MutationPerformed
        Assert-FreshWinFalse -Actual ([IO.File]::Exists($path)) -Because 'A compact-mode dry run must not create the user configuration.'

        $saved = Invoke-FreshWinCliCompactMode -Mode on -ConfigPath $path
        Assert-FreshWinEqual -Expected 'Saved' -Actual $saved.Status
        Assert-FreshWinTrue -Actual $saved.MutationPerformed
        Assert-FreshWinTrue -Actual (Get-FreshWinConfig -Path $path).ui.compactMode

        $status = Invoke-FreshWinCliCompactMode -Mode status -ConfigPath $path
        Assert-FreshWinEqual -Expected 'Current' -Actual $status.Status
        Assert-FreshWinTrue -Actual $status.CompactMode
        Assert-FreshWinFalse -Actual $status.MutationPerformed

        [void](Set-FreshWinConfigCompactMode -CompactMode $false -Path $path)
        Assert-FreshWinFalse -Actual (Get-FreshWinConfig -Path $path).ui.compactMode
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'State envelopes round-trip and reject path traversal names' -Category 'Core' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        [void](Save-FreshWinState -Name 'sample' -State ([pscustomobject]@{ answer = 42 }) -StateDirectory $temporary)
        $loaded = Get-FreshWinState -Name 'sample' -StateDirectory $temporary
        Assert-FreshWinEqual 42 $loaded.answer
        Assert-FreshWinThrows -ScriptBlock { Get-FreshWinStatePath -Name '../escape' -StateDirectory $temporary } -Pattern 'invalid'
        Remove-FreshWinState -Name 'sample' -StateDirectory $temporary -Confirm:$false
        Assert-FreshWinNull (Get-FreshWinState -Name 'sample' -StateDirectory $temporary -AllowMissing)
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Non-Windows scanners return explicit unsupported results without live probes' -Category 'Platform' -ScriptBlock {
    if (Test-FreshWinWindows) { Skip-FreshWinTest 'cross-platform guard assertion is for non-Windows hosts' }
    foreach ($result in @(
        (Get-FreshWinHardwareInfo), (Get-FreshWinSystemInfo), (Get-FreshWinNetworkState),
        (Get-FreshWinActivationStatus), (Get-FreshWinWindowsUpdateState), (Get-FreshWinDriverSummary)
    )) {
        Assert-FreshWinFalse $result.IsSupported
        Assert-FreshWinFalse $result.IsLive
        Assert-FreshWinEqual 'Unsupported' $result.Status
    }
}

Add-FreshWinTest -Name 'Module manifest, root module, and CLI entrypoint are present' -Category 'Metadata' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    foreach ($relativePath in @('FreshWin.psd1', 'FreshWin.psm1', 'FreshWin.ps1')) {
        Assert-FreshWinTrue ([System.IO.File]::Exists((Join-Path $root $relativePath))) -Because "Missing $relativePath."
    }
    $manifestPath = Join-Path $root 'FreshWin.psd1'
    $manifestData = Import-PowerShellDataFile -Path $manifestPath
    Assert-FreshWinTrue (@($manifestData.FunctionsToExport).Count -gt 0) -Because 'FunctionsToExport must be explicit and non-empty.'
    Assert-FreshWinFalse (@($manifestData.FunctionsToExport) -contains '*') -Because 'FunctionsToExport must list the supported public API rather than use a wildcard.'
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
    Assert-FreshWinEqual 'FreshWin' $manifest.Name
    Assert-FreshWinTrue ($manifest.Version -gt [version]'0.0.0')
    $powerShell = (Get-Process -Id $PID).Path
    $manifestLiteral = "'" + $manifestPath.Replace("'", "''") + "'"
    $importCommand = "`$m = Import-Module -Name $manifestLiteral -Force -PassThru -ErrorAction Stop; " +
        "if (`$m.ExportedCommands.Count -lt 1) { throw 'Imported module exported no commands.' }; " +
        "Write-Output `$m.ExportedCommands.Count"
    $importOutput = @(& $powerShell -NoLogo -NoProfile -Command $importCommand 2>&1)
    Assert-FreshWinEqual 0 $LASTEXITCODE ($importOutput -join [Environment]::NewLine)
    Assert-FreshWinTrue ([int]$importOutput[-1] -gt 0) -Because 'Importing the module must export its declared commands.'
}

Add-FreshWinTest -Name 'CLI help starts in a clean PowerShell process and documents the safe command surface' -Category 'CLI' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $child = Invoke-FreshWinTestRepositoryCliProcess -ProjectRoot $root -CliArguments @('help')
    Assert-FreshWinEqual 0 $child.ExitCode ($child.Stdout + $child.Stderr)
    $text = [string]$child.Stdout
    foreach ($command in @('validate','catalog','search','status','history','recommend','plan','install','resume','assistant')) {
        Assert-FreshWinMatch $text "(?m)^\s+$command(?:\s|$)" "Help omitted $command."
    }
}

Add-FreshWinTest -Name 'CLI validate succeeds in a clean process and returns parseable JSON' -Category 'CLI' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $child = Invoke-FreshWinTestRepositoryCliProcess -ProjectRoot $root -CliArguments @('validate','--json')
    Assert-FreshWinEqual 0 $child.ExitCode ($child.Stdout + $child.Stderr)
    $result = $child.Stdout | ConvertFrom-Json -ErrorAction Stop
    Assert-FreshWinTrue $result.IsValid ($result.Errors -join '; ')
    Assert-FreshWinTrue ($result.PackageCount -gt 0)
    Assert-FreshWinEqual 4 $result.LocaleCount
}
