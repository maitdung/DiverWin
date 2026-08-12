function New-FreshWinTestSystemInfo {
    return [pscustomobject]@{
        Component='SystemScanner'; IsSupported=$true; Supported=$true; IsLive=$false; Status='Fixture'
        OSFamily='Windows11'; OSName='Microsoft Windows 11'; BuildNumber=22631; Architecture='x64'
        MemoryGB=16; InternetAvailable=$true; VirtualizationEnabled=$true
        WslAvailable=$true; MicrosoftStoreAvailable=$true; GPUs=@(); Admin=$true; IsAdministrator=$true
    }
}

function New-FreshWinTestPackage {
    param(
        [string]$Id = 'sample',
        [string[]]$Dependencies = @(),
        [string]$Restart = 'none',
        [string]$SourceType = 'winget',
        [bool]$RequiresAdmin = $false,
        [bool]$Silent = $true
    )
    $source = if ($SourceType -eq 'manual') {
        [pscustomobject]@{ type='manual'; manualUrl='https://example.invalid/vendor'; reason='Fixture manual workflow.' }
    } else { [pscustomobject]@{ type=$SourceType; packageId="Fixture.$Id"; sourceName=$SourceType } }
    return [pscustomobject]@{
        schemaVersion='1.0'; id=$Id; name="Fixture $Id"; descriptionKey="packages.$Id.description"
        category='tool'; subcategory='test'; publisher='FreshWin tests'; officialWebsite='https://example.invalid/'
        source=$source
        compatibility=[pscustomobject]@{
            os=@('windows10','windows11'); minimumBuild=10240; architectures=@('x64','arm64')
            minimumRamGB=1; hardware=[pscustomobject]@{}; features=[pscustomobject]@{ internet=$true }
        }
        versionPolicy=[pscustomobject]@{ strategy='latest-compatible'; channel='stable' }
        detection=[pscustomobject]@{ wingetIds=@("Fixture.$Id"); registryDisplayNames=@("Fixture $Id"); knownPaths=@() }
        dependencies=@($Dependencies)
        install=[pscustomobject]@{ mode=$(if ($SourceType -eq 'manual') {'manual'} else {'silent'}); requiresAdmin=$RequiresAdmin; silent=$Silent; scope='either' }
        verification=[pscustomobject]@{ methods=@('winget'); minimumMatches=1 }
        restart=$Restart; riskLevel='SAFE'
        license=[pscustomobject]@{ type='open-source'; cost='free' }
        recommendation=[pscustomobject]@{ profiles=@('test'); default=$false; conditions=@() }
        tags=@('test')
    }
}

function New-FreshWinTestExecutionPlan {
    param([Parameter(Mandatory = $true)][object]$Package, [switch]$DryRun)
    $item = [pscustomobject]@{
        Id=[guid]::NewGuid().ToString('N'); PackageId=[string]$Package.id; Package=$Package; Requested=$true
        Action='INSTALL'; Reason='Fixture plan'; SafetyLevel='SAFE'; RequiresAdmin=$false
        RestartImpact='none'; RestartRequired=$false; DependencyIds=@(); Compatibility=$null; Detection=$null
        ResolvedSource=$null; State='PENDING'; Attempts=0; Result=$null; Verification=$null
    }
    return [pscustomobject]@{
        SchemaVersion=1; Id=[guid]::NewGuid().ToString('N'); CreatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
        FreshWinVersion='test'; DryRun=[bool]$DryRun; UpdatePolicy='missing-only'; Status='PLANNED'
        RequestedPackageIds=@([string]$Package.id); Items=@($item); Counts=[pscustomobject]@{ INSTALL=1 }
        RebootLikely=$false
    }
}

function New-FreshWinTestResolvedSource {
    param([Parameter(Mandatory = $true)][object]$Package)
    return [pscustomobject]@{
        PackageId=[string]$Package.id; SourceType='winget'; Status='Resolved'; Trust='FixtureBoundary'
        Executable=(Get-Process -Id $PID).Path; PackageManagerId="Fixture.$($Package.id)"; SourceName='winget'
        Uri=$null; FeatureName=$null; FeatureNames=@(); VersionPolicy=$Package.versionPolicy; Reason=$null
    }
}

Add-FreshWinTest -Name 'Hardware, system, network, activation, update, and driver scanners accept fixtures' -Category 'Fixtures' -ScriptBlock {
    $computer = [pscustomobject]@{
        TotalPhysicalMemory=16GB; Manufacturer='FixtureCo'; Model='FixtureBook'; PCSystemType=2; HypervisorPresent=$false
    }
    $processor = [pscustomobject]@{
        Name='Fixture CPU'; Manufacturer='Fixture'; NumberOfCores=8; NumberOfLogicalProcessors=16
        MaxClockSpeed=3200; VirtualizationFirmwareEnabled=$true; Status='OK'
    }
    $gpu = [pscustomobject]@{ Name='NVIDIA Fixture'; PNPDeviceID='PCI\VEN_10DE&DEV_0001'; DriverVersion='1.2.3'; Status='OK'; AdapterRAM=4GB }
    $disk = [pscustomobject]@{ Model='Fixture SSD'; Size=256GB; Status='OK'; InterfaceType='NVMe' }
    $hardware = Get-FreshWinHardwareInfo -ComputerSystem $computer -Processors @($processor) -VideoControllers @($gpu) `
        -DiskDrives @($disk) -Enclosures @() -Tpm ([pscustomobject]@{ TpmPresent=$true; TpmReady=$true; SpecVersion='2.0' }) `
        -SecureBootEnabled $true -FirmwareType UEFI
    Assert-FreshWinEqual 'Fixture' $hardware.Status
    Assert-FreshWinEqual 16 $hardware.MemoryGB
    Assert-FreshWinEqual 'NVIDIA' $hardware.GPUs[0].Vendor

    $network = Get-FreshWinNetworkState -Adapters @([pscustomobject]@{ Name='Ethernet'; Status='Up'; HardwareInterface=$true }) `
        -ProblemDevices @() -InternetProbe { $true }
    Assert-FreshWinEqual 'Online' $network.Status

    $system = Get-FreshWinSystemInfo -OperatingSystem ([pscustomobject]@{ Caption='Microsoft Windows 11 Pro'; BuildNumber=22631; OSArchitecture='64-bit' }) `
        -ComputerSystem $computer -HardwareInfo $hardware -NetworkState $network -WslAvailable $true -MicrosoftStoreAvailable $false
    Assert-FreshWinEqual 'Windows11' $system.OSFamily
    Assert-FreshWinTrue $system.WslAvailable
    Assert-FreshWinFalse $system.MicrosoftStoreAvailable

    Assert-FreshWinTrue (Get-FreshWinWslAvailability -StatusProvider { $true })
    Assert-FreshWinFalse (Get-FreshWinWslAvailability -StatusProvider { $false })
    Assert-FreshWinTrue (Get-FreshWinMicrosoftStoreAvailability -PackageProvider { param($name) [pscustomobject]@{ Name=$name } })
    Assert-FreshWinFalse (Get-FreshWinMicrosoftStoreAvailability -PackageProvider { param($name) @() })

    Assert-FreshWinTrue (Test-FreshWinInternetProbeEvidence -StatusCode 200 `
        -ResponseUri 'http://www.msftconnecttest.com/connecttest.txt' -Content 'Microsoft Connect Test')
    Assert-FreshWinFalse (Test-FreshWinInternetProbeEvidence -StatusCode 302 `
        -ResponseUri 'http://portal.example/login' -Content 'Microsoft Connect Test')
    Assert-FreshWinFalse (Test-FreshWinInternetProbeEvidence -StatusCode 200 `
        -ResponseUri 'http://www.msftconnecttest.com/connecttest.txt' -Content '<html>Sign in</html>') `
        -Because 'A captive-portal success page must not be reported as Internet access.'

    $activation = Get-FreshWinActivationStatus -Licenses @([pscustomobject]@{ Name='Windows'; LicenseStatus=1; PartialProductKey='ABCDE' })
    Assert-FreshWinTrue $activation.IsActivated

    $updates = Get-FreshWinWindowsUpdateState -Updates @([pscustomobject]@{ Title='Fixture security update'; RebootRequired=$false }) -RestartPending $false
    Assert-FreshWinEqual 1 $updates.PendingCount

    $drivers = Get-FreshWinDriverInventory -Devices @([pscustomobject]@{ FriendlyName='Fixture device'; InstanceId='PCI\FIXTURE'; Class='System'; Status='OK'; ProblemCode=0; DriverVersion='1.0' }) -SignedDrivers @()
    Assert-FreshWinEqual 'Healthy' $drivers[0].Health

    $readiness = Get-FreshWinWindows11Readiness -SystemInfo $system -HardwareInfo $hardware
    Assert-FreshWinEqual 'ReviewRequired' $readiness.Readiness
    Assert-FreshWinTrue ($readiness.Checks.Count -ge 8)
}

Add-FreshWinTest -Name 'Supplying live network state does not disable Windows system and hardware scans' -Category 'Security' -ScriptBlock {
    $source = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/Scanner/System.ps1'))
    $providedBlock = [regex]::Match($source, '\$provided\s*=\s*\$PSBoundParameters[\s\S]*?\$onWindows\s*=')
    Assert-FreshWinTrue $providedBlock.Success
    Assert-FreshWinFalse ($providedBlock.Value -match "ContainsKey\('NetworkState'\)") `
        -Because 'The CLI supplies NetworkState during a live scan; that must not turn the rest of SystemInfo into a fixture.'
    Assert-FreshWinMatch -Actual $source -Pattern '\$onWindows\s+-and\s+-not\s+\$provided[\s\S]*\$HardwareInfo\s*=\s*Get-FreshWinHardwareInfo\s*(?:\r?\n)' `
        -Because 'A live System scan must invoke the complete hardware scanner without partial fixture arguments.'
}

Add-FreshWinTest -Name 'Compatibility understands feature objects and unknown feature state' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $system = New-FreshWinTestSystemInfo
    $compatible = Get-FreshWinPackageCompatibility $package $system
    Assert-FreshWinEqual 'Compatible' $compatible.Status
    $system.InternetAvailable = $null
    $unknown = Get-FreshWinPackageCompatibility $package $system
    Assert-FreshWinEqual 'Warning' $unknown.Status
    Assert-FreshWinMatch ($unknown.Warnings -join ' ') 'could not be verified'
}

