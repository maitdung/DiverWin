Set-StrictMode -Version Latest

Add-FreshWinTest -Name 'Read-only bootstrap composes configuration localization and catalog without creating data paths' -Category 'Core' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $appRoot = Join-Path $directory 'not-created'
        $paths = [pscustomobject]@{
            AppRoot=$appRoot; ConfigPath=(Join-Path $appRoot 'config.json'); Logs=(Join-Path $appRoot 'logs')
            Cache=(Join-Path $appRoot 'cache'); State=(Join-Path $appRoot 'state'); Updates=(Join-Path $appRoot 'updates')
            TemporaryRoot=(Join-Path $directory 'temporary-not-created')
        }
        $catalog = Import-FreshWinPackageCatalog
        $runtime = Initialize-FreshWinRuntime -ProjectRoot $script:FreshWinTestContext.ProjectRoot -Config (New-FreshWinConfig -Locale vi-VN) -Paths $paths -Catalog $catalog -ReadOnly
        Assert-FreshWinTrue $runtime.CatalogValid
        Assert-FreshWinEqual 'vi-VN' $runtime.Locale
        Assert-FreshWinEqual (Get-FreshWinPlatformName) $runtime.Platform
        Assert-FreshWinFalse ([IO.Directory]::Exists($appRoot))
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Cache envelopes round-trip and reject tampered identity' -Category 'Core' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        [void](Set-FreshWinCacheEntry -Key sample -Value ([pscustomobject]@{ Answer = 42 }) -CacheDirectory $directory)
        $value = Get-FreshWinCacheEntry -Key sample -CacheDirectory $directory
        Assert-FreshWinEqual 42 $value.Answer
        $path = Join-Path $directory 'sample.json'
        $entry = Read-FreshWinJsonFile $path
        $entry.key = 'different'
        [void](Write-FreshWinJsonFile -Path $path -Value $entry -Atomic)
        Assert-FreshWinThrows { Get-FreshWinCacheEntry -Key sample -CacheDirectory $directory } 'invalid'
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Self-update metadata is allowlisted and staged bytes are never executed' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes('FreshWin update fixture')
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
        $config = New-FreshWinConfig
        $config.updates.allowedHosts = @('updates.example.test')
        $config.updates.metadataUri = 'https://updates.example.test/metadata.json'
        $metadata = [pscustomobject]@{
            schemaVersion = 1; channel = 'stable'; version = '0.2.0'
            publishedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            packageUri = 'https://updates.example.test/FreshWin.zip'; sha256 = $hash
            minimumPowerShellVersion = '5.1'
        }
        $status = Get-FreshWinUpdateStatus -Config $config -Metadata $metadata
        Assert-FreshWinEqual 'Available' $status.Status
        Assert-FreshWinFalse $status.MutationPerformed
        $destination = Join-Path $directory 'FreshWin.zip'
        $staged = Save-FreshWinUpdatePackage -UpdateStatus $status -DestinationPath $destination -PackageProvider { param($uri) [Text.Encoding]::UTF8.GetBytes('FreshWin update fixture') } -Confirm:$false
        Assert-FreshWinEqual 'Staged' $staged.Status
        Assert-FreshWinFalse $staged.Executed
        Assert-FreshWinFalse $staged.ApplyAutomatically
        Assert-FreshWinTrue ([IO.File]::Exists($destination))
        Assert-FreshWinTrue ([IO.File]::Exists($staged.MetadataPath))

        $providerState = [pscustomobject]@{ Calls = 0 }
        $reused = Save-FreshWinUpdatePackage -UpdateStatus $status -DestinationPath $destination -PackageProvider {
            param($uri)
            $providerState.Calls++
            throw 'A verified staged archive must be reused before contacting the package provider.'
        } -Confirm:$false
        Assert-FreshWinEqual 'Reused' $reused.Status
        Assert-FreshWinTrue $reused.Reused
        Assert-FreshWinFalse $reused.MutationPerformed
        Assert-FreshWinEqual 0 $providerState.Calls

        $metadata.packageUri = 'https://untrusted.example/FreshWin.zip'
        $rejected = Get-FreshWinUpdateStatus -Config $config -Metadata $metadata
        Assert-FreshWinEqual 'Invalid' $rejected.Status
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Self-update reuse rejects a sidecar whose metadata identity was altered' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes('FreshWin reusable update fixture')
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $config = New-FreshWinConfig
        $config.updates.allowedHosts = @('updates.example.test')
        $metadata = [pscustomobject]@{
            schemaVersion=1; channel='stable'; version='0.2.0'; publishedAtUtc='2026-01-01T00:00:00.0000000+00:00'
            packageUri='https://updates.example.test/FreshWin.zip'; sha256=$hash; minimumPowerShellVersion='5.1'
        }
        $status = Get-FreshWinUpdateStatus -Config $config -Metadata $metadata
        $destination = Join-Path $directory 'FreshWin.zip'
        $staged = Save-FreshWinUpdatePackage -UpdateStatus $status -DestinationPath $destination -PackageProvider { param($uri) $bytes } -Confirm:$false
        $sidecar = Read-FreshWinJsonFile -Path $staged.MetadataPath
        $sidecar.version = '9.9.9'
        [void](Write-FreshWinJsonFile -Path $staged.MetadataPath -Value $sidecar -Atomic)
        Assert-FreshWinThrows -ScriptBlock {
            Save-FreshWinUpdatePackage -UpdateStatus $status -DestinationPath $destination -PackageProvider { throw 'must not download' } -Confirm:$false
        } -Pattern 'cannot be safely reused.*version'

        $sidecar.version = '0.2.0'
        [void](Write-FreshWinJsonFile -Path $staged.MetadataPath -Value $sidecar -Atomic)
        $tamperedBytes = [byte[]]$bytes.Clone()
        $tamperedBytes[0] = $tamperedBytes[0] -bxor 1
        [IO.File]::WriteAllBytes($destination, $tamperedBytes)
        Assert-FreshWinThrows -ScriptBlock {
            Save-FreshWinUpdatePackage -UpdateStatus $status -DestinationPath $destination -PackageProvider { throw 'must not download' } -Confirm:$false
        } -Pattern 'cannot be safely reused.*SHA-256'
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Fallback manifest validation rejects broad registry prefixes and unsafe detection paths' -Category 'Security' -ScriptBlock {
    $manifestPath = Join-Path $script:FreshWinTestContext.ProjectRoot 'catalog/apps/vcpp-x64.json'
    $manifest = Read-FreshWinJsonFile -Path $manifestPath
    $manifest.detection.registryDisplayNamePrefixes = @('')
    $manifest.detection.knownPaths = @('%ProgramFiles%\Vendor\*\tool.exe')
    $validation = Test-FreshWinPackageManifest -Manifest $manifest
    Assert-FreshWinFalse $validation.IsValid
    Assert-FreshWinMatch ($validation.Errors -join ' ') 'registryDisplayNamePrefixes'
    Assert-FreshWinMatch ($validation.Errors -join ' ') 'knownPaths'

    $manifest = Read-FreshWinJsonFile -Path $manifestPath
    $manifest.source = $null
    $manifest.compatibility.minimumBuild = $null
    $validation = Test-FreshWinPackageManifest -Manifest $manifest
    Assert-FreshWinFalse $validation.IsValid
    Assert-FreshWinMatch ($validation.Errors -join ' ') "Property 'source' must be a non-null object"
    Assert-FreshWinMatch ($validation.Errors -join ' ') 'minimumBuild'

    $manifest = Read-FreshWinJsonFile -Path $manifestPath
    $manifest.install.scope = 'portable-user-machine'
    $validation = Test-FreshWinPackageManifest -Manifest $manifest
    Assert-FreshWinFalse $validation.IsValid
    Assert-FreshWinMatch ($validation.Errors -join ' ') 'install.scope'
}

