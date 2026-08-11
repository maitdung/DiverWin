Add-FreshWinTest -Name 'Terminal home preserves the complete product key mapping and order' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $expected = @(
        @('1','Quick Setup'),
        @('2','Drivers & Hardware'),
        @('3','Applications'),
        @('4','Gaming'),
        @('5','Developer'),
        @('6','Security & Protection'),
        @('7','Windows & Runtimes'),
        @('8','Diagnostics & Repair'),
        @('9','Backup / Before Reset'),
        @('A','Assistant'),
        @('L','Language'),
        @('U','Update FreshWin'),
        @('H','About & Support'),
        @('0','Exit')
    )
    $entries = @(Get-FreshWinTerminalHomeEntries)
    Assert-FreshWinCount -Expected $expected.Count -Actual $entries
    for ($index = 0; $index -lt $expected.Count; $index++) {
        Assert-FreshWinEqual -Expected $expected[$index][0] -Actual ([string]$entries[$index].Key)
        Assert-FreshWinEqual -Expected $expected[$index][1] -Actual ([string]$entries[$index].Label)
    }
}

Add-FreshWinTest -Name 'Terminal renderer includes the shared page contract and strips control characters' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $page = New-FreshWinTerminalPage -Breadcrumb @('Home','Applications') -Title "Application`0s" `
        -Description 'Choose packages from the trusted catalog.' -Status @('Fixture status') `
        -Items @((New-FreshWinTerminalItem -Key '1' -Label 'Example' -Badge '[OK]' -Detail 'Detail')) `
        -ContextHelp @('Mixed ranges are accepted.') -Commands @((New-FreshWinTerminalCommand '0' 'Back')) -Prompt 'Select.'
    $text = @(Format-FreshWinTerminalPage -Page $page -Width 80) -join [Environment]::NewLine
    foreach ($pattern in @('Breadcrumb: Home > Applications','Applications','Choose packages','Fixture status','Context help','Commands','Prompt > Select\.')) {
        Assert-FreshWinMatch -Actual $text -Pattern $pattern
    }
    Assert-FreshWinFalse ($text.IndexOf([char]0) -ge 0) -Because 'Terminal output must remove embedded control characters.'
}

Add-FreshWinTest -Name 'Terminal compact mode suppresses repeated help but keeps commands and prompt' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $page = New-FreshWinTerminalPage -Breadcrumb @('Home') -Title 'Compact fixture' -Description 'Fixture.' `
        -ContextHelp @('Long first-time guidance.') -Commands @((New-FreshWinTerminalCommand '0' 'Back')) -Prompt 'Select.'
    try {
        $script:FreshWinTerminalCompactMode = $false
        $full = @(Format-FreshWinTerminalPage -Page $page) -join "`n"
        Assert-FreshWinMatch $full 'Context help'
        $script:FreshWinTerminalCompactMode = $true
        $compact = @(Format-FreshWinTerminalPage -Page $page) -join "`n"
        Assert-FreshWinFalse ($compact -match 'Long first-time guidance')
        Assert-FreshWinMatch $compact '\[0\] Back'
        Assert-FreshWinMatch $compact 'Prompt > Select\.'
    }
    finally { $script:FreshWinTerminalCompactMode = $false }
}

Add-FreshWinTest -Name 'Terminal language page explicitly saves the compact presentation preference' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $output = New-Object System.Collections.Generic.List[string]
    $state = [pscustomobject]@{ Saved=$null }
    try {
        $script:FreshWinTerminalCompactMode = $false
        $result = Show-FreshWinTerminalLanguage -AllowCompactToggle -InputProvider { param($prompt) 'C' } `
            -OutputWriter { param($line) $output.Add([string]$line) } `
            -CompactModeSaver { param($value) $state.Saved = [bool]$value }
        Assert-FreshWinNull -Actual $result
        Assert-FreshWinTrue -Actual $state.Saved
        Assert-FreshWinTrue -Actual $script:FreshWinTerminalCompactMode
        $text = $output -join "`n"
        Assert-FreshWinMatch -Actual $text -Pattern 'Compact presentation: Off'
        Assert-FreshWinMatch -Actual $text -Pattern '\[C\] Toggle and save compact presentation'
        Assert-FreshWinMatch -Actual $text -Pattern 'Compact presentation was saved: On'
    }
    finally { $script:FreshWinTerminalCompactMode = $false }
}

Add-FreshWinTest -Name 'First-run language rendering is UTF-8 safe and bounded for narrow text' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $expectedVietnamese = 'Ti' + [char]0x1EBF + 'ng Vi' + [char]0x1EC7 + 't'
    $expectedChinese = @([char]0x7B80,[char]0x4F53,[char]0x4E2D,[char]0x6587) -join ''
    $expectedJapanese = @([char]0x65E5,[char]0x672C,[char]0x8A9E) -join ''
    $output = New-Object System.Collections.Generic.List[string]
    try {
        $languageParameters = @{
            InputProvider = { param($prompt) '2' }
            OutputWriter = { param($line) $output.Add([string]$line) }
            LocaleSaver = { param($locale) $script:FreshWinRenderedLocale = $locale }
        }
        $selected = Show-FreshWinTerminalLanguage @languageParameters
        Assert-FreshWinEqual 'vi-VN' $selected
        Assert-FreshWinEqual 'vi-VN' $script:FreshWinRenderedLocale
        $rendered = $output -join [Environment]::NewLine
        foreach ($nativeName in @($expectedVietnamese,$expectedChinese,$expectedJapanese)) {
            Assert-FreshWinTrue $rendered.Contains($nativeName) -Because "The first-run language page must render '$nativeName' without OEM-code-page mojibake."
        }
        Assert-FreshWinFalse ($rendered -match '(?m)^\s*#\s*Prompt:') -Because 'The prompt must be rendered as a normal terminal label.'

        foreach ($sample in @('x', ('x' * 20), ('x' * 21), ($expectedChinese * 12), 'short words followed by oneverylongunbrokenvalue')) {
            $wrapped = @(Split-FreshWinTerminalText -Text $sample -Width 20)
            Assert-FreshWinTrue ($wrapped.Count -gt 0)
            foreach ($line in $wrapped) {
                Assert-FreshWinTrue (([string]$line).Length -le 20) -Because 'Every wrapped segment must remain within the requested width.'
            }
        }
    }
    finally {
        Remove-Variable FreshWinRenderedLocale -Scope Script -ErrorAction SilentlyContinue
    }
}

Add-FreshWinTest -Name 'Startup failure diagnostics are complete and cannot mask the original error' -Category 'Terminal' -ScriptBlock {
    $output = New-Object System.Collections.Generic.List[string]
    try {
        throw [System.ArgumentOutOfRangeException]::new('length', 'fixture startup failure')
    }
    catch {
        Assert-FreshWinDoesNotThrow { Write-FreshWinStartupFailureDiagnostic -ErrorRecord $_ -OutputWriter { param($line) $output.Add([string]$line) } }
    }
    $diagnostic = $output -join [Environment]::NewLine
    foreach ($field in @('ExceptionType:','Message:','ScriptStackTrace:','InvocationInfo:','File:','Line:','Function:')) {
        Assert-FreshWinMatch $diagnostic ([regex]::Escape($field))
    }

    try {
        throw 'secondary fixture'
    }
    catch {
        Assert-FreshWinDoesNotThrow { Write-FreshWinStartupFailureDiagnostic -ErrorRecord $_ -OutputWriter { throw 'diagnostic writer unavailable' } }
    }
}

