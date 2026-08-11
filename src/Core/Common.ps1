Set-StrictMode -Version Latest

$freshWinModuleManifestPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\FreshWin.psd1'))
if (-not [IO.File]::Exists($freshWinModuleManifestPath)) { throw 'FreshWin.psd1 is required to resolve the product version.' }
$freshWinModuleManifest = Import-PowerShellDataFile -LiteralPath $freshWinModuleManifestPath -ErrorAction Stop
$script:FreshWinVersion = [string]$freshWinModuleManifest.ModuleVersion
if ($script:FreshWinVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'FreshWin.psd1 contains an invalid product version.' }

function Get-FreshWinVersion {
    [CmdletBinding()]
    param()

    return $script:FreshWinVersion
}

function Test-FreshWinIsWindows {
    [CmdletBinding()]
    param()

    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Test-FreshWinHasProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }

    return $null -ne $InputObject.PSObject.Properties[$Name]
}

function Get-FreshWinPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [AllowNull()]
        [object]$Default = $null
    )

    if (-not (Test-FreshWinHasProperty -InputObject $InputObject -Name $Name)) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject[$Name]
    }

    return $InputObject.PSObject.Properties[$Name].Value
}

function ConvertTo-FreshWinArray {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value)
    }

    return @($Value)
}

function Write-FreshWinUtf8File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,

        [switch]$Atomic,

        [switch]$CreateNew
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "A parent directory is required for '$Path'."
    }

    if (-not [System.IO.Directory]::Exists($directory)) {
        [void][System.IO.Directory]::CreateDirectory($directory)
    }

    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    if ($CreateNew) {
        $bytes = $encoding.GetBytes($Content)
        $stream = [System.IO.File]::Open(
            $fullPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        }
        finally { $stream.Dispose() }
        return $fullPath
    }
    if (-not $Atomic) {
        [System.IO.File]::WriteAllText($fullPath, $Content, $encoding)
        return $fullPath
    }

    $temporaryPath = Join-Path $directory ([System.IO.Path]::GetRandomFileName())
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Content, $encoding)

        if ([System.IO.File]::Exists($fullPath)) {
            $backupPath = "$fullPath.bak"
            try {
                [System.IO.File]::Replace($temporaryPath, $fullPath, $backupPath, $true)
            }
            catch {
                # File.Replace is unavailable on a few non-NTFS test filesystems.
                [System.IO.File]::Copy($fullPath, $backupPath, $true)
                [System.IO.File]::Copy($temporaryPath, $fullPath, $true)
                [System.IO.File]::Delete($temporaryPath)
            }
        }
        else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }

        return $fullPath
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Write-FreshWinJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value,

        [ValidateRange(2, 100)]
        [int]$Depth = 20,

        [switch]$Atomic,

        [switch]$CreateNew
    )

    $json = ConvertTo-Json -InputObject $Value -Depth $Depth
    return Write-FreshWinUtf8File -Path $Path -Content $json -Atomic:$Atomic -CreateNew:$CreateNew
}

function Read-FreshWinJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [switch]$AllowMissing
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($fullPath)) {
        if ($AllowMissing) {
            return $null
        }

        throw "JSON file was not found: $fullPath"
    }

    try {
        $content = [System.IO.File]::ReadAllText($fullPath)
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw 'The file is empty.'
        }

        return ConvertFrom-Json -InputObject $content -ErrorAction Stop
    }
    catch {
        throw "Unable to read JSON file '$fullPath': $($_.Exception.Message)"
    }
}

function Test-FreshWinSafeName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name
    )

    return $Name -match '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$'
}

function ConvertTo-FreshWinDateTimeOffset {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]([DateTime]$Value) }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParseExact(
        [string]$Value,
        'o',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )) { return $parsed }
    # Accept invariant ISO-8601 timestamps emitted by older JSONL writers that
    # omitted the round-trip format's fractional seconds. PowerShell 7 may
    # deserialize these to DateTime, while Windows PowerShell 5.1 leaves them
    # as strings.
    if ([DateTimeOffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal),
        [ref]$parsed
    )) { return $parsed }
    return $null
}

function Get-FreshWinRestartBehavior {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$PackageOrRestart
    )

    $restart = $PackageOrRestart
    if (Test-FreshWinHasProperty -InputObject $PackageOrRestart -Name 'restart') {
        $restart = Get-FreshWinPropertyValue -InputObject $PackageOrRestart -Name 'restart'
    }

    if ($null -eq $restart) {
        return 'none'
    }
    if ($restart -is [bool]) {
        return $(if ($restart) { 'required' } else { 'none' })
    }
    if ($restart -is [string]) {
        $value = $restart.Trim().ToLowerInvariant()
        if ($value -in @('none', 'possible', 'required')) {
            return $value
        }
        return 'none'
    }

    $required = [bool](Get-FreshWinPropertyValue -InputObject $restart -Name 'required' -Default $false)
    $behavior = [string](Get-FreshWinPropertyValue -InputObject $restart -Name 'behavior' -Default '')
    if ($required) {
        return 'required'
    }
    $behavior = $behavior.Trim().ToLowerInvariant()
    if ($behavior -in @('none', 'possible', 'required')) {
        return $behavior
    }
    return 'none'
}