Add-FreshWinTest -Name 'Protected checkpoint path supports an isolated ACL-provider fixture' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $script:FreshWinProtectedDirectoryObserved = $null
        $script:FreshWinProtectedReaderObserved = $null
        $readerSid = 'S-1-5-21-1000-1001-1002-1003'
        $path = Get-FreshWinProtectedCheckpointPath -DataRoot $directory -ReaderSid $readerSid -DirectoryProtector {
            param($stateDirectory, $requestedReaderSid)
            $script:FreshWinProtectedDirectoryObserved = $stateDirectory
            $script:FreshWinProtectedReaderObserved = $requestedReaderSid
            return Test-Path -LiteralPath $stateDirectory -PathType Container
        }
        Assert-FreshWinEqual (Join-Path (Join-Path $directory 'state') 'execution-checkpoint.json') $path
        Assert-FreshWinEqual (Join-Path $directory 'state') $script:FreshWinProtectedDirectoryObserved
        Assert-FreshWinEqual $readerSid $script:FreshWinProtectedReaderObserved
        Assert-FreshWinThrows { Get-FreshWinProtectedCheckpointPath -DataRoot $directory -ReaderSid 'not-a-sid' -DirectoryProtector { $true } } 'reader SID'
    }
    finally {
        Remove-Variable FreshWinProtectedDirectoryObserved -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable FreshWinProtectedReaderObserved -Scope Script -ErrorAction SilentlyContinue
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'Execution checkpoint round-trips ISO timestamps and enforces its content hash' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $package = New-FreshWinTestPackage
        $plan = New-FreshWinTestExecutionPlan -Package $package -DryRun
        $path = Join-Path $directory 'checkpoint.json'
        $write = Save-FreshWinExecutionCheckpoint -Plan $plan -Path $path -PassThruMetadata
        $hash = Get-FreshWinFileSha256 -Path $path
        Assert-FreshWinEqual $hash $write.Sha256
        Assert-FreshWinEqual ([IO.Path]::GetFullPath($path)) $write.Path
        $checkpoint = Get-FreshWinExecutionCheckpoint -Path $path -ExpectedSha256 $hash
        Assert-FreshWinEqual $plan.Id $checkpoint.planId
        Assert-FreshWinEqual 'sample' $checkpoint.items[0].packageId
        [IO.File]::AppendAllText($path, ' ')
        Assert-FreshWinThrows { Get-FreshWinExecutionCheckpoint -Path $path -ExpectedSha256 $hash } 'integrity'
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Resume and elevation resolve PowerShell below the protected Windows system directory' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $relativeExecutable = 'WindowsPowerShell\v1.0\powershell.exe'
        $candidate = Join-Path $directory $relativeExecutable
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $candidate))
        [IO.File]::WriteAllText($candidate, 'fixture')
        $resolved = Get-FreshWinTrustedPowerShellPath -SystemDirectory $directory
        Assert-FreshWinEqual ([IO.Path]::GetFullPath($candidate)) $resolved
        Assert-FreshWinThrows { Get-FreshWinTrustedPowerShellPath -SystemDirectory (Join-Path $directory 'missing') } 'not found'
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Top-level privileged mutation requires a protected FreshWin source' -Category 'Security' -ScriptBlock {
    $entrySource = [IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'FreshWin.ps1'))
    $preImportSource = $entrySource.Substring(0, $entrySource.IndexOf('Import-Module'))
    Assert-FreshWinMatch $preImportSource '\$bootstrapAdministrator'
    Assert-FreshWinMatch $preImportSource 'SpecialFolder\]::ProgramFiles'
    Assert-FreshWinMatch $preImportSource 'untrusted writable ACL'
    Assert-FreshWinMatch $preImportSource '\$specificWriteRights\s*=\s*852310L'
    Assert-FreshWinMatch $preImportSource 'PropagationFlags\]::InheritOnly'
    Assert-FreshWinFalse ($preImportSource -match 'FileSystemRights\]::FullControl\s+-bor') `
        -Because 'Composite read-containing rights must never be used as a writable membership mask.'
    Assert-FreshWinMatch $entrySource 'Test-FreshWinElevationSourceTrust\s+-EntryScriptPath\s+\$PSCommandPath'
    Assert-FreshWinMatch $entrySource 'protected Program Files installation'
}

Add-FreshWinTest -Name 'Top-level trust bootstrap supports Desktop and Core ACL APIs without command discovery' -Category 'Security' -ScriptBlock {
    $entrySource = [IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'FreshWin.ps1'))
    $importOffset = $entrySource.IndexOf('Import-Module')
    Assert-FreshWinTrue ($importOffset -gt 0) 'The entrypoint must contain its module-import boundary.'
    $preImportSource = $entrySource.Substring(0, $importOffset)

    Assert-FreshWinMatch $preImportSource '\[IO\.Directory\]::GetAccessControl\(\$path\)'
    Assert-FreshWinMatch $preImportSource '\[IO\.File\]::GetAccessControl\(\$path\)'
    Assert-FreshWinMatch $preImportSource '\[IO\.FileSystemAclExtensions\]::GetAccessControl'
    Assert-FreshWinMatch $preImportSource "GetMethod\('GetAccessControl',\s*\[type\[\]\]"

    $tokens = $null
    $parseErrors = $null
    $entryAst = [Management.Automation.Language.Parser]::ParseInput(
        $entrySource,
        [ref]$tokens,
        [ref]$parseErrors)
    Assert-FreshWinCount 0 @($parseErrors) 'The entrypoint must parse without syntax errors.'
    $preImportCommands = @($entryAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                    $node.Extent.StartOffset -lt $importOffset
            }, $true))
    Assert-FreshWinCount 1 $preImportCommands 'No discoverable command may run before the trusted module import except the engine-provided Set-StrictMode cmdlet.'
    Assert-FreshWinEqual 'Set-StrictMode' $preImportCommands[0].GetCommandName()
}

Add-FreshWinTest -Name 'Standard inherited Program Files ACL grants read and execute without untrusted write' -Category 'Security' -ScriptBlock {
    $trustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    $system = 'S-1-5-18'
    $administrators = 'S-1-5-32-544'
    $users = 'S-1-5-32-545'
    $creatorOwner = 'S-1-3-0'
    $allApplicationPackages = 'S-1-15-2-1'
    $allRestrictedApplicationPackages = 'S-1-15-2-2'
    $none = [Security.AccessControl.PropagationFlags]::None
    $inheritOnly = [Security.AccessControl.PropagationFlags]::InheritOnly
    $directoryInheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $rules = @(
        [pscustomobject]@{ IdentitySid=$trustedInstaller; AccessControlType='Allow'; FileSystemRights=2032127L; InheritanceFlags='None'; PropagationFlags=$none; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$trustedInstaller; AccessControlType='Allow'; FileSystemRights=268435456L; InheritanceFlags='ContainerInherit'; PropagationFlags=$inheritOnly; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$system; AccessControlType='Allow'; FileSystemRights=2032127L; InheritanceFlags='None'; PropagationFlags=$none; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$system; AccessControlType='Allow'; FileSystemRights=268435456L; InheritanceFlags=$directoryInheritance; PropagationFlags=$inheritOnly; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$administrators; AccessControlType='Allow'; FileSystemRights=2032127L; InheritanceFlags='None'; PropagationFlags=$none; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$administrators; AccessControlType='Allow'; FileSystemRights=268435456L; InheritanceFlags=$directoryInheritance; PropagationFlags=$inheritOnly; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$users; AccessControlType='Allow'; FileSystemRights=1179817L; InheritanceFlags='None'; PropagationFlags=$none; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$users; AccessControlType='Allow'; FileSystemRights=-1610612736L; InheritanceFlags=$directoryInheritance; PropagationFlags=$inheritOnly; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$creatorOwner; AccessControlType='Allow'; FileSystemRights=268435456L; InheritanceFlags=$directoryInheritance; PropagationFlags=$inheritOnly; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$allApplicationPackages; AccessControlType='Allow'; FileSystemRights=1179817L; InheritanceFlags='None'; PropagationFlags=$none; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$allApplicationPackages; AccessControlType='Allow'; FileSystemRights=-1610612736L; InheritanceFlags=$directoryInheritance; PropagationFlags=$inheritOnly; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$allRestrictedApplicationPackages; AccessControlType='Allow'; FileSystemRights=1179817L; InheritanceFlags='None'; PropagationFlags=$none; IsInherited=$true },
        [pscustomobject]@{ IdentitySid=$allRestrictedApplicationPackages; AccessControlType='Allow'; FileSystemRights=-1610612736L; InheritanceFlags=$directoryInheritance; PropagationFlags=$inheritOnly; IsInherited=$true }
    )

    $result = Test-FreshWinProtectedSourceAclDescriptor -OwnerSid $administrators -Rules $rules -Path 'C:\Program Files\FreshWin'
    Assert-FreshWinTrue $result.Trusted $result.Reason
    Assert-FreshWinFalse (Test-FreshWinAclRuleGrantsEffectiveWrite -Rule $rules[6]) -Because 'ReadAndExecute plus Synchronize is not writable.'
    Assert-FreshWinFalse (Test-FreshWinAclRuleGrantsEffectiveWrite -Rule $rules[7]) -Because 'Signed GENERIC_READ plus GENERIC_EXECUTE is not writable.'
    Assert-FreshWinFalse (Test-FreshWinAclRuleGrantsEffectiveWrite -Rule $rules[8]) -Because 'CREATOR OWNER GENERIC_ALL is inherit-only and grants nothing on this directory.'
}

Add-FreshWinTest -Name 'Protected source ACL rejects every effective untrusted mutation right' -Category 'Security' -ScriptBlock {
    $administrators = 'S-1-5-32-544'
    $cases = @(
        [pscustomobject]@{ Sid='S-1-5-32-545'; Rights=[int64][Security.AccessControl.FileSystemRights]::Write; Name='BUILTIN Users Write' },
        [pscustomobject]@{ Sid='S-1-5-32-545'; Rights=[int64][Security.AccessControl.FileSystemRights]::Modify; Name='BUILTIN Users Modify' },
        [pscustomobject]@{ Sid='S-1-1-0'; Rights=[int64][Security.AccessControl.FileSystemRights]::Write; Name='Everyone Write' },
        [pscustomobject]@{ Sid='S-1-1-0'; Rights=[int64][Security.AccessControl.FileSystemRights]::Modify; Name='Everyone Modify' },
        [pscustomobject]@{ Sid='S-1-1-0'; Rights=[int64][Security.AccessControl.FileSystemRights]::FullControl; Name='Everyone FullControl' },
        [pscustomobject]@{ Sid='S-1-5-11'; Rights=[int64][Security.AccessControl.FileSystemRights]::Write; Name='Authenticated Users Write' },
        [pscustomobject]@{ Sid='S-1-5-11'; Rights=[int64][Security.AccessControl.FileSystemRights]::Modify; Name='Authenticated Users Modify' },
        [pscustomobject]@{ Sid='S-1-5-21-1000-1000-1000-1001'; Rights=[int64][Security.AccessControl.FileSystemRights]::Write; Name='current user Write' },
        [pscustomobject]@{ Sid='S-1-5-21-2000-2000-2000-1001'; Rights=[int64][Security.AccessControl.FileSystemRights]::Delete; Name='other user Delete' },
        [pscustomobject]@{ Sid='S-1-5-21-2000-2000-2000-1002'; Rights=[int64][Security.AccessControl.FileSystemRights]::ChangePermissions; Name='other user ChangePermissions' },
        [pscustomobject]@{ Sid='S-1-5-21-2000-2000-2000-1003'; Rights=[int64][Security.AccessControl.FileSystemRights]::TakeOwnership; Name='other user TakeOwnership' },
        [pscustomobject]@{ Sid='S-1-5-21-2000-2000-2000-1004'; Rights=1073741824L; Name='other user GENERIC_WRITE' },
        [pscustomobject]@{ Sid='S-1-5-21-2000-2000-2000-1005'; Rights=268435456L; Name='other user effective GENERIC_ALL' }
    )
    foreach ($case in $cases) {
        $rule = [pscustomobject]@{ IdentitySid=$case.Sid; AccessControlType='Allow'; FileSystemRights=$case.Rights; InheritanceFlags='None'; PropagationFlags='None'; IsInherited=$true }
        $result = Test-FreshWinProtectedSourceAclDescriptor -OwnerSid $administrators -Rules @($rule) -Path 'C:\Program Files\FreshWin'
        Assert-FreshWinFalse $result.Trusted -Because ("The ACL must reject {0}." -f $case.Name)
        Assert-FreshWinEqual $case.Sid $result.OffendingSid
    }

    $inheritedWrite = [pscustomobject]@{ IdentitySid='S-1-5-32-545'; AccessControlType='Allow'; FileSystemRights=278L; InheritanceFlags='ContainerInherit, ObjectInherit'; PropagationFlags='None'; IsInherited=$true }
    Assert-FreshWinFalse (Test-FreshWinProtectedSourceAclDescriptor -OwnerSid $administrators -Rules @($inheritedWrite)).Trusted `
        -Because 'Inherited writable ACEs still apply unless they are explicitly inherit-only.'
}