Add-FreshWinTest -Name 'Real FreshWin entrypoint completes first-run and saved Vietnamese startup' -Category 'Terminal' -ScriptBlock {
    if (-not (Test-FreshWinWindows)) { Skip-FreshWinTest 'real Windows PowerShell startup path requires Windows' }
    if (Test-FreshWinAdministrator) { Skip-FreshWinTest 'the unprotected test checkout must not be launched elevated' }
    $windowsPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    if (-not [IO.File]::Exists($windowsPowerShell)) { Skip-FreshWinTest 'Windows PowerShell 5.1 is unavailable' }
    $entryPath = Join-Path $script:FreshWinTestContext.ProjectRoot 'FreshWin.ps1'

    $invokeStartup = {
        param([bool]$SavedVietnamese)
        $temporary = New-FreshWinTestDirectory
        try {
            if ($SavedVietnamese) {
                $configDirectory = Join-Path $temporary 'FreshWin'
                [void][IO.Directory]::CreateDirectory($configDirectory)
                $config = New-FreshWinConfig -Locale 'vi-VN'
                $json = ConvertTo-Json -InputObject $config -Depth 12
                [IO.File]::WriteAllText((Join-Path $configDirectory 'config.json'), $json, (New-Object Text.UTF8Encoding -ArgumentList $false))
            }
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = $windowsPowerShell
            $startInfo.Arguments = Join-FreshWinProcessArguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$entryPath)
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $temporary
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $startInfo
            try {
                Assert-FreshWinTrue $process.Start()
                if (-not $SavedVietnamese) { $process.StandardInput.WriteLine('2') }
                $process.StandardInput.WriteLine('0')
                $process.StandardInput.Close()
                $standardOutput = $process.StandardOutput.ReadToEnd()
                $standardError = $process.StandardError.ReadToEnd()
                Assert-FreshWinTrue $process.WaitForExit(60000) -Because 'The real FreshWin startup path did not finish within 60 seconds.'
                Assert-FreshWinEqual 0 $process.ExitCode -Because $standardError
                Assert-FreshWinFalse ($standardOutput -match 'Substring.*Index and length') -Because $standardError
                Assert-FreshWinMatch $standardOutput 'vi-VN|Trang ch'
                return $standardOutput
            }
            finally {
                if (-not $process.HasExited) { try { $process.Kill() } catch { } }
                $process.Dispose()
            }
        }
        finally { Remove-FreshWinTestDirectory $temporary }
    }

    $firstRunOutput = & $invokeStartup $false
    $savedOutput = & $invokeStartup $true
    Assert-FreshWinMatch $firstRunOutput 'Language'
    Assert-FreshWinFalse ($savedOutput -match 'Breadcrumb: Home > Language') -Because 'A saved Vietnamese locale must bypass first-run selection.'
}

Add-FreshWinTest -Name 'Terminal selection supports mixed ranges and page-scoped contextual commands' -Category 'Terminal' -ScriptBlock {
    $mixed = ConvertFrom-FreshWinSelection -InputText '1,2-3,8' -AvailableIds @(1,2,3,8) -AllowedCommands @('SELECT','MISSING','SEARCH','BACK')
    Assert-FreshWinTrue $mixed.Valid
    Assert-FreshWinSetEqual -Expected @(1,2,3,8) -Actual $mixed.Values

    $missing = ConvertFrom-FreshWinSelection -InputText 'M' -AllowedCommands @('MISSING','BACK')
    Assert-FreshWinTrue $missing.Valid
    Assert-FreshWinEqual -Expected 'MISSING' -Actual $missing.Command

    $disallowed = ConvertFrom-FreshWinSelection -InputText 'U' -AllowedCommands @('MISSING','BACK')
    Assert-FreshWinFalse $disallowed.Valid
    Assert-FreshWinEqual -Expected 'input.commandNotAvailable' -Actual $disallowed.ErrorKey

    $search = ConvertFrom-FreshWinSelection -InputText '/visual studio' -AllowedCommands @('SEARCH','BACK')
    Assert-FreshWinTrue $search.Valid
    Assert-FreshWinEqual -Expected 'visual studio' -Actual $search.SearchTerm

    $emptyPage = ConvertFrom-FreshWinSelection -InputText '1' -AvailableIds @() -AllowedCommands @('SELECT','BACK')
    Assert-FreshWinFalse $emptyPage.Valid
    Assert-FreshWinEqual -Expected 'input.notAvailable' -Actual $emptyPage.ErrorKey
}

Add-FreshWinTest -Name 'Terminal network rescue scans a local folder and runs only bounded read-only retry providers' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $temporary = New-FreshWinTestDirectory
    try {
        $inputs = New-Object System.Collections.Queue
        foreach ($value in @('F', $temporary, 'R', '0')) { $inputs.Enqueue($value) }
        $output = New-Object System.Collections.Generic.List[string]
        $fixture = [pscustomobject]@{ StateCalls=0; RetryCalls=0; Folder=$null }
        $initialState = [pscustomobject]@{ Status='FixtureObserved'; RescueState='DriverMissing'; Adapters=@(); ProblemDevices=@(); LocalDrivers=@() }
        $initialPlan = New-FreshWinNetworkRescuePlan -State $initialState

        Show-FreshWinTerminalNetworkRescuePlan -State $initialState -Plan $initialPlan `
            -InputProvider { param($prompt) if ($inputs.Count -eq 0) { return $null }; return $inputs.Dequeue() } `
            -OutputWriter { param($line) $output.Add([string]$line) } `
            -StateProvider {
                param($folder)
                $fixture.StateCalls++
                $fixture.Folder = $folder
                [pscustomobject]@{ Status='FixtureObserved'; RescueState='DriverMissing'; Adapters=@(); ProblemDevices=@([pscustomobject]@{ Name='Fixture NIC' }); LocalDrivers=@([pscustomobject]@{ Path=(Join-Path $folder 'fixture.inf') }) }
            } `
            -PlanProvider { param($state) New-FreshWinNetworkRescuePlan -State $state } `
            -OfflineDiagnosticsProvider { [pscustomobject]@{ Status='FixtureObserved'; MutationPerformed=$false } } `
            -RetryProvider {
                $fixture.RetryCalls++
                [pscustomobject]@{ Status='StillOffline'; Attempts=@(1,2,3); MutationPerformed=$false }
            }

        $text = $output -join [Environment]::NewLine
        Assert-FreshWinEqual -Expected 2 -Actual $fixture.StateCalls
        Assert-FreshWinEqual -Expected 1 -Actual $fixture.RetryCalls
        Assert-FreshWinEqual -Expected ([System.IO.Path]::GetFullPath($temporary)) -Actual $fixture.Folder
        Assert-FreshWinMatch -Actual $text -Pattern 'Scan local/USB driver folder'
        Assert-FreshWinMatch -Actual $text -Pattern 'Local folder scan complete; review-only INF matches: 1'
        Assert-FreshWinMatch -Actual $text -Pattern 'Retry status: StillOffline \| probes: 3'
        Assert-FreshWinMatch -Actual $text -Pattern 'never changes an adapter'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Non-Windows terminal reports unsupported without requesting input' -Category 'Terminal' -ScriptBlock {
    if (Test-FreshWinWindows) { Skip-FreshWinTest 'non-Windows interactive guard assertion' }
    $state = [pscustomobject]@{ Prompted = $false }
    $output = New-Object System.Collections.Generic.List[string]
    $result = Start-FreshWinTerminalSession -InputProvider {
        param($prompt)
        $state.Prompted = $true
        throw "Unexpected prompt: $prompt"
    } -OutputWriter { param($line) $output.Add([string]$line) }
    Assert-FreshWinEqual -Expected 'Unsupported' -Actual $result.Status
    Assert-FreshWinFalse $state.Prompted
    Assert-FreshWinMatch -Actual ($output -join [Environment]::NewLine) -Pattern 'unavailable on this platform'
}

Add-FreshWinTest -Name 'Terminal navigation is deterministic with explicit platform session input and output fixtures' -Category 'Terminal' -ScriptBlock {
    $inputQueue = New-Object System.Collections.Queue
    $inputQueue.Enqueue('H')
    $inputQueue.Enqueue('0')
    $output = New-Object System.Collections.Generic.List[string]
    $fixtureSession = [pscustomobject]@{
        Catalog = [pscustomobject]@{ Packages = @() }
        System = [pscustomobject]@{ Admin = $false }
        Network = [pscustomobject]@{ Status = 'Fixture'; InternetAvailable = $false }
        Inventory = [pscustomobject]@{ Available = $false; Status = 'FixtureUnavailable'; Items = @(); Errors = @() }
        Profiles = [pscustomobject]@{ Profiles = @(); Errors = @() }
        IncludeUpdates = $false
    }
    $result = Start-FreshWinTerminalSession -Locale en-US -PlatformProvider { $true } -SessionProvider { $fixtureSession } `
        -InputProvider { param($prompt) if ($inputQueue.Count -eq 0) { return $null }; return $inputQueue.Dequeue() } `
        -OutputWriter { param($line) $output.Add([string]$line) }
    $text = $output -join [Environment]::NewLine
    Assert-FreshWinEqual -Expected 'Exited' -Actual $result.Status
    Assert-FreshWinEqual -Expected 'FixtureWindows' -Actual $result.Platform
    Assert-FreshWinTrue $result.IsFixture
    Assert-FreshWinTrue $result.DryRun -Because 'Fixture navigation must be forced into dry-run mode.'
    Assert-FreshWinMatch -Actual $text -Pattern 'About & Support'
    # Code points keep this assertion stable when Windows PowerShell 5.1 parses
    # a UTF-8 script on a host whose legacy ANSI code page is not UTF-8.
    $developerName = 'Developer: Mai Tu' + [char]0x1EA5 + 'n D' + [char]0x0169 + 'ng'
    Assert-FreshWinMatch -Actual $text -Pattern ([regex]::Escape($developerName))
    Assert-FreshWinMatch -Actual $text -Pattern 'Support: maituandung004@gmail\.com'
    Assert-FreshWinMatch -Actual $text -Pattern 'Windows Post-Install Toolkit'
    Assert-FreshWinTrue (([regex]::Matches($text, 'Breadcrumb: Home')).Count -ge 2) -Because 'The session should return to Home after the About page.'
}

