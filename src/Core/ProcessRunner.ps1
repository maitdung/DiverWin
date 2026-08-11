Set-StrictMode -Version Latest

function ConvertTo-FreshWinProcessArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($Argument.IndexOf([char]0) -ge 0) {
        throw 'Process arguments cannot contain a NUL character.'
    }

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashCount++
            continue
        }

        if ($character -eq [char]34) {
            if ($backslashCount -gt 0) {
                [void]$builder.Append(('\' * ($backslashCount * 2)))
            }
            [void]$builder.Append('\"')
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }

    if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-FreshWinProcessArguments {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$ArgumentList = @()
    )

    $quoted = @()
    foreach ($argument in @($ArgumentList)) {
        if ($null -eq $argument) {
            throw 'Process arguments cannot contain null values.'
        }
        $quoted += ConvertTo-FreshWinProcessArgument -Argument ([string]$argument)
    }
    return $quoted -join ' '
}

function Resolve-FreshWinExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath
    )

    if ($FilePath -match '[\r\n\x00]') {
        throw 'Executable names cannot contain control characters.'
    }

    $resolvedPath = $null
    if ([System.IO.Path]::IsPathRooted($FilePath) -or
        $FilePath.IndexOf([System.IO.Path]::DirectorySeparatorChar) -ge 0 -or
        $FilePath.IndexOf([System.IO.Path]::AltDirectorySeparatorChar) -ge 0) {
        $candidate = [System.IO.Path]::GetFullPath($FilePath)
        if (-not [System.IO.File]::Exists($candidate)) {
            throw "Executable was not found: $candidate"
        }
        $resolvedPath = $candidate
    }
    else {
        $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $command) {
            throw "Executable '$FilePath' was not found on PATH."
        }
        $resolvedPath = [string]$command.Source
        if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
            $resolvedPath = [string]$command.Path
        }
    }

    $unsafeExtensions = @('.ps1', '.psm1', '.psd1', '.bat', '.cmd', '.vbs', '.js', '.wsf')
    if ($unsafeExtensions -contains [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()) {
        throw "Script executable '$resolvedPath' is not allowed by the safe process runner."
    }

    return $resolvedPath
}

function Stop-FreshWinProcessTree {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    if ($Process.HasExited) { return $true }

    # PowerShell 7/.NET exposes Process.Kill(Boolean), which asks the operating
    # system to terminate the full descendant tree rather than only the direct
    # package-manager process.
    try {
        $treeKill = $Process.GetType().GetMethod('Kill', [Type[]]@([bool]))
        if ($null -ne $treeKill) {
            [void]$treeKill.Invoke($Process, @($true))
            return [bool]$Process.WaitForExit(10000)
        }
    }
    catch { }

    # Windows PowerShell 5.1 has no Kill(Boolean).  Use only the protected
    # operating-system taskkill binary and a numeric PID for its /T fallback.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try {
            $systemDirectory = [Environment]::SystemDirectory
            if (-not [string]::IsNullOrWhiteSpace($systemDirectory)) {
                $taskkillPath = [IO.Path]::GetFullPath((Join-Path $systemDirectory 'taskkill.exe'))
                if ([IO.File]::Exists($taskkillPath) -and
                    (([IO.File]::GetAttributes($taskkillPath) -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
                    $killInfo = New-Object Diagnostics.ProcessStartInfo
                    $killInfo.FileName = $taskkillPath
                    $killInfo.Arguments = '/PID {0} /T /F' -f [int]$Process.Id
                    $killInfo.UseShellExecute = $false
                    $killInfo.CreateNoWindow = $true
                    $killProcess = New-Object Diagnostics.Process
                    try {
                        $killProcess.StartInfo = $killInfo
                        if ($killProcess.Start()) { [void]$killProcess.WaitForExit(10000) }
                    }
                    finally { $killProcess.Dispose() }
                    if ($Process.HasExited -or $Process.WaitForExit(10000)) { return $true }
                }
            }
        }
        catch { }
    }

    try {
        $Process.Kill()
        return [bool]$Process.WaitForExit(10000)
    }
    catch { return $false }
}

