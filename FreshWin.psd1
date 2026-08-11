@{
    RootModule           = 'FreshWin.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'd148d85e-8bc9-4e73-a983-71da14b22190'
    Author               = 'FreshWin contributors'
    CompanyName          = 'Community'
    Copyright            = 'Copyright (c) FreshWin contributors'
    Description          = 'Safety-first Windows 10/11 readiness, inventory, recommendation, and package planning toolkit.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Get-FreshWinVersion', 'Get-FreshWinSupportedLocale', 'Get-FreshWinPaths',
        'Initialize-FreshWinEnvironment', 'New-FreshWinConfig', 'Get-FreshWinConfig',
        'Save-FreshWinConfig', 'Set-FreshWinConfigLocale', 'Set-FreshWinConfigCompactMode', 'Initialize-FreshWinLocalization',
        'Get-FreshWinCacheEntry', 'Set-FreshWinCacheEntry', 'Remove-FreshWinCacheEntry',
        'Set-FreshWinLocale', 'Get-FreshWinString', 'Initialize-FreshWinLogger',
        'Get-FreshWinLogPath', 'Get-FreshWinLogHistory', 'Write-FreshWinLog', 'Protect-FreshWinSensitiveText',
        'Test-FreshWinUpdateMetadata', 'Get-FreshWinUpdateStatus', 'Save-FreshWinUpdatePackage', 'Invoke-FreshWinCoreUpdate',
        'Invoke-FreshWinProcess', 'Test-FreshWinPackageManifest',
        'Import-FreshWinPackageManifest', 'Import-FreshWinPackageCatalog',
        'Get-FreshWinPackage', 'Find-FreshWinPackage', 'Test-FreshWinCatalogIntegrity',
        'Test-FreshWinLocalizationResources', 'Test-FreshWinProfiles', 'Test-FreshWinProject',
        'ConvertFrom-FreshWinAssistantCommand', 'Register-FreshWinAssistantProvider',
        'Get-FreshWinAssistantProvider', 'Invoke-FreshWinAssistantProvider',
        'Initialize-FreshWinRuntime',
        'Get-FreshWinPlatformName', 'Test-FreshWinWindows', 'Test-FreshWinAdministrator',
        'Get-FreshWinHardwareInfo', 'Get-FreshWinNetworkState', 'Get-FreshWinSystemInfo',
        'Get-FreshWinActivationStatus', 'Get-FreshWinWindows11Readiness',
        'Get-FreshWinSoftwareInventory', 'Get-FreshWinSoftwareInventorySnapshot',
        'Get-FreshWinWindowsUpdateState', 'Get-FreshWinDriverInventory',
        'Get-FreshWinDriverSummary', 'Get-FreshWinMissingDrivers',
        'Get-FreshWinGpuDriverRecommendation', 'Get-FreshWinDduWorkflow',
        'New-FreshWinDriverBackup', 'Get-FreshWinDriverBackupInventory',
        'New-FreshWinDriverRestorePlan',
        'Find-FreshWinLocalNetworkDriver', 'Get-FreshWinNetworkRescueState',
        'New-FreshWinNetworkRescuePlan', 'Invoke-FreshWinNetworkRescueRetry',
        'Get-FreshWinOfflineNetworkDiagnostics', 'Get-FreshWinSecurityStatus',
        'Get-FreshWinDiagnostics', 'Get-FreshWinHealthSummary',
        'Export-FreshWinDiagnostics', 'Get-FreshWinPreResetObservations',
        'New-FreshWinPreResetPlan', 'Set-FreshWinPreResetChecklistItem',
        'Test-FreshWinPreResetPlan', 'Test-FreshWinDduReplacementArtifact',
        'New-FreshWinDduRecoveryPlan', 'Move-FreshWinDduRecoveryPlan',
        'Test-FreshWinDduRecoveryPlan', 'Save-FreshWinDduRecoveryCheckpoint',
        'Get-FreshWinDduRecoveryCheckpoint',
        'Get-FreshWinPackageCompatibility', 'Get-FreshWinPackageDetection',
        'Get-FreshWinCatalogState', 'Resolve-FreshWinPackageSource',
        'Invoke-FreshWinPackageInstall', 'Test-FreshWinPackageVerification',
        'Import-FreshWinProfiles', 'Get-FreshWinProfile', 'Export-FreshWinProfile',
        'Import-FreshWinUserProfile', 'Get-FreshWinRecommendations',
        'Get-FreshWinMissingRecommendations', 'New-FreshWinInstallPlan',
        'Test-FreshWinInstallPlan', 'Save-FreshWinInstallPlan',
        'Get-FreshWinExecutionSummary', 'Invoke-FreshWinExecutionPlan',
        'Get-FreshWinDefaultCheckpointPath', 'Save-FreshWinExecutionCheckpoint',
        'Get-FreshWinExecutionCheckpoint', 'Restore-FreshWinPlanFromCheckpoint',
        'Remove-FreshWinExecutionCheckpoint', 'Register-FreshWinResume',
        'Unregister-FreshWinResume', 'Get-FreshWinPlanElevationRequirement',
        'Test-FreshWinElevationSourceTrust',
        'Invoke-FreshWinElevatedResume', 'ConvertFrom-FreshWinSelection',
        'ConvertFrom-FreshWinCommandLine', 'Format-FreshWinTerminalPage',
        'Start-FreshWinTerminalSession', 'Invoke-FreshWinCli', 'Start-FreshWinInteractive'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('Windows', 'WinGet', 'Inventory', 'Provisioning')
        }
    }
}
