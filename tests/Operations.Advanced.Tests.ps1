Set-StrictMode -Version Latest

function New-FreshWinAdvancedTestDriverArtifact {
    param([Parameter(Mandatory = $true)][string]$Folder)
    $path = Join-Path $Folder 'official-gpu-driver.exe'
    [System.IO.File]::WriteAllText($path, 'FreshWin deterministic fixture; not an executable driver.')
    return [pscustomobject]@{
        Path      = $path
        Sha256    = Get-FreshWinOperationFileSha256 -Path $path
        SourceUri = 'https://www.nvidia.com/Download/index.aspx'
    }
}

function Get-FreshWinAdvancedTestConfirmations {
    return @{
        UserDataBackupConfirmed             = $true
        DriverBackupVerified                = $true
        ApplicationInventoryCaptured        = $true
        HardwareReportCaptured              = $true
        DiagnosticsExported                 = $true
        BrowserSyncConfirmed                = $true
        LicenseAccountAccessConfirmed       = $true
        BitLockerRecoveryKeyStoredExternally = $true
        RecoveryMediaPrepared               = $true
        PowerReady                          = $true
        StorageReady                        = $true
        RestartNotPending                   = $true
    }
}

Add-FreshWinTest -Name 'Local network driver scan is bounded and matches exact hardware IDs' -Category 'NetworkRescue' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        $netInf = @'
[Version]
Class=Net
Provider=Fixture Network Vendor
DriverVer=01/01/2026,1.2.3.4
CatalogFile=fixture.cat
[Fixture.Models]
%Device%=Install,PCI\VEN_1234&DEV_5678
'@
        $displayInf = @'
[Version]
Class=Display
[Fixture.Models]
%Device%=Install,PCI\VEN_9999&DEV_0001
'@
        [System.IO.File]::WriteAllText((Join-Path $testRoot 'network.inf'), $netInf)
        [System.IO.File]::WriteAllText((Join-Path $testRoot 'display.inf'), $displayInf)

        $result = Find-FreshWinLocalNetworkDriver -Folder $testRoot -HardwareIds @('PCI\VEN_1234&DEV_5678') -MaximumFiles 20
        Assert-FreshWinEqual -Expected 'Completed' -Actual $result.Status
        Assert-FreshWinEqual -Expected 2 -Actual $result.InspectedCount
        Assert-FreshWinCount -Expected 1 -Actual $result.Matches
        Assert-FreshWinEqual -Expected 'Exact' -Actual $result.Matches[0].MatchType
        Assert-FreshWinTrue -Actual $result.Matches[0].IsNetworkClass
        Assert-FreshWinFalse -Actual $result.Matches[0].AutomaticExecution
        Assert-FreshWinMatch -Actual $result.Matches[0].Sha256 -Pattern '^[a-f0-9]{64}$'
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'Network rescue identifies missing drivers and produces a non-executing plan' -Category 'NetworkRescue' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        [System.IO.File]::WriteAllText((Join-Path $testRoot 'network.inf'), "[Version]`nClass=Net`n[Models]`n%Device%=Install,PCI\VEN_1234&DEV_5678")
        $state = Get-FreshWinNetworkRescueState -Adapters @() `
            -ProblemDevices @([pscustomobject]@{ Name = 'Fixture NIC'; ProblemCode = 28; HardwareIds = @('PCI\VEN_1234&DEV_5678') }) `
            -InternetAvailable:$false -LinkAvailable:$false -LocalDriverFolder $testRoot
        Assert-FreshWinEqual -Expected 'DriverMissing' -Actual $state.RescueState
        Assert-FreshWinFalse -Actual $state.IsLive
        Assert-FreshWinCount -Expected 1 -Actual $state.LocalDrivers

        $plan = New-FreshWinNetworkRescuePlan -State $state
        Assert-FreshWinEqual -Expected 'ReviewRequired' -Actual $plan.Status
        Assert-FreshWinFalse -Actual $plan.AutomaticExecution
        Assert-FreshWinFalse -Actual $plan.AllowsDownload
        Assert-FreshWinContains -Collection @($plan.Items.Action) -Expected 'ReviewLocalDriverMatches'
        Assert-FreshWinTrue -Actual (@($plan.Items | Where-Object { $_.AutomaticExecution }).Count -eq 0)
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'Network rescue accepts a legitimate empty problem-device observation' -Category 'NetworkRescue' -ScriptBlock {
    $records = @(Get-FreshWinNetworkDeviceHardwareIds -Devices @())
    Assert-FreshWinCount -Expected 0 -Actual $records

    $state = Get-FreshWinNetworkRescueState -Adapters @() -ProblemDevices @() -InternetAvailable:$false -LinkAvailable:$false
    Assert-FreshWinCount -Expected 0 -Actual $state.ProblemDevices
    Assert-FreshWinEqual -Expected 'NoAdapter' -Actual $state.RescueState
    Assert-FreshWinFalse -Actual $state.IsLive
}

