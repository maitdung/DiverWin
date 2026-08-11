Add-FreshWinTest -Name 'Native argument quoting handles spaces, quotes, empty strings, and trailing slashes' -Category 'Security' -ScriptBlock {
    Assert-FreshWinEqual 'plain' (ConvertTo-FreshWinProcessArgument 'plain')
    Assert-FreshWinEqual '""' (ConvertTo-FreshWinProcessArgument '')
    Assert-FreshWinEqual '"two words"' (ConvertTo-FreshWinProcessArgument 'two words')
    Assert-FreshWinEqual '"a\"b"' (ConvertTo-FreshWinProcessArgument 'a"b')
    Assert-FreshWinEqual '"C:\Program Files\\"' (ConvertTo-FreshWinProcessArgument 'C:\Program Files\')
    Assert-FreshWinThrows -ScriptBlock { ConvertTo-FreshWinProcessArgument ("bad" + [char]0 + "value") } -Pattern 'NUL'
}

Add-FreshWinTest -Name 'Bounded read-only process execution does not lazily create logs' -Category 'Security' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    $previousLocalAppData = $env:LOCALAPPDATA
    $previousLogger = $script:FreshWinLoggerContext
    try {
        $env:LOCALAPPDATA = $temporary
        $script:FreshWinLoggerContext = $null
        $executable = if ([IO.File]::Exists('/usr/bin/true')) { '/usr/bin/true' } else { (Get-Process -Id $PID).Path }
        $arguments = if ($executable -eq '/usr/bin/true') { @('--help') } else { @('-NoLogo','-NoProfile','-Command','exit 0') }
        $result = Invoke-FreshWinProcess -FilePath $executable -ArgumentList $arguments -TimeoutSeconds 10
        Assert-FreshWinTrue $result.Succeeded
        Assert-FreshWinFalse ([IO.Directory]::Exists((Join-Path $temporary 'FreshWin'))) `
            -Because 'A status, inventory, plan, or dry-run process must not initialize application logs.'
    }
    finally {
        $env:LOCALAPPDATA = $previousLocalAppData
        $script:FreshWinLoggerContext = $previousLogger
        Remove-FreshWinTestDirectory $temporary
    }
}

Add-FreshWinTest -Name 'Safe process runner rejects script and shell executable extensions' -Category 'Security' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        foreach ($extension in @('.ps1', '.cmd', '.bat', '.vbs', '.js')) {
            $path = Join-Path $temporary "payload$extension"
            [System.IO.File]::WriteAllText($path, 'not executable')
            Assert-FreshWinThrows -ScriptBlock { Resolve-FreshWinExecutablePath $path } -Pattern 'not allowed'
        }
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Read-only process ignores a removed inherited test log directory' -Category 'Security' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    $previousLogger = $script:FreshWinLoggerContext
    try {
        [void](Initialize-FreshWinLogger -LogDirectory $temporary)
        Remove-FreshWinTestDirectory $temporary
        $executable = (Get-Process -Id $PID).Path
        $result = Invoke-FreshWinProcess -FilePath $executable -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'exit 0') -TimeoutSeconds 15
        Assert-FreshWinTrue $result.Succeeded
        Assert-FreshWinFalse ([IO.Directory]::Exists($temporary)) -Because 'Optional inherited logging must not recreate a removed directory.'
    }
    finally {
        $script:FreshWinLoggerContext = $previousLogger
        if ([IO.Directory]::Exists($temporary)) { Remove-FreshWinTestDirectory $temporary }
    }
}

Add-FreshWinTest -Name 'Sensitive text and structured data are redacted' -Category 'Security' -ScriptBlock {
    $secret = 'freshwin-secret-value'
    $text = Protect-FreshWinSensitiveText "token=$secret Authorization: Bearer abcdefghijklmnopqrstuvwxyz"
    Assert-FreshWinFalse $text.Contains($secret)
    Assert-FreshWinFalse ($text -match 'Bearer\s+abcdefghijklmnopqrstuvwxyz')
    $safe = Protect-FreshWinSensitiveData ([pscustomobject]@{
        user = 'alice'
        apiKey = $secret
        nested = [pscustomobject]@{ password = $secret; note = "token=$secret" }
    })
    Assert-FreshWinEqual '[REDACTED]' $safe.apiKey
    Assert-FreshWinEqual '[REDACTED]' $safe.nested.password
    Assert-FreshWinFalse $safe.nested.note.Contains($secret)
}

Add-FreshWinTest -Name 'JSONL logger never writes known secrets' -Category 'Security' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $secret = 'logger-secret-value'
        $context = Initialize-FreshWinLogger -LogDirectory $temporary
        Write-FreshWinLog -Stage TEST -Message "password=$secret" -Data ([pscustomobject]@{ accessToken = $secret }) -Context $context
        $content = [System.IO.File]::ReadAllText((Get-FreshWinLogPath -Context $context))
        Assert-FreshWinFalse $content.Contains($secret)
        Assert-FreshWinMatch $content 'REDACTED'
        Assert-FreshWinDoesNotThrow { $null = $content | ConvertFrom-Json }
        $logged = $content | ConvertFrom-Json
        Assert-FreshWinFalse ([string]::IsNullOrWhiteSpace([string]$logged.osBuild)) -Because 'Structured history should retain an OS/build observation.'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'History reader is bounded read-only and redacts legacy JSONL records' -Category 'Security' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $missing = Join-Path $temporary 'missing-logs'
        Assert-FreshWinCount 0 @(Get-FreshWinLogHistory -LogDirectory $missing)
        Assert-FreshWinFalse ([IO.Directory]::Exists($missing)) -Because 'Reading history must not create its log directory.'

        $logDirectory = Join-Path $temporary 'logs'
        [void][IO.Directory]::CreateDirectory($logDirectory)
        $path = Join-Path $logDirectory 'freshwin-2026-08-11.jsonl'
        $secret = 'history-legacy-secret'
        $records = @(
            ([pscustomobject]@{ timestamp='2026-08-11T01:00:00Z'; version='0.1.0'; level='INFO'; stage='INSTALL'; action='INSTALL'; packageId='git'; result='Started'; exitCode=$null; message='Starting install'; data=$null } | ConvertTo-Json -Compress),
            'not-json',
            ([pscustomobject]@{ timestamp='2026-08-11T02:00:00Z'; version='0.1.0'; level='ERROR'; stage='VERIFY_INSTALL'; action='INSTALL'; packageId='vscode'; result='Failed'; exitCode=1; message="token=$secret"; data=[pscustomobject]@{ accessToken=$secret } } | ConvertTo-Json -Compress),
            ([pscustomobject]@{ timestamp='invalid'; version='0.1.0'; level='INFO'; stage='INSTALL'; action='INSTALL'; packageId='ignored'; result='Succeeded'; exitCode=0; message=''; data=$null } | ConvertTo-Json -Compress)
        )
        [IO.File]::WriteAllLines($path, $records, (New-Object Text.UTF8Encoding -ArgumentList $false))

        $history = @(Get-FreshWinLogHistory -LogDirectory $logDirectory -Last 1)
        Assert-FreshWinCount 1 $history
        Assert-FreshWinEqual 'vscode' $history[0].PackageId
        Assert-FreshWinEqual 'Failed' $history[0].Result
        Assert-FreshWinFalse $history[0].ErrorSummary.Contains($secret)
        Assert-FreshWinMatch $history[0].ErrorSummary 'REDACTED'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Assistant parser requires confirmation for mutating intents' -Category 'Security' -ScriptBlock {
    $intent = ConvertFrom-FreshWinAssistantCommand 'install git and vscode'
    Assert-FreshWinTrue $intent.isValid
    Assert-FreshWinEqual 'queue_install' $intent.action
    Assert-FreshWinTrue $intent.requiresConfirmation
    Assert-FreshWinSetEqual @('git', 'vscode') $intent.targets
}

Add-FreshWinTest -Name 'Assistant provider output cannot contain executable instructions' -Category 'Security' -ScriptBlock {
    $unsafe = [pscustomobject]@{
        intent = 'InstallPackages'
        action = 'queue_install'
        targets = @('git')
        parameters = [pscustomobject]@{ nested = [pscustomobject]@{ commandLine = 'calc.exe' } }
    }
    $validation = Test-FreshWinAssistantIntent $unsafe
    Assert-FreshWinFalse $validation.IsValid
    Assert-FreshWinMatch ($validation.Errors -join ' ') 'forbidden'

    [void](Register-FreshWinAssistantProvider -Name 'unsafe-test' -Kind custom -Handler { $unsafe } -Force)
    Assert-FreshWinThrows -ScriptBlock { Invoke-FreshWinAssistantProvider -InputText 'anything' -ProviderName 'unsafe-test' } -Pattern 'unsafe intent'
}

Add-FreshWinTest -Name 'Known-path expansion rejects traversal, wildcards, and unknown variables' -Category 'Security' -ScriptBlock {
    Assert-FreshWinNull (Expand-FreshWinKnownPath '..\escape.exe')
    Assert-FreshWinNull (Expand-FreshWinKnownPath '%NOT_ALLOWED%\tool.exe')
    Assert-FreshWinNull (Expand-FreshWinKnownPath '%LOCALAPPDATA%\*.exe')
    $fixtureRoot = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { 'C:\Fixture' } else { '/tmp/freshwin-fixture' }
    Assert-FreshWinNotNull (Expand-FreshWinKnownPath '%LOCALAPPDATA%\Vendor\tool.exe' -Environment @{ LOCALAPPDATA = $fixtureRoot })
}

Add-FreshWinTest -Name 'Known-path detection and verification require a non-reparse regular file' -Category 'Security' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $directoryNamedExecutable = Join-Path $temporary 'Update.exe'
        [void][System.IO.Directory]::CreateDirectory($directoryNamedExecutable)
        $package = [pscustomobject]@{
            id = 'sample'
            source = [pscustomobject]@{ type='winget'; packageId='Vendor.Sample' }
            detection = [pscustomobject]@{ wingetIds=@(); registryDisplayNames=@(); knownPaths=@($directoryNamedExecutable) }
            verification = [pscustomobject]@{ methods=@('path'); minimumMatches=1 }
        }
        $inventory = [pscustomobject]@{ Available=$true; Items=@() }
        Assert-FreshWinEqual 'NotInstalled' (Get-FreshWinPackageDetection -Package $package -Inventory $inventory).State
        $verification = Test-FreshWinPackageVerification -Package $package -Inventory $inventory
        Assert-FreshWinFalse $verification.Verified
        Assert-FreshWinEqual 'NotMatched' $verification.Results[0].Status

        [System.IO.File]::WriteAllText((Join-Path $temporary 'stale.exe'), 'stale')
        $package.detection.knownPaths = @((Join-Path $temporary 'stale.exe'))
        $package.verification.methods = @('winget','path')
        $staleVerification = Test-FreshWinPackageVerification -Package $package -Inventory $inventory
        Assert-FreshWinFalse $staleVerification.Verified
        Assert-FreshWinMatch $staleVerification.Detail 'identity-bearing'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Timed-out installers are never classified as safe to retry' -Category 'Security' -ScriptBlock {
    $result = [pscustomobject]@{
        TimedOut=$true; ExitCode=$null; StandardOutput=''; StandardError='network timeout'; Error=''
    }
    Assert-FreshWinFalse (Test-FreshWinTransientProcessFailure -ProcessResult $result)
}

Add-FreshWinTest -Name 'Create-new JSON output cannot overwrite a raced destination' -Category 'Security' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $path = Join-Path $temporary 'report.json'
        [void](Write-FreshWinJsonFile -Path $path -Value ([pscustomobject]@{ value=1 }) -CreateNew)
        Assert-FreshWinThrows {
            Write-FreshWinJsonFile -Path $path -Value ([pscustomobject]@{ value=2 }) -CreateNew
        } 'exist|already'
        Assert-FreshWinEqual 1 ((Read-FreshWinJsonFile -Path $path).value)
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Execution checkpoints do not persist executable or resolved-source fields' -Category 'Security' -ScriptBlock {
    $package = [pscustomobject]@{ id = 'sample'; name = 'Sample' }
    $item = [pscustomobject]@{
        PackageId='sample'; Action='INSTALL'; State='PENDING'; Attempts=0; RestartRequired=$false
        Result=$null; Verification=$null; Package=$package
        ResolvedSource=[pscustomobject]@{ Executable='untrusted.exe'; ArgumentList=@('--bad') }
    }
    $plan = [pscustomobject]@{
        Id=[guid]::NewGuid().ToString('N'); Status='PLANNED'; DryRun=$true; UpdatePolicy='missing-only'
        RequestedPackageIds=@('sample'); Items=@($item)
    }
    $json = (ConvertTo-FreshWinCheckpoint $plan | ConvertTo-Json -Depth 20)
    Assert-FreshWinFalse ($json -match '(?i)untrusted\.exe|resolvedSource|argumentList')
}

Add-FreshWinTest -Name 'Queue validation catches duplicate IDs and unsafe target data' -Category 'Security' -ScriptBlock {
    $item = New-FreshWinQueueItem -Id 'same' -Type INSTALL -TargetId git
    Assert-FreshWinThrows -ScriptBlock { New-FreshWinQueue -Items @($item, $item) } -Pattern 'duplicate'
    Assert-FreshWinThrows -ScriptBlock { New-FreshWinQueueItem -Type INSTALL -TargetId "git`ncalc" } -Pattern 'control'
}
