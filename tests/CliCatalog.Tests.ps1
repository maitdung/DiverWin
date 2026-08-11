Add-FreshWinTest -Name 'Command-specific CLI help reports usage safety platform and examples' -Category 'CLI' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)

    $installHelp = Get-FreshWinCliHelp -Command install
    foreach ($heading in @('FreshWin command: install', 'Usage:', 'Purpose:', 'Safety:', 'Platform:', 'Examples:')) {
        Assert-FreshWinMatch -Actual $installHelp -Pattern ([regex]::Escape($heading))
    }
    Assert-FreshWinMatch -Actual $installHelp -Pattern '--dry-run'
    Assert-FreshWinMatch -Actual $installHelp -Pattern 'shared queue'

    $networkHelp = Get-FreshWinCliHelp -Command network-rescue
    Assert-FreshWinMatch -Actual $networkHelp -Pattern 'writes no rescue bundle'
    Assert-FreshWinMatch -Actual $networkHelp -Pattern 'does not download or install drivers'
    Assert-FreshWinMatch -Actual $networkHelp -Pattern '--retry'

    $dduHelp = Get-FreshWinCliHelp -Command ddu-plan
    Assert-FreshWinMatch -Actual $dduHelp -Pattern '--output'
    Assert-FreshWinMatch -Actual $dduHelp -Pattern 'never registers startup execution'

    $aliasHelp = Get-FreshWinCliHelp -Command diagnostics -Compact
    Assert-FreshWinMatch -Actual $aliasHelp -Pattern 'FreshWin command: doctor'
    Assert-FreshWinMatch -Actual $aliasHelp -Pattern 'Safety:'

    foreach ($command in @(
        'interactive', 'validate', 'catalog', 'list', 'search', 'status', 'doctor', 'diagnostics',
        'apps', 'drivers', 'updates', 'gaming', 'developer', 'security', 'history', 'recommend', 'profile',
        'restore-profile', 'plan', 'install', 'backup-drivers', 'network-rescue',
        'export-diagnostics', 'ddu-plan', 'resume', 'assistant', 'compact-mode', 'version', 'help'
    )) {
        $targetHelp = Get-FreshWinCliHelp -Command $command -Compact
        Assert-FreshWinMatch -Actual $targetHelp -Pattern 'Usage:' -Because "Help for '$command' omitted usage."
        Assert-FreshWinMatch -Actual $targetHelp -Pattern 'Platform:' -Because "Help for '$command' omitted platform requirements."
    }
}

Add-FreshWinTest -Name 'CLI compact-mode command persists only when not in dry-run' -Category 'CLI' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    $previousLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $temporary
        $configPath = Join-Path (Join-Path $temporary 'FreshWin') 'config.json'
        $preview = Invoke-FreshWinCli -Arguments @('compact-mode','on','--dry-run') 6>$null
        Assert-FreshWinEqual -Expected 0 -Actual $preview.ExitCode
        Assert-FreshWinEqual -Expected 'Preview' -Actual $preview.Data.Status
        Assert-FreshWinFalse -Actual ([IO.File]::Exists($configPath))

        $saved = Invoke-FreshWinCli -Arguments @('compact-mode','on') 6>$null
        Assert-FreshWinEqual -Expected 0 -Actual $saved.ExitCode
        Assert-FreshWinTrue -Actual $saved.Data.CompactMode
        Assert-FreshWinTrue -Actual (Get-FreshWinConfig -Path $configPath).ui.compactMode

        $disabled = Invoke-FreshWinCli -Arguments @('compact-mode','off') 6>$null
        Assert-FreshWinEqual -Expected 0 -Actual $disabled.ExitCode
        Assert-FreshWinFalse -Actual (Get-FreshWinConfig -Path $configPath).ui.compactMode
    }
    finally {
        $env:LOCALAPPDATA = $previousLocalAppData
        Remove-FreshWinTestDirectory $temporary
    }
}