Add-FreshWinTest -Name 'Pre-import startup failure always emits the complete fallback diagnostic' -Category 'Security' -Platform Windows -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $entry = Join-Path $directory 'FreshWin.ps1'
        [IO.File]::Copy((Join-Path $script:FreshWinTestContext.ProjectRoot 'FreshWin.ps1'), $entry)
        $windowsPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        if (-not [IO.File]::Exists($windowsPowerShell)) { Skip-FreshWinTest 'Windows PowerShell 5.1 is unavailable' }
        $process = Invoke-FreshWinProcess -FilePath $windowsPowerShell -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$entry,'validate','--json') -TimeoutSeconds 30
        Assert-FreshWinFalse $process.Succeeded
        $diagnostic = ([string]$process.StandardOutput) + [Environment]::NewLine + ([string]$process.StandardError)
        foreach ($field in @('FreshWin failed:','ExceptionType:','ScriptStackTrace:','InvocationInfo:','File:','Line:','Function:')) {
            Assert-FreshWinMatch $diagnostic ([regex]::Escape($field))
        }
        Assert-FreshWinFalse ($diagnostic -match 'startup diagnostic was unavailable')
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'WinGet trust requires the Microsoft App Installer identity and Microsoft signature' -Category 'Security' -ScriptBlock {
    $trustedPackage = [pscustomobject]@{
        Name = 'Microsoft.DesktopAppInstaller'
        PackageFamilyName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
        PublisherId = '8wekyb3d8bbwe'
        SignatureKind = 'Store'
    }
    Assert-FreshWinTrue (Test-FreshWinTrustedAppInstallerIdentity -Package $trustedPackage)
    $trustedPackage.PublisherId = 'untrustedpublisher'
    Assert-FreshWinFalse (Test-FreshWinTrustedAppInstallerIdentity -Package $trustedPackage)

    $validSignature = {
        param($path)
        [pscustomobject]@{
            Status = 'Valid'
            SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
        }
    }
    $otherSignature = {
        param($path)
        [pscustomobject]@{
            Status = 'Valid'
            SignerCertificate = [pscustomobject]@{ Subject = 'CN=Example, O=Example Corporation, C=US' }
        }
    }
    Assert-FreshWinTrue (Test-FreshWinTrustedMicrosoftExecutableSignature -Path 'C:\fixture\winget.exe' -SignatureProvider $validSignature)
    Assert-FreshWinFalse (Test-FreshWinTrustedMicrosoftExecutableSignature -Path 'C:\fixture\winget.exe' -SignatureProvider $otherSignature)
}

