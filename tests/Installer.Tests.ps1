$installerCommon = Join-Path (Split-Path -Parent $PSScriptRoot) 'installer\Install.Common.ps1'
. $installerCommon

Add-FreshWinTest -Name 'Windows launcher uses only process-scoped policy bypass and forwards the original argument tail' -Category 'Installer' -Platform Windows -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $launcherSource = [IO.File]::ReadAllText((Join-Path $root 'bin\freshwin.cmd'))
    Assert-FreshWinMatch $launcherSource '%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe'
    Assert-FreshWinMatch $launcherSource '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0\.\.\\FreshWin\.ps1" %\*'
    Assert-FreshWinFalse ($launcherSource -match '(?i)Set-ExecutionPolicy|RunAs|setx')
    foreach ($sourceFile in @('FreshWin.ps1','install.ps1','uninstall.ps1')) {
        Assert-FreshWinFalse ([IO.File]::ReadAllText((Join-Path $root $sourceFile)) -match '(?i)\bSet-ExecutionPolicy\b') `
            -Because "$sourceFile must never change a persistent execution-policy scope."
    }
}

Add-FreshWinTest -Name 'Windows launcher starts under Restricted direct-script policy and preserves CLI arguments from unrelated directories' -Category 'Installer' -Platform Windows -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    $oldPath = $env:Path
    $oldLocation = Get-Location
    try {
        $launcherRoot = Join-Path $directory ('Program Files - T' + [char]0x1EA3 + 'i xu' + [char]0x1ED1 + 'ng')
        [void][IO.Directory]::CreateDirectory($launcherRoot)
        [IO.File]::Copy((Join-Path $script:FreshWinTestContext.ProjectRoot 'bin\freshwin.cmd'), (Join-Path $launcherRoot 'freshwin.cmd'))
        $fixtureScript = @'
[pscustomobject]@{ Executed=$true; Arguments=@($args) } | ConvertTo-Json -Compress
'@
        $utf8 = New-Object Text.UTF8Encoding -ArgumentList $false
        $entryPath = Join-Path $directory 'FreshWin.ps1'
        [IO.File]::WriteAllText($entryPath, $fixtureScript, $utf8)
        $windowsPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        $savedErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $directOutput = @(& $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Restricted -File $entryPath help 2>&1)
        $directExitCode = $LASTEXITCODE
        $ErrorActionPreference = $savedErrorActionPreference
        Assert-FreshWinFalse ($directExitCode -eq 0) -Because 'The unsigned .ps1 fixture must remain blocked when the direct child policy is Restricted.'

        $policyBefore = @(Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ';'
        $env:Path = $launcherRoot + [IO.Path]::PathSeparator + $oldPath
        $fixtureLauncher = Join-Path $launcherRoot 'freshwin.cmd'
        $resolvedLauncher = @(Get-Command freshwin -CommandType Application -All -ErrorAction Stop | Where-Object {
            [string]::Equals([IO.Path]::GetFullPath($_.Source), [IO.Path]::GetFullPath($fixtureLauncher), [StringComparison]::OrdinalIgnoreCase)
        })[0]
        Assert-FreshWinEqual ([IO.Path]::GetFullPath((Join-Path $launcherRoot 'freshwin.cmd'))) ([IO.Path]::GetFullPath($resolvedLauncher.Source))
        $locations = New-Object Collections.Generic.List[string]
        $locations.Add([IO.Path]::GetPathRoot($directory))
        $downloads = try { Get-FreshWinUserDownloadsPath } catch { $null }
        foreach ($known in @(
                [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop),
                $downloads,
                $directory)) {
            if (-not [string]::IsNullOrWhiteSpace($known) -and [IO.Directory]::Exists($known) -and $locations -notcontains $known) { $locations.Add($known) }
        }
        foreach ($location in $locations) {
            Set-Location -LiteralPath $location
            $output = @(& $fixtureLauncher install chrome discord '--dry-run' 2>&1)
            Assert-FreshWinEqual 0 $LASTEXITCODE
            Assert-FreshWinMatch ($output -join [Environment]::NewLine) '(?m)^\{' -Because 'The isolated launcher did not emit its JSON fixture payload.'
            $payload = ConvertFrom-Json -InputObject ($output -join [Environment]::NewLine) -ErrorAction Stop
            Assert-FreshWinTrue ([bool]$payload.Executed) -Because 'The launcher did not execute the unsigned fixture that Restricted direct invocation blocked.'
            Assert-FreshWinEqual 'install,chrome,discord,--dry-run' (@($payload.Arguments) -join ',')
        }
        $policyAfter = @(Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ';'
        Assert-FreshWinEqual $policyBefore $policyAfter -Because 'The launcher must not persist an execution-policy change.'
    }
    finally {
        Set-Location -LiteralPath $oldLocation
        $env:Path = $oldPath
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'Machine PATH registration is idempotent reversible and Unicode-safe' -Category 'Installer' -Platform Windows -ScriptBlock {
    $entry = 'C:\Program Files\FreshWin\bin'
    $initial = 'C:\Windows;"C:\Program Files\FreshWin\bin\";C:\Tools;C:\PROGRAM FILES\FRESHWIN\BIN'
    $added = Add-FreshWinPathEntryValue -CurrentValue $initial -Entry $entry
    Assert-FreshWinEqual 'C:\Windows;C:\Program Files\FreshWin\bin;C:\Tools' $added
    Assert-FreshWinEqual $added (Add-FreshWinPathEntryValue -CurrentValue $added -Entry $entry)
    Assert-FreshWinEqual 'C:\Windows;C:\Tools' (Remove-FreshWinPathEntryValue -CurrentValue $added -Entry $entry)

    $unicodeEntry = 'D:\OneDrive - Team Space\T' + [char]0x1EA3 + 'i xu' + [char]0x1ED1 + 'ng\FreshWin'
    $unicodePath = Add-FreshWinPathEntryValue -CurrentValue 'C:\Windows' -Entry $unicodeEntry
    Assert-FreshWinMatch $unicodePath ([regex]::Escape($unicodeEntry))
    Assert-FreshWinEqual 'C:\Windows' (Remove-FreshWinPathEntryValue -CurrentValue $unicodePath -Entry ($unicodeEntry + '\'))
}

Add-FreshWinTest -Name 'Local installer stages validates verifies and registers only protected Program Files core' -Category 'Installer' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $installer = [IO.File]::ReadAllText((Join-Path $root 'install.ps1'))
    $launcher = [IO.File]::ReadAllText((Join-Path $root 'install.cmd'))
    $uninstaller = [IO.File]::ReadAllText((Join-Path $root 'uninstall.ps1'))
    Assert-FreshWinMatch $installer 'SpecialFolder\]::ProgramFiles'
    Assert-FreshWinMatch $installer 'FreshWin\.install-'
    Assert-FreshWinMatch $installer 'Get-FreshWinInstallPayloadDigest'
    Assert-FreshWinMatch $installer 'Invoke-FreshWinSourceValidation -Root \$stagingRoot'
    Assert-FreshWinMatch $installer "SetEnvironmentVariable\('Path'.*EnvironmentVariableTarget\]::Machine"
    Assert-FreshWinMatch $installer 'Get-Command freshwin -CommandType Application'
    Assert-FreshWinMatch $installer '-Verb RunAs'
    Assert-FreshWinMatch $uninstaller 'Remove-FreshWinPathEntryValue'
    Assert-FreshWinMatch $uninstaller '\[IO\.Directory\]::Delete\(\$installRoot, \$true\)'
    Assert-FreshWinFalse ($installer -match '(?i)Downloads.*FreshWin\.ps1')
    Assert-FreshWinMatch $launcher 'exit /b %ERRORLEVEL%'
    Assert-FreshWinFalse ($uninstaller -match '(?i)LOCALAPPDATA|Downloads\\FreshWin') `
        -Because 'Uninstall must preserve user configuration and retained artifacts.'
}