Add-FreshWinTest -Name 'First interactive Windows launch selects and saves language before session scanning' -Category 'Terminal' -ScriptBlock {
    $inputQueue = New-Object System.Collections.Queue
    $inputQueue.Enqueue('2')
    $inputQueue.Enqueue('0')
    $state = [pscustomobject]@{ SavedLocale = $null }
    $output = New-Object System.Collections.Generic.List[string]
    $fixtureSession = [pscustomobject]@{
        Catalog = [pscustomobject]@{ Packages = @() }
        System = [pscustomobject]@{ Admin = $false }
        Network = [pscustomobject]@{ Status = 'Fixture'; InternetAvailable = $false }
        Inventory = [pscustomobject]@{ Available = $false; Status = 'FixtureUnavailable'; Items = @(); Errors = @() }
        Profiles = [pscustomobject]@{ Profiles = @(); Errors = @() }
        IncludeUpdates = $false
    }
    $result = Start-FreshWinTerminalSession -PlatformProvider { $true } -SessionProvider { $fixtureSession } `
        -ConfigurationProvider { [pscustomobject]@{ locale=$null; languageSelected=$false } } `
        -LocaleSaver { param($selectedLocale) $state.SavedLocale = $selectedLocale } `
        -InputProvider { param($prompt) if ($inputQueue.Count -eq 0) { return $null }; return $inputQueue.Dequeue() } `
        -OutputWriter { param($line) $output.Add([string]$line) }
    $text = $output -join [Environment]::NewLine
    Assert-FreshWinEqual -Expected 'Exited' -Actual $result.Status
    Assert-FreshWinEqual -Expected 'vi-VN' -Actual $result.Locale
    Assert-FreshWinEqual -Expected 'vi-VN' -Actual $state.SavedLocale
    $languagePosition = $text.IndexOf('Breadcrumb: Home > Language')
    $homePosition = $text.IndexOf('Đường dẫn: Trang chủ', $languagePosition + 1)
    $localizedHomeBreadcrumb = Get-FreshWinString -Key 'terminal.common.breadcrumb' -FormatArguments @((Get-FreshWinString -Key 'terminal.common.home'))
    $homePosition = $text.IndexOf($localizedHomeBreadcrumb, $languagePosition + 1)
    Assert-FreshWinTrue ($languagePosition -ge 0 -and $homePosition -gt $languagePosition) -Because 'Language selection must render before Home and before session work.'
}

Add-FreshWinTest -Name 'Explicit interactive locale is runtime-only and bypasses first-launch persistence' -Category 'Terminal' -ScriptBlock {
    $inputQueue = New-Object System.Collections.Queue
    $inputQueue.Enqueue('0')
    $state = [pscustomobject]@{ SaveCalls = 0 }
    $fixtureSession = [pscustomobject]@{
        Catalog = [pscustomobject]@{ Packages = @() }
        System = [pscustomobject]@{ Admin = $false }
        Network = [pscustomobject]@{ Status = 'Fixture'; InternetAvailable = $false }
        Inventory = [pscustomobject]@{ Available = $false; Status = 'FixtureUnavailable'; Items = @(); Errors = @() }
        Profiles = [pscustomobject]@{ Profiles = @(); Errors = @() }
        IncludeUpdates = $false
    }
    $result = Start-FreshWinTerminalSession -Locale ja-JP -LocaleExplicit -PlatformProvider { $true } -SessionProvider { $fixtureSession } `
        -ConfigurationProvider { [pscustomobject]@{ locale=$null; languageSelected=$false } } `
        -LocaleSaver { param($selectedLocale) $state.SaveCalls++ } `
        -InputProvider { param($prompt) if ($inputQueue.Count -eq 0) { return $null }; return $inputQueue.Dequeue() } `
        -OutputWriter { param($line) }
    Assert-FreshWinEqual -Expected 'Exited' -Actual $result.Status
    Assert-FreshWinEqual -Expected 'ja-JP' -Actual $result.Locale
    Assert-FreshWinEqual -Expected 0 -Actual $state.SaveCalls
}

Add-FreshWinTest -Name 'Terminal default session starts missing-only and update filter refreshes update-aware inventory' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $terminalSource = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/UI/Terminal.ps1'))
    Assert-FreshWinMatch -Actual $terminalSource -Pattern 'New-FreshWinTerminalSessionContext\s+-IncludeUpdates:\$false' `
        -Because 'Interactive startup must not silently opt every package plan into updates.'

    $package = New-FreshWinTestPackage
    $initialInventory = [pscustomobject]@{
        Available=$true; Status='Ready'; Items=@([pscustomobject]@{
            WingetId='Fixture.sample'; DisplayName='Fixture sample'; Version='1.0'
            UpdateAvailable=$false; AvailableVersion=$null
        }); Errors=@()
    }
    $updatedInventory = [pscustomobject]@{
        Available=$true; Status='Ready'; UpdatesScanned=$true; UpdateSourcesScanned=@('winget'); Items=@([pscustomobject]@{
            WingetId='Fixture.sample'; DisplayName='Fixture sample'; Version='1.0'
            UpdateAvailable=$true; AvailableVersion='2.0'
        }); Errors=@()
    }
    $session = [pscustomobject]@{
        Catalog=[pscustomobject]@{ Packages=@($package); Errors=@() }
        System=New-FreshWinTestSystemInfo
        Network=[pscustomobject]@{ Status='Fixture'; InternetAvailable=$true }
        Inventory=$initialInventory
        Profiles=[pscustomobject]@{ Profiles=@(); Errors=@() }
        IncludeUpdates=$false
    }
    $state = [pscustomobject]@{ Calls=0; IncludeUpdates=$null }
    $inputQueue = New-Object System.Collections.Queue
    $inputQueue.Enqueue('U')
    $inputQueue.Enqueue('0')
    $output = New-Object System.Collections.Generic.List[string]

    Show-FreshWinTerminalPackageCenter -Session $session -Center applications -DryRun `
        -InventoryProvider { param($includeUpdates) $state.Calls++; $state.IncludeUpdates=[bool]$includeUpdates; return $updatedInventory } `
        -InputProvider { param($prompt) return $inputQueue.Dequeue() } `
        -OutputWriter { param($line) $output.Add([string]$line) }

    Assert-FreshWinEqual -Expected 1 -Actual $state.Calls
    Assert-FreshWinTrue $state.IncludeUpdates
    Assert-FreshWinTrue $session.IncludeUpdates
    Assert-FreshWinTrue ([object]::ReferenceEquals($updatedInventory, $session.Inventory))
    Assert-FreshWinMatch -Actual ($output -join [Environment]::NewLine) -Pattern 'View: UPDATES[\s\S]*\[UP\]'
}

Add-FreshWinTest -Name 'Every terminal assistant update intent refreshes inventory before planning' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    [void](Initialize-FreshWinAssistant)
    foreach ($request in @('update', 'update sample')) {
        $package = New-FreshWinTestPackage
        $initialInventory = [pscustomobject]@{
            Available=$true; Status='Ready'; Items=@([pscustomobject]@{
                WingetId='Fixture.sample'; DisplayName='Fixture sample'; Version='1.0'
                UpdateAvailable=$false; AvailableVersion=$null
            }); Errors=@()
        }
        $updatedInventory = [pscustomobject]@{
            Available=$true; Status='Ready'; UpdatesScanned=$true; UpdateSourcesScanned=@('winget'); Items=@([pscustomobject]@{
                WingetId='Fixture.sample'; DisplayName='Fixture sample'; Version='1.0'
                UpdateAvailable=$true; AvailableVersion='2.0'
            }); Errors=@()
        }
        $session = [pscustomobject]@{
            Catalog=[pscustomobject]@{ Packages=@($package); Errors=@() }
            System=New-FreshWinTestSystemInfo
            Network=[pscustomobject]@{ Status='Fixture'; InternetAvailable=$true }
            Inventory=$initialInventory
            Profiles=[pscustomobject]@{ Profiles=@(); Errors=@() }
            IncludeUpdates=$false
        }
        $state = [pscustomobject]@{ Calls=0; IncludeUpdates=$null }
        $inputQueue = New-Object System.Collections.Queue
        $inputQueue.Enqueue($request)
        $inputQueue.Enqueue('0')
        $output = New-Object System.Collections.Generic.List[string]

        Show-FreshWinTerminalAssistant -Session $session -DryRun `
            -InventoryProvider { param($includeUpdates) $state.Calls++; $state.IncludeUpdates=[bool]$includeUpdates; return $updatedInventory } `
            -InputProvider { param($prompt) return $inputQueue.Dequeue() } `
            -OutputWriter { param($line) $output.Add([string]$line) }

        Assert-FreshWinEqual -Expected 1 -Actual $state.Calls -Because "Assistant request '$request' did not refresh inventory exactly once."
        Assert-FreshWinTrue $state.IncludeUpdates -Because "Assistant request '$request' did not request update evidence."
        Assert-FreshWinTrue $session.IncludeUpdates
        Assert-FreshWinTrue ([object]::ReferenceEquals($updatedInventory, $session.Inventory))
        Assert-FreshWinMatch -Actual ($output -join [Environment]::NewLine) -Pattern 'UPDATE sample' `
            -Because "Assistant request '$request' did not plan from the refreshed update snapshot."
    }
}