Add-FreshWinTest -Name 'Package detection distinguishes unknown, missing, installed, and update states' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage
    Assert-FreshWinEqual 'Unknown' (Get-FreshWinPackageDetection -Package $package -Inventory $null).State
    Assert-FreshWinEqual 'NotInstalled' (Get-FreshWinPackageDetection -Package $package -Inventory ([pscustomobject]@{ Available=$true; Items=@() })).State
    $installed = [pscustomobject]@{ Available=$true; Items=@([pscustomobject]@{ WingetId='Fixture.sample'; Name='Fixture sample'; Version='1.0' }) }
    Assert-FreshWinEqual 'Installed' (Get-FreshWinPackageDetection -Package $package -Inventory $installed).State
    $installed.Items[0] | Add-Member -NotePropertyName UpdateAvailable -NotePropertyValue $true
    Assert-FreshWinEqual 'UpdateAvailable' (Get-FreshWinPackageDetection -Package $package -Inventory $installed).State
}

Add-FreshWinTest -Name 'Store package detection uses AppX evidence and source-specific availability' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $package.source = [pscustomobject]@{ type='msstore'; packageId='9MV0B5HZVK9Z'; sourceName='msstore' }
    $package.detection.wingetIds = @()
    $package.detection.registryDisplayNames = @()
    $package.detection | Add-Member -NotePropertyName appxPackageNames -NotePropertyValue @('Microsoft.GamingApp')

    $installed = [pscustomobject]@{
        Available=$true; AppxAvailable=$true
        Items=@([pscustomobject]@{ AppxName='Microsoft.GamingApp'; DisplayName='Xbox'; Source='Appx'; Version='1.0' })
    }
    $detected = Get-FreshWinPackageDetection -Package $package -Inventory $installed
    Assert-FreshWinEqual 'Installed' $detected.State
    Assert-FreshWinContains @($detected.Evidence) 'appx'

    Assert-FreshWinEqual 'NotInstalled' (Get-FreshWinPackageDetection -Package $package -Inventory ([pscustomobject]@{
        Available=$true; AppxAvailable=$true; Items=@()
    })).State
    Assert-FreshWinEqual 'Unknown' (Get-FreshWinPackageDetection -Package $package -Inventory ([pscustomobject]@{
        Available=$true; AppxAvailable=$false; Items=@()
    })).State

    $records = @(Get-FreshWinSoftwareInventory -WingetOutput 'No installed package found.' -RegistryEntries @() -KnownPaths @() `
        -AppxPackages @([pscustomobject]@{ Name='Microsoft.GamingApp'; DisplayName='Xbox'; Version='1.2.3'; PackageFamilyName='Microsoft.GamingApp_8wekyb3d8bbwe' }))
    Assert-FreshWinCount 1 @($records | Where-Object AppxName -eq 'Microsoft.GamingApp')
    Assert-FreshWinTrue ([bool]$script:FreshWinSoftwareInventoryLastStatus.AppxAvailable)
}

Add-FreshWinTest -Name 'Post-install verification honors an explicit versioned registry prefix' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $package.detection.registryDisplayNames = @()
    $package.detection | Add-Member -NotePropertyName registryDisplayNamePrefixes -NotePropertyValue @('Fixture Runtime (x64) - ')
    $package.verification.methods = @('registry')
    $inventory = [pscustomobject]@{
        Available = $true
        Items = @([pscustomobject]@{ DisplayName='Fixture Runtime (x64) - 10.1.2'; Source='Registry' })
    }
    $verification = Test-FreshWinPackageVerification -Package $package -Inventory $inventory
    Assert-FreshWinEqual 'Verified' $verification.Status
    Assert-FreshWinEqual 1 $verification.MatchCount
}

Add-FreshWinTest -Name 'Planner expands dependencies in stable dependency-first order' -Category 'Workflow' -ScriptBlock {
    $dependency = New-FreshWinTestPackage -Id dependency
    $application = New-FreshWinTestPackage -Id application -Dependencies @('dependency') -Restart possible
    $catalog = [pscustomobject]@{ Packages=@($application, $dependency); Errors=@() }
    $inventory = [pscustomobject]@{ Available=$true; Items=@() }
    $processPath = (Get-Process -Id $PID).Path
    $plan = New-FreshWinInstallPlan -PackageIds @('application') -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) `
        -Inventory $inventory -WingetPath $processPath -DryRun
    Assert-FreshWinSetEqual @('dependency','application') @($plan.Items.PackageId)
    Assert-FreshWinEqual 'dependency' $plan.Items[0].PackageId
    Assert-FreshWinEqual 'possible' $plan.Items[1].RestartImpact
    Assert-FreshWinFalse $plan.Items[1].RestartRequired
}

Add-FreshWinTest -Name 'Plan review reasons surface unverified compatibility features' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $package.compatibility.features | Add-Member -NotePropertyName wsl -NotePropertyValue $true
    $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
    $system = New-FreshWinTestSystemInfo
    $system.WslAvailable = $null
    $inventory = [pscustomobject]@{ Available=$true; Items=@() }
    $plan = New-FreshWinInstallPlan -PackageIds @('sample') -Catalog $catalog -SystemInfo $system -Inventory $inventory -WingetPath (Get-Process -Id $PID).Path
    Assert-FreshWinMatch -Actual $plan.Items[0].Reason -Pattern "Compatibility warning: Required feature 'wsl' could not be verified"
}