Add-FreshWinTest -Name 'WinGet resolver prefers current-user App Installer then uses elevated all-users fallback' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    $script:FreshWinAppxScopesObserved = New-Object System.Collections.Generic.List[string]
    try {
        $currentRoot = Join-Path $directory 'current-user-app-installer'
        $allUsersRoot = Join-Path $directory 'all-users-app-installer'
        [void][IO.Directory]::CreateDirectory($currentRoot)
        [void][IO.Directory]::CreateDirectory($allUsersRoot)
        $currentWinget = Join-Path $currentRoot 'winget.exe'
        $allUsersWinget = Join-Path $allUsersRoot 'winget.exe'
        [IO.File]::WriteAllText($currentWinget, 'current-user fixture')
        [IO.File]::WriteAllText($allUsersWinget, 'all-users fixture')

        $currentPackage = [pscustomobject]@{
            Name='Microsoft.DesktopAppInstaller'; PackageFamilyName='Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
            PublisherId='8wekyb3d8bbwe'; SignatureKind='Store'; InstallLocation=$currentRoot; Version=[version]'1.0.0.0'
        }
        $allUsersPackage = [pscustomobject]@{
            Name='Microsoft.DesktopAppInstaller'; PackageFamilyName='Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
            PublisherId='8wekyb3d8bbwe'; SignatureKind='System'; InstallLocation=$allUsersRoot; Version=[version]'2.0.0.0'
        }
        $microsoftSignature = {
            param($path)
            [pscustomobject]@{
                Status='Valid'
                SignerCertificate=[pscustomobject]@{ Subject='CN=Microsoft Windows, O=Microsoft Corporation, C=US' }
            }
        }

        $resolvedFallback = Resolve-FreshWinTrustedWingetPath -WindowsProvider { $true } `
            -AdministratorProvider { $true } -SignatureProvider $microsoftSignature -AppxPackageProvider {
                param($scope, $name)
                $script:FreshWinAppxScopesObserved.Add($scope)
                Assert-FreshWinEqual 'Microsoft.DesktopAppInstaller' $name
                if ($scope -ceq 'AllUsers') { return $allUsersPackage }
                return @()
            }
        Assert-FreshWinEqual ([IO.Path]::GetFullPath($allUsersWinget)) $resolvedFallback
        Assert-FreshWinEqual 'CurrentUser,AllUsers' ($script:FreshWinAppxScopesObserved -join ',')

        $script:FreshWinAppxScopesObserved.Clear()
        $resolvedCurrent = Resolve-FreshWinTrustedWingetPath -WindowsProvider { $true } `
            -AdministratorProvider { $true } -SignatureProvider $microsoftSignature -AppxPackageProvider {
                param($scope, $name)
                $script:FreshWinAppxScopesObserved.Add($scope)
                if ($scope -ceq 'AllUsers') { throw 'All-users enumeration must remain a fallback.' }
                return $currentPackage
            }
        Assert-FreshWinEqual ([IO.Path]::GetFullPath($currentWinget)) $resolvedCurrent
        Assert-FreshWinEqual 'CurrentUser' ($script:FreshWinAppxScopesObserved -join ',')
    }
    finally {
        Remove-Variable FreshWinAppxScopesObserved -Scope Script -ErrorAction SilentlyContinue
        Remove-FreshWinTestDirectory $directory
    }
}

Add-FreshWinTest -Name 'WinGet resolver never enumerates all-users App Installer while unelevated' -Category 'Security' -ScriptBlock {
    $script:FreshWinAppxScopesObserved = New-Object System.Collections.Generic.List[string]
    try {
        $resolved = Resolve-FreshWinTrustedWingetPath -WindowsProvider { $true } `
            -AdministratorProvider { $false } -SignatureProvider { throw 'No candidate should reach signature validation.' } `
            -AppxPackageProvider {
                param($scope, $name)
                $script:FreshWinAppxScopesObserved.Add($scope)
                if ($scope -ceq 'AllUsers') { throw 'Unelevated code must not request all-users packages.' }
                return @()
            }
        Assert-FreshWinNull $resolved
        Assert-FreshWinEqual 'CurrentUser' ($script:FreshWinAppxScopesObserved -join ',')
    }
    finally {
        Remove-Variable FreshWinAppxScopesObserved -Scope Script -ErrorAction SilentlyContinue
    }
}