Add-FreshWinTest -Name 'Update center and Assistant distinguish unknown update state from a scanned empty result' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    [void](Initialize-FreshWinAssistant)
    $package = New-FreshWinTestPackage
    foreach ($case in @(
        [pscustomobject]@{
            Name='unknown'; Expected='Community WinGet update state is unknown'; Unexpected='No community WinGet package updates were observed'
            Inventory=[pscustomobject]@{ Available=$true; Status='Partial'; UpdatesScanned=$false; Items=@(); Errors=@('fixture upgrade provider failed') }
        },
        [pscustomobject]@{
            Name='empty'; Expected='No community WinGet package updates were observed'; Unexpected='Community WinGet update state is unknown'
            Inventory=[pscustomobject]@{ Available=$true; Status='Ready'; UpdatesScanned=$true; UpdateSourcesScanned=@('winget'); Items=@(); Errors=@() }
        }
    )) {
        $session = [pscustomobject]@{
            Catalog=[pscustomobject]@{ Packages=@($package); Errors=@() }
            System=New-FreshWinTestSystemInfo
            Network=[pscustomobject]@{ Status='Fixture'; InternetAvailable=$true }
            Inventory=[pscustomobject]@{ Available=$true; Status='Ready'; UpdatesScanned=$false; Items=@(); Errors=@() }
            Profiles=[pscustomobject]@{ Profiles=@(); Errors=@() }
            IncludeUpdates=$false
        }
        $inputs = New-Object System.Collections.Queue
        $inputs.Enqueue('update')
        $output = New-Object System.Collections.Generic.List[string]
        [void](Show-FreshWinTerminalAssistant -Session $session -DryRun `
            -InventoryProvider { param($includeUpdates) $case.Inventory } `
            -InputProvider { param($prompt) if ($inputs.Count -eq 0) { return $null }; return $inputs.Dequeue() } `
            -OutputWriter { param($line) $output.Add([string]$line) })
        $text = $output -join "`n"
        Assert-FreshWinMatch -Actual $text -Pattern ([regex]::Escape($case.Expected)) -Because "Assistant case '$($case.Name)' reported the wrong update conclusion."
        Assert-FreshWinFalse -Actual ($text -match [regex]::Escape($case.Unexpected))
        if ($case.Name -eq 'unknown') { Assert-FreshWinMatch -Actual $text -Pattern 'fixture upgrade provider failed' }
    }

    $centerSession = [pscustomobject]@{
        Catalog=[pscustomobject]@{ Packages=@($package); Errors=@() }
        System=New-FreshWinTestSystemInfo
        Network=[pscustomobject]@{ Status='Fixture'; InternetAvailable=$true }
        Inventory=[pscustomobject]@{ Available=$true; Status='Ready'; UpdatesScanned=$false; Items=@(); Errors=@() }
        Profiles=[pscustomobject]@{ Profiles=@(); Errors=@() }
        IncludeUpdates=$false
    }
    $centerOutput = New-Object System.Collections.Generic.List[string]
    [void](Show-FreshWinTerminalPackageCenter -Session $centerSession -Center updates -DryRun `
        -InventoryProvider { param($includeUpdates) [pscustomobject]@{ Available=$true; Status='Partial'; UpdatesScanned=$false; Items=@(); Errors=@('fixture center provider failed') } } `
        -InputProvider { param($prompt) '0' } -OutputWriter { param($line) $centerOutput.Add([string]$line) })
    $centerText = $centerOutput -join "`n"
    Assert-FreshWinMatch -Actual $centerText -Pattern 'Community WinGet update state is unknown'
    Assert-FreshWinMatch -Actual $centerText -Pattern 'fixture center provider failed'
    Assert-FreshWinFalse -Actual ($centerText -match 'Packages shown: 0')
}

