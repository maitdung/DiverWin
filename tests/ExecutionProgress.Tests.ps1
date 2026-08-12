Set-StrictMode -Version Latest

function New-FreshWinExecutionProgressFixture {
    param([object[]]$Packages, [switch]$DryRun)

    $catalog = [pscustomobject]@{ Packages=@($Packages); Errors=@(); IsValid=$true }
    $inventory = [pscustomobject]@{ Available=$true; Status='Ready'; Items=@(); Errors=@() }
    $resolver = { param($package) New-FreshWinTestResolvedSource -Package $package }
    $plan = New-FreshWinInstallPlan -PackageIds @($Packages.id) -Catalog $catalog `
        -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $inventory -SourceResolver $resolver -DryRun:$DryRun
    return [pscustomobject]@{ Catalog=$catalog; Inventory=$inventory; Resolver=$resolver; Plan=$plan }
}

Add-FreshWinTest -Name 'Shared execution stages are ordered and verified success is explicit' -Category 'ExecutionProgress' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $fixture = New-FreshWinExecutionProgressFixture -Packages @($package)
    $script:FreshWinProgressInventoryCall = 0
    try {
        $execution = Invoke-FreshWinExecutionPlan -Plan $fixture.Plan -Catalog $fixture.Catalog `
            -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $fixture.Inventory -SourceResolver $fixture.Resolver `
            -ProcessInvoker { [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput='installer complete'; StandardError='' } } `
            -InventoryProvider {
                $script:FreshWinProgressInventoryCall++
                $items = if ($script:FreshWinProgressInventoryCall -eq 1) { @() }
                    else { @([pscustomobject]@{ WingetId='Fixture.sample'; DisplayName='Fixture sample'; Source='Winget'; Version='1.0' }) }
                [pscustomobject]@{ Available=$true; Status='Ready'; Items=$items; Errors=@() }
            }
        $firstStages = New-Object System.Collections.Generic.List[string]
        foreach ($event in @($execution.Progress | Where-Object Stage -ne 'COMPLETE')) {
            if (-not $firstStages.Contains([string]$event.Stage)) { $firstStages.Add([string]$event.Stage) }
        }
        Assert-FreshWinEqual -Expected 'CHECKING_INSTALLED_STATE,RESOLVING_SOURCE,DOWNLOADING,INSTALLING,VERIFYING,REFRESHING_INVENTORY' `
            -Actual ($firstStages -join ',')
        Assert-FreshWinEqual 'SUCCEEDED' $execution.Plan.Items[0].State
        $report = New-FreshWinExecutionReport -ExecutionResult $execution -Progress $execution.Progress
        Assert-FreshWinEqual 'Installed' $report.Items[0].Outcome
        Assert-FreshWinTrue $report.Items[0].Verified
        Assert-FreshWinFalse ($null -ne $execution.Progress[0].PSObject.Properties['Percent'])
    }
    finally { Remove-Variable FreshWinProgressInventoryCall -Scope Script -ErrorAction SilentlyContinue }
}

Add-FreshWinTest -Name 'Resolver failure is isolated to its package and reports the failed stage' -Category 'ExecutionProgress' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $catalog = [pscustomobject]@{ Packages=@($package); Errors=@() }
    $plan = New-FreshWinTestExecutionPlan -Package $package
    $execution = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo (New-FreshWinTestSystemInfo) `
        -Inventory ([pscustomobject]@{ Available=$true; Status='Ready'; Items=@(); Errors=@() }) `
        -SourceResolver { throw 'fixture trusted resolver failure' }
    Assert-FreshWinEqual 'BLOCKED' $execution.Plan.Items[0].State
    Assert-FreshWinEqual 'Resolve' $execution.Plan.Items[0].Result.Stage
    Assert-FreshWinEqual 'Failed' (New-FreshWinExecutionReport -ExecutionResult $execution).Items[0].Outcome
}

Add-FreshWinTest -Name 'Installer classifies download installer timeout and agreement failures without hidden input' -Category 'ExecutionProgress' -ScriptBlock {
    $package = New-FreshWinTestPackage
    $source = New-FreshWinTestResolvedSource -Package $package

    $download = Invoke-FreshWinPackageInstall -Package $package -Action INSTALL -ResolvedSource $source -MaxAttempts 1 `
        -ProcessInvoker { [pscustomobject]@{ ExitCode=1; Succeeded=$false; StandardOutput=''; StandardError='Download failed: network connection unavailable' } }
    Assert-FreshWinEqual 'Download' $download.Stage
    Assert-FreshWinEqual 'Failed' $download.Outcome

    $installer = Invoke-FreshWinPackageInstall -Package $package -Action INSTALL -ResolvedSource $source -MaxAttempts 1 `
        -ProcessInvoker { [pscustomobject]@{ ExitCode=1603; Succeeded=$false; StandardOutput=''; StandardError='MSI fatal error' } }
    Assert-FreshWinEqual 'Install' $installer.Stage

    $timeout = Invoke-FreshWinPackageInstall -Package $package -Action INSTALL -ResolvedSource $source -MaxAttempts 3 `
        -ProcessInvoker { [pscustomobject]@{ ExitCode=$null; Succeeded=$false; TimedOut=$true; StandardOutput=''; StandardError='' } }
    Assert-FreshWinEqual 1 $timeout.Attempts
    Assert-FreshWinMatch $timeout.Message 'bounded timeout'

    $agreement = Invoke-FreshWinPackageInstall -Package $package -Action INSTALL -ResolvedSource $source -MaxAttempts 3 `
        -ProcessInvoker { [pscustomobject]@{ ExitCode=1; Succeeded=$false; StandardOutput='The source agreement must be accepted before use.'; StandardError='' } }
    Assert-FreshWinEqual 1 $agreement.Attempts
    Assert-FreshWinEqual 'ManualRequired' $agreement.Outcome
    Assert-FreshWinEqual 'SourceAgreement' $agreement.Stage

    $arguments = @(Get-FreshWinInstallArguments -ResolvedSource $source -Action INSTALL)
    Assert-FreshWinContains $arguments '--source'
    Assert-FreshWinContains $arguments 'winget'
    Assert-FreshWinFalse ($arguments -contains '--accept-source-agreements')
    Assert-FreshWinFalse ($arguments -contains '--accept-package-agreements')
}

Add-FreshWinTest -Name 'Verification and inventory refresh failures never become verified success' -Category 'ExecutionProgress' -ScriptBlock {
    foreach ($mode in @('verification-failed', 'inventory-unavailable')) {
        $package = New-FreshWinTestPackage
        $fixture = New-FreshWinExecutionProgressFixture -Packages @($package)
        $script:FreshWinFailureInventoryCall = 0
        try {
            $execution = Invoke-FreshWinExecutionPlan -Plan $fixture.Plan -Catalog $fixture.Catalog `
                -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $fixture.Inventory -SourceResolver $fixture.Resolver `
                -ProcessInvoker { [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' } } `
                -InventoryProvider {
                    $script:FreshWinFailureInventoryCall++
                    if ($mode -eq 'inventory-unavailable' -and $script:FreshWinFailureInventoryCall -gt 1) {
                        return [pscustomobject]@{ Available=$false; Status='Unavailable'; Items=@(); Errors=@('fixture refresh failure') }
                    }
                    return [pscustomobject]@{ Available=$true; Status='Ready'; Items=@(); Errors=@() }
                }
            Assert-FreshWinFalse ([bool]$execution.Plan.Items[0].Verification.Verified)
            Assert-FreshWinTrue ($execution.Plan.Items[0].State -in @('FAILED','UNKNOWN_VERIFICATION'))
            Assert-FreshWinFalse ((New-FreshWinExecutionReport -ExecutionResult $execution).Items[0].Outcome -eq 'Installed')
            if ($mode -eq 'inventory-unavailable') {
                $refreshFailure = @($execution.Progress | Where-Object { $_.Stage -eq 'REFRESHING_INVENTORY' -and $_.Status -eq 'Failed' })
                Assert-FreshWinCount 1 $refreshFailure
            } else {
                Assert-FreshWinEqual 'Verify' $execution.Plan.Items[0].Result.Stage
            }
        }
        finally { Remove-Variable FreshWinFailureInventoryCall -Scope Script -ErrorAction SilentlyContinue }
    }
}

