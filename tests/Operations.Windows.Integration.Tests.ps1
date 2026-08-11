Set-StrictMode -Version Latest

Add-FreshWinTest -Name 'Live network rescue observation remains query-only' -Category 'WindowsLive' -Platform 'WindowsLive' -ScriptBlock {
    $state = Get-FreshWinNetworkRescueState
    Assert-FreshWinTrue -Actual $state.IsLive
    $plan = New-FreshWinNetworkRescuePlan -State $state
    Assert-FreshWinFalse -Actual $plan.AutomaticExecution
    Assert-FreshWinFalse -Actual $plan.AllowsDownload
}

Add-FreshWinTest -Name 'Live Security Center observation never changes protection settings' -Category 'WindowsLive' -Platform 'WindowsLive' -ScriptBlock {
    $status = Get-FreshWinSecurityStatus
    Assert-FreshWinTrue -Actual $status.IsLive
    Assert-FreshWinFalse -Actual $status.MutationPerformed
    Assert-FreshWinContains -Collection @('Healthy', 'Attention', 'Review') -Expected $status.OverallHealth
    foreach ($product in @($status.AntivirusProducts) + @($status.FirewallProducts)) {
        Assert-FreshWinEqual -Expected 'NotInterpreted' -Actual $product.StateInterpretation
    }
}

Add-FreshWinTest -Name 'Live pre-reset observations do not expose recovery material' -Category 'WindowsLive' -Platform 'WindowsLive' -ScriptBlock {
    $observations = Get-FreshWinPreResetObservations
    Assert-FreshWinTrue -Actual $observations.IsLive
    Assert-FreshWinFalse -Actual $observations.MutationPerformed
    $json = ConvertTo-Json -InputObject $observations -Depth 20
    Assert-FreshWinFalse -Actual ($json -match '(?i)RecoveryPassword\s*[:=]')
    foreach ($volume in @($observations.BitLockerVolumes)) {
        Assert-FreshWinFalse -Actual $volume.RecoverySecretRead
        Assert-FreshWinSetEqual -Expected @('MountPoint', 'VolumeStatus', 'ProtectionStatus', 'EncryptionPercentage', 'KeyProtectorTypes', 'RecoverySecretRead') -Actual @($volume.PSObject.Properties.Name)
    }
}

Add-FreshWinTest -Name 'Live offline network diagnostics are read-only and privacy-redacted' -Category 'WindowsLive' -Platform 'WindowsLive' -ScriptBlock {
    $diagnostics = Get-FreshWinOfflineNetworkDiagnostics
    Assert-FreshWinTrue -Actual $diagnostics.IsLive
    Assert-FreshWinFalse -Actual $diagnostics.MutationPerformed
    $json = ConvertTo-Json -InputObject $diagnostics.Data -Depth 30
    Assert-FreshWinFalse -Actual ($json -match '(?i)\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b')
    Assert-FreshWinFalse -Actual ($json -match '(?<![0-9])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![0-9])')
}

Add-FreshWinTest -Name 'Live diagnostics aggregate and export remain query-only and redacted' -Category 'WindowsLive' -Platform 'WindowsLive' -ScriptBlock {
    $snapshot = Get-FreshWinDiagnostics
    Assert-FreshWinTrue -Actual $snapshot.IsLive
    Assert-FreshWinFalse -Actual $snapshot.MutationPerformed
    $summary = Get-FreshWinHealthSummary -Diagnostics $snapshot
    Assert-FreshWinTrue -Actual $summary.IsLive
    Assert-FreshWinNull -Actual $summary.NumericalScore

    $testRoot = New-FreshWinTestDirectory
    try {
        $export = Export-FreshWinDiagnostics -OutputRoot $testRoot -Diagnostics $snapshot -Confirm:$false
        Assert-FreshWinTrue -Actual $export.Succeeded
        Assert-FreshWinTrue -Actual $export.Redacted
        $manifest = Read-FreshWinJsonFile -Path $export.ManifestPath
        Assert-FreshWinCount -Expected 2 -Actual $manifest.Files
        foreach ($file in $manifest.Files) {
            Assert-FreshWinEqual -Expected $file.Sha256 -Actual (Get-FreshWinOperationFileSha256 -Path (Join-Path $export.OutputPath $file.Path))
        }
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'Live DDU planning detects GPUs but cannot execute cleanup' -Category 'WindowsLive' -Platform 'WindowsLive' -ScriptBlock {
    $plan = New-FreshWinDduRecoveryPlan
    Assert-FreshWinTrue -Actual $plan.IsLive
    Assert-FreshWinFalse -Actual $plan.AutomaticCleanup
    Assert-FreshWinFalse -Actual $plan.AutomaticDownload
    Assert-FreshWinFalse -Actual $plan.AutomaticExecution
    Assert-FreshWinNull -Actual $plan.CleanupExecutable
    Assert-FreshWinCount -Expected 0 -Actual $plan.CleanupArguments
}
