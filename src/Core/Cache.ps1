Set-StrictMode -Version Latest

function Get-FreshWinCacheEntryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$CacheDirectory
    )

    if (-not (Test-FreshWinSafeName -Name $Key)) { throw "Cache key '$Key' is invalid." }
    if ([string]::IsNullOrWhiteSpace($CacheDirectory)) { $CacheDirectory = (Get-FreshWinPaths).Cache }
    $directory = [IO.Path]::GetFullPath($CacheDirectory)
    return Join-Path $directory "$Key.json"
}

function Set-FreshWinCacheEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowNull()][object]$Value,
        [ValidateRange(1, 525600)][int]$TimeToLiveMinutes = 60,
        [string]$CacheDirectory
    )

    $path = Get-FreshWinCacheEntryPath -Key $Key -CacheDirectory $CacheDirectory
    $savedAt = [DateTimeOffset]::UtcNow
    $entry = [pscustomobject][ordered]@{
        schemaVersion = 1
        key           = $Key
        savedAtUtc    = $savedAt.ToString('o')
        expiresAtUtc  = $savedAt.AddMinutes($TimeToLiveMinutes).ToString('o')
        value         = $Value
    }
    [void](Write-FreshWinJsonFile -Path $path -Value $entry -Depth 40 -Atomic)
    return $entry
}

function Get-FreshWinCacheEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$CacheDirectory,
        [switch]$IncludeExpired,
        [switch]$Envelope
    )

    $path = Get-FreshWinCacheEntryPath -Key $Key -CacheDirectory $CacheDirectory
    if (-not [IO.File]::Exists($path)) { return $null }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Cache entries cannot be reparse points.' }
    if ($item.Length -gt 5MB) { throw "Cache entry '$Key' exceeds the 5 MB limit." }

    $entry = Read-FreshWinJsonFile -Path $path
    if ([int](Get-FreshWinPropertyValue -InputObject $entry -Name 'schemaVersion' -Default 0) -ne 1 -or
        [string](Get-FreshWinPropertyValue -InputObject $entry -Name 'key' -Default '') -cne $Key -or
        -not (Test-FreshWinHasProperty -InputObject $entry -Name 'value')) {
        throw "Cache entry '$Key' is invalid."
    }
    $savedAt = ConvertTo-FreshWinDateTimeOffset -Value $entry.savedAtUtc
    $expiresAt = ConvertTo-FreshWinDateTimeOffset -Value $entry.expiresAtUtc
    if ($null -eq $savedAt -or $null -eq $expiresAt -or
        $expiresAt -lt $savedAt) {
        throw "Cache entry '$Key' has invalid timestamps."
    }
    $expired = $expiresAt -le [DateTimeOffset]::UtcNow
    if ($expired -and -not $IncludeExpired) { return $null }
    $entry | Add-Member -NotePropertyName Expired -NotePropertyValue $expired -Force
    if ($Envelope) { return $entry }
    return Get-FreshWinPropertyValue -InputObject $entry -Name 'value'
}

function Remove-FreshWinCacheEntry {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$CacheDirectory
    )

    $path = Get-FreshWinCacheEntryPath -Key $Key -CacheDirectory $CacheDirectory
    if ([IO.File]::Exists($path) -and $PSCmdlet.ShouldProcess($path, 'Remove FreshWin cache entry')) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Cache entries cannot be reparse points.' }
        Remove-Item -LiteralPath $path -Force
        return $true
    }
    return $false
}