Add-FreshWinTest -Name 'CLI Assistant returns non-success for unknown update state and NothingToDo only after a completed empty scan' -Category 'CLI' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
    $intent = [pscustomobject]@{ isValid=$true; action='queue_update'; targets=@(); parameters=[pscustomobject]@{} }
    foreach ($case in @(
        [pscustomobject]@{ UpdatesScanned=$false; UpdateSourcesScanned=@(); Status='Partial'; Errors=@('fixture provider failed'); ExpectedExit=1; ExpectedStatus='UpdateStateUnknown' },
        [pscustomobject]@{ UpdatesScanned=$true; Status='Ready'; UpdateSourcesScanned=@('winget'); Errors=@(); ExpectedExit=0; ExpectedStatus='NothingToDo' }
    )) {
        $parsed = ConvertFrom-FreshWinCommandLine -Arguments @('assistant','update','--dry-run')
        $context = [pscustomobject]@{
            System=New-FreshWinTestSystemInfo
            Inventory=[pscustomobject]@{ Available=$true; Status=$case.Status; UpdatesScanned=$case.UpdatesScanned; UpdateSourcesScanned=@($case.UpdateSourcesScanned); Items=@(); Errors=$case.Errors }
        }
        $result = Invoke-FreshWinCliAssistantDispatch -Intent $intent -Parsed $parsed -Catalog $catalog -Context $context 6>$null
        Assert-FreshWinEqual -Expected $case.ExpectedExit -Actual $result.ExitCode
        Assert-FreshWinEqual -Expected $case.ExpectedStatus -Actual $result.Data.Status
    }

    $storePackage = New-FreshWinTestPackage -Id store-fixture -SourceType msstore
    $storeIntent = [pscustomobject]@{ isValid=$true; action='queue_update'; targets=@('store-fixture'); parameters=[pscustomobject]@{} }
    $storeParsed = ConvertFrom-FreshWinCommandLine -Arguments @('assistant','update','store-fixture','--dry-run')
    $storeContext = [pscustomobject]@{
        System=New-FreshWinTestSystemInfo
        Inventory=[pscustomobject]@{ Available=$true; Status='Ready'; UpdatesScanned=$true; UpdateSourcesScanned=@('winget'); Items=@(); Errors=@() }
    }
    $storeResult = Invoke-FreshWinCliAssistantDispatch -Intent $storeIntent -Parsed $storeParsed `
        -Catalog ([pscustomobject]@{ Packages=@($storePackage); Errors=@() }) -Context $storeContext 6>$null
    Assert-FreshWinEqual -Expected 1 -Actual $storeResult.ExitCode
    Assert-FreshWinEqual -Expected 'UpdateStateUnknown' -Actual $storeResult.Data.Status
    Assert-FreshWinContains -Collection @($storeResult.Data.ManualReviewTargets) -Expected 'store-fixture'
    Assert-FreshWinMatch -Actual $storeResult.Data.Reason -Pattern 'outside the community WinGet update scan'
}

Add-FreshWinTest -Name 'Terminal assistant dispatches every deterministic read-only intent to observed data or an existing center' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    [void](Initialize-FreshWinAssistant)
    $catalog = Import-FreshWinPackageCatalog
    $profiles = Import-FreshWinProfiles -Catalog $catalog
    $session = [pscustomobject]@{
        Catalog=$catalog
        System=[pscustomobject]@{
            Status='Fixture'; OSFamily='Windows11'; OSName='Microsoft Windows 11 Fixture'; BuildNumber=22631; Architecture='x64'
            CPU='Fixture CPU'; MemoryGB=32; Manufacturer='Fixture OEM'; Model='Fixture Model'; Admin=$false
            GPUs=@([pscustomobject]@{ Name='Fixture GPU'; Vendor='NVIDIA'; DriverVersion='1.2.3' })
        }
        Network=[pscustomobject]@{ Status='Fixture'; InternetAvailable=$true }
        Inventory=[pscustomobject]@{
            Available=$true; Status='Ready'; UpdatesScanned=$true; Errors=@()
            Items=@([pscustomobject]@{ WingetId='Git.Git'; DisplayName='Fixture App'; Version='2.0'; UpdateAvailable=$true; AvailableVersion='2.1' })
        }
        Profiles=$profiles
        IncludeUpdates=$false
    }
    $state = [pscustomobject]@{ DriverCalls=0; DiagnosticsCalls=0; UpdateCalls=0 }
    $driverProvider = {
        $state.DriverCalls++
        return @([pscustomobject]@{
            Component='DriverScanner'; Name='Fixture Ethernet'; Category='Network'; Health='Healthy'; Priority='Optional'
            Reason='Fixture observation.'; ScanErrors=@(); IsLive=$false
        })
    }
    $diagnosticsProvider = {
        $state.DiagnosticsCalls++
        return [pscustomobject]@{
            Status='FixtureOrPortableObserved'; IsLive=$false; Errors=@()
            Components=[pscustomobject]@{ System=[pscustomobject]@{ Status='Ready'; Errors=@() } }
        }
    }
    $windowsUpdateProvider = {
        $state.UpdateCalls++
        return [pscustomobject]@{
            Status='Attention'; PendingCount=1; RestartPending=$false; Errors=@()
            Updates=@([pscustomobject]@{ Title='Fixture cumulative update'; KBArticleIds=@('5000000'); IsDriver=$false; RebootRequired=$false })
        }
    }
    $cases = @(
        [pscustomobject]@{ Request='status'; Expected='Microsoft Windows 11 Fixture'; ExtraInput=@() },
        [pscustomobject]@{ Request='system info'; Expected='Fixture CPU'; ExtraInput=@() },
        [pscustomobject]@{ Request='search git'; Expected='Git'; ExtraInput=@() },
        [pscustomobject]@{ Request='scan drivers'; Expected='Fixture Ethernet'; ExtraInput=@() },
        [pscustomobject]@{ Request='drivers'; Expected='Fixture Ethernet'; ExtraInput=@() },
        [pscustomobject]@{ Request='doctor'; Expected='Overall health'; ExtraInput=@() },
        [pscustomobject]@{ Request='apps'; Expected='Fixture App'; ExtraInput=@() },
        [pscustomobject]@{ Request='updates'; Expected='Fixture cumulative update'; ExtraInput=@() },
        [pscustomobject]@{ Request='missing'; Expected='Packages shown:'; ExtraInput=@() },
        [pscustomobject]@{ Request='help'; Expected='install <package IDs>'; ExtraInput=@() },
        [pscustomobject]@{ Request='gaming'; Expected='Gaming'; ExtraInput=@('0') },
        [pscustomobject]@{ Request='developer'; Expected='Developer'; ExtraInput=@('0') }
    )
    foreach ($case in $cases) {
        $inputs = New-Object System.Collections.Queue
        $inputs.Enqueue([string]$case.Request)
        foreach ($extra in @($case.ExtraInput)) { $inputs.Enqueue([string]$extra) }
        $output = New-Object System.Collections.Generic.List[string]
        Show-FreshWinTerminalAssistant -Session $session -DryRun `
            -DriverInventoryProvider $driverProvider -DiagnosticsProvider $diagnosticsProvider -WindowsUpdateProvider $windowsUpdateProvider `
            -InputProvider { param($prompt) if ($inputs.Count -eq 0) { return $null }; return $inputs.Dequeue() } `
            -OutputWriter { param($line) $output.Add([string]$line) }
        Assert-FreshWinMatch -Actual ($output -join [Environment]::NewLine) -Pattern ([regex]::Escape([string]$case.Expected)) `
            -Because "Assistant request '$($case.Request)' did not dispatch to its observed result or existing center."
    }
    Assert-FreshWinEqual 2 $state.DriverCalls
    Assert-FreshWinEqual 1 $state.DiagnosticsCalls
    Assert-FreshWinEqual 1 $state.UpdateCalls
}

Add-FreshWinTest -Name 'Terminal assistant never executes driver backup directly and keeps package mutations on the shared plan workflow' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    [void](Initialize-FreshWinAssistant)
    $session = [pscustomobject]@{
        Catalog=[pscustomobject]@{ Packages=@(); Errors=@() }
        System=New-FreshWinTestSystemInfo
        Network=[pscustomobject]@{ Status='Fixture'; InternetAvailable=$true }
        Inventory=[pscustomobject]@{ Available=$true; Status='Ready'; UpdatesScanned=$false; Items=@(); Errors=@() }
        Profiles=[pscustomobject]@{ Profiles=@(); Errors=@() }
        IncludeUpdates=$false
    }
    $inputs = New-Object System.Collections.Queue
    $inputs.Enqueue('backup drivers')
    $output = New-Object System.Collections.Generic.List[string]
    Show-FreshWinTerminalAssistant -Session $session -DryRun `
        -DriverInventoryProvider { throw 'Driver inventory must not run for a backup intent.' } `
        -InputProvider { param($prompt) if ($inputs.Count -eq 0) { return $null }; return $inputs.Dequeue() } `
        -OutputWriter { param($line) $output.Add([string]$line) }
    Assert-FreshWinMatch -Actual ($output -join [Environment]::NewLine) -Pattern 'output is redirected below'

    $terminalSource = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/UI/Terminal.ps1'))
    Assert-FreshWinMatch -Actual $terminalSource -Pattern "action -in @\('queue_install','queue_update','recommend_profile'\)[\s\S]*Invoke-FreshWinTerminalPlanWorkflow" `
        -Because 'Assistant package/profile mutations must stay on the shared planner and execution workflow.'
}

Add-FreshWinTest -Name 'Terminal portable-profile restore refreshes inventory for the declared update policy before planning' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $temporary = New-FreshWinTestDirectory
    try {
        $catalog = Import-FreshWinPackageCatalog
        $package = Get-FreshWinPackage -Catalog $catalog -Id git
        $profileDirectory = if ($temporary.StartsWith('/var/')) { '/private' + $temporary } else { $temporary }
        foreach ($case in @(
            [pscustomobject]@{ Policy='include-updates'; Initial=$false; Expected=$true; ExpectedAction='UPDATE'; UpdateAvailable=$true },
            [pscustomobject]@{ Policy='missing-only'; Initial=$true; Expected=$false; ExpectedAction='SKIP'; UpdateAvailable=$false }
        )) {
            $profilePath = Join-Path $profileDirectory ("$($case.Policy).json")
            [void](Export-FreshWinProfile -Path $profilePath -PackageIds @('git') -UpdatePolicy $case.Policy -Catalog $catalog)
            $initialInventory = [pscustomobject]@{ Available=$true; Status='Ready'; Items=@(); Errors=@() }
            $refreshedInventory = [pscustomobject]@{
                Available=$true; Status='Ready'; Items=@([pscustomobject]@{
                    WingetId='Git.Git'; DisplayName='Git'; Version='1.0'
                    UpdateAvailable=[bool]$case.UpdateAvailable; AvailableVersion=$(if ($case.UpdateAvailable) { '2.0' } else { $null })
                }); Errors=@()
            }
            $session = [pscustomobject]@{
                Catalog=$catalog
                System=New-FreshWinTestSystemInfo
                Network=[pscustomobject]@{ Status='Fixture'; InternetAvailable=$true }
                Inventory=$initialInventory
                Profiles=[pscustomobject]@{ Profiles=@(); Errors=@() }
                IncludeUpdates=[bool]$case.Initial
            }
            $state = [pscustomobject]@{ Calls=0; IncludeUpdates=$null }
            $inputQueue = New-Object System.Collections.Queue
            $inputQueue.Enqueue('4')
            $inputQueue.Enqueue($profilePath)
            $inputQueue.Enqueue('0')
            $inputQueue.Enqueue('0')
            $output = New-Object System.Collections.Generic.List[string]

            Show-FreshWinTerminalBackup -Session $session -DryRun `
                -InventoryProvider { param($includeUpdates) $state.Calls++; $state.IncludeUpdates=[bool]$includeUpdates; return $refreshedInventory } `
                -InputProvider { param($prompt) return $inputQueue.Dequeue() } `
                -OutputWriter { param($line) $output.Add([string]$line) }

            Assert-FreshWinEqual -Expected 1 -Actual $state.Calls -Because "Restore policy '$($case.Policy)' did not refresh inventory exactly once."
            Assert-FreshWinEqual -Expected ([bool]$case.Expected) -Actual ([bool]$state.IncludeUpdates)
            Assert-FreshWinEqual -Expected ([bool]$case.Expected) -Actual ([bool]$session.IncludeUpdates)
            Assert-FreshWinTrue ([object]::ReferenceEquals($refreshedInventory, $session.Inventory))
            Assert-FreshWinMatch -Actual ($output -join [Environment]::NewLine) -Pattern ("$($case.ExpectedAction) git") `
                -Because "Restore policy '$($case.Policy)' did not plan from its refreshed inventory."
        }
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Resume parser accepts an integrity hash normally and registers RunOnce only by explicit flag' -Category 'CLI' -ScriptBlock {
    $path = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path 'fixture-checkpoint.json'))
    $hash = 'a' * 64
    $runOnce = ConvertFrom-FreshWinCommandLine -Arguments @('--resume', $path, '--checkpoint-hash', $hash, '--register-resume')
    Assert-FreshWinTrue $runOnce.Valid
    Assert-FreshWinEqual -Expected 'resume' -Actual $runOnce.Command
    Assert-FreshWinEqual -Expected $hash -Actual $runOnce.CheckpointHash
    Assert-FreshWinTrue $runOnce.RegisterResume

    $normal = ConvertFrom-FreshWinCommandLine -Arguments @('resume', $path, '--checkpoint-hash', $hash)
    Assert-FreshWinTrue $normal.Valid
    Assert-FreshWinFalse $normal.RegisterResume

    $unsafeHelper = ConvertFrom-FreshWinCommandLine -Arguments @('--resume', $path, '--elevated-helper')
    Assert-FreshWinFalse $unsafeHelper.Valid
    Assert-FreshWinMatch -Actual $unsafeHelper.Error -Pattern 'checkpoint-hash'

    $callerSid = 'S-1-5-21-1000-1001-1002-1003'
    $handoffId = 'b' * 32
    $helper = ConvertFrom-FreshWinCommandLine -Arguments @('--resume', $path, '--checkpoint-hash', $hash, '--caller-sid', $callerSid, '--handoff-id', $handoffId, '--elevated-helper')
    Assert-FreshWinTrue $helper.Valid
    Assert-FreshWinEqual $callerSid $helper.CallerSid
    Assert-FreshWinEqual $handoffId $helper.HandoffId
    $unboundCaller = ConvertFrom-FreshWinCommandLine -Arguments @('resume', $path, '--caller-sid', $callerSid)
    Assert-FreshWinFalse $unboundCaller.Valid
    Assert-FreshWinMatch -Actual $unboundCaller.Error -Pattern 'controlled elevation helper'

    foreach ($unsafePath in @('//server/share/checkpoint.json', '\\server\share\checkpoint.json', '\\?\C:\checkpoint.json', '\\.\C:\checkpoint.json')) {
        $unsafePathResult = ConvertFrom-FreshWinCommandLine -Arguments @('--resume', $unsafePath, '--checkpoint-hash', $hash)
        Assert-FreshWinFalse $unsafePathResult.Valid -Because "Resume accepted unsafe path '$unsafePath'."
        Assert-FreshWinMatch -Actual $unsafePathResult.Error -Pattern 'absolute local path'
        $unsafePositionalResult = ConvertFrom-FreshWinCommandLine -Arguments @('resume', $unsafePath, '--checkpoint-hash', $hash)
        Assert-FreshWinFalse $unsafePositionalResult.Valid -Because "Positional resume accepted unsafe path '$unsafePath'."
        Assert-FreshWinMatch -Actual $unsafePositionalResult.Error -Pattern 'absolute local path'
    }
}

Add-FreshWinTest -Name 'Compact and full CLI help document the complete command surface and explicit resume policy' -Category 'CLI' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $full = Get-FreshWinCliHelp
    $compact = Get-FreshWinCliHelp -Compact
    foreach ($command in @('gaming','developer','profile','restore-profile','backup-drivers','network-rescue','security','diagnostics','export-diagnostics','ddu-plan','assistant')) {
        Assert-FreshWinMatch -Actual $full -Pattern ([regex]::Escape($command))
        Assert-FreshWinMatch -Actual $compact -Pattern ([regex]::Escape($command))
    }
    foreach ($option in @('--register-resume','--checkpoint-hash')) {
        Assert-FreshWinMatch -Actual $full -Pattern ([regex]::Escape($option))
    }
    Assert-FreshWinMatch -Actual $compact -Pattern 'never registered implicitly'
}

Add-FreshWinTest -Name 'CLI and terminal mutation routes use the shared planner and execution queue' -Category 'Security' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $cliSource = [System.IO.File]::ReadAllText((Join-Path $root 'src/UI/Cli.ps1'))
    $terminalSource = [System.IO.File]::ReadAllText((Join-Path $root 'src/UI/Terminal.ps1'))
    Assert-FreshWinMatch -Actual $cliSource -Pattern 'function\s+Invoke-FreshWinCliPackageWorkflow[\s\S]*New-FreshWinInstallPlan[\s\S]*Invoke-FreshWinExecutionPlan'
    Assert-FreshWinMatch -Actual $terminalSource -Pattern 'function\s+Invoke-FreshWinTerminalPlanWorkflow[\s\S]*New-FreshWinInstallPlan[\s\S]*Invoke-FreshWinExecutionPlan'
    Assert-FreshWinMatch -Actual $terminalSource -Pattern 'Invoke-FreshWinElevatedResume[^\r\n]*-Wait' `
        -Because 'Terminal must wait for the elevated helper before refreshing inventory or accepting another plan.'
    Assert-FreshWinMatch -Actual $cliSource -Pattern '\$parsed\.ElevatedHelper[\s\S]*\{\s*''AdminOnly''\s*\}[\s\S]*Invoke-FreshWinExecutionPlan[^\r\n]*-ExecutionMode\s+\$resumeExecutionMode' `
        -Because 'The elevated helper must execute only catalog actions that require administrator rights.'
    Assert-FreshWinMatch -Actual $cliSource -Pattern 'ProtectedCheckpointPath[\s\S]*Restore-FreshWinPlanFromCheckpoint[\s\S]*-ExecutionMode\s+NonAdminOnly' `
        -Because 'CLI must return to a refreshed non-admin phase after the protected elevated phase.'
    Assert-FreshWinMatch -Actual $terminalSource -Pattern 'ProtectedCheckpointPath[\s\S]*Restore-FreshWinPlanFromCheckpoint[\s\S]*-ExecutionMode\s+NonAdminOnly' `
        -Because 'Terminal must return to a refreshed non-admin phase after the protected elevated phase.'
    Assert-FreshWinMatch -Actual $cliSource -Pattern '''restore-profile''\s*\{[\s\S]*Import-FreshWinUserProfile[\s\S]*\$parsed\.IncludeUpdates\s*=\s*\$profileIncludesUpdates[\s\S]*Invoke-FreshWinCliPackageWorkflow\s+-Command\s+restore-profile' `
        -Because 'CLI portable-profile restore must honor its update policy and route through the shared planner.'
    Assert-FreshWinMatch -Actual $terminalSource -Pattern 'Import-FreshWinUserProfile[\s\S]*\$profileIncludesUpdates\s*=[\s\S]*Set-FreshWinTerminalInventoryPolicy\s+-Session\s+\$Session\s+-IncludeUpdates\s+\$profileIncludesUpdates[\s\S]*Invoke-FreshWinTerminalPlanWorkflow' `
        -Because 'Terminal portable-profile restore must refresh the policy-specific inventory and route through the shared planner.'
    Assert-FreshWinFalse ($cliSource -match 'Invoke-FreshWinPackageInstall') -Because 'CLI commands must not call the package installer directly.'
    Assert-FreshWinFalse ($terminalSource -match 'Invoke-FreshWinPackageInstall') -Because 'Terminal centers must not call the package installer directly.'
    foreach ($operation in @('Get-FreshWinGpuDriverRecommendation','Get-FreshWinNetworkRescueState','New-FreshWinDduRecoveryPlan','Get-FreshWinSecurityStatus','Get-FreshWinDiagnostics','Get-FreshWinHealthSummary','Export-FreshWinDiagnostics','New-FreshWinDriverBackup','New-FreshWinPreResetPlan')) {
        Assert-FreshWinMatch -Actual $terminalSource -Pattern ([regex]::Escape($operation)) -Because "Terminal did not wire $operation."
    }
}

Add-FreshWinTest -Name 'Unavailable inventory blocks planning while an installed snapshot skips without a process' -Category 'Security' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
    $system = New-FreshWinTestSystemInfo
    $wingetFixture = (Get-Process -Id $PID).Path

    $unavailable = [pscustomobject]@{ Available=$false; Status='Failed'; Items=@(); Errors=@('fixture inventory unavailable') }
    $blockedPlan = New-FreshWinInstallPlan -PackageIds sample -Catalog $catalog -SystemInfo $system -Inventory $unavailable -WingetPath $wingetFixture
    Assert-FreshWinEqual -Expected 'Unknown' -Actual $blockedPlan.Items[0].Detection.State
    Assert-FreshWinEqual -Expected 'BLOCKED' -Actual $blockedPlan.Items[0].Action
    $state = [pscustomobject]@{ ProcessCalls = 0 }
    [void](Invoke-FreshWinExecutionPlan -Plan $blockedPlan -Catalog $catalog -SystemInfo $system -Inventory $unavailable `
        -ProcessInvoker { $state.ProcessCalls++; throw 'Process must not run for unknown inventory.' })
    Assert-FreshWinEqual -Expected 0 -Actual $state.ProcessCalls

    $installed = [pscustomobject]@{ Available=$true; Status='Ready'; Items=@([pscustomobject]@{ WingetId='Fixture.sample'; DisplayName='Fixture sample'; Version='1.0' }); Errors=@() }
    $skipPlan = New-FreshWinInstallPlan -PackageIds sample -Catalog $catalog -SystemInfo $system -Inventory $installed -WingetPath $wingetFixture
    Assert-FreshWinEqual -Expected 'Installed' -Actual $skipPlan.Items[0].Detection.State
    Assert-FreshWinEqual -Expected 'SKIP' -Actual $skipPlan.Items[0].Action
    [void](Invoke-FreshWinExecutionPlan -Plan $skipPlan -Catalog $catalog -SystemInfo $system -Inventory $installed `
        -ProcessInvoker { $state.ProcessCalls++; throw 'Process must not run for an installed package.' })
    Assert-FreshWinEqual -Expected 0 -Actual $state.ProcessCalls
}

Add-FreshWinTest -Name 'CLI output path resolver refuses relative paths and overwrites' -Category 'Security' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $path = Join-Path $temporary 'diagnostics.json'
        Assert-FreshWinEqual -Expected ([System.IO.Path]::GetFullPath($path)) -Actual (Resolve-FreshWinCliNewOutputPath -Path $path -AllowedExtensions @('.json'))
        [System.IO.File]::WriteAllText($path, '{}')
        Assert-FreshWinThrows -ScriptBlock { Resolve-FreshWinCliNewOutputPath -Path $path -AllowedExtensions @('.json') } -Pattern 'overwrite'
        Assert-FreshWinThrows -ScriptBlock { Resolve-FreshWinCliNewOutputPath -Path 'relative.json' -AllowedExtensions @('.json') } -Pattern 'absolute'
        Assert-FreshWinThrows -ScriptBlock { Resolve-FreshWinCliNewOutputPath -Path (Join-Path $temporary 'report.txt') -AllowedExtensions @('.json') } -Pattern 'extensions'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Mutating JSON workflows require explicit authorization without an invisible prompt' -Category 'Security' -ScriptBlock {
    $cliSource = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/UI/Cli.ps1'))
    Assert-FreshWinMatch -Actual $cliSource -Pattern '\$Parsed\.Json\s+-and\s+-not\s+\$Parsed\.Yes[\s\S]*Status=''ConfirmationRequired''[\s\S]*Explicit --yes is required for a mutating JSON command' `
        -Because 'Install/profile JSON mode must return a structured plan instead of prompting for an unseen plan.'
    Assert-FreshWinMatch -Actual $cliSource -Pattern '\$parsed\.Json[\s\S]*Review the rebuilt plan and repeat with --yes[\s\S]*Explicit --yes is required for a mutating JSON resume' `
        -Because 'JSON resume must never prompt interactively after suppressing the plan view.'
}

Add-FreshWinTest -Name 'CLI dry-run execution paths suppress checkpoints and output writes' -Category 'Security' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $cliSource = [System.IO.File]::ReadAllText((Join-Path $root 'src/UI/Cli.ps1'))
    $terminalSource = [System.IO.File]::ReadAllText((Join-Path $root 'src/UI/Terminal.ps1'))

    Assert-FreshWinMatch -Actual $cliSource -Pattern '\$checkpointPath\s*=\s*if\s*\(\$Parsed\.DryRun\)\s*\{\s*\$null\s*\}' `
        -Because 'CLI package dry-runs must never receive a checkpoint path.'
    Assert-FreshWinMatch -Actual $cliSource -Pattern 'if\s*\(-not\s+\$Parsed\.DryRun\)\s*\{\s*\[void\]\(Save-FreshWinInstallPlan' `
        -Because 'A dry-run with --output must not create a plan file.'
    Assert-FreshWinMatch -Actual $cliSource -Pattern '\$executionCheckpointPath\s*=\s*if\s*\(\[bool\]\$plan\.DryRun\)\s*\{\s*\$null\s*\}' `
        -Because 'A resumed dry-run must never write its source or protected checkpoint.'
    Assert-FreshWinMatch -Actual $terminalSource -Pattern '\$checkpointPath\s*=\s*if\s*\(\$DryRun\)\s*\{\s*\$null\s*\}' `
        -Because 'Interactive dry-runs must never receive a checkpoint path.'
}

Add-FreshWinTest -Name 'Resume elevation is explicit hash-bound and switches to a protected checkpoint' -Category 'Security' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $cliSource = [System.IO.File]::ReadAllText((Join-Path $root 'src/UI/Cli.ps1'))
    $elevationSource = [System.IO.File]::ReadAllText((Join-Path $root 'src/Execution/Elevation.ps1'))

    Assert-FreshWinMatch -Actual $cliSource -Pattern 'Get-FreshWinExecutionCheckpoint\s+-Path\s+\$resumePath\s+-ExpectedSha256\s+\$expectedHash' `
        -Because 'The incoming checkpoint must be verified before a plan is restored.'
    Assert-FreshWinMatch -Actual $cliSource -Pattern '\$resumeElevation\s*=\s*Get-FreshWinPlanElevationRequirement[\s\S]*Invoke-FreshWinElevatedResume\s+@elevationParameters' `
        -Because 'A trusted pending admin plan must go through the controlled elevation helper.'
    Assert-FreshWinMatch -Actual $cliSource -Pattern '\$parsed\.ElevatedHelper[\s\S]*Get-FreshWinProtectedCheckpointPath' `
        -Because 'The elevated helper must continue from a protected checkpoint instead of writing the user checkpoint.'
    Assert-FreshWinMatch -Actual $cliSource -Pattern 'Get-FreshWinProtectedCheckpointPath\s+-ReaderSid[\s\S]*\$parsed\.CallerSid' `
        -Because 'The protected checkpoint ACL must grant read access to the original invoking SID, not an alternate administrator credential.'
    Assert-FreshWinMatch -Actual $elevationSource -Pattern '--caller-sid\s+\{3\}\s+--handoff-id\s+\{4\}\s+--elevated-helper' `
        -Because 'The original invoking SID must cross the controlled UAC boundary explicitly.'
    Assert-FreshWinFalse ($elevationSource -match '\$arguments\s*\+=\s*'' --register-resume''') `
        -Because 'The alternate elevated identity must never register RunOnce in its own HKCU.'
    Assert-FreshWinMatch -Actual $elevationSource -Pattern 'still running in the invoking user''s token[\s\S]*Register-FreshWinResume' `
        -Because 'Explicit RunOnce registration must occur in the original invoking user context.'
    Assert-FreshWinMatch -Actual $cliSource -Pattern 'Test-FreshWinUiExecutionRequiresReboot\s+-ExecutionResult\s+\$data[\s\S]*New-FreshWinCliRebootEnvelope[\s\S]*-RegisterResume:\$parsed\.RegisterResume' `
        -Because 'RunOnce registration must remain explicit and honor reboot evidence in a completed-with-issues summary.'
    Assert-FreshWinMatch -Actual $cliSource -Pattern 'Test-FreshWinLocalAbsolutePath\s+-Path\s+\$resumePath' `
        -Because 'Every positional or option resume path must pass the local-filesystem guard.'
}