Add-FreshWinTest -Name 'Installer update handoff publishes bounded child diagnostics and preserves rollback stages' -Category 'Installer' -ScriptBlock {
    $installer = [IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'install.ps1'))
    foreach ($stage in @(
        'VALIDATE SOURCE', 'VALIDATE CURRENT INSTALLATION', 'STAGE NEW VERSION',
        'VERIFY STAGED FILES', 'ELEVATE', 'INSTALL / REPLACE CORE',
            'BACKUP CURRENT INSTALL', 'REPLACE FILES', 'VERIFY INSTALLED FILES',
            'VERIFY INSTALLED HASHES',
            'VERIFY ACL', 'VERIFY LAUNCHER', 'VERIFY PATH', 'COMMIT', 'COMPLETE', 'ROLLBACK')) {
        Assert-FreshWinMatch $installer ([regex]::Escape("Set-FreshWinInstallerStage '$stage'")) `
            -Because "Installer must expose the '$stage' stage."
    }
    foreach ($field in @('exceptionType','message','scriptStackTrace','invocationInfo','file','line','function','stdout','stderr','rollback','rollbackStage')) {
        Assert-FreshWinMatch $installer ([regex]::Escape($field)) `
            -Because "Elevated installer failures must propagate '$field'."
    }
    Assert-FreshWinMatch $installer 'FreshWin-install-failure-'
    Assert-FreshWinMatch $installer 'Rollback result:'
    Assert-FreshWinMatch $installer 'Copy-FreshWinInstallPayload'
    Assert-FreshWinMatch $installer 'Get-FreshWinInstallerLiveProcess'
    Assert-FreshWinMatch $installer 'Test-FreshWinInstallerPayloadAvailable'
    Assert-FreshWinMatch $installer 'Close FreshWin and retry'
    Assert-FreshWinMatch $installer 'source is inside the live FreshWin installation'
    Assert-FreshWinFalse ($installer -match '\[IO\.Directory\]::Move\(\$installRoot') `
        -Because 'Updates must not rename the protected live installation root.'
    Assert-FreshWinFalse ($installer -match '(?i)\btakeown\b|\bicacls\b') `
        -Because 'The installer must preserve Program Files ACLs rather than weakening them.'
}