Add-FreshWinTest -Name 'Include-updates planning never reports an installed package current without source coverage' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
    $record = [pscustomobject]@{ WingetId='Fixture.sample'; DisplayName='Fixture sample'; Version='1.0'; UpdateAvailable=$false }
    $unknownUpdates = [pscustomobject]@{
        Available=$true; Status='Partial'; UpdatesScanned=$false; UpdateSourcesScanned=@(); Errors=@('fixture upgrade provider failed'); Items=@($record)
    }
    $unknownPlan = New-FreshWinInstallPlan -PackageIds sample -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) `
        -Inventory $unknownUpdates -UpdatePolicy include-updates -WingetPath (Get-Process -Id $PID).Path
    Assert-FreshWinEqual 'BLOCKED' $unknownPlan.Items[0].Action
    Assert-FreshWinMatch $unknownPlan.Items[0].Reason 'could not be verified'

    $knownCurrent = [pscustomobject]@{
        Available=$true; Status='Ready'; UpdatesScanned=$true; UpdateSourcesScanned=@('winget'); Errors=@(); Items=@($record)
    }
    $knownPlan = New-FreshWinInstallPlan -PackageIds sample -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) `
        -Inventory $knownCurrent -UpdatePolicy include-updates -WingetPath (Get-Process -Id $PID).Path
    Assert-FreshWinEqual 'SKIP' $knownPlan.Items[0].Action

    $storePackage = New-FreshWinTestPackage -SourceType msstore
    $storeCoverage = [pscustomobject]@{ Available=$true; UpdatesScanned=$true; UpdateSourcesScanned=@('winget'); Items=@() }
    Assert-FreshWinFalse (Test-FreshWinPackageUpdateCoverage -Package $storePackage -Inventory $storeCoverage) `
        -Because 'A community source query cannot prove Microsoft Store update state.'
}

Add-FreshWinTest -Name 'Reviewed dependency capabilities are rechecked live before dependent execution' -Category 'Workflow' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
    $wingetFixture = Join-Path $directory 'winget.exe'
    [IO.File]::WriteAllText($wingetFixture, 'fixture')
    $dependency = New-FreshWinTestPackage
    $dependency.id = 'dependency'
    $dependency.name = 'Dependency'
    $dependency.source.packageId = 'Fixture.dependency'
    $dependency.detection.wingetIds = @('Fixture.dependency')
    $dependency.compatibility | Add-Member -NotePropertyName providesFeatures -NotePropertyValue @('wsl') -Force

    $application = New-FreshWinTestPackage
    $application.id = 'application'
    $application.name = 'Application'
    $application.source.packageId = 'Fixture.application'
    $application.detection.wingetIds = @('Fixture.application')
    $application.dependencies = @('dependency')
    $application.compatibility.features | Add-Member -NotePropertyName wsl -NotePropertyValue $true -Force
    $catalog = [pscustomobject]@{ Packages=@($dependency, $application); Errors=@() }
    $initialSystem = New-FreshWinTestSystemInfo
    $initialSystem.WslAvailable = $false
    $emptyInventory = [pscustomobject]@{ Available=$true; Status='Ready'; Items=@(); Errors=@() }
    $plan = New-FreshWinInstallPlan -PackageIds application -Catalog $catalog -SystemInfo $initialSystem `
        -Inventory $emptyInventory -WingetPath $wingetFixture -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage }
    Assert-FreshWinEqual 'INSTALL' (@($plan.Items | Where-Object PackageId -eq application)[0].Action)
    Assert-FreshWinMatch (@($plan.Items | Where-Object PackageId -eq application)[0].Reason) 'reviewed dependency'

    foreach ($case in @(
        [pscustomobject]@{ BecomesAvailable=$true; ExpectedState='SUCCEEDED'; ExpectedCalls=2 },
        [pscustomobject]@{ BecomesAvailable=$false; ExpectedState='BLOCKED'; ExpectedCalls=1 }
    )) {
        $casePlan = New-FreshWinInstallPlan -PackageIds application -Catalog $catalog -SystemInfo $initialSystem `
            -Inventory $emptyInventory -WingetPath $wingetFixture -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage }
        $script:FreshWinCapabilityInventoryCall = 0
        $script:FreshWinCapabilitySystemCall = 0
        $script:FreshWinCapabilityProcessCall = 0
        $result = Invoke-FreshWinExecutionPlan -Plan $casePlan -Catalog $catalog -SystemInfo $initialSystem -Inventory $emptyInventory `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
            -ProcessInvoker { $script:FreshWinCapabilityProcessCall++; [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' } } `
            -InventoryProvider {
                $script:FreshWinCapabilityInventoryCall++
                $items = if ($script:FreshWinCapabilityInventoryCall -le 1) { @() }
                    elseif ($script:FreshWinCapabilityInventoryCall -eq 2) { @([pscustomobject]@{ WingetId='Fixture.dependency'; Version='1.0' }) }
                    else { @([pscustomobject]@{ WingetId='Fixture.dependency'; Version='1.0' }, [pscustomobject]@{ WingetId='Fixture.application'; Version='1.0' }) }
                [pscustomobject]@{ Available=$true; Status='Ready'; Items=$items; Errors=@() }
            } `
            -SystemInfoProvider {
                $script:FreshWinCapabilitySystemCall++
                $system = New-FreshWinTestSystemInfo
                $system.WslAvailable = if ($script:FreshWinCapabilitySystemCall -le 1) { $false } else { [bool]$case.BecomesAvailable }
                return $system
            }
        $dependentItem = @($result.Plan.Items | Where-Object PackageId -eq application)[0]
        Assert-FreshWinEqual $case.ExpectedState $dependentItem.State
        Assert-FreshWinEqual $case.ExpectedCalls $script:FreshWinCapabilityProcessCall
    }
    foreach ($name in @('FreshWinCapabilityInventoryCall','FreshWinCapabilitySystemCall','FreshWinCapabilityProcessCall')) {
        Remove-Variable $name -Scope Script -ErrorAction SilentlyContinue
    }
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Windows optional-feature detection requires every declared WSL platform feature' -Category 'Workflow' -ScriptBlock {
    $catalog = Import-FreshWinPackageCatalog
    $package = Get-FreshWinPackage -Catalog $catalog -Id wsl-platform-features
    Assert-FreshWinTrue ($null -ne $package)
    $enabled = Get-FreshWinPackageDetection -Package $package -Inventory $null -FeatureVerifier { param($name) $true }
    Assert-FreshWinEqual 'Installed' $enabled.State
    $disabled = Get-FreshWinPackageDetection -Package $package -Inventory $null -FeatureVerifier { param($name) $name -ne 'VirtualMachinePlatform' }
    Assert-FreshWinEqual 'NotInstalled' $disabled.State
    Assert-FreshWinContains @($disabled.Record.Disabled) 'VirtualMachinePlatform'
    $unknown = Get-FreshWinPackageDetection -Package $package -Inventory $null -FeatureVerifier { param($name) $null }
    Assert-FreshWinEqual 'Unknown' $unknown.State
    $pending = Get-FreshWinPackageDetection -Package $package -Inventory $null -FeatureVerifier { param($name) 'EnablePending' }
    Assert-FreshWinEqual 'Unknown' $pending.State
    Assert-FreshWinCount 2 @($pending.Record.PendingReboot)
}

Add-FreshWinTest -Name 'Reboot-pending Windows features remain pending until post-reboot verification' -Category 'Security' -ScriptBlock {
    $catalog = Import-FreshWinPackageCatalog
    $package = Get-FreshWinPackage -Catalog $catalog -Id wsl-platform-features
    $plan = New-FreshWinTestExecutionPlan -Package $package
    $emptyInventory = [pscustomobject]@{ Available=$true; Status='Ready'; Items=@(); Errors=@() }
    $resolvedFeature = [pscustomobject]@{
        PackageId='wsl-platform-features'; SourceType='windows-feature'; Status='Resolved'; Trust='FixtureBoundary'
        Executable=(Get-Process -Id $PID).Path; PackageManagerId=$null; SourceName=$null; Uri=$null
        FeatureName=$null; FeatureNames=@('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')
        VersionPolicy=$package.versionPolicy; Reason=$null
    }
    $script:FreshWinFeatureProcessStarted = $false
    try {
        $execution = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) `
            -Inventory $emptyInventory -FeatureVerifier {
                param($name)
                if ($script:FreshWinFeatureProcessStarted) { 'EnablePending' } else { $false }
            } -SourceResolver { param($trustedPackage) $resolvedFeature } -ProcessInvoker {
                $script:FreshWinFeatureProcessStarted = $true
                [pscustomobject]@{ ExitCode=3010; Succeeded=$true; StandardOutput=''; StandardError='' }
            }
        Assert-FreshWinEqual 'REBOOT_REQUIRED' $execution.Status
        Assert-FreshWinEqual 'PENDING' $execution.Plan.Items[0].State
        Assert-FreshWinEqual 'PendingReboot' $execution.Plan.Items[0].Verification.Status
        Assert-FreshWinFalse $execution.Plan.Items[0].Verification.Verified
        Assert-FreshWinTrue $execution.Summary.RebootRequired
        Assert-FreshWinTrue (Test-FreshWinElevatedHelperExecutionResult -ExecutionResult $execution)

        $verified = Test-FreshWinPackageVerification -Package $package -Inventory $emptyInventory `
            -SystemInfo (New-FreshWinTestSystemInfo) -FeatureVerifier { param($name) 'Enabled' }
        Assert-FreshWinEqual 'Verified' $verified.Status
    }
    finally {
        Remove-Variable FreshWinFeatureProcessStarted -Scope Script -ErrorAction SilentlyContinue
    }
}

Add-FreshWinTest -Name 'Partial Windows-feature failure preserves reboot recovery evidence and stops the queue' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $wingetFixture = Join-Path $directory 'winget.exe'
        [IO.File]::WriteAllText($wingetFixture, 'fixture')
        $catalogBase = Import-FreshWinPackageCatalog
        $featurePackage = Get-FreshWinPackage -Catalog $catalogBase -Id wsl-platform-features
        $laterPackage = New-FreshWinTestPackage -Id later -Dependencies @('wsl-platform-features')
        $catalog = [pscustomobject]@{ Packages=@($featurePackage, $laterPackage); Errors=@() }
        $emptyInventory = [pscustomobject]@{ Available=$true; Status='Ready'; Items=@(); Errors=@() }
        $plan = New-FreshWinInstallPlan -PackageIds @('wsl-platform-features','later') -Catalog $catalog `
            -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $emptyInventory -WingetPath $wingetFixture `
            -FeatureVerifier { param($name) $false } -SourceResolver {
                param($trustedPackage)
                if ([string]$trustedPackage.id -eq 'wsl-platform-features') {
                    [pscustomobject]@{ PackageId='wsl-platform-features'; SourceType='windows-feature'; Status='Resolved'; Trust='FixtureBoundary'; Executable=(Get-Process -Id $PID).Path; PackageManagerId=$null; SourceName=$null; Uri=$null; FeatureName=$null; FeatureNames=@('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform'); VersionPolicy=$trustedPackage.versionPolicy; Reason=$null }
                } else { New-FreshWinTestResolvedSource $trustedPackage }
            }
        $featurePlanItem = @($plan.Items | Where-Object PackageId -eq 'wsl-platform-features')[0]
        # DISM cannot resolve on macOS; the execution resolver below is the
        # explicit fixture boundary for a plan that was reviewed on Windows.
        $featurePlanItem.Action = 'INSTALL'
        $featurePlanItem.State = 'PENDING'
        $featurePlanItem.Reason = 'Fixture Windows feature install.'
        $resolvedFeature = [pscustomobject]@{
            PackageId='wsl-platform-features'; SourceType='windows-feature'; Status='Resolved'; Trust='FixtureBoundary'
            Executable=(Get-Process -Id $PID).Path; PackageManagerId=$null; SourceName=$null; Uri=$null
            FeatureName=$null; FeatureNames=@('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')
            VersionPolicy=$featurePackage.versionPolicy; Reason=$null
        }
        $script:FreshWinPartialFeatureCall = 0
        $execution = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) `
            -Inventory $emptyInventory -FeatureVerifier { param($name) $false } `
            -SourceResolver {
                param($trustedPackage)
                if ([string]$trustedPackage.id -eq 'wsl-platform-features') { $resolvedFeature }
                else { New-FreshWinTestResolvedSource $trustedPackage }
            } -ProcessInvoker {
                $script:FreshWinPartialFeatureCall++
                if ($script:FreshWinPartialFeatureCall -eq 1) {
                    [pscustomobject]@{ ExitCode=3010; Succeeded=$true; StandardOutput=''; StandardError='' }
                } else {
                    [pscustomobject]@{ ExitCode=1; Succeeded=$false; StandardOutput=''; StandardError='fixture feature failure' }
                }
            }

        Assert-FreshWinEqual 2 $script:FreshWinPartialFeatureCall `
            -Because 'The later package must not run after a partially mutated feature operation requires reboot.'
        $featureItem = @($execution.Plan.Items | Where-Object PackageId -eq 'wsl-platform-features')[0]
        $laterItem = @($execution.Plan.Items | Where-Object PackageId -eq 'later')[0]
        Assert-FreshWinEqual 'FAILED' $featureItem.State
        Assert-FreshWinTrue $featureItem.Result.RebootRequired
        Assert-FreshWinEqual 'PENDING' $laterItem.State
        Assert-FreshWinTrue $execution.Summary.RebootRequired
        Assert-FreshWinEqual 'COMPLETED_WITH_ISSUES' $execution.Status
        $checkpoint = ConvertTo-FreshWinCheckpoint -Plan $execution.Plan
        Assert-FreshWinTrue $checkpoint.items[0].result.rebootRequired
        Assert-FreshWinTrue (Test-FreshWinCheckpointRequiresReboot -Checkpoint $checkpoint)
        Assert-FreshWinFalse (Test-FreshWinElevatedHelperExecutionResult -ExecutionResult $execution) `
            -Because 'Recovery guidance must not convert the failed feature operation into a successful helper exit.'
    }
    finally {
        Remove-Variable FreshWinPartialFeatureCall -Scope Script -ErrorAction SilentlyContinue
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'Resume requires a changed Windows boot session after a reboot boundary' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $wingetFixture = Join-Path $directory 'winget.exe'
        [IO.File]::WriteAllText($wingetFixture, 'fixture')
        $package = New-FreshWinTestPackage
        $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
        $plan = New-FreshWinTestExecutionPlan -Package $package
        $plan.Status = 'COMPLETED_WITH_ISSUES'
        $plan.Items[0].State = 'FAILED'
        $plan.Items[0].RestartRequired = $true
        $plan.Items[0].Result = [pscustomobject]@{
            Outcome='Failed'; Stage='Install'; ExitCode=-1978334966
            RebootRequired=$true; RetryAfterReboot=$true
            Message='Windows must restart before retry.'
        }
        $checkpoint = ConvertTo-FreshWinCheckpoint -Plan $plan -BootSessionProvider {
            [DateTimeOffset]'2026-08-11T00:00:00Z'
        }
        Assert-FreshWinEqual '2026-08-11T00:00:00.0000000+00:00' $checkpoint.rebootBootSessionUtc
        $checkpointPath = Join-Path $directory 'execution-checkpoint.json'
        [void](Save-FreshWinExecutionCheckpoint -Plan $plan -Path $checkpointPath -BootSessionProvider {
            [DateTimeOffset]'2026-08-11T00:00:00Z'
        })
        $loadedCheckpoint = Get-FreshWinExecutionCheckpoint -Path $checkpointPath
        Assert-FreshWinEqual $checkpoint.rebootBootSessionUtc $loadedCheckpoint.rebootBootSessionUtc
        Assert-FreshWinThrows -ScriptBlock {
            Restore-FreshWinPlanFromCheckpoint -Checkpoint ([pscustomobject]$checkpoint) -Catalog $catalog `
                -SystemInfo (New-FreshWinTestSystemInfo) -Inventory ([pscustomobject]@{ Available=$true; Items=@() }) `
                -WingetPath $wingetFixture -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } -BootSessionProvider { [DateTimeOffset]'2026-08-11T00:00:00Z' }
        } -Pattern 'has not restarted'

        $restored = Restore-FreshWinPlanFromCheckpoint -Checkpoint ([pscustomobject]$checkpoint) -Catalog $catalog `
            -SystemInfo (New-FreshWinTestSystemInfo) -Inventory ([pscustomobject]@{ Available=$true; Items=@() }) `
            -WingetPath $wingetFixture -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } -BootSessionProvider { [DateTimeOffset]'2026-08-11T00:05:00Z' }
        Assert-FreshWinEqual 'RESUMED' $restored.Status
        Assert-FreshWinEqual 'INSTALL' $restored.Items[0].Action

        $legacyCheckpoint = [ordered]@{}
        foreach ($key in $checkpoint.Keys) {
            if ([string]$key -ne 'rebootBootSessionUtc') { $legacyCheckpoint[$key] = $checkpoint[$key] }
        }
        Assert-FreshWinThrows -ScriptBlock {
            Restore-FreshWinPlanFromCheckpoint -Checkpoint ([pscustomobject]$legacyCheckpoint) -Catalog $catalog `
                -SystemInfo (New-FreshWinTestSystemInfo) -Inventory ([pscustomobject]@{ Available=$true; Items=@() }) `
                -WingetPath $wingetFixture -BootSessionProvider { [DateTimeOffset]'2026-08-11T00:05:00Z' }
        } -Pattern 'does not contain a trustworthy'

        $invalidCheckpoint = [ordered]@{}
        foreach ($key in $checkpoint.Keys) { $invalidCheckpoint[$key] = $checkpoint[$key] }
        $invalidCheckpoint.rebootBootSessionUtc = '2026-08-11T00:00:00.0000000Z'
        Assert-FreshWinThrows -ScriptBlock {
            Restore-FreshWinPlanFromCheckpoint -Checkpoint ([pscustomobject]$invalidCheckpoint) -Catalog $catalog `
                -SystemInfo (New-FreshWinTestSystemInfo) -Inventory ([pscustomobject]@{ Available=$true; Items=@() }) `
                -WingetPath $wingetFixture -BootSessionProvider { [DateTimeOffset]'2026-08-11T00:05:00Z' }
        } -Pattern 'non-canonical'
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Dry-run execution validates a plan without invoking a process' -Category 'Workflow' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $logDirectory = Join-Path $directory 'logs'
        [void](Initialize-FreshWinLogger -LogDirectory $logDirectory -Version test)
        $checkpoint = Join-Path (Join-Path $directory 'state-not-created') 'checkpoint.json'
        $package = New-FreshWinTestPackage
        $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
        $inventory = [pscustomobject]@{ Available=$true; Items=@() }
        $plan = New-FreshWinTestExecutionPlan -Package $package -DryRun
        $script:FreshWinUnexpectedProcessCall = $false
        $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $inventory `
            -CheckpointPath $checkpoint `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
            -ProcessInvoker { $script:FreshWinUnexpectedProcessCall = $true; throw 'process must not run' }
        Assert-FreshWinEqual 'DRY_RUN_COMPLETE' $result.Status
        Assert-FreshWinFalse $script:FreshWinUnexpectedProcessCall
        Assert-FreshWinEqual 'VALIDATED' $result.Plan.Items[0].State
        Assert-FreshWinEqual 0 @(Get-ChildItem -LiteralPath $logDirectory -File -ErrorAction Stop).Count
        Assert-FreshWinFalse ([IO.Directory]::Exists((Split-Path -Parent $checkpoint)))
    }
    finally {
        $script:FreshWinLoggerContext = $null
        Remove-Variable FreshWinUnexpectedProcessCall -Scope Script -ErrorAction SilentlyContinue
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'Execution history records package action result and exit code as structured fields' -Category 'Workflow' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $context = Initialize-FreshWinLogger -LogDirectory $directory -Version test
        Write-FreshWinExecutionLog -Stage VERIFY_INSTALL -Action UPDATE -PackageId sample -Result SUCCEEDED -ExitCode 0 `
            -Message 'Verified fixture update.' -Data ([pscustomobject]@{ Verified=$true })
        $history = @(Get-FreshWinLogHistory -LogDirectory $directory -Last 1)
        Assert-FreshWinCount 1 $history
        Assert-FreshWinEqual 'UPDATE' $history[0].Action
        Assert-FreshWinEqual 'sample' $history[0].PackageId
        Assert-FreshWinEqual 'SUCCEEDED' $history[0].Result
        Assert-FreshWinEqual 0 $history[0].ExitCode
    }
    finally {
        $script:FreshWinLoggerContext = $null
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'Mocked install executes typed arguments and verifies inventory' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
    $emptyInventory = [pscustomobject]@{ Available=$true; Items=@() }
    $plan = New-FreshWinTestExecutionPlan -Package $package
    $script:FreshWinCapturedArguments = @()
    $script:FreshWinMockInventoryCallCount = 0
    $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $emptyInventory `
        -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
        -ProcessInvoker { param($file, $arguments) $script:FreshWinCapturedArguments = @($arguments); [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' } } `
        -InventoryProvider {
            $script:FreshWinMockInventoryCallCount++
            $items = if ($script:FreshWinMockInventoryCallCount -ge 2) { @([pscustomobject]@{ WingetId='Fixture.sample'; Name='Fixture sample'; Version='1.0' }) } else { @() }
            [pscustomobject]@{ Available=$true; Items=$items }
        }
    Assert-FreshWinEqual 'COMPLETED' $result.Status
    Assert-FreshWinEqual 'SUCCEEDED' $result.Plan.Items[0].State
    Assert-FreshWinContains $script:FreshWinCapturedArguments '--id'
    Assert-FreshWinContains $script:FreshWinCapturedArguments 'Fixture.sample'
    Remove-Variable FreshWinCapturedArguments -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable FreshWinMockInventoryCallCount -Scope Script -ErrorAction SilentlyContinue
}

Add-FreshWinTest -Name 'Execution refreshes installed state before the first installer process' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
    $staleInventory = [pscustomobject]@{ Available=$true; Items=@() }
    $plan = New-FreshWinTestExecutionPlan -Package $package
    $script:FreshWinRaceProcessCalled = $false
    $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $staleInventory `
        -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
        -ProcessInvoker { $script:FreshWinRaceProcessCalled = $true; throw 'stale plan must not install' } `
        -InventoryProvider { [pscustomobject]@{ Available=$true; Items=@([pscustomobject]@{ WingetId='Fixture.sample'; Source='Winget'; Version='1.0' }) } }
    Assert-FreshWinFalse $script:FreshWinRaceProcessCalled
    Assert-FreshWinEqual 'SKIP' $result.Plan.Items[0].Action
    Assert-FreshWinEqual 'SKIP' $result.Plan.Items[0].State
    Assert-FreshWinEqual 'COMPLETED' $result.Status
    Remove-Variable FreshWinRaceProcessCalled -Scope Script -ErrorAction SilentlyContinue
}

Add-FreshWinTest -Name 'Public execution engine supplies a live default inventory refresh' -Category 'Security' -ScriptBlock {
    $queueSource = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/Execution/Queue.ps1'))
    Assert-FreshWinMatch -Actual $queueSource -Pattern '\$null\s+-eq\s+\$InventoryProvider[\s\S]*\$liveSystemInfo[\s\S]*Get-FreshWinSoftwareInventorySnapshot\s+-Refresh' `
        -Because 'A live direct module call must not execute from a stale caller-supplied snapshot.'
    Assert-FreshWinMatch -Actual $queueSource -Pattern '\$null\s+-eq\s+\$SystemInfoProvider[\s\S]*Get-FreshWinSystemInfo[\s\S]*System information could not be refreshed after package execution' `
        -Because 'Feature-dependent packages must not reuse stale WSL or Microsoft Store observations.'
}

Add-FreshWinTest -Name 'Update execution fails closed when refreshed inventory still reports an update' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
    $updateInventory = [pscustomobject]@{
        Available=$true; Status='Ready'; Errors=@()
        Items=@([pscustomobject]@{
            WingetId='Fixture.sample'; DisplayName='Fixture sample'; Name='Fixture sample'; Source='Winget'
            Version='1.0'; UpdateAvailable=$true; AvailableVersion='2.0'
        })
    }
    $plan = New-FreshWinTestExecutionPlan -Package $package
    $plan.UpdatePolicy = 'include-updates'
    $plan.Items[0].Action = 'UPDATE'
    $plan.Items[0].Reason = 'Fixture update is available.'
    $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $updateInventory `
        -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
        -ProcessInvoker { [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' } } `
        -InventoryProvider { $updateInventory }
    Assert-FreshWinEqual -Expected 'FAILED' -Actual $result.Plan.Items[0].State
    Assert-FreshWinEqual -Expected 'Failed' -Actual $result.Plan.Items[0].Verification.Status
    Assert-FreshWinEqual -Expected 'UpdateAvailable' -Actual $result.Plan.Items[0].Detection.State
    Assert-FreshWinEqual -Expected 'COMPLETED_WITH_ISSUES' -Actual $result.Status
    Assert-FreshWinEqual -Expected 0 -Actual $result.Summary.Updated
}