Add-FreshWinTest -Name 'Terminal plan review can save safely, request edits, and previews without dry-run writes' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $temporary = New-FreshWinTestDirectory
    try {
        $package = New-FreshWinTestPackage
        $system = New-FreshWinTestSystemInfo
        $system.Admin = $false
        $system.IsAdministrator = $false
        $inventory = [pscustomobject]@{
            Available=$true; Status='Ready'; Errors=@()
            Items=@([pscustomobject]@{ WingetId='Fixture.sample'; DisplayName='Fixture sample'; Version='1.0' })
        }
        $session = [pscustomobject]@{
            Catalog=[pscustomobject]@{ Packages=@($package); Errors=@() }
            System=$system; Inventory=$inventory; IncludeUpdates=$false
        }

        $savedPath = Join-Path $temporary 'reviewed-plan.json'
        $saveInputs = New-Object System.Collections.Queue
        foreach ($value in @('S', $savedPath, 'E')) { $saveInputs.Enqueue($value) }
        $savedResult = Invoke-FreshWinTerminalPlanWorkflow -Session $session -PackageIds @('sample') `
            -InputProvider { param($prompt) return $saveInputs.Dequeue() } -OutputWriter { param($line) }
        Assert-FreshWinEqual -Expected 'EditRequested' -Actual $savedResult.Status
        Assert-FreshWinTrue ([System.IO.File]::Exists($savedPath))
        $persisted = [System.IO.File]::ReadAllText($savedPath) | ConvertFrom-Json
        Assert-FreshWinEqual -Expected ([string]$savedResult.Plan.Id) -Actual ([string]$persisted.Id)

        $previewPath = Join-Path $temporary 'dry-run-preview.json'
        $previewInputs = New-Object System.Collections.Queue
        foreach ($value in @('S', $previewPath, '0')) { $previewInputs.Enqueue($value) }
        $previewOutput = New-Object System.Collections.Generic.List[string]
        $previewResult = Invoke-FreshWinTerminalPlanWorkflow -Session $session -PackageIds @('sample') -DryRun `
            -InputProvider { param($prompt) return $previewInputs.Dequeue() } `
            -OutputWriter { param($line) $previewOutput.Add([string]$line) }
        Assert-FreshWinEqual -Expected 'Cancelled' -Actual $previewResult.Status
        Assert-FreshWinFalse ([System.IO.File]::Exists($previewPath)) -Because 'A terminal dry-run must not save a plan file.'
        Assert-FreshWinMatch -Actual ($previewOutput -join "`n") -Pattern 'no file was written'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Terminal self-update page reports validated status and requires explicit install review' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $output = New-Object System.Collections.Generic.List[string]
    $state = [pscustomobject]@{ InstallerCalls=0 }
    Show-FreshWinTerminalUpdateFreshWin -UpdateStatusProvider {
        [pscustomobject]@{
            Status='Available'; UpdateAvailable=$true; CurrentVersion='1.0.0'; AvailableVersion='1.1.0'
            MutationPerformed=$false; Reason='Trusted metadata fixture was validated.'
        }
    } -OutputWriter { param($line) $output.Add([string]$line) } -UpdateInstaller { param($status) $state.InstallerCalls++; throw 'must not run without input' }
    $text = $output -join "`n"
    Assert-FreshWinMatch -Actual $text -Pattern 'Installed version: 1\.0\.0'
    Assert-FreshWinMatch -Actual $text -Pattern 'Update check status: Available'
    Assert-FreshWinMatch -Actual $text -Pattern 'Available version: 1\.1\.0'
    Assert-FreshWinMatch -Actual $text -Pattern 'explicit INSTALL confirmation'
    Assert-FreshWinMatch -Actual $text -Pattern 'Install reviewed update'
    Assert-FreshWinEqual 0 $state.InstallerCalls
}