Add-FreshWinTest -Name 'CLI network rescue composes local folder state and bounded retry fixtures without mutation' -Category 'CLI' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $fixture = [pscustomobject]@{ StateCalls=0; RetryCalls=0; Folder=$null }
        $data = Get-FreshWinCliNetworkRescueData -LocalDriverFolder $temporary -Retry `
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
                [pscustomobject]@{ Status='StillOffline'; Attempts=@([pscustomobject]@{ Attempt=1 },[pscustomobject]@{ Attempt=2 },[pscustomobject]@{ Attempt=3 }); MutationPerformed=$false }
            }
        Assert-FreshWinEqual -Expected 1 -Actual $fixture.StateCalls
        Assert-FreshWinEqual -Expected 1 -Actual $fixture.RetryCalls
        Assert-FreshWinEqual -Expected ([System.IO.Path]::GetFullPath($temporary)) -Actual $fixture.Folder
        Assert-FreshWinEqual -Expected 'ReviewRequired' -Actual $data.Plan.Status
        Assert-FreshWinCount -Expected 3 -Actual $data.Retry.Attempts
        Assert-FreshWinFalse -Actual $data.MutationPerformed
        Assert-FreshWinFalse -Actual $data.Plan.AutomaticExecution

        $parsed = ConvertFrom-FreshWinCommandLine -Arguments @('network-rescue', $temporary, '--retry')
        Assert-FreshWinTrue -Actual $parsed.Valid
        Assert-FreshWinTrue -Actual $parsed.Retry
        Assert-FreshWinEqual -Expected ([System.IO.Path]::GetFullPath($temporary)) -Actual (Resolve-FreshWinCliNetworkDriverFolder -Path $temporary)
        Assert-FreshWinThrows -ScriptBlock { Resolve-FreshWinCliNetworkDriverFolder -Path 'relative-folder' } -Pattern 'absolute local path'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'CLI DDU checkpoint helper previews without writing and saves only a validated plan' -Category 'CLI' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $gpu = [pscustomobject]@{ Name='Fixture GPU'; Vendor='NVIDIA'; PnpDeviceId='PCI\VEN_10DE&DEV_0001'; DriverVersion='1.0'; Status='Problem' }
        $plan = New-FreshWinDduRecoveryPlan -GPUs @($gpu) -AcknowledgeAdvancedRisk
        $previewPath = Join-Path $temporary 'preview.json'
        $preview = Save-FreshWinCliDduCheckpointArtifact -Plan $plan -Path $previewPath -DryRun
        Assert-FreshWinEqual -Expected 'Preview' -Actual $preview.Status
        Assert-FreshWinFalse -Actual $preview.MutationPerformed
        Assert-FreshWinFalse -Actual ([System.IO.File]::Exists($previewPath))

        $savedPath = Join-Path $temporary 'saved.json'
        $saved = Save-FreshWinCliDduCheckpointArtifact -Plan $plan -Path $savedPath
        Assert-FreshWinEqual -Expected 'Saved' -Actual $saved.Status
        Assert-FreshWinTrue -Actual $saved.MutationPerformed
        Assert-FreshWinTrue -Actual ([System.IO.File]::Exists($savedPath))
        $restored = Get-FreshWinDduRecoveryCheckpoint -Path $savedPath
        Assert-FreshWinEqual -Expected 'ReplacementPreparationRequired' -Actual $restored.State
        Assert-FreshWinFalse -Actual $restored.AutomaticExecution
        Assert-FreshWinThrows -ScriptBlock { Save-FreshWinCliDduCheckpointArtifact -Plan $plan -Path $savedPath } -Pattern 'overwrite'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'CLI history is read-only bounded and validates its count' -Category 'CLI' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    $previousLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $temporary
        $empty = Invoke-FreshWinCli -Arguments @('history') 6>$null
        Assert-FreshWinEqual 0 $empty.ExitCode
        Assert-FreshWinEqual 'Empty' $empty.Data.Status
        Assert-FreshWinFalse $empty.Data.MutationPerformed
        Assert-FreshWinFalse ([IO.Directory]::Exists((Join-Path $temporary 'FreshWin'))) `
            -Because 'An empty history query must not initialize user-local state.'

        $invalid = Invoke-FreshWinCli -Arguments @('history', '501') 6>$null
        Assert-FreshWinEqual 1 $invalid.ExitCode
        Assert-FreshWinMatch $invalid.Error '1 to 500'

        $help = Get-FreshWinCliHelp -Command history -Compact
        Assert-FreshWinMatch $help 'Read-only'
        Assert-FreshWinMatch $help 'limited to 500'
    }
    finally {
        $env:LOCALAPPDATA = $previousLocalAppData
        Remove-FreshWinTestDirectory $temporary
    }
}

Add-FreshWinTest -Name 'CLI help rejects unknown and excess command targets and compact help includes version' -Category 'CLI' -ScriptBlock {
    Assert-FreshWinThrows -ScriptBlock { Get-FreshWinCliHelp -Command definitely-not-a-command } -Pattern 'Unknown help target'

    $unknown = Invoke-FreshWinCli -Arguments @('help', 'definitely-not-a-command') 6>$null
    Assert-FreshWinEqual -Expected 1 -Actual $unknown.ExitCode
    Assert-FreshWinMatch -Actual $unknown.Error -Pattern 'Unknown help target'

    $excess = Invoke-FreshWinCli -Arguments @('help', 'install', 'extra') 6>$null
    Assert-FreshWinEqual -Expected 1 -Actual $excess.ExitCode
    Assert-FreshWinMatch -Actual $excess.Error -Pattern 'at most one command name'

    $compact = Get-FreshWinCliHelp -Compact
    Assert-FreshWinMatch -Actual $compact -Pattern '(?m)^\s+.*version.*help\r?$'
}

Add-FreshWinTest -Name 'Catalog search is bounded literal and includes category and subcategory metadata' -Category 'Catalog' -ScriptBlock {
    $catalog = [pscustomobject]@{
        Packages = @(
            [pscustomobject]@{
                id = 'fixture-alpha'; name = 'Alpha'; publisher = 'Example'; tags = @('utility')
                category = 'developer'; subcategory = 'database'
            },
            [pscustomobject]@{
                id = 'fixture-beta'; name = 'Beta'; publisher = 'Example'; tags = @('browser')
                category = 'applications'; subcategory = 'web-browser'
            }
        )
    }

    Assert-FreshWinSetEqual -Expected @('fixture-alpha') -Actual @(
        Find-FreshWinPackage -Catalog $catalog -Query developer | ForEach-Object id
    )
    Assert-FreshWinSetEqual -Expected @('fixture-alpha') -Actual @(
        Find-FreshWinPackage -Catalog $catalog -Query database | ForEach-Object id
    )
    Assert-FreshWinSetEqual -Expected @('fixture-beta') -Actual @(
        Find-FreshWinPackage -Catalog $catalog -Query 'web-browser' | ForEach-Object id
    )
    Assert-FreshWinThrows -ScriptBlock {
        Find-FreshWinPackage -Catalog $catalog -Query ('x' * 129)
    } -Pattern '128 characters'
    Assert-FreshWinThrows -ScriptBlock {
        Find-FreshWinPackage -Catalog $catalog -Query "browser`nanything"
    } -Pattern 'control characters'
}