Add-FreshWinTest -Name 'Update execution remains unknown when the refreshed update provider fails' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
    $initial = [pscustomobject]@{
        Available=$true; UpdatesScanned=$true; Items=@([pscustomobject]@{
            WingetId='Fixture.sample'; DisplayName='Fixture sample'; Source='Winget'; Version='1.0'
            UpdateAvailable=$true; AvailableVersion='2.0'
        })
    }
    $unverifiedCurrent = [pscustomobject]@{
        Available=$true; UpdatesScanned=$false; Status='Partial'; Errors=@('fixture update query failed')
        Items=@([pscustomobject]@{
            WingetId='Fixture.sample'; DisplayName='Fixture sample'; Source='Winget'; Version='2.0'
            UpdateAvailable=$false; AvailableVersion=$null
        })
    }
    $plan = New-FreshWinTestExecutionPlan -Package $package
    $plan.UpdatePolicy = 'include-updates'
    $plan.Items[0].Action = 'UPDATE'
    $script:FreshWinUpdateRefreshCount = 0
    $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $initial `
        -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
        -ProcessInvoker { [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' } } `
        -InventoryProvider {
            $script:FreshWinUpdateRefreshCount++
            if ($script:FreshWinUpdateRefreshCount -eq 1) { $initial } else { $unverifiedCurrent }
        }
    Assert-FreshWinEqual 'UNKNOWN_VERIFICATION' $result.Plan.Items[0].State
    Assert-FreshWinEqual 'Unknown' $result.Plan.Items[0].Verification.Status
    Assert-FreshWinMatch -Actual $result.Plan.Items[0].Verification.Detail -Pattern 'update provider'
    Assert-FreshWinEqual 'COMPLETED_WITH_ISSUES' $result.Status
    Assert-FreshWinEqual 0 $result.Summary.Updated
    Remove-Variable FreshWinUpdateRefreshCount -Scope Script -ErrorAction SilentlyContinue
}