Add-FreshWinTest -Name 'Terminal self-update invokes the verified updater only after INSTALL confirmation and owns its result page' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $inputQueue = New-Object Collections.Generic.Queue[string]
    foreach ($value in @('I','INSTALL','0')) { $inputQueue.Enqueue($value) }
    $output = New-Object Collections.Generic.List[string]
    $state = [pscustomobject]@{ Calls=0 }
    Show-FreshWinTerminalUpdateFreshWin -UpdateStatusProvider {
        [pscustomobject]@{ Status='Available'; UpdateAvailable=$true; CurrentVersion='1.0.0'; AvailableVersion='1.1.0'; MutationPerformed=$false; Reason='fixture' }
    } -InputProvider { param($prompt) $inputQueue.Dequeue() } -OutputWriter { param($line) $output.Add([string]$line) } -UpdateInstaller {
        param($status) $state.Calls++; [pscustomobject]@{ Status='Installed'; Version='1.1.0'; Verified=$true }
    }
    Assert-FreshWinEqual 1 $state.Calls
    Assert-FreshWinMatch ($output -join "`n") 'FreshWin update result'
    Assert-FreshWinMatch ($output -join "`n") 'Verified: True'
}

Add-FreshWinTest -Name 'Terminal renders a protected reboot checkpoint before returning to a center' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $output = New-Object System.Collections.Generic.List[string]
    $registration = Show-FreshWinTerminalRebootBoundary -CheckpointPath 'C:\ProgramData\FreshWin\state\execution-checkpoint.json' `
        -EntryScriptPath 'C:\Program Files\FreshWin\FreshWin.ps1' -InputProvider { param($prompt) 'R' } `
        -OutputWriter { param($line) $output.Add([string]$line) } `
        -ResumeRegistrar { param($entry, $checkpoint) [pscustomobject]@{ Registered=$true; Entry=$entry; Checkpoint=$checkpoint } }
    Assert-FreshWinTrue $registration.Registered
    $rendered = $output -join "`n"
    Assert-FreshWinMatch -Actual $rendered -Pattern 'Restart required'
    Assert-FreshWinMatch -Actual $rendered -Pattern 'C:\\ProgramData\\FreshWin\\state\\execution-checkpoint\.json'
    Assert-FreshWinMatch -Actual $rendered -Pattern 'powershell\.exe[\s\S]+resume'
    Assert-FreshWinMatch -Actual $rendered -Pattern 'One-time resume was registered'
}