Add-FreshWinTest -Name 'Downloaded executables never become trusted WinGet or elevation candidates' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $downloadsRoot = Join-Path $directory ('OneDrive - T' + [char]0x1EA3 + 'i xu' + [char]0x1ED1 + 'ng')
        $installersRoot = Join-Path (Join-Path $downloadsRoot 'FreshWin') 'Installers'
        $appInstallerRoot = Join-Path $directory 'trusted-app-installer'
        [void][IO.Directory]::CreateDirectory($installersRoot)
        [void][IO.Directory]::CreateDirectory($appInstallerRoot)
        $downloadedWinget = Join-Path $installersRoot 'winget.exe'
        $packagedWinget = Join-Path $appInstallerRoot 'winget.exe'
        [IO.File]::WriteAllText($downloadedWinget, 'untrusted download fixture')
        [IO.File]::WriteAllText($packagedWinget, 'trusted package fixture')
        $appInstaller = [pscustomobject]@{
            Name='Microsoft.DesktopAppInstaller'; PackageFamilyName='Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
            PublisherId='8wekyb3d8bbwe'; SignatureKind='Store'; InstallLocation=$appInstallerRoot; Version=[version]'1.0.0.0'
        }
        $resolved = Resolve-FreshWinTrustedWingetPath -CandidatePath $downloadedWinget -WindowsProvider { $true } `
            -AdministratorProvider { $false } -AppxPackageProvider { param($scope, $name) $appInstaller } `
            -SignatureProvider {
                param($path)
                [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{ Subject='CN=Microsoft Windows, O=Microsoft Corporation, C=US' } }
            }
        Assert-FreshWinEqual ([IO.Path]::GetFullPath($packagedWinget)) $resolved
        Assert-FreshWinFalse ([string]::Equals([IO.Path]::GetFullPath($downloadedWinget), $resolved, [StringComparison]::OrdinalIgnoreCase)) `
            -Because 'A signature alone cannot make an executable below Downloads an App Installer trust-root candidate.'
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Official WinGet and Microsoft Store source metadata passes strict trust validation' -Category 'Security' -ScriptBlock {
    $script:FreshWinSourceFixtureName = $null
    $script:FreshWinSourceFixturePath = $null
    try {
        $winget = Test-FreshWinTrustedWingetSource -SourceName winget -WingetPath 'C:\fixture\winget.exe' -SourceProvider {
            param($sourceName, $wingetPath)
            $script:FreshWinSourceFixtureName = $sourceName
            $script:FreshWinSourceFixturePath = $wingetPath
            return '{"Arg":"https://cdn.winget.microsoft.com/cache","Data":"Microsoft.Winget.Source_8wekyb3d8bbwe","Explicit":false,"Identifier":"Microsoft.Winget.Source_8wekyb3d8bbwe","Name":"winget","TrustLevel":["Trusted","StoreOrigin"],"Type":"Microsoft.PreIndexed.Package"}'
        }
        Assert-FreshWinTrue $winget.Trusted
        Assert-FreshWinEqual 'winget' $script:FreshWinSourceFixtureName
        Assert-FreshWinEqual 'C:\fixture\winget.exe' $script:FreshWinSourceFixturePath
        Assert-FreshWinEqual 'https://cdn.winget.microsoft.com/cache' $winget.Endpoint
        Assert-FreshWinEqual 'Microsoft.Winget.Source_8wekyb3d8bbwe' $winget.Identifier

        $msstore = Test-FreshWinTrustedWingetSource -SourceName msstore -SourceProvider {
            [pscustomobject]@{
                Arg = 'https://storeedgefd.dsx.mp.microsoft.com/v9.0'
                Name = 'msstore'
                Type = 'Microsoft.Rest'
            }
        }
        Assert-FreshWinTrue $msstore.Trusted
        Assert-FreshWinEqual 'https://storeedgefd.dsx.mp.microsoft.com/v9.0' $msstore.Endpoint
        Assert-FreshWinEqual 'Microsoft.Rest' $msstore.SourceType
    }
    finally {
        Remove-Variable FreshWinSourceFixtureName -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable FreshWinSourceFixturePath -Scope Script -ErrorAction SilentlyContinue
    }
}

Add-FreshWinTest -Name 'WinGet source trust fails closed for endpoint identity type and query failures' -Category 'Security' -ScriptBlock {
    $substitutedEndpoint = Test-FreshWinTrustedWingetSource -SourceName winget -SourceProvider {
        [pscustomobject]@{
            Arg = 'https://cdn.winget.microsoft.com.attacker.test/cache'
            Data = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
            Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
            Name = 'winget'
            Type = 'Microsoft.PreIndexed.Package'
        }
    }
    Assert-FreshWinFalse $substitutedEndpoint.Trusted
    Assert-FreshWinMatch $substitutedEndpoint.Reason 'official Microsoft endpoint'

    $normalizedSubstitution = Test-FreshWinTrustedWingetSource -SourceName winget -SourceProvider {
        [pscustomobject]@{
            Arg = 'https://cdn.winget.microsoft.com/untrusted/../cache'
            Data = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
            Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
            Name = 'winget'
            Type = 'Microsoft.PreIndexed.Package'
        }
    }
    Assert-FreshWinFalse $normalizedSubstitution.Trusted
    Assert-FreshWinMatch $normalizedSubstitution.Reason 'official Microsoft endpoint'

    $substitutedIdentity = Test-FreshWinTrustedWingetSource -SourceName winget -SourceProvider {
        [pscustomobject]@{
            Arg = 'https://cdn.winget.microsoft.com/cache'
            Data = 'Attacker.Source_8wekyb3d8bbwe'
            Identifier = 'Attacker.Source_8wekyb3d8bbwe'
            Name = 'winget'
            Type = 'Microsoft.PreIndexed.Package'
        }
    }
    Assert-FreshWinFalse $substitutedIdentity.Trusted
    Assert-FreshWinMatch $substitutedIdentity.Reason 'identity'

    $storeWithQuery = Test-FreshWinTrustedWingetSource -SourceName msstore -SourceProvider {
        [pscustomobject]@{
            Arg = 'https://storeedgefd.dsx.mp.microsoft.com/v9.0?redirect=attacker'
            Name = 'msstore'
            Type = 'Microsoft.Rest'
        }
    }
    Assert-FreshWinFalse $storeWithQuery.Trusted
    Assert-FreshWinMatch $storeWithQuery.Reason 'official Microsoft endpoint'

    $wrongStoreType = Test-FreshWinTrustedWingetSource -SourceName msstore -SourceProvider {
        [pscustomobject]@{
            Arg = 'https://storeedgefd.dsx.mp.microsoft.com/v9.0'
            Name = 'msstore'
            Type = 'Microsoft.PreIndexed.Package'
        }
    }
    Assert-FreshWinFalse $wrongStoreType.Trusted
    Assert-FreshWinMatch $wrongStoreType.Reason 'source type'

    $malformed = Test-FreshWinTrustedWingetSource -SourceName winget -SourceProvider { return '{not-json' }
    Assert-FreshWinFalse $malformed.Trusted
    Assert-FreshWinMatch $malformed.Reason 'not valid JSON'

    $queryFailure = Test-FreshWinTrustedWingetSource -SourceName winget -SourceProvider { throw 'fixture query failed' }
    Assert-FreshWinFalse $queryFailure.Trusted
    Assert-FreshWinMatch $queryFailure.Reason 'could not be queried'
}

Add-FreshWinTest -Name 'Malformed localized WinGet tables fail inventory closed' -Category 'Security' -ScriptBlock {
    [void](Get-FreshWinSoftwareInventory -WingetOutput @(
        'Nombre Identificador Versión',
        '---------------------------------------------------',
        'Aplicación de ejemplo Ejemplo.Aplicacion   1.0.0'
    ) -RegistryEntries @() -KnownPaths @())
    Assert-FreshWinFalse ([bool]$script:FreshWinSoftwareInventoryLastStatus.Available)
    Assert-FreshWinEqual 'Unknown' $script:FreshWinSoftwareInventoryLastStatus.Status
    Assert-FreshWinMatch ($script:FreshWinSoftwareInventoryLastStatus.Errors -join ' ') 'columns were not recognized'

    $none = @(ConvertFrom-FreshWinWingetOutput -Output 'No applicable upgrade found.' -Mode Upgrade)
    Assert-FreshWinEqual 0 $none.Count
    Assert-FreshWinTrue ([bool]$script:FreshWinWingetLastParseStatus.Recognized)
}

Add-FreshWinTest -Name 'Localized WinGet tables use the invariant separator layout' -Category 'Core' -ScriptBlock {
    $records = @(ConvertFrom-FreshWinWingetOutput -Output @(
        '名称                          标识符                  版本         可用         源',
        '----------------------------  ----------------------  -----------  -----------  -------',
        '示例应用程序                  Ejemplo.Aplicacion      1.0.0        1.1.0        winget'
    ) -Mode Upgrade)
    Assert-FreshWinTrue ([bool]$script:FreshWinWingetLastParseStatus.Recognized)
    Assert-FreshWinEqual 'Table' $script:FreshWinWingetLastParseStatus.Format
    Assert-FreshWinCount 1 $records
    Assert-FreshWinEqual 'Ejemplo.Aplicacion' $records[0].WingetId
    Assert-FreshWinEqual '1.0.0' $records[0].Version
    Assert-FreshWinEqual '1.1.0' $records[0].AvailableVersion
    Assert-FreshWinEqual 'winget' $records[0].Repository
    Assert-FreshWinTrue $records[0].UpdateAvailable
}

Add-FreshWinTest -Name 'WinGet table parsing rejects truncated identities and supports a continuous localized separator' -Category 'Security' -ScriptBlock {
    $truncated = @(ConvertFrom-FreshWinWingetOutput -Output @(
        'Name                    Id                         Version',
        '---------------------------------------------------------',
        'Example                 Example.Truncated...       1.0.0'
    ))
    Assert-FreshWinEqual 0 $truncated.Count
    Assert-FreshWinFalse ([bool]$script:FreshWinWingetLastParseStatus.Recognized)
    Assert-FreshWinMatch ([string]$script:FreshWinWingetLastParseStatus.Reason) 'truncated or invalid package identifier'

    $continuous = @(ConvertFrom-FreshWinWingetOutput -Output @(
        'Nombre                 Identificador        Versión',
        '---------------------------------------------------',
        'Aplicación de ejemplo Ejemplo.Aplicacion   1.0.0'
    ))
    Assert-FreshWinTrue ([bool]$script:FreshWinWingetLastParseStatus.Recognized)
    Assert-FreshWinCount 1 $continuous
    Assert-FreshWinEqual 'Ejemplo.Aplicacion' $continuous[0].WingetId
    Assert-FreshWinEqual '1.0.0' $continuous[0].Version
}

Add-FreshWinTest -Name 'Short WinGet rows fail closed without an out-of-range substring' -Category 'Security' -ScriptBlock {
    $shortRows = @(
        'Name                            Id                              Version',
        '---------------------------------------------------------------------',
        'X                               Example.Package'
    )
    Assert-FreshWinDoesNotThrow { $script:FreshWinShortWingetRows = @(ConvertFrom-FreshWinWingetOutput -Output $shortRows) }
    try {
        Assert-FreshWinCount 0 $script:FreshWinShortWingetRows
        Assert-FreshWinFalse ([bool]$script:FreshWinWingetLastParseStatus.Recognized)
        Assert-FreshWinMatch ([string]$script:FreshWinWingetLastParseStatus.Reason) 'truncated or invalid'
    }
    finally {
        Remove-Variable FreshWinShortWingetRows -Scope Script -ErrorAction SilentlyContinue
    }
}

Add-FreshWinTest -Name 'Software inventory cache distinguishes missing-only and update-aware evidence' -Category 'Security' -ScriptBlock {
    $source = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/Scanner/Software.ps1'))
    Assert-FreshWinMatch -Actual $source -Pattern 'FreshWinSoftwareInventoryCacheIncludesUpdates'
    Assert-FreshWinMatch -Actual $source -Pattern '-not \[bool\]\$IncludeUpdates\s+-or\s+\[bool\]\$script:FreshWinSoftwareInventoryCacheIncludesUpdates'
    Assert-FreshWinMatch -Actual $source -Pattern 'UpdatesScanned\s*=.*UpdatesAvailable'
    Assert-FreshWinMatch -Actual $source -Pattern 'UpdateSourcesScanned[\s\S]*winget' `
        -Because 'Update evidence must name the exact package source it covered.'

    [void](Get-FreshWinSoftwareInventory -WingetOutput 'No installed package found.' `
        -WingetUpgradeOutput 'unrecognized localized failure' -RegistryEntries @() -KnownPaths @() -AppxPackages @())
    Assert-FreshWinTrue ([bool]$script:FreshWinSoftwareInventoryLastStatus.Available) `
        -Because 'An update-only query failure must not invalidate complete installed-state evidence.'
    Assert-FreshWinFalse ([bool]$script:FreshWinSoftwareInventoryLastStatus.UpdatesAvailable)
    Assert-FreshWinEqual 'Partial' $script:FreshWinSoftwareInventoryLastStatus.Status
}

