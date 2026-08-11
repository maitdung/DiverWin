Set-StrictMode -Version Latest

$script:FreshWinLoggerContext = $null

function Test-FreshWinSensitiveKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name
    )

    return $Name -match '(?i)(password|passwd|pwd|token|secret|credential|authorization|cookie|api.?key|private.?key|connection.?string)'
}

function Protect-FreshWinSensitiveText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return $null
    }

    $protected = $Text
    # When the complete value is JSON, parse it and apply the same recursive key
    # policy used for structured log data.  This covers secret-valued objects and
    # arrays that a scalar regular expression cannot safely balance.
    $trimmedText = $Text.Trim()
    if ($Text.Length -le 1048576 -and
        (($trimmedText.StartsWith('{') -and $trimmedText.EndsWith('}')) -or
         ($trimmedText.StartsWith('[') -and $trimmedText.EndsWith(']')))) {
        try {
            $jsonValue = ConvertFrom-Json -InputObject $trimmedText -ErrorAction Stop
            $safeJsonValue = Protect-FreshWinSensitiveData -InputObject $jsonValue
            return ConvertTo-Json -InputObject $safeJsonValue -Depth 20 -Compress
        }
        catch {
            # It may only resemble JSON; continue with text-oriented redaction.
        }
    }
    # Redact quoted JSON values before applying the more general assignment
    # matcher.  The previous pattern did not match the quote between a JSON key
    # and its colon (for example, {"access_token":"value"}).
    $jsonSecretPattern = '(?i)(["''](?:password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|api[_-]?key|secret|authorization|cookie|private[_-]?key|connection[_-]?string)["'']\s*:\s*)["''](?:\\.|[^"''\\])*["'']'
    $protected = [System.Text.RegularExpressions.Regex]::Replace(
        $protected,
        $jsonSecretPattern,
        '$1"[REDACTED]"'
    )
    $assignmentPattern = '(?i)\b(password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|api[_-]?key|secret|authorization)\b(\s*[:=]\s*)([^,;\s]+)'
    $protected = [System.Text.RegularExpressions.Regex]::Replace(
        $protected,
        $assignmentPattern,
        '$1$2[REDACTED]'
    )
    $protected = [System.Text.RegularExpressions.Regex]::Replace(
        $protected,
        '(?i)(--?(?:password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|api[_-]?key|secret|authorization)\s+)(?:"(?:\\.|[^"\\])*"|''(?:''''|[^''])*''|\S+)',
        '$1[REDACTED]'
    )
    $protected = [System.Text.RegularExpressions.Regex]::Replace(
        $protected,
        '(?i)([?&](?:password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|api[_-]?key|secret|authorization)=)[^&#\s]*',
        '$1[REDACTED]'
    )
    $protected = [System.Text.RegularExpressions.Regex]::Replace(
        $protected,
        '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+',
        'Bearer [REDACTED]'
    )
    $protected = [System.Text.RegularExpressions.Regex]::Replace(
        $protected,
        '(?i)(https?://[^:/\s]+:)[^@\s/]+@',
        '$1[REDACTED]@'
    )
    $protected = [System.Text.RegularExpressions.Regex]::Replace(
        $protected,
        '\bAKIA[A-Z0-9]{16}\b',
        '[REDACTED_AWS_KEY]'
    )
    $protected = [System.Text.RegularExpressions.Regex]::Replace(
        $protected,
        '(?i)\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b',
        '[REDACTED_TOKEN]'
    )
    $protected = [System.Text.RegularExpressions.Regex]::Replace(
        $protected,
        '(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----',
        '[REDACTED_PRIVATE_KEY]'
    )

    return $protected
}

function Protect-FreshWinSensitiveData {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,

        [ValidateRange(0, 100)]
        [int]$Depth = 0,

        [ValidateRange(1, 100)]
        [int]$MaximumDepth = 20
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($Depth -ge $MaximumDepth) {
        return '[TRUNCATED]'
    }
    if ($InputObject -is [System.Security.SecureString] -or
        $InputObject -is [System.Management.Automation.PSCredential]) {
        return '[REDACTED]'
    }
    if ($InputObject -is [string]) {
        return Protect-FreshWinSensitiveText -Text $InputObject
    }
    if ($InputObject -is [datetime]) {
        return $InputObject.ToUniversalTime().ToString('o')
    }
    if ($InputObject -is [System.DateTimeOffset]) {
        return $InputObject.ToUniversalTime().ToString('o')
    }
    if ($InputObject -is [ValueType]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $safeDictionary = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $keyText = [string]$key
            if (Test-FreshWinSensitiveKey -Name $keyText) {
                $safeDictionary[$keyText] = '[REDACTED]'
            }
            else {
                $safeDictionary[$keyText] = Protect-FreshWinSensitiveData `
                    -InputObject $InputObject[$key] `
                    -Depth ($Depth + 1) `
                    -MaximumDepth $MaximumDepth
            }
        }
        return [PSCustomObject]$safeDictionary
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $safeItems = @()
        foreach ($item in $InputObject) {
            $safeItems += ,(Protect-FreshWinSensitiveData `
                -InputObject $item `
                -Depth ($Depth + 1) `
                -MaximumDepth $MaximumDepth)
        }
        return ,$safeItems
    }

    $safeObject = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) {
        if (-not $property.IsGettable) {
            continue
        }

        if (Test-FreshWinSensitiveKey -Name $property.Name) {
            $safeObject[$property.Name] = '[REDACTED]'
        }
        else {
            try {
                $propertyValue = $property.Value
                $safeObject[$property.Name] = Protect-FreshWinSensitiveData `
                    -InputObject $propertyValue `
                    -Depth ($Depth + 1) `
                    -MaximumDepth $MaximumDepth
            }
            catch {
                $safeObject[$property.Name] = '[UNREADABLE]'
            }
        }
    }

    return [PSCustomObject]$safeObject
}

function Initialize-FreshWinLogger {
    [CmdletBinding()]
    param(
        [string]$LogDirectory,
        [ValidateNotNullOrEmpty()]
        [string]$Version = '0.1.0',
        [string]$OsBuild = ([System.Environment]::OSVersion.Version.ToString()),
        [switch]$VerboseTerminal
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = (Get-FreshWinPaths).Logs
    }

    $fullDirectory = [System.IO.Path]::GetFullPath($LogDirectory)
    if (-not [System.IO.Directory]::Exists($fullDirectory)) {
        [void][System.IO.Directory]::CreateDirectory($fullDirectory)
    }

    $script:FreshWinLoggerContext = [PSCustomObject]@{
        LogDirectory   = $fullDirectory
        Version        = $Version
        OsBuild        = Protect-FreshWinSensitiveText -Text $OsBuild
        VerboseTerminal = [bool]$VerboseTerminal
    }
    return $script:FreshWinLoggerContext
}

function Get-FreshWinLoggerContext {
    [CmdletBinding()]
    param()

    if ($null -eq $script:FreshWinLoggerContext) {
        return Initialize-FreshWinLogger
    }
    return $script:FreshWinLoggerContext
}

function Get-FreshWinLogPath {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Context = $null,
        [datetime]$Date = (Get-Date)
    )

    if ($null -eq $Context) {
        $Context = Get-FreshWinLoggerContext
    }
    return Join-Path $Context.LogDirectory ('freshwin-{0}.jsonl' -f $Date.ToString('yyyy-MM-dd'))
}

function Get-FreshWinLogHistory {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 500)]
        [int]$Last = 50,

        [ValidateRange(1, 31)]
        [int]$MaximumFiles = 31,

        [string]$LogDirectory
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = (Get-FreshWinPaths).Logs
    }

    $directory = [System.IO.Path]::GetFullPath($LogDirectory)
    if (-not [System.IO.Directory]::Exists($directory)) { return }

    $directoryItem = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
    if (($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The FreshWin log directory cannot be a reparse point.'
    }

    # Read only a bounded tail from a bounded number of daily files. A history
    # query must not turn an unexpectedly large or malformed log into an
    # unbounded memory operation. Oversized files remain available to an
    # administrator for offline inspection, but are not rendered by FreshWin.
    $files = @(Get-ChildItem -LiteralPath $directory -Filter 'freshwin-*.jsonl' -File -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '^freshwin-\d{4}-\d{2}-\d{2}\.jsonl$' } |
        Sort-Object Name -Descending |
        Select-Object -First $MaximumFiles)

    $records = New-Object System.Collections.Generic.List[object]
    # Read a bounded surplus so malformed/unsupported lines near the end do not
    # prevent the caller from receiving the requested number of valid records.
    $tailCount = [Math]::Min(2000, [Math]::Max($Last, ($Last * 4)))
    foreach ($file in $files) {
        if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $file.Length -gt 16MB) {
            continue
        }

        foreach ($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Tail $tailCount -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace([string]$line) -or ([string]$line).Length -gt 65536) { continue }
            try { $raw = ConvertFrom-Json -InputObject ([string]$line) -ErrorAction Stop }
            catch { continue }

            $timestamp = ConvertTo-FreshWinDateTimeOffset -Value (Get-FreshWinPropertyValue -InputObject $raw -Name 'timestamp' -Default $null)
            if ($null -eq $timestamp) { continue }

            # Apply the current redaction policy again. This also protects users
            # when displaying legacy records written by an older FreshWin build.
            $safe = Protect-FreshWinSensitiveData -InputObject $raw
            $data = Get-FreshWinPropertyValue -InputObject $safe -Name 'data' -Default $null
            $packageId = [string](Get-FreshWinPropertyValue -InputObject $safe -Name 'packageId' -Default '')
            if ([string]::IsNullOrWhiteSpace($packageId)) {
                $packageId = [string](Get-FreshWinPropertyValue -InputObject $data -Name 'packageId' -Default '')
            }
            $result = [string](Get-FreshWinPropertyValue -InputObject $safe -Name 'result' -Default '')
            if ([string]::IsNullOrWhiteSpace($result)) {
                $result = [string](Get-FreshWinPropertyValue -InputObject $data -Name 'result' -Default '')
            }
            $message = [string](Get-FreshWinPropertyValue -InputObject $safe -Name 'message' -Default '')
            $level = [string](Get-FreshWinPropertyValue -InputObject $safe -Name 'level' -Default '')
            $errorSummary = if ($level -eq 'ERROR' -or $result -match '(?i)failed|blocked|timedout|unknown') { $message } else { '' }

            $records.Add([pscustomobject][ordered]@{
                TimestampUtc = $timestamp.ToUniversalTime().ToString('o')
                Version      = [string](Get-FreshWinPropertyValue -InputObject $safe -Name 'version' -Default '')
                OsBuild      = [string](Get-FreshWinPropertyValue -InputObject $safe -Name 'osBuild' -Default '')
                Action       = [string](Get-FreshWinPropertyValue -InputObject $safe -Name 'action' -Default '')
                PackageId    = $packageId
                Stage        = [string](Get-FreshWinPropertyValue -InputObject $safe -Name 'stage' -Default '')
                Result       = $result
                ExitCode     = Get-FreshWinPropertyValue -InputObject $safe -Name 'exitCode' -Default $null
                ErrorSummary = $errorSummary
            })
        }
    }

    $records | Sort-Object TimestampUtc -Descending | Select-Object -First $Last
}

function Write-FreshWinLog {
    [CmdletBinding()]
    param(
        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Stage,

        [string]$Action,
        [string]$PackageId,
        [string]$Result,
        [Nullable[int]]$ExitCode = $null,
        [string]$Message,
        [AllowNull()]
        [object]$Data = $null,
        [AllowNull()]
        [object]$Context = $null,
        [switch]$PassThru
    )

    if ($null -eq $Context) {
        $Context = Get-FreshWinLoggerContext
    }

    $record = [ordered]@{
        timestamp = [System.DateTimeOffset]::UtcNow.ToString('o')
        version   = [string]$Context.Version
        osBuild   = [string](Get-FreshWinPropertyValue -InputObject $Context -Name 'OsBuild' -Default '')
        level     = $Level
        stage     = $Stage.ToUpperInvariant()
        action    = Protect-FreshWinSensitiveText -Text $Action
        packageId = Protect-FreshWinSensitiveText -Text $PackageId
        result    = Protect-FreshWinSensitiveText -Text $Result
        exitCode  = $ExitCode
        message   = Protect-FreshWinSensitiveText -Text $Message
        data      = Protect-FreshWinSensitiveData -InputObject $Data
    }

    $json = ConvertTo-Json -InputObject ([PSCustomObject]$record) -Depth 20 -Compress
    $logPath = Get-FreshWinLogPath -Context $Context
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $writer = New-Object System.IO.StreamWriter -ArgumentList $logPath, $true, $encoding
    try {
        $writer.WriteLine($json)
    }
    finally {
        $writer.Dispose()
    }

    if ($Context.VerboseTerminal) {
        Write-Verbose -Message (Protect-FreshWinSensitiveText -Text "[$Stage] $Message") -Verbose
    }

    if ($PassThru) {
        return [PSCustomObject]$record
    }
}