Add-FreshWinTest -Name 'Execution reconciles already-satisfied update and repair actions to skip' -Category 'Workflow' -ScriptBlock {
    foreach ($action in @('UPDATE','REPAIR')) {
        $package = New-FreshWinTestPackage
        $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
        $plan = New-FreshWinTestExecutionPlan -Package $package
        $plan.Items[0].Action = $action
        $initial = if ($action -eq 'UPDATE') {
            [pscustomobject]@{ Available=$true; Items=@([pscustomobject]@{ WingetId='Fixture.sample'; Source='Winget'; Version='1.0'; UpdateAvailable=$true; AvailableVersion='2.0' }) }
        } else {
            [pscustomobject]@{ Available=$true; Items=@([pscustomobject]@{ WingetId='Fixture.sample'; Source='Winget'; Version='1.0'; Broken=$true }) }
        }
        $current = [pscustomobject]@{ Available=$true; Items=@([pscustomobject]@{ WingetId='Fixture.sample'; Source='Winget'; Version='2.0'; UpdateAvailable=$false; Broken=$false }) }
        $script:FreshWinReconcileProcessCalled = $false
        $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $initial `
            -InventoryProvider { $current } `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
            -ProcessInvoker { $script:FreshWinReconcileProcessCalled = $true; throw 'An already satisfied action must not execute.' }
        Assert-FreshWinFalse $script:FreshWinReconcileProcessCalled
        Assert-FreshWinEqual 'SKIP' $result.Plan.Items[0].Action
        Assert-FreshWinEqual 'SKIP' $result.Plan.Items[0].State
        Assert-FreshWinEqual 'COMPLETED' $result.Status
    }
    Remove-Variable FreshWinReconcileProcessCalled -Scope Script -ErrorAction SilentlyContinue
}

Add-FreshWinTest -Name 'Include-updates execution never completes a stale reviewed skip when an update appears' -Category 'Security' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
    $plan = New-FreshWinTestExecutionPlan -Package $package
    $plan.UpdatePolicy = 'include-updates'
    $plan.Items[0].Action = 'SKIP'
    $plan.Items[0].State = 'SKIP'
    $plan.Items[0].Reason = 'Reviewed as current before execution.'
    $refreshed = [pscustomobject]@{
        Available=$true; Status='Ready'; UpdatesScanned=$true; UpdateSourcesScanned=@('winget'); Errors=@()
        Items=@([pscustomobject]@{
            WingetId='Fixture.sample'; DisplayName='Fixture sample'; Source='Winget'; Version='1.0'
            UpdateAvailable=$true; AvailableVersion='2.0'
        })
    }
    $script:FreshWinStaleSkipProcessCalled = $false
    try {
        $execution = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) `
            -Inventory $refreshed -InventoryProvider { $refreshed } `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
            -ProcessInvoker { $script:FreshWinStaleSkipProcessCalled = $true; throw 'A newly discovered update requires a new reviewed plan.' }
        Assert-FreshWinFalse $script:FreshWinStaleSkipProcessCalled
        Assert-FreshWinEqual 'SKIP' $execution.Plan.Items[0].Action
        Assert-FreshWinEqual 'BLOCKED' $execution.Plan.Items[0].State
        Assert-FreshWinEqual 'StalePlan' $execution.Plan.Items[0].Result.Stage
        Assert-FreshWinEqual 'COMPLETED_WITH_ISSUES' $execution.Status
        Assert-FreshWinEqual 1 $execution.Summary.Blocked
        Assert-FreshWinEqual 0 $execution.Summary.Skipped
    }
    finally { Remove-Variable FreshWinStaleSkipProcessCalled -Scope Script -ErrorAction SilentlyContinue }
}

Add-FreshWinTest -Name 'Reboot evidence never masks a failed verification' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage -Restart required
    $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
    $empty = [pscustomobject]@{ Available=$true; Items=@() }
    $plan = New-FreshWinTestExecutionPlan -Package $package
    $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $empty `
        -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
        -ProcessInvoker { [pscustomobject]@{ ExitCode=3010; Succeeded=$true; StandardOutput=''; StandardError='' } } `
        -InventoryProvider { $empty }
    Assert-FreshWinEqual 'FAILED' $result.Plan.Items[0].State
    Assert-FreshWinTrue $result.Summary.RebootRequired -Because 'The native process still reported that Windows needs a reboot.'
    Assert-FreshWinEqual 'COMPLETED_WITH_ISSUES' $result.Status
}