Add-FreshWinTest -Name 'Reboot UI helpers honor summary reboot evidence and preserve issue status in CLI envelopes' -Category 'Terminal' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $execution = [pscustomobject]@{
        Status='COMPLETED_WITH_ISSUES'
        Plan=[pscustomobject]@{ Id='fixture-plan' }
        Summary=[pscustomobject]@{ RebootRequired=$true; Failed=1 }
    }
    Assert-FreshWinTrue (Test-FreshWinUiExecutionRequiresReboot -ExecutionResult $execution)

    $envelope = New-FreshWinCliRebootEnvelope -ExecutionResult $execution `
        -CheckpointPath 'C:\ProgramData\FreshWin\state\execution-checkpoint.json' `
        -EntryScriptPath 'C:\Program Files\FreshWin\FreshWin.ps1' -RegisterResume `
        -ResumeRegistrar { param($entry, $checkpoint) [pscustomobject]@{ Registered=$true } }
    Assert-FreshWinEqual -Expected 'REBOOT_REQUIRED' -Actual $envelope.Status
    Assert-FreshWinEqual -Expected 'COMPLETED_WITH_ISSUES' -Actual $envelope.ExecutionStatus
    Assert-FreshWinEqual -Expected 'fixture-plan' -Actual $envelope.PlanId
    Assert-FreshWinTrue $envelope.ResumeRegistration.Requested
    Assert-FreshWinTrue $envelope.ResumeRegistration.Registered
    Assert-FreshWinMatch -Actual $envelope.ResumeCommand -Pattern '^(pwsh|powershell)\.exe .* resume "C:\\ProgramData'

    $failedRegistration = New-FreshWinCliRebootEnvelope -ExecutionResult $execution `
        -CheckpointPath 'C:\ProgramData\FreshWin\state\execution-checkpoint.json' `
        -EntryScriptPath 'C:\Program Files\FreshWin\FreshWin.ps1' -RegisterResume `
        -ResumeRegistrar { throw 'fixture registration failed' }
    Assert-FreshWinEqual -Expected 'COMPLETED_WITH_ISSUES' -Actual $failedRegistration.ExecutionStatus
    Assert-FreshWinEqual -Expected 'Failed' -Actual $failedRegistration.ResumeRegistration.Status
    Assert-FreshWinMatch -Actual $failedRegistration.ResumeRegistration.Error -Pattern 'fixture registration failed'

    $output = New-Object System.Collections.Generic.List[string]
    $terminalBoundary = Show-FreshWinTerminalExecutionRebootBoundary -ExecutionResult $execution `
        -CheckpointPath 'C:\ProgramData\FreshWin\state\execution-checkpoint.json' `
        -EntryScriptPath 'C:\Program Files\FreshWin\FreshWin.ps1' -InputProvider { param($prompt) '0' } `
        -OutputWriter { param($line) $output.Add([string]$line) }
    Assert-FreshWinFalse $terminalBoundary.Registered
    Assert-FreshWinMatch -Actual ($output -join "`n") -Pattern 'Restart required'

    $terminalSource = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/UI/Terminal.ps1'))
    Assert-FreshWinMatch -Actual $terminalSource -Pattern 'Show-FreshWinTerminalExecutionResult\s+-ExecutionResult\s+\$execution[\s\S]*Show-FreshWinTerminalExecutionRebootBoundary' `
        -Because 'Direct-admin and post-helper execution results must own the screen before rendering the reboot boundary.'
}