Add-FreshWinTest -Name 'Network rescue retry is bounded and distinguishes fixture observations' -Category 'NetworkRescue' -ScriptBlock {
    $result = Invoke-FreshWinNetworkRescueRetry -MaximumAttempts 3 -ProbeProvider {
        param($Attempt)
        [pscustomobject]@{
            RescueState       = $(if ($Attempt -eq 3) { 'Online' } else { 'Offline' })
            InternetAvailable = ($Attempt -eq 3)
        }
    }
    Assert-FreshWinTrue -Actual $result.Recovered
    Assert-FreshWinEqual -Expected 'FixtureOnlineObserved' -Actual $result.Status
    Assert-FreshWinFalse -Actual $result.IsLive
    Assert-FreshWinFalse -Actual $result.WindowsExecutionVerified
    Assert-FreshWinFalse -Actual $result.MutationPerformed
    Assert-FreshWinCount -Expected 3 -Actual $result.Attempts
}

Add-FreshWinTest -Name 'Network rescue retry records each failed probe exactly once' -Category 'NetworkRescue' -ScriptBlock {
    $result = Invoke-FreshWinNetworkRescueRetry -MaximumAttempts 2 -ProbeProvider {
        param($Attempt)
        if ($Attempt -eq 1) { throw 'fixture probe failed' }
        [pscustomobject]@{ RescueState='Online'; InternetAvailable=$true }
    }
    Assert-FreshWinTrue -Actual $result.Recovered
    Assert-FreshWinCount -Expected 2 -Actual $result.Attempts
    Assert-FreshWinEqual -Expected 'ProbeFailed' -Actual $result.Attempts[0].State
    Assert-FreshWinMatch -Actual $result.Attempts[0].Error -Pattern 'fixture probe failed'
    Assert-FreshWinEqual -Expected 'Online' -Actual $result.Attempts[1].State
}