Add-FreshWinTest -Name 'Execution refreshes dependency inventory before authorizing the dependent package' -Category 'Workflow' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $wingetFixture = Join-Path $directory 'winget.exe'
        [IO.File]::WriteAllText($wingetFixture, 'fixture')
        $dependency = New-FreshWinTestPackage -Id dependency
        $application = New-FreshWinTestPackage -Id application -Dependencies @('dependency')
        $catalog = [pscustomobject]@{ Packages=@($application, $dependency); Errors=@() }
        $emptyInventory = [pscustomobject]@{ Available=$true; Items=@() }
        $plan = New-FreshWinInstallPlan -PackageIds application -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) `
            -Inventory $emptyInventory -WingetPath $wingetFixture `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage }
        $script:FreshWinDependencyInstallCount = 0
        $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $emptyInventory `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
            -ProcessInvoker {
                $script:FreshWinDependencyInstallCount++
                [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' }
            } `
            -InventoryProvider {
                $items = @()
                if ($script:FreshWinDependencyInstallCount -ge 1) { $items += [pscustomobject]@{ WingetId='Fixture.dependency'; Source='Winget'; Version='1.0' } }
                if ($script:FreshWinDependencyInstallCount -ge 2) { $items += [pscustomobject]@{ WingetId='Fixture.application'; Source='Winget'; Version='1.0' } }
                [pscustomobject]@{ Available=$true; Items=$items }
            }
        Assert-FreshWinEqual 'COMPLETED' $result.Status
        Assert-FreshWinEqual 2 $script:FreshWinDependencyInstallCount
        Assert-FreshWinSetEqual @('SUCCEEDED') @($result.Plan.Items.State)
    }
    finally {
        Remove-Variable FreshWinDependencyInstallCount -Scope Script -ErrorAction SilentlyContinue
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'Execution pauses at a confirmed reboot boundary and preserves later work for resume' -Category 'Workflow' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $wingetFixture = Join-Path $directory 'winget.exe'
        [IO.File]::WriteAllText($wingetFixture, 'fixture')
        $runtime = New-FreshWinTestPackage -Id runtime -Restart required
        $application = New-FreshWinTestPackage -Id application
        $catalog = [pscustomobject]@{ Packages=@($runtime, $application); Errors=@() }
        $emptyInventory = [pscustomobject]@{ Available=$true; Items=@() }
        $plan = New-FreshWinInstallPlan -PackageIds @('runtime','application') -Catalog $catalog `
            -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $emptyInventory -WingetPath $wingetFixture `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage }
        $script:FreshWinRebootProcessCount = 0
        $script:FreshWinRebootInventoryCount = 0
        $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $emptyInventory `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
            -ProcessInvoker {
                $script:FreshWinRebootProcessCount++
                [pscustomobject]@{ ExitCode=3010; Succeeded=$true; StandardOutput=''; StandardError='' }
            } `
            -InventoryProvider {
                $script:FreshWinRebootInventoryCount++
                $items = if ($script:FreshWinRebootInventoryCount -ge 2) { @([pscustomobject]@{ WingetId='Fixture.runtime'; Source='Winget'; Version='1.0' }) } else { @() }
                [pscustomobject]@{ Available=$true; Items=$items }
            }
        Assert-FreshWinEqual 1 $script:FreshWinRebootProcessCount
        Assert-FreshWinEqual 'SUCCEEDED' $result.Plan.Items[0].State
        Assert-FreshWinEqual 'PENDING' $result.Plan.Items[1].State
        Assert-FreshWinEqual 'REBOOT_REQUIRED' $result.Status
        Assert-FreshWinTrue $result.Summary.RebootRequired
        Assert-FreshWinEqual 1 $result.Summary.Pending
    }
    finally {
        Remove-Variable FreshWinRebootProcessCount -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable FreshWinRebootInventoryCount -Scope Script -ErrorAction SilentlyContinue
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'Admin-only execution never invokes non-admin package actions' -Category 'Workflow' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $wingetFixture = Join-Path $directory 'winget.exe'
        [IO.File]::WriteAllText($wingetFixture, 'fixture')
        $userPackage = New-FreshWinTestPackage -Id user
        $adminPackage = New-FreshWinTestPackage -Id admin -RequiresAdmin $true
        $catalog = [pscustomobject]@{ Packages=@($userPackage, $adminPackage); Errors=@() }
        $emptyInventory = [pscustomobject]@{ Available=$true; Items=@() }
        $plan = New-FreshWinInstallPlan -PackageIds @('user', 'admin') -Catalog $catalog `
            -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $emptyInventory -WingetPath $wingetFixture `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage }
        $script:FreshWinPrivilegeProcessIds = @()
        $script:FreshWinPrivilegeResolverIds = @()
        $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) `
            -Inventory $emptyInventory -ExecutionMode AdminOnly `
            -SourceResolver {
                param($trustedPackage)
                $script:FreshWinPrivilegeResolverIds += [string]$trustedPackage.id
                New-FreshWinTestResolvedSource $trustedPackage
            } `
            -ProcessInvoker {
                param($file, $arguments)
                $managerId = [string]$arguments[([Array]::IndexOf([object[]]$arguments, '--id') + 1)]
                $script:FreshWinPrivilegeProcessIds += $managerId
                [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' }
            } `
            -InventoryProvider {
                $items = @($script:FreshWinPrivilegeProcessIds | ForEach-Object {
                    [pscustomobject]@{ WingetId=$_; Source='Winget'; Version='1.0' }
                })
                [pscustomobject]@{ Available=$true; Items=$items }
            }
        Assert-FreshWinSetEqual @('Fixture.admin') @($script:FreshWinPrivilegeProcessIds)
        Assert-FreshWinSetEqual @('admin') @($script:FreshWinPrivilegeResolverIds)
        Assert-FreshWinEqual 'PENDING' @($result.Plan.Items | Where-Object PackageId -eq 'user')[0].State
        Assert-FreshWinEqual 'PrivilegePartition' @($result.Plan.Items | Where-Object PackageId -eq 'user')[0].Result.Stage
        Assert-FreshWinEqual 'SUCCEEDED' @($result.Plan.Items | Where-Object PackageId -eq 'admin')[0].State
        Assert-FreshWinEqual 1 $result.Summary.Pending
        Assert-FreshWinEqual 1 $result.Summary.Deferred
        Assert-FreshWinEqual 'INCOMPLETE' $result.Status
    }
    finally {
        Remove-Variable FreshWinPrivilegeProcessIds -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable FreshWinPrivilegeResolverIds -Scope Script -ErrorAction SilentlyContinue
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'Non-admin-only execution never invokes administrator package actions' -Category 'Workflow' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $wingetFixture = Join-Path $directory 'winget.exe'
        [IO.File]::WriteAllText($wingetFixture, 'fixture')
        $userPackage = New-FreshWinTestPackage -Id user
        $adminPackage = New-FreshWinTestPackage -Id admin -RequiresAdmin $true
        $catalog = [pscustomobject]@{ Packages=@($userPackage, $adminPackage); Errors=@() }
        $emptyInventory = [pscustomobject]@{ Available=$true; Items=@() }
        $systemInfo = New-FreshWinTestSystemInfo
        $systemInfo.Admin = $false
        $systemInfo.IsAdministrator = $false
        $plan = New-FreshWinInstallPlan -PackageIds @('user', 'admin') -Catalog $catalog `
            -SystemInfo $systemInfo -Inventory $emptyInventory -WingetPath $wingetFixture `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage }
        $script:FreshWinPrivilegeProcessIds = @()
        $script:FreshWinPrivilegeResolverIds = @()
        $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo $systemInfo `
            -Inventory $emptyInventory -ExecutionMode NonAdminOnly `
            -SourceResolver {
                param($trustedPackage)
                $script:FreshWinPrivilegeResolverIds += [string]$trustedPackage.id
                New-FreshWinTestResolvedSource $trustedPackage
            } `
            -ProcessInvoker {
                param($file, $arguments)
                $managerId = [string]$arguments[([Array]::IndexOf([object[]]$arguments, '--id') + 1)]
                $script:FreshWinPrivilegeProcessIds += $managerId
                [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' }
            } `
            -InventoryProvider {
                $items = @($script:FreshWinPrivilegeProcessIds | ForEach-Object {
                    [pscustomobject]@{ WingetId=$_; Source='Winget'; Version='1.0' }
                })
                [pscustomobject]@{ Available=$true; Items=$items }
            }
        Assert-FreshWinSetEqual @('Fixture.user') @($script:FreshWinPrivilegeProcessIds)
        Assert-FreshWinSetEqual @('user') @($script:FreshWinPrivilegeResolverIds)
        Assert-FreshWinEqual 'SUCCEEDED' @($result.Plan.Items | Where-Object PackageId -eq 'user')[0].State
        Assert-FreshWinEqual 'PENDING' @($result.Plan.Items | Where-Object PackageId -eq 'admin')[0].State
        Assert-FreshWinEqual 'PrivilegePartition' @($result.Plan.Items | Where-Object PackageId -eq 'admin')[0].Result.Stage
        Assert-FreshWinEqual 1 $result.Summary.Pending
        Assert-FreshWinEqual 1 $result.Summary.Deferred
        Assert-FreshWinEqual 'INCOMPLETE' $result.Status
    }
    finally {
        Remove-Variable FreshWinPrivilegeProcessIds -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable FreshWinPrivilegeResolverIds -Scope Script -ErrorAction SilentlyContinue
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'Opposite-privilege dependencies defer dependents instead of blocking them' -Category 'Workflow' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $wingetFixture = Join-Path $directory 'winget.exe'
        [IO.File]::WriteAllText($wingetFixture, 'fixture')
        $userDependency = New-FreshWinTestPackage -Id user-dependency
        $adminApplication = New-FreshWinTestPackage -Id admin-application -Dependencies @('user-dependency') -RequiresAdmin $true
        $catalog = [pscustomobject]@{ Packages=@($adminApplication, $userDependency); Errors=@() }
        $emptyInventory = [pscustomobject]@{ Available=$true; Items=@() }
        $plan = New-FreshWinInstallPlan -PackageIds admin-application -Catalog $catalog `
            -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $emptyInventory -WingetPath $wingetFixture `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage }
        $script:FreshWinUnexpectedPrivilegeCall = $false
        $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) `
            -Inventory $emptyInventory -ExecutionMode AdminOnly `
            -SourceResolver { $script:FreshWinUnexpectedPrivilegeCall = $true; throw 'a deferred package must not resolve a live source' } `
            -ProcessInvoker { $script:FreshWinUnexpectedPrivilegeCall = $true; throw 'a deferred package must not run' }
        $dependencyItem = @($result.Plan.Items | Where-Object PackageId -eq 'user-dependency')[0]
        $applicationItem = @($result.Plan.Items | Where-Object PackageId -eq 'admin-application')[0]
        Assert-FreshWinFalse $script:FreshWinUnexpectedPrivilegeCall
        Assert-FreshWinEqual 'PENDING' $dependencyItem.State
        Assert-FreshWinEqual 'PrivilegePartition' $dependencyItem.Result.Stage
        Assert-FreshWinEqual 'PENDING' $applicationItem.State
        Assert-FreshWinEqual 'Dependency' $applicationItem.Result.Stage
        Assert-FreshWinEqual 2 $result.Summary.Pending
        Assert-FreshWinEqual 2 $result.Summary.Deferred
        Assert-FreshWinEqual 0 $result.Summary.Blocked
        Assert-FreshWinEqual 'INCOMPLETE' $result.Status
    }
    finally {
        Remove-Variable FreshWinUnexpectedPrivilegeCall -Scope Script -ErrorAction SilentlyContinue
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'A genuinely failed dependency still blocks its dependent in a privilege phase' -Category 'Workflow' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $wingetFixture = Join-Path $directory 'winget.exe'
        [IO.File]::WriteAllText($wingetFixture, 'fixture')
        $adminDependency = New-FreshWinTestPackage -Id admin-dependency -RequiresAdmin $true
        $adminApplication = New-FreshWinTestPackage -Id admin-application -Dependencies @('admin-dependency') -RequiresAdmin $true
        $catalog = [pscustomobject]@{ Packages=@($adminApplication, $adminDependency); Errors=@() }
        $emptyInventory = [pscustomobject]@{ Available=$true; Items=@() }
        $plan = New-FreshWinInstallPlan -PackageIds admin-application -Catalog $catalog `
            -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $emptyInventory -WingetPath $wingetFixture `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage }
        $script:FreshWinFailedDependencyCalls = 0
        $result = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) `
            -Inventory $emptyInventory -ExecutionMode AdminOnly -MaxAttempts 1 `
            -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource $trustedPackage } `
            -ProcessInvoker {
                $script:FreshWinFailedDependencyCalls++
                [pscustomobject]@{ ExitCode=1; Succeeded=$false; StandardOutput=''; StandardError='fixture failure' }
            }
        $dependencyItem = @($result.Plan.Items | Where-Object PackageId -eq 'admin-dependency')[0]
        $applicationItem = @($result.Plan.Items | Where-Object PackageId -eq 'admin-application')[0]
        Assert-FreshWinEqual 1 $script:FreshWinFailedDependencyCalls
        Assert-FreshWinEqual 'FAILED' $dependencyItem.State
        Assert-FreshWinEqual 'BLOCKED' $applicationItem.State
        Assert-FreshWinEqual 'Dependency' $applicationItem.Result.Stage
        Assert-FreshWinEqual 0 $result.Summary.Pending
        Assert-FreshWinEqual 1 $result.Summary.Blocked
        Assert-FreshWinEqual 'COMPLETED_WITH_ISSUES' $result.Status
    }
    finally {
        Remove-Variable FreshWinFailedDependencyCalls -Scope Script -ErrorAction SilentlyContinue
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'Admin and user phases progress independently around manual plan items' -Category 'Workflow' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $winget = Join-Path $temporary 'winget'
        [IO.File]::WriteAllText($winget, 'fixture')
        $admin = New-FreshWinTestPackage -Id admin-tool -RequiresAdmin $true
        $user = New-FreshWinTestPackage -Id user-tool -RequiresAdmin $false
        $manual = New-FreshWinTestPackage -Id manual-tool -SourceType manual -Silent $false
        $catalog = [pscustomobject]@{ Packages=@($admin,$user,$manual); Errors=@() }
        $empty = [pscustomobject]@{ Available=$true; Items=@() }
        $plan = New-FreshWinInstallPlan -PackageIds @('admin-tool','user-tool','manual-tool') -Catalog $catalog `
            -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $empty -WingetPath $winget `
            -SourceResolver {
                param($trustedPackage)
                if ([string]$trustedPackage.source.type -eq 'manual') { Resolve-FreshWinPackageSource -Package $trustedPackage }
                else { New-FreshWinTestResolvedSource $trustedPackage }
            }
        $script:FreshWinPartitionInstalled = New-Object System.Collections.Generic.List[string]
        $script:FreshWinPartitionCalls = New-Object System.Collections.Generic.List[string]
        $inventoryProvider = {
            $items = @($script:FreshWinPartitionInstalled | ForEach-Object {
                [pscustomobject]@{ WingetId="Fixture.$_"; Source='Winget'; Version='1.0' }
            })
            [pscustomobject]@{ Available=$true; Items=$items }
        }
        $processInvoker = {
            param($file,$arguments)
            $id = [string]$arguments[@($arguments).IndexOf('--id') + 1]
            $shortId = $id.Substring('Fixture.'.Length)
            $script:FreshWinPartitionCalls.Add($shortId)
            $script:FreshWinPartitionInstalled.Add($shortId)
            [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' }
        }
        $adminPhase = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $empty `
            -InventoryProvider $inventoryProvider -SourceResolver { param($package) New-FreshWinTestResolvedSource $package } `
            -ProcessInvoker $processInvoker -ExecutionMode AdminOnly
        Assert-FreshWinSetEqual @('admin-tool') @($script:FreshWinPartitionCalls)
        Assert-FreshWinEqual 'COMPLETED_WITH_ISSUES' $adminPhase.Status

        $userPhase = Invoke-FreshWinExecutionPlan -Plan $adminPhase.Plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory (& $inventoryProvider) `
            -InventoryProvider $inventoryProvider -SourceResolver { param($package) New-FreshWinTestResolvedSource $package } `
            -ProcessInvoker $processInvoker -ExecutionMode NonAdminOnly
        Assert-FreshWinSetEqual @('admin-tool','user-tool') @($script:FreshWinPartitionCalls)
        Assert-FreshWinEqual 'MANUAL' (@($userPhase.Plan.Items | Where-Object PackageId -eq 'manual-tool')[0].State)
        Assert-FreshWinEqual 'COMPLETED_WITH_ISSUES' $userPhase.Status
    }
    finally {
        Remove-Variable FreshWinPartitionInstalled -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable FreshWinPartitionCalls -Scope Script -ErrorAction SilentlyContinue
        Remove-FreshWinTestDirectory $temporary
    }
}

