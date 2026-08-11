Set-StrictMode -Version 2.0

function Get-FreshWinProcessExitCode {
    [CmdletBinding()]
    param([AllowNull()][object]$ProcessResult)

    if ($null -eq $ProcessResult) { return $null }
    foreach ($name in @('ExitCode', 'Code')) {
        $property = $ProcessResult.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Test-FreshWinTransientProcessFailure {
    [CmdletBinding()]
    param([AllowNull()][object]$ProcessResult)

    if ($null -eq $ProcessResult) { return $true }
    if ([bool](Get-FreshWinPropertyValue -InputObject $ProcessResult -Name 'TimedOut' -Default $false)) {
        # The runner requests tree termination, but a timed-out vendor process
        # remains an uncertain mutation boundary.  An automatic retry could
        # overlap a surviving child and is therefore never safe.
        return $false
    }
    $combined = @(
        [string](Get-FreshWinPropertyValue -InputObject $ProcessResult -Name 'StandardOutput' -Default (Get-FreshWinPropertyValue -InputObject $ProcessResult -Name 'StdOut' -Default '')),
        [string](Get-FreshWinPropertyValue -InputObject $ProcessResult -Name 'StandardError' -Default (Get-FreshWinPropertyValue -InputObject $ProcessResult -Name 'StdErr' -Default '')),
        [string](Get-FreshWinPropertyValue -InputObject $ProcessResult -Name 'Error' -Default '')
    ) -join ' '
    return ($combined -match '(?i)timeout|temporar|network|connection|download|source.*unavailable|0x8a15000')
}

function Get-FreshWinInstallerFailureClassification {
    [CmdletBinding()]
    param([AllowNull()][object]$ProcessResult, [string]$FallbackMessage)

    $timedOut = [bool](Get-FreshWinPropertyValue -InputObject $ProcessResult -Name 'TimedOut' -Default $false)
    $outputSummary = if (Get-Command -Name Get-FreshWinProcessOutputSummary -ErrorAction SilentlyContinue) {
        Get-FreshWinProcessOutputSummary -ProcessResult $ProcessResult
    } else { '' }
    $combined = @($outputSummary, $FallbackMessage) -join ' '
    if ($combined -match '(?i)source agreement|package agreement|agreements? (?:must|need|is required|are required)|accept.+agreements?|terms of (?:transaction|use)') {
        return [pscustomobject]@{
            Outcome='ManualRequired'; Stage='SourceAgreement'; OutputSummary=$outputSummary
            Message='WinGet requires an agreement that FreshWin did not accept automatically. Review the agreement and provide explicit consent before retrying.'
        }
    }
    if ($timedOut) {
        return [pscustomobject]@{
            Outcome='Failed'; Stage='Install'; OutputSummary=$outputSummary
            Message='The package-manager process exceeded FreshWin''s bounded timeout and was stopped. Its completion state is unknown; it was not retried automatically.'
        }
    }
    if ($combined -match '(?i)download|network|connection|name resolution|0x8a15000|0x80072') {
        return [pscustomobject]@{
            Outcome='Failed'; Stage='Download'; OutputSummary=$outputSummary
            Message='The trusted package manager reported a download or network failure.'
        }
    }
    return [pscustomobject]@{
        Outcome='Failed'; Stage='Install'; OutputSummary=$outputSummary
        Message=$(if ($FallbackMessage) { $FallbackMessage } else { 'Installer process failed. See the FreshWin log for details.' })
    }
}

function Invoke-FreshWinInstallerProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 600,
        [int[]]$ExpectedExitCodes = @(0, 1641, 3010),
        [scriptblock]$ProcessInvoker
    )

    if ($null -ne $ProcessInvoker) {
        return & $ProcessInvoker $FilePath $ArgumentList
    }
    if (-not (Get-Command 'Invoke-FreshWinProcess' -ErrorAction SilentlyContinue)) {
        throw 'FreshWin safe process runner is not loaded.'
    }
    return Invoke-FreshWinProcess -FilePath $FilePath -ArgumentList $ArgumentList `
        -TimeoutSeconds $TimeoutSeconds -ExpectedExitCodes $ExpectedExitCodes
}

function Get-FreshWinInstallerExitPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourceType)

    $successful = @(0, 1641, 3010)
    $reboot = @(1641, 3010)
    $retryAfterReboot = @()
    if ($SourceType -in @('winget', 'msstore')) {
        # WinGet converts installer reboot outcomes into App Installer HRESULTs.
        # These two codes mean that the installer completed and Windows must
        # restart.  0x8A15010A (-1978334966) deliberately remains a failure:
        # it means Windows must restart *before* the install can be retried.
        $wingetCompletedRebootCodes = @(-1978334967, -1978334965)
        $successful += $wingetCompletedRebootCodes
        $reboot += $wingetCompletedRebootCodes
        $retryAfterReboot = @(-1978334966)
    }

    return [pscustomobject]@{
        SuccessfulExitCodes = [int[]]$successful
        RebootExitCodes = [int[]]$reboot
        RetryAfterRebootExitCodes = [int[]]$retryAfterReboot
    }
}

function Get-FreshWinInstallArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$ResolvedSource,
        [Parameter(Mandatory = $true)][ValidateSet('INSTALL', 'UPDATE', 'REPAIR')][string]$Action
    )

    if ($ResolvedSource.SourceType -in @('winget', 'msstore')) {
        $verb = if ($Action -eq 'UPDATE') { 'upgrade' } else { 'install' }
        $arguments = @(
            $verb, '--id', [string]$ResolvedSource.PackageManagerId,
            '--exact', '--disable-interactivity'
        )
        if ([bool](Get-FreshWinPropertyValue -InputObject $ResolvedSource -Name 'Silent' -Default $true)) {
            $arguments += '--silent'
        }
        $sourceName = [string](Get-FreshWinPropertyValue -InputObject $ResolvedSource -Name 'SourceName' -Default $ResolvedSource.SourceType)
        if ($sourceName -in @('winget', 'msstore')) { $arguments += @('--source', $sourceName) }
        if ($ResolvedSource.SourceType -eq 'winget') {
            $installScope = ([string](Get-FreshWinPropertyValue -InputObject $ResolvedSource -Name 'InstallScope' -Default 'either')).ToLowerInvariant()
            if ($installScope -in @('machine', 'user')) { $arguments += @('--scope', $installScope) }
        }
        if ($Action -eq 'REPAIR') { $arguments += '--force' }
        return $arguments
    }

    if ($ResolvedSource.SourceType -eq 'windows-feature') {
        $featureName = [string](Get-FreshWinPropertyValue -InputObject $ResolvedSource -Name 'FeatureName' -Default '')
        $featureNames = if (-not [string]::IsNullOrWhiteSpace($featureName)) { @($featureName) }
            else { @(Get-FreshWinPropertyValue -InputObject $ResolvedSource -Name 'FeatureNames' -Default @()) }
        $arguments = @('/Online', '/Enable-Feature')
        foreach ($featureName in $featureNames) { $arguments += "/FeatureName:$([string]$featureName)" }
        return @($arguments + @('/All', '/NoRestart'))
    }

    return @()
}

function Invoke-FreshWinPackageInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [Parameter(Mandatory = $true)][ValidateSet('INSTALL', 'UPDATE', 'REPAIR')][string]$Action,
        [AllowNull()][object]$ResolvedSource,
        [switch]$DryRun,
        [bool]$IsAdministrator = $false,
        [ValidateRange(1, 3)][int]$MaxAttempts = 3,
        [ValidateRange(0, 30)][int]$RetryDelaySeconds = 2,
        [scriptblock]$ProcessInvoker
    )

    # A live call never trusts a caller-supplied executable/source envelope.
    # Re-resolve it from the validated package and protected platform tools.
    # ProcessInvoker is the explicit fixture seam used by portable tests.
    $liveWindows = if ($null -ne (Get-Command -Name Test-FreshWinResolverWindows -ErrorAction SilentlyContinue)) {
        [bool](Test-FreshWinResolverWindows)
    } else { [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT }
    if ($null -eq $ProcessInvoker -and $liveWindows) {
        $ResolvedSource = Resolve-FreshWinPackageSource -Package $Package
    }
    elseif ($null -eq $ResolvedSource) {
        $ResolvedSource = Resolve-FreshWinPackageSource -Package $Package
    }

    if ($null -eq $ProcessInvoker -and -not $liveWindows -and -not $DryRun) {
        return [pscustomobject]@{
            PackageId = [string]$Package.id; Action = $Action; Outcome = 'Blocked'; Stage = 'Platform'
            Attempts = 0; ExitCode = $null; RebootRequired = $false; ProcessResult = $null
            Message = 'Live package installation is supported only on Windows.'; OfficialUri = $null
        }
    }

    if ($ResolvedSource.Status -eq 'Manual') {
        return [pscustomobject]@{
            PackageId = [string]$Package.id; Action = $Action; Outcome = 'ManualRequired'; Stage = 'Resolve'
            Attempts = 0; ExitCode = $null; RebootRequired = $false; ProcessResult = $null
            Message = $ResolvedSource.Reason; OfficialUri = $ResolvedSource.Uri
        }
    }
    if ($ResolvedSource.Status -ne 'Resolved') {
        return [pscustomobject]@{
            PackageId = [string]$Package.id; Action = $Action; Outcome = 'Blocked'; Stage = 'Resolve'
            Attempts = 0; ExitCode = $null; RebootRequired = $false; ProcessResult = $null
            Message = $ResolvedSource.Reason; OfficialUri = $null
        }
    }

    $install = Get-FreshWinPropertyValue -InputObject $Package -Name 'install' -Default ([pscustomobject]@{})
    $requiresAdmin = [bool](Get-FreshWinPropertyValue -InputObject $install -Name 'requiresAdmin' -Default $false)
    $installMode = ([string](Get-FreshWinPropertyValue -InputObject $install -Name 'mode' -Default 'silent')).ToLowerInvariant()
    if ($installMode -eq 'interactive') {
        return [pscustomobject]@{
            PackageId = [string]$Package.id; Action = $Action; Outcome = 'ManualRequired'; Stage = 'Preflight'
            Attempts = 0; ExitCode = $null; RebootRequired = $false; ProcessResult = $null
            Message = 'This package requires an interactive vendor workflow and was not started unattended.'
            OfficialUri = [string](Get-FreshWinPropertyValue -InputObject $Package -Name 'officialWebsite' -Default $null)
        }
    }

    $ResolvedSource | Add-Member -NotePropertyName Silent -NotePropertyValue ([bool](Get-FreshWinPropertyValue -InputObject $install -Name 'silent' -Default $true)) -Force
    $installScope = ([string](Get-FreshWinPropertyValue -InputObject $install -Name 'scope' -Default 'either')).ToLowerInvariant()
    if ($installScope -notin @('user', 'machine', 'either', 'system')) {
        return [pscustomobject]@{
            PackageId = [string]$Package.id; Action = $Action; Outcome = 'Blocked'; Stage = 'Preflight'
            Attempts = 0; ExitCode = $null; RebootRequired = $false; ProcessResult = $null
            Message = "The trusted package declares an unsupported install scope '$installScope'."; OfficialUri = $null
        }
    }
    $ResolvedSource | Add-Member -NotePropertyName InstallScope -NotePropertyValue $installScope -Force

    $argumentSets = New-Object System.Collections.Generic.List[object]
    if ($ResolvedSource.SourceType -eq 'windows-feature') {
        $featureNames = @(Get-FreshWinPropertyValue -InputObject $ResolvedSource -Name 'FeatureNames' -Default @())
        if ($featureNames.Count -eq 0) { $featureNames = @([string]$ResolvedSource.FeatureName) }
        foreach ($featureName in $featureNames) {
            $featureSource = $ResolvedSource.PSObject.Copy()
            $featureSource.FeatureName = [string]$featureName
            $argumentSets.Add([string[]]@(Get-FreshWinInstallArguments -ResolvedSource $featureSource -Action $Action))
        }
    }
    else {
        $argumentSets.Add([string[]]@(Get-FreshWinInstallArguments -ResolvedSource $ResolvedSource -Action $Action))
    }
    if ($DryRun) {
        return [pscustomobject]@{
            PackageId = [string]$Package.id; Action = $Action; Outcome = 'DryRun'; Stage = 'Validated'
            Attempts = 0; ExitCode = $null; RebootRequired = $false; ProcessResult = $null
            Message = 'Source and arguments validated; no changes were made.'; OfficialUri = $null
        }
    }
    if ($requiresAdmin -and -not $IsAdministrator) {
        return [pscustomobject]@{
            PackageId = [string]$Package.id; Action = $Action; Outcome = 'ElevationRequired'; Stage = 'Preflight'
            Attempts = 0; ExitCode = $null; RebootRequired = $false; ProcessResult = $null
            Message = 'This operation requires administrator approval.'; OfficialUri = $null
        }
    }

    $lastResult = $null
    $lastError = $null
    $attempt = 0
    $rebootExitObserved = $false
    $retryAfterRebootObserved = $false
    $exitPolicy = Get-FreshWinInstallerExitPolicy -SourceType ([string]$ResolvedSource.SourceType)
    $operationTimeoutSeconds = if ([string]$ResolvedSource.SourceType -in @('winget', 'msstore')) { 600 } else { 3600 }
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            $attemptResults = New-Object System.Collections.Generic.List[object]
            $succeeded = $true
            $exitCode = 0
            foreach ($arguments in $argumentSets) {
                $lastResult = Invoke-FreshWinInstallerProcess -FilePath ([string]$ResolvedSource.Executable) -ArgumentList ([string[]]$arguments) `
                    -TimeoutSeconds $operationTimeoutSeconds -ExpectedExitCodes ([int[]]$exitPolicy.SuccessfulExitCodes) -ProcessInvoker $ProcessInvoker
                $attemptResults.Add($lastResult)
                $exitCode = Get-FreshWinProcessExitCode -ProcessResult $lastResult
                if ($exitCode -in @($exitPolicy.RebootExitCodes)) { $rebootExitObserved = $true }
                if ($exitCode -in @($exitPolicy.RetryAfterRebootExitCodes)) { $retryAfterRebootObserved = $true }
                $processSucceeded = if ($exitCode -in @($exitPolicy.SuccessfulExitCodes)) {
                    $true
                } elseif ($null -ne $lastResult.PSObject.Properties['Succeeded']) {
                    [bool]$lastResult.Succeeded
                } else { ($exitCode -eq 0) }
                if (-not $processSucceeded) { $succeeded = $false; break }
            }
            if ($succeeded) {
                $restart = Get-FreshWinRestartBehavior -PackageOrRestart $Package
                return [pscustomobject]@{
                    PackageId = [string]$Package.id; Action = $Action; Outcome = 'ProcessSucceeded'; Stage = 'Install'
                    Attempts = $attempt; ExitCode = $exitCode; RebootRequired = ($restart -eq 'required' -or $rebootExitObserved)
                    RetryAfterReboot = $false
                    ProcessResult = $(if ($attemptResults.Count -eq 1) { $attemptResults[0] } else { $attemptResults.ToArray() })
                    Message = 'Installer process finished; verification is still required.'; OfficialUri = $null
                }
            }

            if ($retryAfterRebootObserved) { break }
            $failureClassification = Get-FreshWinInstallerFailureClassification -ProcessResult $lastResult
            if ($failureClassification.Stage -eq 'SourceAgreement') { break }
            if (-not (Test-FreshWinTransientProcessFailure -ProcessResult $lastResult)) { break }
        }
        catch {
            $lastError = $_.Exception.Message
            # An exception may have happened after a native installer started.
            # Without an observed exit code it is unsafe to launch it again.
            break
        }

        if ($attempt -lt $MaxAttempts -and $RetryDelaySeconds -gt 0) {
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    $exitCode = Get-FreshWinProcessExitCode -ProcessResult $lastResult
    $failure = Get-FreshWinInstallerFailureClassification -ProcessResult $lastResult -FallbackMessage $lastError
    return [pscustomobject]@{
        PackageId = [string]$Package.id; Action = $Action; Outcome = $failure.Outcome; Stage = $failure.Stage
        # A later sub-operation can fail after an earlier one already changed
        # Windows and returned a reboot code. Preserve that recovery boundary
        # without converting the overall operation into success.
        Attempts = $attempt; ExitCode = $exitCode
        RebootRequired = ($rebootExitObserved -or $retryAfterRebootObserved)
        RetryAfterReboot = $retryAfterRebootObserved
        ProcessResult = $lastResult
        OutputSummary = $failure.OutputSummary
        Message = if ($retryAfterRebootObserved) {
            'WinGet reported that Windows must restart before this installation can be retried. The package was not installed.'
        } else { $failure.Message }
        OfficialUri = $null
    }
}