Add-FreshWinTest -Name 'WinGet inventory isolates and validates the community source' -Category 'Security' -ScriptBlock {
    $source = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/Scanner/Software.ps1'))
    Assert-FreshWinMatch -Actual $source -Pattern 'Test-FreshWinTrustedWingetSource\s+-SourceName\s+winget'
    Assert-FreshWinMatch -Actual $source -Pattern '\$arguments\s*=\s*@\(\$Operation,\s*''--source'',\s*''winget'',\s*''--disable-interactivity''\)'
    Assert-FreshWinFalse ($source -match '\$arguments\s*=\s*@\(\$Operation,\s*''--disable-interactivity''\)') `
        -Because 'An implicit all-source query can be blocked by an unrelated Microsoft Store agreement.'
}

Add-FreshWinTest -Name 'WinGet inventory rejects clients that can truncate redirected package IDs' -Category 'Security' -ScriptBlock {
    $supported = Get-FreshWinWingetInventoryVersionState -WingetPath 'C:\fixture\winget.exe' -VersionProvider {
        param($path)
        Assert-FreshWinEqual 'C:\fixture\winget.exe' $path
        [pscustomobject]@{ Succeeded=$true; ExitCode=0; StandardOutput='v1.29.280'; StandardError='' }
    }
    Assert-FreshWinTrue $supported.Supported
    Assert-FreshWinEqual '1.29.280' $supported.Version

    $old = Get-FreshWinWingetInventoryVersionState -WingetPath 'C:\fixture\winget.exe' -VersionProvider {
        [pscustomobject]@{ Succeeded=$true; ExitCode=0; StandardOutput='v1.28.100'; StandardError='' }
    }
    Assert-FreshWinFalse $old.Supported
    Assert-FreshWinMatch -Actual $old.Reason -Pattern 'Update Microsoft App Installer'

    $unknown = Get-FreshWinWingetInventoryVersionState -WingetPath 'C:\fixture\winget.exe' -VersionProvider {
        [pscustomobject]@{ Succeeded=$true; ExitCode=0; StandardOutput='unexpected'; StandardError='' }
    }
    Assert-FreshWinFalse $unknown.Supported
    Assert-FreshWinMatch -Actual $unknown.Reason -Pattern 'could not be verified'

    $source = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/Scanner/Software.ps1'))
    Assert-FreshWinMatch -Actual $source -Pattern 'Get-FreshWinWingetInventoryVersionState\s+-WingetPath\s+\$wingetPath[\s\S]*-not\s+\[bool\]\$versionState\.Supported' `
        -Because 'Live inventory must gate the redirected table before accepting negative package evidence.'
}