function Invoke-FreshWinProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [AllowNull()]
        [string[]]$ArgumentList = @(),

        [string]$WorkingDirectory,

        [AllowNull()]
        [hashtable]$Environment = $null,

        [ValidateRange(0, 86400)]
        [int]$TimeoutSeconds = 0,

        [int[]]$ExpectedExitCodes = @(0),
        [switch]$Elevated,
        [switch]$ThrowOnError,

        [AllowNull()]
        [object]$LogContext = $null,

        [AllowNull()]
        [System.Text.Encoding]$OutputEncoding = $null,

        [string]$LogStage = 'PROCESS',
        [string]$LogAction
    )

    # Read-only commands use the same bounded runner, but must not lazily
    # initialize a logger and mutate LocalAppData. Logging is enabled only when
    # the caller supplied a context or the application already initialized one.
    $effectiveLogContext = $LogContext
    if ($null -eq $effectiveLogContext) {
        $existingLogger = Get-Variable -Name FreshWinLoggerContext -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $existingLogger -and $null -ne $existingLogger.Value) { $effectiveLogContext = $existingLogger.Value }
        # A test or embedding host may remove an explicitly initialized,
        # temporary log directory while the process-wide context remains.
        # Read-only process execution must neither recreate that directory nor
        # fail merely because optional inherited logging is no longer usable.
        if ($null -ne $effectiveLogContext) {
            $inheritedLogDirectory = [string](Get-FreshWinPropertyValue -InputObject $effectiveLogContext -Name 'LogDirectory' -Default '')
            if ([string]::IsNullOrWhiteSpace($inheritedLogDirectory) -or
                -not [System.IO.Directory]::Exists($inheritedLogDirectory)) {
                $effectiveLogContext = $null
            }
        }
    }
    $loggingEnabled = $null -ne $effectiveLogContext -and $null -ne (Get-Command -Name Write-FreshWinLog -ErrorAction SilentlyContinue)

    $resolvedPath = Resolve-FreshWinExecutablePath -FilePath $FilePath
    $nativeArguments = Join-FreshWinProcessArguments -ArgumentList $ArgumentList

    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = (Get-Location).ProviderPath
    }
    $fullWorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
    if (-not [System.IO.Directory]::Exists($fullWorkingDirectory)) {
        throw "Working directory was not found: $fullWorkingDirectory"
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $resolvedPath
    $startInfo.Arguments = $nativeArguments
    $startInfo.WorkingDirectory = $fullWorkingDirectory

    if ($Elevated) {
        if (-not (Test-FreshWinIsWindows)) {
            throw 'Controlled elevation is supported only on Windows.'
        }
        $startInfo.UseShellExecute = $true
        $startInfo.Verb = 'runas'
    }
    else {
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        if ($null -ne $OutputEncoding) {
            # Native utilities do not all emit the active console encoding.
            # Setting the redirected-stream encoding explicitly is independent
            # of the OEM code page and works on Windows PowerShell 5.1.
            $startInfo.StandardOutputEncoding = $OutputEncoding
            $startInfo.StandardErrorEncoding = $OutputEncoding
        }

        if ($null -ne $Environment) {
            foreach ($name in $Environment.Keys) {
                $nameText = [string]$name
                if ([string]::IsNullOrWhiteSpace($nameText) -or $nameText -match '[=\x00\r\n]') {
                    throw "Invalid environment variable name '$nameText'."
                }
                $value = $Environment[$name]
                if ($null -eq $value) {
                    $startInfo.EnvironmentVariables.Remove($nameText)
                }
                else {
                    $valueText = [string]$value
                    if ($valueText.IndexOf([char]0) -ge 0) {
                        throw "Environment variable '$nameText' contains a NUL character."
                    }
                    $startInfo.EnvironmentVariables[$nameText] = $valueText
                }
            }
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $startedAt = [System.DateTimeOffset]::UtcNow
    $standardOutput = ''
    $standardError = ''
    $timedOut = $false
    $exitCode = $null

    try {
        if (-not $process.Start()) {
            throw "The operating system did not start '$resolvedPath'."
        }

        if (-not $Elevated) {
            $outputTask = $process.StandardOutput.ReadToEndAsync()
            $errorTask = $process.StandardError.ReadToEndAsync()
        }

        if ($TimeoutSeconds -gt 0) {
            $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        }
        else {
            $process.WaitForExit()
            $completed = $true
        }

        if (-not $completed) {
            $timedOut = $true
            [void](Stop-FreshWinProcessTree -Process $process)
        }

        if (-not $Elevated) {
            if (-not $timedOut) {
                $process.WaitForExit()
                $standardOutput = [string]$outputTask.Result
                $standardError = [string]$errorTask.Result
            }
            else {
                # A surviving descendant may still hold redirected pipe handles.
                # Never wait indefinitely for output after the timeout boundary.
                try { [void]$outputTask.Wait(2000) } catch { }
                try { [void]$errorTask.Wait(2000) } catch { }
                if ($outputTask.IsCompleted -and -not $outputTask.IsFaulted) { $standardOutput = [string]$outputTask.Result }
                if ($errorTask.IsCompleted -and -not $errorTask.IsFaulted) { $standardError = [string]$errorTask.Result }
            }
        }
        if (-not $timedOut) {
            $exitCode = [int]$process.ExitCode
        }
    }
    catch {
        $safeMessage = Protect-FreshWinSensitiveText -Text $_.Exception.Message
        if ($loggingEnabled) {
            Write-FreshWinLog -Level ERROR -Stage $LogStage -Action $LogAction `
                -Result 'FailedToStart' -Message $safeMessage -Context $effectiveLogContext
        }
        throw "Unable to run '$resolvedPath': $safeMessage"
    }
    finally {
        $process.Dispose()
    }

    $duration = [System.DateTimeOffset]::UtcNow - $startedAt
    $succeeded = -not $timedOut -and $ExpectedExitCodes -contains $exitCode
    $result = [PSCustomObject]@{
        FilePath       = $resolvedPath
        ArgumentList   = @($ArgumentList)
        ExitCode       = $exitCode
        StandardOutput = Protect-FreshWinSensitiveText -Text $standardOutput
        StandardError  = Protect-FreshWinSensitiveText -Text $standardError
        TimedOut       = $timedOut
        Succeeded      = $succeeded
        Duration       = $duration
    }

    if ($loggingEnabled) {
        $logResult = if ($succeeded) { 'Succeeded' } elseif ($timedOut) { 'TimedOut' } else { 'Failed' }
        Write-FreshWinLog -Level $(if ($succeeded) { 'INFO' } else { 'ERROR' }) `
            -Stage $LogStage `
            -Action $LogAction `
            -Result $logResult `
            -ExitCode $exitCode `
            -Message (Protect-FreshWinSensitiveText -Text $standardError) `
            -Data ([PSCustomObject]@{ executable = $resolvedPath; durationMs = [int]$duration.TotalMilliseconds }) `
            -Context $effectiveLogContext
    }

    if ($ThrowOnError -and -not $succeeded) {
        if ($timedOut) {
            throw "Process '$resolvedPath' exceeded the $TimeoutSeconds second timeout."
        }
        throw "Process '$resolvedPath' exited with code $exitCode."
    }

    return $result
}