Add-FreshWinTest -Name 'Elevated helper success never hides a failed admin attempt' -Category 'Security' -ScriptBlock {
    $adminItem = [pscustomobject]@{
        RequiresAdmin=$true; Action='INSTALL'; State='SUCCEEDED'
        Result=[pscustomobject]@{ Stage='Install'; Outcome='ProcessSucceeded' }
    }
    $manualItem = [pscustomobject]@{ RequiresAdmin=$true; Action='MANUAL'; State='MANUAL'; Result=$null }
    $userPending = [pscustomobject]@{
        RequiresAdmin=$false; Action='INSTALL'; State='PENDING'
        Result=[pscustomobject]@{ Stage='PrivilegePartition'; Outcome='Deferred' }
    }
    $tolerable = [pscustomobject]@{
        Status='COMPLETED_WITH_ISSUES'
        Plan=[pscustomobject]@{ Items=@($adminItem, $manualItem, $userPending) }
    }
    Assert-FreshWinTrue (Test-FreshWinElevatedHelperExecutionResult -ExecutionResult $tolerable) `
        -Because 'Manual choices and deferred user-scope work must not prevent the parent phase.'

    foreach ($failureState in @('FAILED','BLOCKED','ELEVATION_REQUIRED','UNKNOWN_VERIFICATION')) {
        $failedAdmin = [pscustomobject]@{
            RequiresAdmin=$true; Action='INSTALL'; State=$failureState
            Result=[pscustomobject]@{ Stage='Install'; Outcome='Failed' }
        }
        $failed = [pscustomobject]@{
            Status='COMPLETED_WITH_ISSUES'
            Plan=[pscustomobject]@{ Items=@($failedAdmin, $userPending) }
        }
        Assert-FreshWinFalse (Test-FreshWinElevatedHelperExecutionResult -ExecutionResult $failed) `
            -Because "Admin state $failureState must produce a nonzero helper exit and stop the parent phase."
    }
    Assert-FreshWinFalse (Test-FreshWinElevatedHelperExecutionResult -ExecutionResult ([pscustomobject]@{ Status='COMPLETED_WITH_ISSUES'; Plan=$null }))
}