Add-FreshWinTest -Name 'WinGet inventory treats documented empty-query HRESULTs as healthy' -Category 'Security' -ScriptBlock {
    $listPolicy = Get-FreshWinWingetInventoryExitPolicy -Operation list
    Assert-FreshWinContains @($listPolicy.ExpectedExitCodes) 0
    Assert-FreshWinContains @($listPolicy.EmptyExitCodes) -1978335212
    Assert-FreshWinFalse (@($listPolicy.EmptyExitCodes) -contains -1978335189)

    $upgradePolicy = Get-FreshWinWingetInventoryExitPolicy -Operation upgrade
    Assert-FreshWinContains @($upgradePolicy.ExpectedExitCodes) -1978335189
    Assert-FreshWinContains @($upgradePolicy.EmptyExitCodes) -1978335212
    $source = [System.IO.File]::ReadAllText((Join-Path $script:FreshWinTestContext.ProjectRoot 'src/Scanner/Software.ps1'))
    Assert-FreshWinMatch -Actual $source -Pattern '\$emptyResult\s*=\s*\$processResult\.ExitCode\s+-in[\s\S]*-not\s+\$emptyResult' `
        -Because 'Localized error text for a documented empty query must not be sent to the table parser.'
}

Add-FreshWinTest -Name 'Blank WinGet output cannot prove an empty installed or update set' -Category 'Security' -ScriptBlock {
    $blankInstalled = @(Get-FreshWinSoftwareInventory -WingetOutput @('', '   ') `
        -RegistryEntries @() -KnownPaths @() -AppxPackages @())
    Assert-FreshWinEqual 0 $blankInstalled.Count
    Assert-FreshWinFalse ([bool]$script:FreshWinSoftwareInventoryLastStatus.Available)
    Assert-FreshWinEqual 'Unknown' $script:FreshWinSoftwareInventoryLastStatus.Status
    Assert-FreshWinMatch ($script:FreshWinSoftwareInventoryLastStatus.Errors -join ' ') 'empty result was not proven'

    $package = New-FreshWinTestPackage
    $detection = Get-FreshWinPackageDetection -Package $package -Inventory ([pscustomobject]@{
        Available = [bool]$script:FreshWinSoftwareInventoryLastStatus.Available
        Items = $blankInstalled
    })
    Assert-FreshWinEqual 'Unknown' $detection.State `
        -Because 'A successful process exit with blank output must not authorize a NotInstalled result.'

    [void](Get-FreshWinSoftwareInventory -WingetOutput 'No installed package found.' `
        -WingetUpgradeOutput "`r`n   " -RegistryEntries @() -KnownPaths @() -AppxPackages @())
    Assert-FreshWinTrue ([bool]$script:FreshWinSoftwareInventoryLastStatus.Available)
    Assert-FreshWinFalse ([bool]$script:FreshWinSoftwareInventoryLastStatus.UpdatesAvailable)
    Assert-FreshWinCount 0 @($script:FreshWinSoftwareInventoryLastStatus.UpdateSourcesScanned)
    Assert-FreshWinEqual 'Partial' $script:FreshWinSoftwareInventoryLastStatus.Status
}