Add-FreshWinTest -Name 'Offline network diagnostics redact addresses without mutating state' -Category 'NetworkRescue' -ScriptBlock {
    $result = Get-FreshWinOfflineNetworkDiagnostics `
        -IpConfigurationProvider { @([pscustomobject]@{ InterfaceAlias = 'Ethernet'; IPv4Address = '192.168.4.25'; MacAddress = '00-11-22-33-44-55' }) } `
        -RouteProvider { @([pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.4.1' }) } `
        -DnsProvider { @([pscustomobject]@{ ServerAddresses = @('1.1.1.1', '2001:4860:4860::8888') }) }
    Assert-FreshWinEqual -Expected 'FixtureObserved' -Actual $result.Status
    Assert-FreshWinFalse -Actual $result.IsLive
    Assert-FreshWinFalse -Actual $result.MutationPerformed
    $json = ConvertTo-Json -InputObject $result.Data -Depth 20
    Assert-FreshWinMatch -Actual $json -Pattern '\[REDACTED\]'
    Assert-FreshWinMatch -Actual $json -Pattern '\[REDACTED_IP\]'
    Assert-FreshWinFalse -Actual ($json -match '192\.168\.4|00-11-22|1\.1\.1\.1|2001:4860')
}

Add-FreshWinTest -Name 'Security status reports healthy only from explicit Defender and firewall facts' -Category 'SecurityStatus' -ScriptBlock {
    $result = Get-FreshWinSecurityStatus `
        -SecurityProductProvider { [pscustomobject]@{ AntivirusProducts = @([pscustomobject]@{ displayName = 'Microsoft Defender Antivirus'; productState = 397568 }); FirewallProducts = @() } } `
        -DefenderStatusProvider { [pscustomobject]@{ AntivirusEnabled = $true; RealTimeProtectionEnabled = $true } } `
        -FirewallProfileProvider { @([pscustomobject]@{ Name = 'Domain'; Enabled = $true }, [pscustomobject]@{ Name = 'Private'; Enabled = $true }, [pscustomobject]@{ Name = 'Public'; Enabled = $true }) }
    Assert-FreshWinEqual -Expected 'Healthy' -Actual $result.OverallHealth
    Assert-FreshWinEqual -Expected 'Healthy' -Actual $result.DefenderHealth
    Assert-FreshWinEqual -Expected 'Healthy' -Actual $result.FirewallHealth
    Assert-FreshWinEqual -Expected 397568 -Actual $result.AntivirusProducts[0].ProductState
    Assert-FreshWinEqual -Expected 'NotInterpreted' -Actual $result.AntivirusProducts[0].StateInterpretation
    Assert-FreshWinFalse -Actual $result.IsLive
    Assert-FreshWinFalse -Actual $result.MutationPerformed
}

Add-FreshWinTest -Name 'Security status flags explicit protection failures and reviews unknowns' -Category 'SecurityStatus' -ScriptBlock {
    $attention = Get-FreshWinSecurityStatus `
        -DefenderStatusProvider { [pscustomobject]@{ RealTimeProtectionEnabled = $false } } `
        -FirewallProfileProvider { @([pscustomobject]@{ Name = 'Public'; Enabled = $true }) }
    Assert-FreshWinEqual -Expected 'Attention' -Actual $attention.OverallHealth

    $unknown = Get-FreshWinSecurityStatus `
        -SecurityProductProvider { [pscustomobject]@{ AntivirusProducts = @([pscustomobject]@{ displayName = 'Third Party'; productState = 1 }); FirewallProducts = @() } } `
        -DefenderStatusProvider { $null } `
        -FirewallProfileProvider { @() }
    Assert-FreshWinEqual -Expected 'Review' -Actual $unknown.OverallHealth
}

Add-FreshWinTest -Name 'Diagnostics aggregate providers and export only redacted hashed payloads' -Category 'Diagnostics' -ScriptBlock {
    $providers = @{
        System        = { [pscustomobject]@{ Status = 'Ready'; Errors = @(); SerialNumber = 'SERIAL-DO-NOT-EXPORT'; Path = '/Users/private-name/Desktop' } }
        Hardware      = { [pscustomobject]@{ Status = 'Ready'; Errors = @() } }
        Network       = { [pscustomobject]@{ Status = 'FixtureObserved'; RescueState = 'Online'; Errors = @(); MacAddress = '00-11-22-33-44-55' } }
        Security      = { [pscustomobject]@{ Status = 'FixtureObserved'; OverallHealth = 'Healthy'; DefenderHealth = 'Healthy'; FirewallHealth = 'Healthy'; Errors = @() } }
        Drivers       = { [pscustomobject]@{ Status = 'Fixture'; Required = 0; Recommended = 0; Errors = @() } }
        WindowsUpdate = { [pscustomobject]@{ Status = 'Fixture'; PendingCount = 0; RestartPending = $false; Errors = @() } }
        Activation    = { [pscustomobject]@{ Status = 'Fixture'; IsActivated = $true; ActivationStatus = 'Licensed'; PartialProductKey = 'ABCDE'; Errors = @() } }
        Readiness     = { [pscustomobject]@{ Status = 'Fixture'; Readiness = 'Ready'; Errors = @() } }
    }
    $diagnostics = Get-FreshWinDiagnostics -Providers $providers
    Assert-FreshWinFalse -Actual $diagnostics.IsLive
    Assert-FreshWinFalse -Actual $diagnostics.MutationPerformed
    $summary = Get-FreshWinHealthSummary -Diagnostics $diagnostics
    Assert-FreshWinEqual -Expected 'Healthy' -Actual $summary.OverallHealth
    Assert-FreshWinNull -Actual $summary.NumericalScore

    $testRoot = New-FreshWinTestDirectory
    try {
        $export = Export-FreshWinDiagnostics -OutputRoot $testRoot -Diagnostics $diagnostics -Confirm:$false
        Assert-FreshWinTrue -Actual $export.Succeeded
        Assert-FreshWinTrue -Actual $export.Redacted
        $payload = [System.IO.File]::ReadAllText($export.DiagnosticsPath)
        Assert-FreshWinFalse -Actual ($payload -match 'SERIAL-DO-NOT-EXPORT|private-name|00-11-22|ABCDE')
        Assert-FreshWinMatch -Actual $payload -Pattern '\[REDACTED'

        $manifest = Read-FreshWinJsonFile -Path $export.ManifestPath
        Assert-FreshWinCount -Expected 2 -Actual $manifest.Files
        foreach ($file in $manifest.Files) {
            $actual = Get-FreshWinOperationFileSha256 -Path (Join-Path $export.OutputPath $file.Path)
            Assert-FreshWinEqual -Expected $file.Sha256 -Actual $actual
        }
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'Health summary gives attention precedence without inventing a score' -Category 'Diagnostics' -ScriptBlock {
    $diagnostics = [pscustomobject]@{
        IsLive = $false
        Components = [pscustomobject]@{
            Network = [pscustomobject]@{ Status = 'FixtureObserved'; RescueState = 'DriverMissing' }
            Security = [pscustomobject]@{ Status = 'FixtureObserved'; OverallHealth = 'Review'; DefenderHealth = 'Review'; FirewallHealth = 'Healthy' }
        }
    }
    $summary = Get-FreshWinHealthSummary -Diagnostics $diagnostics
    Assert-FreshWinEqual -Expected 'Attention' -Actual $summary.OverallHealth
    Assert-FreshWinEqual -Expected 1 -Actual $summary.AttentionCount
    Assert-FreshWinNull -Actual $summary.NumericalScore
}

Add-FreshWinTest -Name 'Pre-reset observations never retain BitLocker recovery secrets' -Category 'PreReset' -ScriptBlock {
    $observations = Get-FreshWinPreResetObservations `
        -BitLockerProvider { @([pscustomobject]@{
                    MountPoint = 'C:'; VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'On'; EncryptionPercentage = 100
                    RecoveryPassword = '111111-222222-333333'; KeyProtector = @([pscustomobject]@{ KeyProtectorType = 'RecoveryPassword'; RecoveryPassword = 'TOP-SECRET-KEY' })
                }) } `
        -StorageProvider { @([pscustomobject]@{ DriveLetter = 'C'; HealthStatus = 'Healthy'; Size = 100GB; SizeRemaining = 50GB }) } `
        -PowerProvider { [pscustomobject]@{ BatteryPresent = $true; MinimumCharge = 90; AcPowerReported = $true } } `
        -RestartProvider { $false }
    $json = ConvertTo-Json -InputObject $observations -Depth 20
    Assert-FreshWinFalse -Actual ($json -match '111111-222222|TOP-SECRET-KEY')
    Assert-FreshWinFalse -Actual $observations.BitLockerVolumes[0].RecoverySecretRead
    Assert-FreshWinContains -Collection $observations.BitLockerVolumes[0].KeyProtectorTypes -Expected 'RecoveryPassword'
}

Add-FreshWinTest -Name 'Pre-reset workflow remains a checklist and cannot execute reset' -Category 'PreReset' -ScriptBlock {
    $observations = [pscustomobject]@{ IsLive = $false; RestartPending = $false; Status = 'FixtureObserved'; BitLockerVolumes = @(); Storage = @(); Errors = @() }
    $blocked = New-FreshWinPreResetPlan -Observations $observations
    $blockedValidation = Test-FreshWinPreResetPlan -Plan $blocked
    Assert-FreshWinFalse -Actual $blockedValidation.Ready
    Assert-FreshWinTrue -Actual ($blockedValidation.BlockerCount -gt 0)
    Assert-FreshWinFalse -Actual $blocked.ResetExecutionAllowed
    Assert-FreshWinFalse -Actual $blocked.AutomaticExecution
    Assert-FreshWinNull -Actual $blocked.ResetCommand

    $ready = New-FreshWinPreResetPlan -Observations $observations -Confirmations (Get-FreshWinAdvancedTestConfirmations)
    $readyValidation = Test-FreshWinPreResetPlan -Plan $ready
    Assert-FreshWinTrue -Actual $readyValidation.Ready
    Assert-FreshWinEqual -Expected 'ReadyForManualResetReview' -Actual $ready.Status
    Assert-FreshWinFalse -Actual $ready.ResetExecutionAllowed
}

Add-FreshWinTest -Name 'DDU artifact planning requires hash official source and explicit signature evidence' -Category 'DduRecovery' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        $artifact = New-FreshWinAdvancedTestDriverArtifact -Folder $testRoot
        $valid = Test-FreshWinDduReplacementArtifact -Artifact $artifact -SignatureProvider { param($Path) [pscustomobject]@{ Valid = $true; Status = 'FixtureValid' } }
        Assert-FreshWinTrue -Actual $valid.Valid
        Assert-FreshWinEqual -Expected 'FixtureValid' -Actual $valid.Status
        Assert-FreshWinFalse -Actual $valid.WindowsSignatureVerified

        $artifact.SourceUri = 'https://example.invalid/driver.exe'
        $invalid = Test-FreshWinDduReplacementArtifact -Artifact $artifact -SignatureProvider { param($Path) [pscustomobject]@{ Valid = $true; Status = 'FixtureValid' } }
        Assert-FreshWinFalse -Actual $invalid.Valid
        Assert-FreshWinMatch -Actual ($invalid.Errors -join ' ') -Pattern 'official HTTPS source'
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'DDU recovery state machine represents cleanup reboot resume install and verification only' -Category 'DduRecovery' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        $artifact = New-FreshWinAdvancedTestDriverArtifact -Folder $testRoot
        $gpu = [pscustomobject]@{
            Name = 'NVIDIA Fixture GPU'; Vendor = 'NVIDIA'; PnpDeviceId = 'PCI\VEN_10DE&DEV_1234'
            AdapterCompatibility = 'NVIDIA'; DriverVersion = '1.0'; Status = 'Problem'
        }
        $signatureProvider = { param($Path) [pscustomobject]@{ Valid = $true; Status = 'FixtureValid' } }
        $plan = New-FreshWinDduRecoveryPlan -GPUs @($gpu) -AcknowledgeAdvancedRisk `
            -ReplacementArtifact $artifact -SignatureProvider $signatureProvider -ConfirmSafetyCheckpoint
        Assert-FreshWinEqual -Expected 'ReadyForManualCleanup' -Actual $plan.State
        Assert-FreshWinFalse -Actual $plan.AutomaticCleanup
        Assert-FreshWinFalse -Actual $plan.AutomaticDownload
        Assert-FreshWinFalse -Actual $plan.AutomaticExecution
        Assert-FreshWinNull -Actual $plan.CleanupExecutable
        Assert-FreshWinCount -Expected 0 -Actual $plan.CleanupArguments

        Assert-FreshWinThrows -ScriptBlock { Move-FreshWinDduRecoveryPlan -Plan $plan -Action RecordManualCleanupComplete } -Pattern 'explicit confirmation'
        $plan = Move-FreshWinDduRecoveryPlan -Plan $plan -Action RecordManualCleanupComplete -ManualConfirmation
        Assert-FreshWinEqual -Expected 'RebootRequired' -Actual $plan.State
        $plan = Move-FreshWinDduRecoveryPlan -Plan $plan -Action PrepareRebootResume -ManualConfirmation
        Assert-FreshWinEqual -Expected 'ResumeAfterReboot' -Actual $plan.State
        Assert-FreshWinThrows -ScriptBlock { Move-FreshWinDduRecoveryPlan -Plan $plan -Action ConfirmResumedAfterReboot -Observation ([pscustomobject]@{ RebootObserved = $false }) } -Pattern 'post-reboot observation'
        $plan = Move-FreshWinDduRecoveryPlan -Plan $plan -Action ConfirmResumedAfterReboot -Observation ([pscustomobject]@{ RebootObserved = $true })
        Assert-FreshWinEqual -Expected 'ReplacementInstallationRequired' -Actual $plan.State
        $plan = Move-FreshWinDduRecoveryPlan -Plan $plan -Action RecordManualReplacementInstalled -ManualConfirmation
        Assert-FreshWinEqual -Expected 'VerificationRequired' -Actual $plan.State

        $unverified = Move-FreshWinDduRecoveryPlan -Plan $plan -Action RecordVerification -Observation ([pscustomobject]@{ GpuPresent = $true; DriverVersion = ''; DeviceHealth = 'Problem'; IsLive = $false })
        Assert-FreshWinEqual -Expected 'VerificationRequired' -Actual $unverified.State
        $complete = Move-FreshWinDduRecoveryPlan -Plan $unverified -Action RecordVerification -VerificationProvider {
            param($Gpus) [pscustomobject]@{ GpuPresent = $true; DriverVersion = '2.0'; DeviceHealth = 'Healthy'; IsLive = $false }
        }
        Assert-FreshWinEqual -Expected 'Completed' -Actual $complete.State
        Assert-FreshWinEqual -Expected 'FixtureCompleted' -Actual $complete.Status
        Assert-FreshWinFalse -Actual $complete.Verification.IsLive
        Assert-FreshWinTrue -Actual (Test-FreshWinDduRecoveryPlan -Plan $complete).Valid

        $forgedLive = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $unverified -Depth 40)
        $forgedLive.IsLive = $true
        $forgedLive.ReplacementArtifact.WindowsSignatureVerified = $true
        $fixtureObservation = Move-FreshWinDduRecoveryPlan -Plan $forgedLive -Action RecordVerification `
            -Observation ([pscustomobject]@{ GpuPresent = $true; DriverVersion = '2.1'; DeviceHealth = 'Healthy'; IsLive = $true })
        Assert-FreshWinEqual -Expected 'FixtureCompleted' -Actual $fixtureObservation.Status
        Assert-FreshWinFalse -Actual $fixtureObservation.Verification.IsLive
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'DDU recovery checkpoint preserves only a validated non-executing plan' -Category 'DduRecovery' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        $gpu = [pscustomobject]@{ Name = 'AMD Fixture GPU'; Vendor = 'AMD'; PnpDeviceId = 'PCI\VEN_1002&DEV_1234'; AdapterCompatibility = 'AMD'; DriverVersion = '1.0'; Status = 'Problem' }
        $plan = New-FreshWinDduRecoveryPlan -GPUs @($gpu)
        $path = Join-Path $testRoot 'ddu-state.json'
        [void](Save-FreshWinDduRecoveryCheckpoint -Plan $plan -Path $path -Confirm:$false)
        $restored = Get-FreshWinDduRecoveryCheckpoint -Path $path
        Assert-FreshWinEqual -Expected $plan.PlanId -Actual $restored.PlanId
        Assert-FreshWinFalse -Actual $restored.AutomaticCleanup
        Assert-FreshWinNull -Actual $restored.CleanupExecutable
        Assert-FreshWinThrows -ScriptBlock { Save-FreshWinDduRecoveryCheckpoint -Plan $plan -Path (Join-Path $testRoot 'bad.txt') -Confirm:$false } -Pattern '\.json'
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}