Add-FreshWinTest -Name 'Two-phase execution never crosses a persisted reboot boundary' -Category 'Security' -ScriptBlock {
    $checkpoint = [pscustomobject]@{
        status='COMPLETED_WITH_ISSUES'
        items=@(
            [pscustomobject]@{ state='SUCCEEDED'; restartRequired=$true; result=[pscustomobject]@{ outcome='ProcessSucceeded' } },
            [pscustomobject]@{ state='MANUAL'; restartRequired=$false; result=$null },
            [pscustomobject]@{ state='PENDING'; restartRequired=$false; result=[pscustomobject]@{ outcome='Deferred' } }
        )
    }
    Assert-FreshWinTrue (Test-FreshWinCheckpointRequiresReboot -Checkpoint $checkpoint)
    $checkpoint.items[0].restartRequired = $false
    Assert-FreshWinFalse (Test-FreshWinCheckpointRequiresReboot -Checkpoint $checkpoint)

    $cliSource = [IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/UI/Cli.ps1'))
    $terminalSource = [IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/UI/Terminal.ps1'))
    Assert-FreshWinTrue ([regex]::Matches($cliSource, 'Test-FreshWinCheckpointRequiresReboot\s+-Checkpoint\s+\$elevatedCheckpoint').Count -ge 2) `
        -Because 'Both initial install and resume elevation boundaries must stop before the user phase.'
    Assert-FreshWinMatch -Actual $terminalSource -Pattern 'Test-FreshWinCheckpointRequiresReboot\s+-Checkpoint\s+\$elevatedCheckpoint'

    $resumeSource = [IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/Execution/Resume.ps1'))
    Assert-FreshWinMatch -Actual $resumeSource -Pattern '--checkpoint-hash\s+\{3\}\s+--register-resume' `
        -Because 'An explicitly registered multi-reboot workflow must preserve registration after RunOnce is consumed.'
}

Add-FreshWinTest -Name 'Manual sources never invoke an installer process' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage -SourceType manual -Silent $false
    $resolved = Resolve-FreshWinPackageSource $package
    $script:FreshWinManualProcessCalled = $false
    $result = Invoke-FreshWinPackageInstall -Package $package -Action INSTALL -ResolvedSource $resolved `
        -ProcessInvoker { $script:FreshWinManualProcessCalled = $true; throw 'must not run' }
    Assert-FreshWinEqual 'ManualRequired' $result.Outcome
    Assert-FreshWinFalse $script:FreshWinManualProcessCalled
    Remove-Variable FreshWinManualProcessCalled -Scope Script -ErrorAction SilentlyContinue
}

Add-FreshWinTest -Name 'WinGet completed-reboot HRESULTs are successful only for WinGet sources' -Category 'Workflow' -ScriptBlock {
    $wingetPackage = New-FreshWinTestPackage
    $wingetSource = New-FreshWinTestResolvedSource $wingetPackage
    foreach ($code in @(-1978334967, -1978334965)) {
        $result = Invoke-FreshWinPackageInstall -Package $wingetPackage -Action INSTALL -ResolvedSource $wingetSource `
            -MaxAttempts 1 -ProcessInvoker { [pscustomobject]@{ ExitCode=$code; Succeeded=$false; StandardOutput=''; StandardError='' } }
        Assert-FreshWinEqual 'ProcessSucceeded' $result.Outcome
        Assert-FreshWinTrue $result.RebootRequired
        Assert-FreshWinEqual $code $result.ExitCode
    }

    $preInstallReboot = Invoke-FreshWinPackageInstall -Package $wingetPackage -Action INSTALL -ResolvedSource $wingetSource `
        -MaxAttempts 1 -ProcessInvoker { [pscustomobject]@{ ExitCode=-1978334966; Succeeded=$false; StandardOutput=''; StandardError='' } }
    Assert-FreshWinEqual 'Failed' $preInstallReboot.Outcome `
        -Because 'WinGet says the install did not run and may only be retried after a reboot.'
    Assert-FreshWinTrue $preInstallReboot.RebootRequired
    Assert-FreshWinTrue $preInstallReboot.RetryAfterReboot
    Assert-FreshWinMatch $preInstallReboot.Message 'must restart before this installation can be retried'

    $featurePackage = New-FreshWinTestPackage -SourceType windows-feature
    $featureSource = [pscustomobject]@{
        PackageId='sample'; SourceType='windows-feature'; Status='Resolved'; Trust='FixtureBoundary'
        Executable=(Get-Process -Id $PID).Path; PackageManagerId=$null; SourceName=$null
        Uri=$null; FeatureName='Microsoft-Windows-Subsystem-Linux'; FeatureNames=@('Microsoft-Windows-Subsystem-Linux')
        VersionPolicy=$featurePackage.versionPolicy; Reason=$null
    }
    $featureResult = Invoke-FreshWinPackageInstall -Package $featurePackage -Action INSTALL -ResolvedSource $featureSource `
        -MaxAttempts 1 -ProcessInvoker { [pscustomobject]@{ ExitCode=-1978334967; Succeeded=$false; StandardOutput=''; StandardError='' } }
    Assert-FreshWinEqual 'Failed' $featureResult.Outcome `
        -Because 'WinGet HRESULTs must never be accepted globally for DISM or another executable.'
}

Add-FreshWinTest -Name 'WinGet execution enforces trusted machine and user scope without guessing either scope' -Category 'Workflow' -ScriptBlock {
    foreach ($scopeCase in @(
        [pscustomobject]@{ Scope='machine'; Expected='machine' },
        [pscustomobject]@{ Scope='user'; Expected='user' },
        [pscustomobject]@{ Scope='either'; Expected=$null }
    )) {
        $package = New-FreshWinTestPackage
        $package.install.scope = $scopeCase.Scope
        $source = New-FreshWinTestResolvedSource $package
        $script:FreshWinScopeArguments = $null
        $result = Invoke-FreshWinPackageInstall -Package $package -Action INSTALL -ResolvedSource $source -MaxAttempts 1 `
            -ProcessInvoker {
                param($file, $arguments)
                $script:FreshWinScopeArguments = @($arguments)
                [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' }
            }
        Assert-FreshWinEqual 'ProcessSucceeded' $result.Outcome
        $scopeIndex = [Array]::IndexOf([object[]]$script:FreshWinScopeArguments, '--scope')
        if ($null -eq $scopeCase.Expected) {
            Assert-FreshWinEqual -Expected -1 -Actual $scopeIndex -Because 'Either scope must remain an explicit package-manager choice.'
        }
        else {
            Assert-FreshWinTrue ($scopeIndex -ge 0)
            Assert-FreshWinEqual $scopeCase.Expected $script:FreshWinScopeArguments[$scopeIndex + 1]
        }
    }
    Remove-Variable FreshWinScopeArguments -Scope Script -ErrorAction SilentlyContinue

    $storePackage = New-FreshWinTestPackage -SourceType msstore
    $storePackage.install.scope = 'machine'
    $storeSource = New-FreshWinTestResolvedSource $storePackage
    $storeSource.SourceName = 'msstore'
    $storeArguments = Get-FreshWinInstallArguments -ResolvedSource $storeSource -Action INSTALL
    Assert-FreshWinFalse (@($storeArguments) -contains '--scope') `
        -Because 'Microsoft Store sources do not support the WinGet scope selector contract used here.'
}

Add-FreshWinTest -Name 'Windows feature installation consumes every validated feature name' -Category 'Workflow' -ScriptBlock {
    $package = New-FreshWinTestPackage -SourceType windows-feature
    $source = [pscustomobject]@{
        PackageId='sample'; SourceType='windows-feature'; Status='Resolved'; Trust='FixtureBoundary'
        Executable=(Get-Process -Id $PID).Path; PackageManagerId=$null; SourceName=$null; Uri=$null
        FeatureName='Feature.One'; FeatureNames=@('Feature.One','Feature.Two')
        VersionPolicy=$package.versionPolicy; Reason=$null
    }
    $script:FreshWinFeatureArguments = @()
    $result = Invoke-FreshWinPackageInstall -Package $package -Action INSTALL -ResolvedSource $source -MaxAttempts 1 `
        -ProcessInvoker {
            param($file, $arguments)
            $script:FreshWinFeatureArguments += ,@($arguments)
            [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' }
        }
    Assert-FreshWinEqual 'ProcessSucceeded' $result.Outcome
    Assert-FreshWinEqual 2 $script:FreshWinFeatureArguments.Count
    Assert-FreshWinContains @($script:FreshWinFeatureArguments[0]) '/FeatureName:Feature.One'
    Assert-FreshWinContains @($script:FreshWinFeatureArguments[1]) '/FeatureName:Feature.Two'
    foreach ($arguments in $script:FreshWinFeatureArguments) {
        Assert-FreshWinContains @($arguments) '/Online'
        Assert-FreshWinContains @($arguments) '/NoRestart'
    }
    Remove-Variable FreshWinFeatureArguments -Scope Script -ErrorAction SilentlyContinue
}

Add-FreshWinTest -Name 'Progress events include package identity without fabricating percentage' -Category 'Workflow' -ScriptBlock {
    $item = [pscustomobject]@{ PackageId='sample'; Package=[pscustomobject]@{ name='Sample' }; State='RUNNING' }
    $event = New-FreshWinProgressEvent -Item $item -Stage INSTALLING -Position 5 -Total 3
    Assert-FreshWinFalse ($null -ne $event.PSObject.Properties['Percent']) `
        -Because 'Queue position must not be represented as backend progress.'
    Assert-FreshWinEqual 'sample' $event.PackageId
}
