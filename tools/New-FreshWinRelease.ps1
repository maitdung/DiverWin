#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][DateTimeOffset]$PublishedAtUtc,
    [ValidateSet('stable','preview')][string]$Channel = 'stable'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-FreshWinReleaseText {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $utf8 = New-Object Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8)
}

function Get-FreshWinReleaseSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose(); $stream.Dispose() }
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Repository must be an owner/name GitHub repository identifier.' }
if (-not [IO.Directory]::Exists($ProjectRoot)) { throw 'Project root was not found.' }
$moduleManifestPath = Join-Path $ProjectRoot 'FreshWin.psd1'
$bootstrapTemplatePath = Join-Path $ProjectRoot 'bootstrap.ps1'
$installerCommonPath = Join-Path $ProjectRoot 'installer\Install.Common.ps1'
foreach ($required in @($moduleManifestPath, $bootstrapTemplatePath, $installerCommonPath)) {
    if (-not [IO.File]::Exists($required)) { throw "Required release source file is missing: $required" }
}

$moduleManifest = Import-PowerShellDataFile -LiteralPath $moduleManifestPath -ErrorAction Stop
$version = [string]$moduleManifest.ModuleVersion
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'FreshWin.psd1 contains an invalid release version.' }
. $installerCommonPath
$payloadRecords = @(Get-FreshWinInstallPayloadRecords -SourceRoot $ProjectRoot | Sort-Object Path)
if ($payloadRecords.Count -eq 0) { throw 'The release payload is empty.' }

if (-not [IO.Directory]::Exists($OutputDirectory)) { [void][IO.Directory]::CreateDirectory($OutputDirectory) }
$artifactName = "FreshWin-$version.zip"
$checksumName = "FreshWin-$version.sha256"
$metadataName = 'FreshWin-stable.release.json'
$archivePath = Join-Path $OutputDirectory $artifactName
$checksumPath = Join-Path $OutputDirectory $checksumName
$metadataPath = Join-Path $OutputDirectory $metadataName
$bootstrapPath = Join-Path $OutputDirectory 'bootstrap.ps1'
foreach ($target in @($archivePath, $checksumPath, $metadataPath, $bootstrapPath)) {
    if ([IO.File]::Exists($target)) { throw "Release output already exists: $target" }
}

$releaseManifest = [pscustomobject][ordered]@{
    schemaVersion = 'FreshWin.ReleaseManifest/1'
    version = $version
    files = @($payloadRecords | ForEach-Object {
        [pscustomobject][ordered]@{ path=[string]$_.Path; sha256=[string]$_.Sha256; length=[long]$_.Length }
    })
}
$manifestJson = (ConvertTo-Json $releaseManifest -Depth 8) -replace "`r`n", "`n"
$manifestBytes = (New-Object Text.UTF8Encoding -ArgumentList $false).GetBytes($manifestJson)

Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$archive = New-Object IO.Compression.ZipArchive -ArgumentList $archiveStream, ([IO.Compression.ZipArchiveMode]::Create), $false
$fixedTimestamp = [DateTimeOffset]'1980-01-01T00:00:00Z'
try {
    foreach ($record in $payloadRecords) {
        $entryName = ([string]$record.Path).Replace('\','/')
        $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $fixedTimestamp
        $entryStream = $entry.Open()
        $sourceStream = [IO.File]::OpenRead((Join-Path $ProjectRoot $entryName.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        try { $sourceStream.CopyTo($entryStream) }
        finally { $sourceStream.Dispose(); $entryStream.Dispose() }
    }
    $manifestEntry = $archive.CreateEntry('release-manifest.json', [IO.Compression.CompressionLevel]::Optimal)
    $manifestEntry.LastWriteTime = $fixedTimestamp
    $manifestStream = $manifestEntry.Open()
    try { $manifestStream.Write($manifestBytes, 0, $manifestBytes.Length) }
    finally { $manifestStream.Dispose() }
}
finally { $archive.Dispose(); $archiveStream.Dispose() }

$archiveHash = Get-FreshWinReleaseSha256 -Path $archivePath
Write-FreshWinReleaseText -Path $checksumPath -Text ("{0} *{1}`n" -f $archiveHash, $artifactName)
$releaseBase = "https://github.com/$Repository/releases/download/v$version"
$packageUri = "$releaseBase/$artifactName"
$metadataUri = "https://github.com/$Repository/releases/latest/download/$metadataName"
$metadata = [pscustomobject][ordered]@{
    schemaVersion = 1
    channel = $Channel
    version = $version
    publishedAtUtc = $PublishedAtUtc.ToUniversalTime().ToString('o')
    packageUri = $packageUri
    sha256 = $archiveHash
    minimumPowerShellVersion = '5.1'
    notes = "FreshWin $version"
}
Write-FreshWinReleaseText -Path $metadataPath -Text (ConvertTo-Json $metadata -Depth 4)

$bootstrapTemplate = [IO.File]::ReadAllText($bootstrapTemplatePath)
$token = '__FRESHWIN_OFFICIAL_METADATA_URL__'
if (($bootstrapTemplate.Split(@($token), [StringSplitOptions]::None).Count - 1) -ne 1) { throw 'bootstrap.ps1 must contain exactly one official metadata URL token.' }
Write-FreshWinReleaseText -Path $bootstrapPath -Text $bootstrapTemplate.Replace($token, $metadataUri)

[pscustomobject][ordered]@{
    Version = $version
    ArchivePath = $archivePath
    ArchiveSha256 = $archiveHash
    ChecksumPath = $checksumPath
    MetadataPath = $metadataPath
    BootstrapPath = $bootstrapPath
    PayloadFileCount = $payloadRecords.Count
}