Add-FreshWinTest -Name 'Already-installed items skip and multi-package partial failure remains visible' -Category 'ExecutionProgress' -ScriptBlock {
    $installedPackage = New-FreshWinTestPackage -Id installed
    $installedFixture = New-FreshWinExecutionProgressFixture -Packages @($installedPackage)
    $script:FreshWinUnexpectedInstall = 0
    try {
        $installedInventory = [pscustomobject]@{
            Available=$true; Status='Ready'; Errors=@()
            Items=@([pscustomobject]@{ WingetId='Fixture.installed'; DisplayName='Fixture installed'; Source='Winget'; Version='1.0' })
        }
        $skipped = Invoke-FreshWinExecutionPlan -Plan $installedFixture.Plan -Catalog $installedFixture.Catalog `
            -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $installedFixture.Inventory -SourceResolver $installedFixture.Resolver `
            -InventoryProvider { $installedInventory } `
            -ProcessInvoker { $script:FreshWinUnexpectedInstall++; [pscustomobject]@{ ExitCode=0; Succeeded=$true } }
        Assert-FreshWinEqual 0 $script:FreshWinUnexpectedInstall
        Assert-FreshWinEqual 'SKIP' $skipped.Plan.Items[0].State
        Assert-FreshWinEqual 'Skipped' (New-FreshWinExecutionReport -ExecutionResult $skipped).Items[0].Outcome
    }
    finally { Remove-Variable FreshWinUnexpectedInstall -Scope Script -ErrorAction SilentlyContinue }

    $first = New-FreshWinTestPackage -Id first
    $second = New-FreshWinTestPackage -Id second
    $fixture = New-FreshWinExecutionProgressFixture -Packages @($first, $second)
    $script:FreshWinPartialProcessCall = 0
    $script:FreshWinPartialInventoryCall = 0
    try {
        $partial = Invoke-FreshWinExecutionPlan -Plan $fixture.Plan -Catalog $fixture.Catalog `
            -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $fixture.Inventory -SourceResolver $fixture.Resolver `
            -ProcessInvoker {
                $script:FreshWinPartialProcessCall++
                if ($script:FreshWinPartialProcessCall -eq 1) { [pscustomobject]@{ ExitCode=0; Succeeded=$true; StandardOutput=''; StandardError='' } }
                else { [pscustomobject]@{ ExitCode=1603; Succeeded=$false; StandardOutput=''; StandardError='fixture installer failed' } }
            } -InventoryProvider {
                $script:FreshWinPartialInventoryCall++
                $items = if ($script:FreshWinPartialInventoryCall -gt 1) {
                    @([pscustomobject]@{ WingetId='Fixture.first'; DisplayName='Fixture first'; Source='Winget'; Version='1.0' })
                } else { @() }
                [pscustomobject]@{ Available=$true; Status='Ready'; Items=$items; Errors=@() }
            }
        Assert-FreshWinEqual 1 $partial.Summary.Succeeded
        Assert-FreshWinEqual 1 $partial.Summary.Failed
        Assert-FreshWinEqual 'COMPLETED_WITH_ISSUES' $partial.Status
        $partialReport = New-FreshWinExecutionReport -ExecutionResult $partial
        Assert-FreshWinSetEqual @('Installed','Failed') @($partialReport.Items.Outcome)
    }
    finally {
        Remove-Variable FreshWinPartialProcessCall -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable FreshWinPartialInventoryCall -Scope Script -ErrorAction SilentlyContinue
    }
}

Add-FreshWinTest -Name 'Terminal result owns navigation and exposes retry details log and verified status' -Category 'ExecutionProgress' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $failedPackage = New-FreshWinTestPackage
    $failedPlan = New-FreshWinTestExecutionPlan -Package $failedPackage
    $failedPlan.Items[0].State = 'FAILED'
    $failedPlan.Items[0].ResolvedSource = New-FreshWinTestResolvedSource -Package $failedPackage
    $failedPlan.Items[0].Result = [pscustomobject]@{ Outcome='Failed'; Stage='Install'; ExitCode=1603; Message='Fixture failure'; ProcessResult=[pscustomobject]@{ StandardError='fixture raw failure' } }
    $failedExecution = [pscustomobject]@{ Status='COMPLETED_WITH_ISSUES'; Plan=$failedPlan; Summary=(Get-FreshWinExecutionSummary $failedPlan); Progress=@() }
    $inputs = New-Object System.Collections.Queue
    foreach ($value in @('D','L','0')) { $inputs.Enqueue($value) }
    $output = New-Object System.Collections.Generic.List[string]
    $choice = Show-FreshWinTerminalExecutionResult -ExecutionResult $failedExecution `
        -InputProvider { param($prompt) $inputs.Dequeue() } -OutputWriter { param($line) $output.Add([string]$line) }
    Assert-FreshWinEqual 'Back' $choice.Action
    Assert-FreshWinTrue ((@($output | Where-Object { $_ -match 'Execution Results' })).Count -ge 3) `
        -Because 'Details and Log must return to the owned result screen instead of the catalog.'
    Assert-FreshWinMatch ($output -join "`n") 'Retry through a newly reviewed plan'
    Assert-FreshWinMatch ($output -join "`n") 'View failure details'

    $successPlan = New-FreshWinTestExecutionPlan -Package $failedPackage
    $successPlan.Items[0].State = 'SUCCEEDED'
    $successPlan.Items[0].Result = [pscustomobject]@{ Outcome='ProcessSucceeded'; Stage='Install'; ExitCode=0; Message='Verification required'; ProcessResult=$null }
    $successPlan.Items[0].Verification = [pscustomobject]@{ Status='Verified'; Verified=$true; Detail='Exact package identity matched.' }
    $successExecution = [pscustomobject]@{ Status='COMPLETED'; Plan=$successPlan; Summary=(Get-FreshWinExecutionSummary $successPlan); Progress=@() }
    $successOutput = New-Object System.Collections.Generic.List[string]
    [void](Show-FreshWinTerminalExecutionResult -ExecutionResult $successExecution -InputProvider { param($prompt) '0' } `
        -OutputWriter { param($line) $successOutput.Add([string]$line) })
    Assert-FreshWinMatch ($successOutput -join "`n") 'Installed - VERIFIED'
}

Add-FreshWinTest -Name 'Reviewed terminal dry-run transitions through execution and owned result before returning' -Category 'ExecutionProgress' -ScriptBlock {
    [void](Initialize-FreshWinLocalization -Locale en-US)
    $package = New-FreshWinTestPackage
    $system = New-FreshWinTestSystemInfo
    $inventory = [pscustomobject]@{ Available=$true; Status='Ready'; Items=@(); Errors=@() }
    $session = [pscustomobject]@{
        Catalog=[pscustomobject]@{ Packages=@($package); Errors=@() }
        System=$system; Inventory=$inventory; IncludeUpdates=$false
    }
    $inputs = New-Object System.Collections.Queue
    foreach ($value in @('', '0')) { $inputs.Enqueue($value) }
    $prompts = New-Object System.Collections.Generic.List[string]
    $output = New-Object System.Collections.Generic.List[string]
    $result = Invoke-FreshWinTerminalPlanWorkflow -Session $session -PackageIds @('sample') -DryRun `
        -SourceResolver { param($trustedPackage) New-FreshWinTestResolvedSource -Package $trustedPackage } `
        -ProcessInvoker { throw 'A dry-run must not invoke a package-manager process.' } `
        -InputProvider { param($prompt) $prompts.Add([string]$prompt); $inputs.Dequeue() } `
        -OutputWriter { param($line) $output.Add([string]$line) }
    Assert-FreshWinEqual 'DRY_RUN_COMPLETE' $result.Status
    Assert-FreshWinContains $prompts 'confirm'
    Assert-FreshWinContains $prompts 'execution-result'
    $rendered = $output -join "`n"
    Assert-FreshWinMatch $rendered 'Executing reviewed plan'
    Assert-FreshWinMatch $rendered 'Execution Results'
    Assert-FreshWinFalse ($rendered -match '\d+%') -Because 'No backend percentage was supplied.'
}

Add-FreshWinTest -Name 'CLI execution output uses live callbacks and JSON reports retain progress and item reasons' -Category 'ExecutionProgress' -ScriptBlock {
    $item = [pscustomobject]@{
        PackageId='sample'; Package=[pscustomobject]@{ name='Fixture sample' }; Action='INSTALL'; State='VALIDATED'
        ResolvedSource=[pscustomobject]@{ SourceName='winget'; SourceType='winget'; PackageManagerId='Fixture.sample' }
        Result=[pscustomobject]@{ Outcome='DryRun'; Stage='Validated'; ExitCode=$null; Message='No changes were made.'; ProcessResult=$null }
        Verification=[pscustomobject]@{ Status='NotRun'; Verified=$false; Detail='Dry-run never verifies installed state.' }
        Reason='Fixture plan'
    }
    $plan = [pscustomobject]@{ Id='fixture-plan'; Items=@($item) }
    $summary = [pscustomobject]@{ Succeeded=0; Updated=0; Skipped=0; Failed=0; UnknownVerification=0; Validated=1; RebootRequired=$false }
    $event = New-FreshWinProgressEvent -Item $item -Stage INSTALLING -Status Skipped -Detail 'Dry-run' -Position 1 -Total 1
    $execution = [pscustomobject]@{ Status='DRY_RUN_COMPLETE'; Plan=$plan; Summary=$summary; Progress=@($event) }
    $report = New-FreshWinExecutionReport -ExecutionResult $execution -Progress $execution.Progress
    $json = $report | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    Assert-FreshWinEqual 'DRY_RUN_COMPLETE' $json.Status
    Assert-FreshWinEqual 'VALIDATED' $json.Items[0].State
    Assert-FreshWinMatch $json.Items[0].Reason 'Dry-run'
    Assert-FreshWinEqual 'INSTALLING' $json.Progress[0].Stage
    Assert-FreshWinFalse ($null -ne $json.Progress[0].PSObject.Properties['Percent'])

    $cliSource = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/UI/Cli.ps1'))
    Assert-FreshWinMatch $cliSource 'Invoke-FreshWinCliPackageWorkflow[\s\S]*-ProgressCallback\s+\$cliProgressCallback'
    Assert-FreshWinMatch $cliSource '''resume''[\s\S]*-ProgressCallback\s+\$resumeProgressCallback'
    Assert-FreshWinMatch $cliSource 'New-FreshWinExecutionReport[\s\S]*IncludeDetails:\$Parsed\.VerboseOutput'
}
