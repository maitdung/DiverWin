Set-StrictMode -Version Latest

function New-FreshWinTestDriverInventory {
    return @(
        [pscustomobject]@{
            Name           = 'Fixture Ethernet Controller'
            Category       = 'Ethernet'
            PnpClass       = 'Net'
            HardwareIds    = @('PCI\VEN_1234&DEV_5678', 'PCI\VEN_1234&DEV_5678&SUBSYS_0001')
            DriverVersion  = '1.2.3.4'
            DriverDate     = '2026-01-01'
            DriverProvider = 'Fixture Provider'
            InfName        = 'fixture.inf'
            IsSigned       = $true
        }
    )
}

function New-FreshWinTestDriverBackup {
    param([Parameter(Mandatory = $true)][string]$OutputRoot)

    $provider = {
        param($Context)
        $packageDirectory = Join-Path $Context.ArgumentList[2] 'fixture-package'
        [void][System.IO.Directory]::CreateDirectory($packageDirectory)
        [System.IO.File]::WriteAllText(
            (Join-Path $packageDirectory 'fixture.inf'),
            "[Version]`nSignature=`"`$Windows NT`"`nClass=Net`n"
        )
        return [pscustomobject]@{
            Succeeded      = $true
            ExitCode       = 0
            StandardOutput = 'One driver package exported.'
            StandardError  = ''
        }
    }

    return New-FreshWinDriverBackup -OutputRoot $OutputRoot `
        -HardwareReport ([pscustomobject]@{
                Manufacturer = 'Fixture Manufacturer'
                Model        = 'Fixture Model'
                SerialNumber = 'DO-NOT-EXPORT-THIS-SERIAL'
            }) `
        -DriverInventory (New-FreshWinTestDriverInventory) `
        -ProcessInvoker $provider -Confirm:$false
}

Add-FreshWinTest -Name 'Operations reject a filesystem root as an output target' -Category 'Security' -ScriptBlock {
    $filesystemRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetTempPath())
    Assert-FreshWinThrows -ScriptBlock { Assert-FreshWinSafeOutputRoot -Path $filesystemRoot } -Pattern 'filesystem root'
    Assert-FreshWinThrows -ScriptBlock { Assert-FreshWinSafeOutputRoot -Path 'relative-output' } -Pattern 'absolute local'
}

Add-FreshWinTest -Name 'Protected operation ACL policy rejects unprivileged writes and gates the final user grant' -Category 'Security' -ScriptBlock {
    $administratorsSid = 'S-1-5-32-544'
    $systemSid = 'S-1-5-18'
    $userSid = 'S-1-5-21-1000-1000-1000-1001'
    $fullControl = [int64][Security.AccessControl.FileSystemRights]::FullControl
    $modify = [int64][Security.AccessControl.FileSystemRights]::Modify
    $readOnly = [int64][Security.AccessControl.FileSystemRights]::ReadAndExecute
    $baseRules = @(
        [pscustomobject]@{ IdentitySid=$administratorsSid; AccessControlType='Allow'; Rights=$fullControl; IsInherited=$false },
        [pscustomobject]@{ IdentitySid=$systemSid; AccessControlType='Allow'; Rights=$fullControl; IsInherited=$false }
    )
    $restricted = [pscustomobject]@{
        OwnerSid=$administratorsSid; AreAccessRulesProtected=$true; Rules=$baseRules
    }
    Assert-FreshWinTrue (Test-FreshWinProtectedOperationAclDescriptor -Descriptor $restricted -RequireRestrictedAcl)

    $readableParent = [pscustomobject]@{
        OwnerSid=$administratorsSid; AreAccessRulesProtected=$true
        Rules=@($baseRules) + @([pscustomobject]@{ IdentitySid=$userSid; AccessControlType='Allow'; Rights=$readOnly; IsInherited=$false })
    }
    Assert-FreshWinTrue (Test-FreshWinProtectedOperationAclDescriptor -Descriptor $readableParent)
    Assert-FreshWinFalse (Test-FreshWinProtectedOperationAclDescriptor -Descriptor $readableParent -RequireRestrictedAcl)

    $creatableStableParent = [pscustomobject]@{
        OwnerSid=$administratorsSid; AreAccessRulesProtected=$false
        Rules=@($baseRules) + @(
            [pscustomobject]@{
                IdentitySid=$userSid; AccessControlType='Allow'
                Rights=[int64][Security.AccessControl.FileSystemRights]::CreateDirectories
                IsInherited=$true; AppliesToCurrent=$true
            },
            [pscustomobject]@{
                IdentitySid='S-1-3-0'; AccessControlType='Allow'; Rights=$fullControl
                IsInherited=$true; AppliesToCurrent=$false
            }
        )
    }
    Assert-FreshWinTrue (Test-FreshWinProtectedOperationAclDescriptor -Descriptor $creatableStableParent -RequireStableParent)
    $deletableStableParent = [pscustomobject]@{
        OwnerSid=$administratorsSid; AreAccessRulesProtected=$false
        Rules=@($baseRules) + @([pscustomobject]@{
                IdentitySid=$userSid; AccessControlType='Allow'
                Rights=[int64][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
                IsInherited=$true; AppliesToCurrent=$true
            })
    }
    Assert-FreshWinFalse (Test-FreshWinProtectedOperationAclDescriptor -Descriptor $deletableStableParent -RequireStableParent)

    $writableByUser = [pscustomobject]@{
        OwnerSid=$administratorsSid; AreAccessRulesProtected=$true
        Rules=@($baseRules) + @([pscustomobject]@{ IdentitySid=$userSid; AccessControlType='Allow'; Rights=$modify; IsInherited=$false })
    }
    Assert-FreshWinFalse (Test-FreshWinProtectedOperationAclDescriptor -Descriptor $writableByUser -RequireRestrictedAcl)
    Assert-FreshWinTrue (Test-FreshWinProtectedOperationAclDescriptor -Descriptor $writableByUser -RequireRestrictedAcl -AllowedModifySid $userSid)

    $permissionChangingUser = [pscustomobject]@{
        OwnerSid=$administratorsSid; AreAccessRulesProtected=$true
        Rules=@($baseRules) + @([pscustomobject]@{
                IdentitySid=$userSid; AccessControlType='Allow'
                Rights=([int64]($modify -bor [int64][Security.AccessControl.FileSystemRights]::ChangePermissions))
                IsInherited=$false
            })
    }
    Assert-FreshWinFalse (Test-FreshWinProtectedOperationAclDescriptor -Descriptor $permissionChangingUser -RequireRestrictedAcl -AllowedModifySid $userSid)
}

Add-FreshWinTest -Name 'Live driver backup source stages before PnPUtil and grants access only after manifest completion' -Category 'Security' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        $plannedRoot = Get-FreshWinProtectedDriverBackupRoot -CommonApplicationDataPath $testRoot
        Assert-FreshWinEqual (Join-Path (Join-Path $testRoot 'FreshWin') 'DriverBackups') $plannedRoot
        Assert-FreshWinFalse ([System.IO.Directory]::Exists((Join-Path $testRoot 'FreshWin')))

        $fixture = New-FreshWinTestDriverBackup -OutputRoot $testRoot
        Assert-FreshWinEqual ([System.IO.Path]::GetFullPath($testRoot)) $fixture.OutputRoot
        Assert-FreshWinEqual ([System.IO.Path]::GetFullPath($testRoot)) $fixture.RequestedOutputRoot
        Assert-FreshWinFalse $fixture.OutputRedirected
        Assert-FreshWinFalse $fixture.ProtectedStaging
        Assert-FreshWinFalse $fixture.UserAccessGranted

        $source = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/Operations/DriverBackup.ps1'))
        $stageIndex = $source.IndexOf('$root = Initialize-FreshWinProtectedDriverBackupRoot', [StringComparison]::Ordinal)
        $invokeIndex = $source.IndexOf('$processResult = Invoke-FreshWinProcess', [StringComparison]::Ordinal)
        $manifestIndex = $source.IndexOf('Write-FreshWinJsonFile -Path $manifestPath', [StringComparison]::Ordinal)
        $grantIndex = $source.IndexOf('$access = Complete-FreshWinDriverBackupOutputAccess', $manifestIndex, [StringComparison]::Ordinal)
        Assert-FreshWinTrue ($stageIndex -ge 0 -and $stageIndex -lt $invokeIndex)
        Assert-FreshWinTrue ($manifestIndex -gt $invokeIndex -and $grantIndex -gt $manifestIndex)
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'Operations privacy protection redacts device and network identifiers' -Category 'Security' -ScriptBlock {
    $protected = Protect-FreshWinPrivacyData -InputObject ([pscustomobject]@{
            SerialNumber = 'SERIAL-123'
            MacAddress   = '00-11-22-33-44-55'
            Note         = 'Contact 192.168.10.22 with token=super-secret'
            HardwareIds  = @('PCI\VEN_1234&DEV_5678')
        })
    Assert-FreshWinEqual -Expected '[REDACTED]' -Actual $protected.SerialNumber
    Assert-FreshWinEqual -Expected '[REDACTED]' -Actual $protected.MacAddress
    Assert-FreshWinMatch -Actual $protected.Note -Pattern '\[REDACTED_IP\]'
    Assert-FreshWinMatch -Actual $protected.Note -Pattern 'token=\[REDACTED\]'
    Assert-FreshWinEqual -Expected '[REDACTED]' -Actual $protected.HardwareIds

    $profile = Protect-FreshWinPrivacyData -InputObject ([pscustomobject]@{
            HardwareIds = @('PCI\VEN_1234&DEV_5678')
            SerialNumber = 'SERIAL-123'
        }) -PreserveHardwareIds
    Assert-FreshWinContains -Collection $profile.HardwareIds -Expected 'PCI\VEN_1234&DEV_5678'
    Assert-FreshWinEqual -Expected '[REDACTED]' -Actual $profile.SerialNumber
}

Add-FreshWinTest -Name 'Driver backup does not claim Windows execution without Windows or a provider' -Category 'Platform' -ScriptBlock {
    if (Test-FreshWinOperationsWindows) {
        Skip-FreshWinTest -Reason 'this assertion covers the explicit non-Windows unsupported contract'
    }
    $testRoot = New-FreshWinTestDirectory
    try {
        $result = New-FreshWinDriverBackup -OutputRoot $testRoot -Confirm:$false
        Assert-FreshWinEqual -Expected 'Unsupported' -Actual $result.Status
        Assert-FreshWinFalse -Actual $result.Succeeded
        Assert-FreshWinFalse -Actual $result.WindowsExecutionVerified
        Assert-FreshWinCount -Expected 0 -Actual @(Get-ChildItem -LiteralPath $testRoot -Force)
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'Driver backup fixture verifies exported INF and writes redacted reports' -Category 'Operations' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        $result = New-FreshWinTestDriverBackup -OutputRoot $testRoot
        Assert-FreshWinEqual -Expected 'FixtureVerified' -Actual $result.Status
        Assert-FreshWinTrue -Actual $result.Succeeded
        Assert-FreshWinFalse -Actual $result.IsLive
        Assert-FreshWinFalse -Actual $result.WindowsExecutionVerified
        Assert-FreshWinEqual -Expected 1 -Actual $result.ExportedInfCount
        Assert-FreshWinTrue -Actual ([System.IO.File]::Exists($result.ManifestPath))
        Assert-FreshWinTrue -Actual ([System.IO.File]::Exists($result.HardwareReportPath))

        $hardwareJson = [System.IO.File]::ReadAllText($result.HardwareReportPath)
        Assert-FreshWinMatch -Actual $hardwareJson -Pattern '\[REDACTED\]'
        Assert-FreshWinFalse -Actual ($hardwareJson -match 'DO-NOT-EXPORT-THIS-SERIAL')

        $inventory = Get-FreshWinDriverBackupInventory -BackupPath $result.BackupPath
        Assert-FreshWinEqual -Expected 'Verified' -Actual $inventory.Status
        Assert-FreshWinTrue -Actual $inventory.Valid
        Assert-FreshWinTrue -Actual $inventory.IsRestorable
        Assert-FreshWinCount -Expected 1 -Actual $inventory.Packages
        Assert-FreshWinTrue -Actual $inventory.Packages[0].Verified
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'Driver backup rejects provider success when no INF was exported' -Category 'Operations' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        $provider = { param($Context) [pscustomobject]@{ Succeeded = $true; ExitCode = 0 } }
        $result = New-FreshWinDriverBackup -OutputRoot $testRoot `
            -HardwareReport ([pscustomobject]@{ Model = 'Fixture' }) `
            -DriverInventory (New-FreshWinTestDriverInventory) `
            -ProcessInvoker $provider -Confirm:$false
        Assert-FreshWinEqual -Expected 'ExportVerificationFailed' -Actual $result.Status
        Assert-FreshWinFalse -Actual $result.Succeeded
        Assert-FreshWinFalse -Actual $result.WindowsExecutionVerified
        Assert-FreshWinEqual -Expected 0 -Actual $result.ExportedInfCount
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'Driver backup integrity scan detects tampering' -Category 'Security' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        $backup = New-FreshWinTestDriverBackup -OutputRoot $testRoot
        $inventory = Get-FreshWinDriverBackupInventory -BackupPath $backup.BackupPath
        [System.IO.File]::AppendAllText($inventory.Packages[0].FullPath, "`n; tampered")

        $tampered = Get-FreshWinDriverBackupInventory -BackupPath $backup.BackupPath
        Assert-FreshWinEqual -Expected 'Invalid' -Actual $tampered.Status
        Assert-FreshWinFalse -Actual $tampered.Valid
        Assert-FreshWinFalse -Actual $tampered.IsRestorable
        Assert-FreshWinMatch -Actual ($tampered.Errors -join ' ') -Pattern 'hash mismatch'

        $plan = New-FreshWinDriverRestorePlan -BackupInventory $inventory `
            -ProblemDevices @([pscustomobject]@{ Name = 'Fixture NIC'; HardwareIds = @('PCI\VEN_1234&DEV_5678') })
        Assert-FreshWinEqual -Expected 'Blocked' -Actual $plan.Status
        Assert-FreshWinFalse -Actual $plan.ExecutionAllowed
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'Unmanifested driver folders remain review-only' -Category 'Security' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        [System.IO.File]::WriteAllText((Join-Path $testRoot 'unknown.inf'), '[Version]')
        $defaultScan = Get-FreshWinDriverBackupInventory -BackupPath $testRoot
        Assert-FreshWinEqual -Expected 'Unmanifested' -Actual $defaultScan.Status
        Assert-FreshWinFalse -Actual $defaultScan.IsRestorable
        Assert-FreshWinCount -Expected 0 -Actual $defaultScan.Packages

        $reviewScan = Get-FreshWinDriverBackupInventory -BackupPath $testRoot -IncludeUnmanifested
        Assert-FreshWinFalse -Actual $reviewScan.IsRestorable
        Assert-FreshWinCount -Expected 1 -Actual $reviewScan.Packages
        Assert-FreshWinFalse -Actual $reviewScan.Packages[0].Verified
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'Driver restore output is a non-executing exact-ID review plan' -Category 'Operations' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        $backup = New-FreshWinTestDriverBackup -OutputRoot $testRoot
        $inventory = Get-FreshWinDriverBackupInventory -BackupPath $backup.BackupPath
        $problemDevices = @([pscustomobject]@{
                Name        = 'Fixture Ethernet Controller'
                HardwareIds = @('PCI\VEN_1234&DEV_5678')
            })
        $plan = New-FreshWinDriverRestorePlan -BackupInventory $inventory -ProblemDevices $problemDevices
        Assert-FreshWinEqual -Expected 'ReviewRequired' -Actual $plan.Status
        Assert-FreshWinTrue -Actual $plan.Ready
        Assert-FreshWinFalse -Actual $plan.ExecutionAllowed
        Assert-FreshWinCount -Expected 1 -Actual $plan.Items
        Assert-FreshWinEqual -Expected 'ExactHardwareId' -Actual $plan.Items[0].MatchType
        Assert-FreshWinFalse -Actual $plan.Items[0].AutomaticExecution
        Assert-FreshWinTrue -Actual $plan.Items[0].RequiresAdministrator
        Assert-FreshWinSetEqual -Expected @('/add-driver', $inventory.Packages[0].FullPath, '/install') -Actual $plan.Items[0].ArgumentList
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}

Add-FreshWinTest -Name 'Driver restore planning blocks invalid backups' -Category 'Security' -ScriptBlock {
    $invalidInventory = [pscustomobject]@{ IsRestorable = $false; Packages = @(); DriverProfile = $null }
    $plan = New-FreshWinDriverRestorePlan -BackupInventory $invalidInventory -ProblemDevices @()
    Assert-FreshWinEqual -Expected 'Blocked' -Actual $plan.Status
    Assert-FreshWinFalse -Actual $plan.Ready
    Assert-FreshWinFalse -Actual $plan.ExecutionAllowed
    Assert-FreshWinCount -Expected 0 -Actual $plan.Items
}

Add-FreshWinTest -Name 'Driver restore planning rejects a lone INF without identity evidence' -Category 'Security' -ScriptBlock {
    $testRoot = New-FreshWinTestDirectory
    try {
        $provider = {
            param($Context)
            $packageDirectory = Join-Path $Context.ArgumentList[2] 'unrelated-package'
            [void][System.IO.Directory]::CreateDirectory($packageDirectory)
            [System.IO.File]::WriteAllText((Join-Path $packageDirectory 'unrelated.inf'), "[Version]`nClass=Net`n[Models]`n%Other%=Install,PCI\VEN_9999&DEV_0001")
            [pscustomobject]@{ Succeeded = $true; ExitCode = 0 }
        }
        $profile = New-FreshWinTestDriverInventory
        $profile[0].InfName = 'published-oem-name.inf'
        $backup = New-FreshWinDriverBackup -OutputRoot $testRoot `
            -HardwareReport ([pscustomobject]@{ Model = 'Fixture' }) -DriverInventory $profile `
            -ProcessInvoker $provider -Confirm:$false
        $plan = New-FreshWinDriverRestorePlan -BackupPath $backup.BackupPath `
            -ProblemDevices @([pscustomobject]@{ Name = 'Fixture NIC'; HardwareIds = @('PCI\VEN_1234&DEV_5678') })
        Assert-FreshWinEqual -Expected 'NoMatch' -Actual $plan.Status
        Assert-FreshWinFalse -Actual $plan.Ready
        Assert-FreshWinCount -Expected 0 -Actual $plan.Items
    }
    finally { Remove-FreshWinTestDirectory -Path $testRoot }
}