Add-FreshWinTest -Name 'Scanner accepts only operation-allowlisted WinGet empty-result HRESULT evidence' -Category 'Security' -ScriptBlock {
    $script:FreshWinEmptyQueryOperations = @()
    try {
        $records = @(Get-FreshWinSoftwareInventory -WingetQueryProvider {
            param($operation)
            $script:FreshWinEmptyQueryOperations += $operation
            $exitCode = if ($operation -eq 'upgrade') { -1978335189 } else { -1978335212 }
            return [pscustomobject]@{
                Available = $true; ExitCode = $exitCode; Output = @(); Error = $null
                TimedOut = $false; EmptyResult = $true
            }
        } -IncludeUpdates -RegistryEntries @() -KnownPaths @() -AppxPackages @())

        Assert-FreshWinEqual 0 $records.Count
        Assert-FreshWinSetEqual @('list', 'upgrade') $script:FreshWinEmptyQueryOperations
        Assert-FreshWinTrue ([bool]$script:FreshWinSoftwareInventoryLastStatus.Available)
        Assert-FreshWinTrue ([bool]$script:FreshWinSoftwareInventoryLastStatus.UpdatesAvailable)
        Assert-FreshWinSetEqual @('winget') @($script:FreshWinSoftwareInventoryLastStatus.UpdateSourcesScanned)
        Assert-FreshWinEqual 'Ready' $script:FreshWinSoftwareInventoryLastStatus.Status

        [void](ConvertFrom-FreshWinWingetQueryEvidence -Query ([pscustomobject]@{
            ExitCode = -1978335189; EmptyResult = $true; Output = @()
        }) -Mode Installed)
        Assert-FreshWinFalse ([bool]$script:FreshWinWingetLastParseStatus.Recognized) `
            -Because 'UPDATE_NOT_APPLICABLE is healthy-empty evidence only for an upgrade query.'
    }
    finally {
        Remove-Variable -Name FreshWinEmptyQueryOperations -Scope Script -ErrorAction SilentlyContinue
    }
}

Add-FreshWinTest -Name 'Update WhatIf does not create its destination directory' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes('preview bytes')
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $parent = Join-Path $directory 'not-created'
        $destination = Join-Path $parent 'FreshWin.zip'
        $status = [pscustomobject]@{
            Status = 'Available'
            Validation = [pscustomobject]@{ IsValid = $true; PackageUri = 'https://updates.example.test/FreshWin.zip'; Sha256 = $hash }
        }
        $result = Save-FreshWinUpdatePackage -UpdateStatus $status -DestinationPath $destination -PackageProvider { param($uri) $bytes } -WhatIf
        Assert-FreshWinEqual 'Preview' $result.Status
        Assert-FreshWinFalse ([IO.Directory]::Exists($parent))
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'FreshWin-managed update preview reports the default installer destination without creating it' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes('preview bytes')
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $downloads = Join-Path $directory 'Redirected Downloads'
        $status = [pscustomobject]@{
            Status = 'Available'
            Validation = [pscustomobject]@{ IsValid=$true; Version=[version]'1.2.3'; PackageUri='https://updates.example.test/FreshWin.zip'; Sha256=$hash }
        }
        $result = Save-FreshWinUpdatePackage -UpdateStatus $status -DownloadsKnownFolderProvider { $downloads } -PackageProvider { throw 'WhatIf must not download' } -WhatIf
        $expected = Join-Path (Join-Path (Join-Path $downloads 'FreshWin') 'Installers') 'FreshWin-1.2.3.zip'
        Assert-FreshWinEqual ([IO.Path]::GetFullPath($expected)) $result.Path
        Assert-FreshWinFalse ([IO.Directory]::Exists($downloads))
        Assert-FreshWinFalse $result.Executed
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Portable profiles round-trip through a bounded catalog without overwrite' -Category 'Profiles' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $catalog = Import-FreshWinPackageCatalog
        # macOS exposes its temporary root through /var -> /private/var. Use
        # the physical local path so the reparse-chain policy is still tested.
        $profileDirectory = if ($directory.StartsWith('/var/')) { '/private' + $directory } else { $directory }
        $path = Join-Path $profileDirectory 'portable-profile.json'
        $exported = Export-FreshWinProfile -Path $path -PackageIds @('git', 'vscode') -Name 'Developer essentials' -UpdatePolicy include-updates -Catalog $catalog
        Assert-FreshWinTrue ([IO.File]::Exists($path))
        Assert-FreshWinEqual 2 $exported.PackageCount

        $imported = Import-FreshWinUserProfile -Path $path -Catalog $catalog
        Assert-FreshWinEqual 'Developer essentials' $imported.name
        Assert-FreshWinEqual 'include-updates' $imported.updatePolicy
        Assert-FreshWinSetEqual @('git', 'vscode') @($imported.NormalizedPackageIds)
        Assert-FreshWinThrows { Export-FreshWinProfile -Path $path -PackageIds @('git') -Catalog $catalog } 'overwrite'

        $unknownPath = Join-Path $profileDirectory 'unknown.json'
        Assert-FreshWinThrows { Export-FreshWinProfile -Path $unknownPath -PackageIds @('not-in-the-catalog') -Catalog $catalog } 'unknown package'
        Assert-FreshWinFalse ([IO.File]::Exists($unknownPath))
        Assert-FreshWinThrows { Export-FreshWinProfile -Path 'relative-profile.json' -PackageIds @('git') -Catalog $catalog } 'absolute local'

        $unicodeLeaf = 'T' + [char]0x1EA3 + 'i xu' + [char]0x1ED1 + 'ng'
        $redirectedDownloads = Join-Path (Join-Path $profileDirectory 'OneDrive - Team Space') $unicodeLeaf
        $lazyBackupPath = Get-FreshWinDefaultArtifactPath -Category Backups -FileName 'FreshWin-Profile.json' -DownloadsPath $redirectedDownloads
        Assert-FreshWinFalse ([IO.Directory]::Exists($redirectedDownloads))
        Assert-FreshWinThrows { Export-FreshWinProfile -Path $lazyBackupPath -PackageIds @('not-in-the-catalog') -Catalog $catalog } 'unknown package'
        Assert-FreshWinFalse ([IO.Directory]::Exists($redirectedDownloads)) -Because 'Invalid exports must not create the retained-artifact directory.'
        $lazyExport = Export-FreshWinProfile -Path $lazyBackupPath -PackageIds @('git') -Catalog $catalog
        Assert-FreshWinEqual ([IO.Path]::GetFullPath($lazyBackupPath)) $lazyExport.Path
        Assert-FreshWinTrue ([IO.File]::Exists($lazyBackupPath)) -Because 'The retained backup directory is created only for the validated write.'
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Portable profile import rejects extensions duplicates and invalid UTF-8' -Category 'Security' -ScriptBlock {
    $directory = New-FreshWinTestDirectory
    try {
        $catalog = Import-FreshWinPackageCatalog
        $profileDirectory = if ($directory.StartsWith('/var/')) { '/private' + $directory } else { $directory }
        $base = [ordered]@{
            schemaVersion = 1
            id = 'custom-export'
            name = 'Fixture profile'
            descriptionKey = 'profiles.custom.description'
            packageIds = @('git')
            updatePolicy = 'missing-only'
            exportedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }

        $extended = [ordered]@{}
        foreach ($entry in $base.GetEnumerator()) { $extended[$entry.Key] = $entry.Value }
        $extended['command'] = 'not-allowed'
        $extendedPath = Join-Path $profileDirectory 'extended.json'
        [IO.File]::WriteAllText($extendedPath, ($extended | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Assert-FreshWinThrows { Import-FreshWinUserProfile -Path $extendedPath -Catalog $catalog } 'Unsupported portable profile property'

        $base.packageIds = @('git', 'git')
        $duplicatePath = Join-Path $profileDirectory 'duplicate.json'
        [IO.File]::WriteAllText($duplicatePath, ($base | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Assert-FreshWinThrows { Import-FreshWinUserProfile -Path $duplicatePath -Catalog $catalog } 'duplicate package'

        $invalidUtf8Path = Join-Path $profileDirectory 'invalid-utf8.json'
        [IO.File]::WriteAllBytes($invalidUtf8Path, [byte[]]@(0x7b, 0xff, 0x7d))
        Assert-FreshWinThrows { Import-FreshWinUserProfile -Path $invalidUtf8Path -Catalog $catalog } 'valid UTF-8'
    }
    finally { Remove-FreshWinTestDirectory $directory }
}

Add-FreshWinTest -Name 'Execution dry-run bypasses elevation but manual and stale-skip plans remain issues' -Category 'Workflow' -ScriptBlock {
    $system = New-FreshWinTestSystemInfo
    $system.Admin = $false
    $system.IsAdministrator = $false
    $inventory = [pscustomobject]@{ Available = $true; Items = @() }

    $adminPackage = New-FreshWinTestPackage -RequiresAdmin $true
    $catalog = [pscustomobject]@{ Packages = @($adminPackage); Errors = @() }
    $plan = New-FreshWinTestExecutionPlan -Package $adminPackage -DryRun
    $dryRun = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo $system -Inventory $inventory -SourceResolver { param($package) New-FreshWinTestResolvedSource $package }
    Assert-FreshWinEqual 'DRY_RUN_COMPLETE' $dryRun.Status
    Assert-FreshWinEqual 'VALIDATED' $dryRun.Plan.Items[0].State

    $manualPackage = New-FreshWinTestPackage -Id manualpkg -SourceType manual -Silent $false
    $manualCatalog = [pscustomobject]@{ Packages = @($manualPackage); Errors = @() }
    $manualPlan = New-FreshWinInstallPlan -PackageIds manualpkg -Catalog $manualCatalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $inventory
    $manualResult = Invoke-FreshWinExecutionPlan -Plan $manualPlan -Catalog $manualCatalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $inventory
    Assert-FreshWinEqual 'COMPLETED_WITH_ISSUES' $manualResult.Status
    Assert-FreshWinEqual 1 $manualResult.Summary.ManualRequired

    $dependency = New-FreshWinTestPackage -Id dependency
    $application = New-FreshWinTestPackage -Id application -Dependencies @('dependency')
    $dependencyCatalog = [pscustomobject]@{ Packages = @($application, $dependency); Errors = @() }
    $stalePlan = New-FreshWinInstallPlan -PackageIds application -Catalog $dependencyCatalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $inventory -WingetPath (Get-Process -Id $PID).Path -DryRun
    $stalePlan.Items[0].Action = 'SKIP'; $stalePlan.Items[0].State = 'SKIP'
    $staleResult = Invoke-FreshWinExecutionPlan -Plan $stalePlan -Catalog $dependencyCatalog -SystemInfo (New-FreshWinTestSystemInfo) -Inventory $inventory -SourceResolver { param($package) New-FreshWinTestResolvedSource $package }
    Assert-FreshWinEqual 'BLOCKED' $staleResult.Plan.Items[0].State
    Assert-FreshWinEqual 'BLOCKED' $staleResult.Plan.Items[1].State
    Assert-FreshWinEqual 'COMPLETED_WITH_ISSUES' $staleResult.Status
}
Add-FreshWinTest -Name 'Path trimming never passes a multi-character separator to a Char overload' -Category 'Compatibility' -ScriptBlock {
    $sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:FreshWinTestContext.ProjectRoot 'src') -Filter '*.ps1' -File -Recurse)
    $sourceFiles += @(Get-ChildItem -LiteralPath $script:FreshWinTestContext.ProjectRoot -Filter '*.ps1' -File)
    $sourceFiles += @(Get-ChildItem -LiteralPath (Join-Path $script:FreshWinTestContext.ProjectRoot 'installer') -Filter '*.ps1' -File -Recurse)
    foreach ($sourceFile in $sourceFiles) {
        $source = [System.IO.File]::ReadAllText($sourceFile.FullName)
        Assert-FreshWinFalse ($source -match "\.Trim(?:Start|End)?\(\s*'\\\\'") -Because "PowerShell 5.1 cannot bind a two-character backslash string to a System.Char trim argument in '$($sourceFile.FullName)'."
    }
}
