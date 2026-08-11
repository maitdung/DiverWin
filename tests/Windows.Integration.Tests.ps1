# These tests are deliberately opt-in and read-only. Run on a disposable or CI Windows
# host with: pwsh -NoProfile -File tests/Run-Tests.ps1 -IncludeWindowsIntegration

Add-FreshWinTest -Name 'Live Windows platform and administrator probes return real host state' -Category 'WindowsLive' -Platform WindowsLive -ScriptBlock {
    Assert-FreshWinTrue (Test-FreshWinWindows)
    Assert-FreshWinEqual 'Windows' (Get-FreshWinPlatformName)
    $admin = Test-FreshWinAdministrator
    Assert-FreshWinTrue ($admin -is [bool])
}

Add-FreshWinTest -Name 'Live protected FreshWin installation ACL is accepted without mutation' -Category 'WindowsLive' -Platform WindowsLive -ScriptBlock {
    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    $installedEntry = Join-Path (Join-Path $programFiles 'FreshWin') 'FreshWin.ps1'
    if (-not [IO.File]::Exists($installedEntry)) { Skip-FreshWinTest 'No protected Program Files FreshWin installation is available for the read-only ACL check' }
    $result = Test-FreshWinElevationSourceTrust -EntryScriptPath $installedEntry
    Assert-FreshWinTrue $result.Trusted $result.Reason
}

Add-FreshWinTest -Name 'Live installed launcher resolves and runs read-only from an unrelated directory' -Category 'WindowsLive' -Platform WindowsLive -ScriptBlock {
    $command = Get-Command freshwin -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) { Skip-FreshWinTest 'freshwin is not registered on PATH for this new process' }
    $expectedRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'FreshWin'
    Assert-FreshWinEqual ([IO.Path]::GetFullPath((Join-Path (Join-Path $expectedRoot 'bin') 'freshwin.cmd'))) ([IO.Path]::GetFullPath($command.Source))
    $oldLocation = Get-Location
    $policyBefore = @(Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ';'
    try {
        Set-Location -LiteralPath ([IO.Path]::GetPathRoot($expectedRoot))
        $output = @(& $command.Source version 2>&1)
        Assert-FreshWinEqual 0 $LASTEXITCODE
        Assert-FreshWinMatch ($output -join [Environment]::NewLine) '^FreshWin \d+\.\d+\.\d+'
    }
    finally { Set-Location -LiteralPath $oldLocation }
    $policyAfter = @(Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ';'
    Assert-FreshWinEqual $policyBefore $policyAfter
}

Add-FreshWinTest -Name 'Live Windows system and hardware scanners identify their data as live' -Category 'WindowsLive' -Platform WindowsLive -ScriptBlock {
    $hardware = Get-FreshWinHardwareInfo
    Assert-FreshWinTrue $hardware.IsSupported
    Assert-FreshWinTrue $hardware.IsLive
    Assert-FreshWinEqual 'HardwareScanner' $hardware.Component
    Assert-FreshWinFalse ($hardware.Status -eq 'Fixture')

    $system = Get-FreshWinSystemInfo
    Assert-FreshWinTrue $system.IsSupported
    Assert-FreshWinTrue $system.IsLive
    Assert-FreshWinMatch $system.OSFamily '^Windows(10|11)$'
    Assert-FreshWinNotNull $system.BuildNumber
}

Add-FreshWinTest -Name 'Live Windows network and activation scans are non-mutating' -Category 'WindowsLive' -Platform WindowsLive -ScriptBlock {
    $network = Get-FreshWinNetworkState -SkipInternetProbe
    Assert-FreshWinTrue $network.IsSupported
    Assert-FreshWinTrue $network.IsLive
    Assert-FreshWinNotNull $network.Adapters

    $activation = Get-FreshWinActivationStatus
    Assert-FreshWinTrue $activation.IsSupported
    Assert-FreshWinTrue $activation.IsLive
    Assert-FreshWinFalse $activation.MutationPerformed
}

Add-FreshWinTest -Name 'Live Windows Update scan is query-only and reports no mutation' -Category 'WindowsLive' -Platform WindowsLive -ScriptBlock {
    $updates = Get-FreshWinWindowsUpdateState
    Assert-FreshWinTrue $updates.IsSupported
    Assert-FreshWinTrue $updates.IsLive
    Assert-FreshWinFalse $updates.MutationPerformed
    Assert-FreshWinEqual 'IsInstalled=0 and IsHidden=0' $updates.Query
}

Add-FreshWinTest -Name 'Live Windows driver inventory is query-only' -Category 'WindowsLive' -Platform WindowsLive -ScriptBlock {
    $drivers = @(Get-FreshWinDriverInventory -IncludeHealthy:$false)
    if ($drivers.Count -eq 1 -and $drivers[0].Status -eq 'Unsupported') {
        throw 'Windows driver inventory incorrectly reported Unsupported.'
    }
    foreach ($driver in $drivers) { Assert-FreshWinTrue $driver.PlatformSupported }
}

Add-FreshWinTest -Name 'Live Windows safe process runner executes a read-only system command' -Category 'WindowsLive' -Platform WindowsLive -ScriptBlock {
    $where = Get-Command where.exe -ErrorAction SilentlyContinue
    if ($null -eq $where) { Skip-FreshWinTest 'where.exe is unavailable on this Windows host' }
    $result = Invoke-FreshWinProcess -FilePath $where.Source -ArgumentList @('cmd.exe') -TimeoutSeconds 15
    Assert-FreshWinTrue $result.Succeeded
    Assert-FreshWinMatch $result.StandardOutput '(?i)cmd\.exe'
}

Add-FreshWinTest -Name 'Live WinGet resolution is reported only when WinGet actually exists' -Category 'WindowsLive' -Platform WindowsLive -ScriptBlock {
    $wingetAlias = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $wingetAlias) { Skip-FreshWinTest 'WinGet is not exposed to this user; no success is inferred' }
    $trustedWinget = Resolve-FreshWinTrustedWingetPath
    if ([string]::IsNullOrWhiteSpace($trustedWinget)) {
        Skip-FreshWinTest 'A WinGet App Execution Alias is exposed, but a Microsoft-signed App Installer package is not resolvable for this test token; alias exposure alone is not trusted installation evidence'
    }
    $package = New-FreshWinTestPackage
    $resolved = Resolve-FreshWinPackageSource -Package $package -WingetPath $trustedWinget
    Assert-FreshWinEqual 'Resolved' $resolved.Status
    Assert-FreshWinEqual 'VerifiedPackageManager' $resolved.Trust
    Assert-FreshWinTrue ([System.IO.File]::Exists($resolved.Executable))
    Assert-FreshWinTrue (Test-FreshWinTrustedMicrosoftExecutableSignature -Path $resolved.Executable)
    $version = Invoke-FreshWinProcess -FilePath $resolved.Executable -ArgumentList @('--version') -TimeoutSeconds 30
    Assert-FreshWinTrue $version.Succeeded
    Assert-FreshWinMatch $version.StandardOutput '\d+\.\d+'
}
