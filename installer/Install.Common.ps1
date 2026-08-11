Set-StrictMode -Version 2.0

function ConvertTo-FreshWinComparablePathEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = $Path.Trim().Trim('"').TrimEnd([char]'\', [char]'/')
    if ([string]::IsNullOrWhiteSpace($candidate)) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
    try {
        if ([IO.Path]::IsPathRooted($expanded)) {
            return [IO.Path]::GetFullPath($expanded).TrimEnd([char]'\', [char]'/')
        }
    }
    catch { }
    return $expanded
}

function Add-FreshWinPathEntryValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$CurrentValue,
        [Parameter(Mandatory = $true)][string]$Entry
    )

    $normalizedEntry = ConvertTo-FreshWinComparablePathEntry -Path $Entry
    if ([string]::IsNullOrWhiteSpace($normalizedEntry) -or -not [IO.Path]::IsPathRooted($normalizedEntry)) {
        throw 'The FreshWin PATH entry must be an absolute path.'
    }
    $entries = New-Object Collections.Generic.List[string]
    $found = $false
    foreach ($item in @([string]$CurrentValue -split ';')) {
        $trimmed = [string]$item
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ([string]::Equals((ConvertTo-FreshWinComparablePathEntry -Path $trimmed), $normalizedEntry, [StringComparison]::OrdinalIgnoreCase)) {
            if (-not $found) { $entries.Add($Entry); $found = $true }
            continue
        }
        $entries.Add($trimmed)
    }
    if (-not $found) { $entries.Add($Entry) }
    return [string]::Join(';', $entries.ToArray())
}

function Remove-FreshWinPathEntryValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$CurrentValue,
        [Parameter(Mandatory = $true)][string]$Entry
    )

    $normalizedEntry = ConvertTo-FreshWinComparablePathEntry -Path $Entry
    $entries = New-Object Collections.Generic.List[string]
    foreach ($item in @([string]$CurrentValue -split ';')) {
        $trimmed = [string]$item
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ([string]::Equals((ConvertTo-FreshWinComparablePathEntry -Path $trimmed), $normalizedEntry, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $entries.Add($trimmed)
    }
    return [string]::Join(';', $entries.ToArray())
}

function Get-FreshWinInstallPayloadRelativePaths {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    $root = [IO.Path]::GetFullPath($SourceRoot)
    $relativePaths = New-Object Collections.Generic.List[string]
    foreach ($fileName in @('FreshWin.ps1','FreshWin.psd1','FreshWin.psm1','install.cmd','install.ps1','uninstall.ps1')) {
        $path = Join-Path $root $fileName
        if (-not [IO.File]::Exists($path)) { throw "Required installation file is missing: $fileName" }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installation payload cannot contain a reparse point: $path" }
        $relativePaths.Add($fileName)
    }
    # bootstrap.ps1 was introduced as an installed release-validation helper
    # after the original install-manifest schema. Treat it as production input
    # when present while preserving validation/update compatibility with older
    # protected installs whose recorded payload predates the file.
    $bootstrapPath = Join-Path $root 'bootstrap.ps1'
    if ([IO.File]::Exists($bootstrapPath)) {
        $bootstrapItem = Get-Item -LiteralPath $bootstrapPath -Force -ErrorAction Stop
        if (($bootstrapItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installation payload cannot contain a reparse point: $bootstrapPath" }
        $relativePaths.Add('bootstrap.ps1')
    }
    foreach ($relativeDirectory in @('bin','catalog','locales','profiles','src','installer')) {
        $directory = Join-Path $root $relativeDirectory
        if (-not [IO.Directory]::Exists($directory)) { throw "Required installation directory is missing: $relativeDirectory" }
        $pending = New-Object Collections.Generic.Stack[string]
        $pending.Push($directory)
        $entryCount = 0
        while ($pending.Count -gt 0) {
            $current = $pending.Pop()
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
                $entryCount++
                if ($entryCount -gt 20000) { throw "Installation payload directory is too large: $relativeDirectory" }
                $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installation payload cannot contain a reparse point: $entry" }
                if ($item -is [IO.DirectoryInfo]) { $pending.Push($item.FullName); continue }
                if ($item -isnot [IO.FileInfo]) { throw "Installation payload contains an unsupported filesystem object: $entry" }
                $relative = $item.FullName.Substring($root.TrimEnd([char]'\', [char]'/').Length).TrimStart([char]'\', [char]'/')
                $relativePaths.Add($relative)
            }
        }
    }
    return @($relativePaths | Sort-Object -Unique)
}

function Get-FreshWinInstallPayloadRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    $root = [IO.Path]::GetFullPath($SourceRoot)
    $records = New-Object Collections.Generic.List[object]
    foreach ($relativePath in @(Get-FreshWinInstallPayloadRelativePaths -SourceRoot $root)) {
        $path = Join-Path $root $relativePath
        $hash = [Security.Cryptography.SHA256]::Create()
        $stream = $null
        try {
            $stream = [IO.File]::OpenRead($path)
            $sha256 = ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
            $hash.Dispose()
        }
        $records.Add([pscustomobject][ordered]@{ Path=$relativePath.Replace('\','/'); Sha256=$sha256; Length=[long](Get-Item -LiteralPath $path -Force).Length })
    }
    return $records.ToArray()
}

function Get-FreshWinInstallPayloadDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Records)

    $lines = @($Records | Sort-Object Path | ForEach-Object { '{0}|{1}|{2}' -f $_.Path, $_.Sha256, $_.Length })
    $bytes = (New-Object Text.UTF8Encoding -ArgumentList $false).GetBytes(($lines -join "`n"))
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
