#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$MetadataUri,
    [switch]$LibraryMode
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:FreshWinOfficialMetadataUri = '__FRESHWIN_OFFICIAL_METADATA_URL__'
$script:FreshWinBootstrapAllowedHosts = @('github.com','objects.githubusercontent.com','release-assets.githubusercontent.com')

function Get-FreshWinBootstrapSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Test-FreshWinBootstrapUri {
    param([Parameter(Mandatory = $true)][Uri]$Uri)
    return $Uri.IsAbsoluteUri -and $Uri.Scheme -ceq 'https' -and
        $script:FreshWinBootstrapAllowedHosts -contains $Uri.DnsSafeHost.ToLowerInvariant()
}

function Invoke-FreshWinBootstrapDownload {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [ValidateRange(1,120)][int]$TimeoutSeconds = 30,
        [ValidateRange(1,209715200)][long]$MaximumBytes = 104857600
    )
    if (-not (Test-FreshWinBootstrapUri -Uri $Uri)) { throw "Bootstrap download URI is not allowlisted: $Uri" }
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object Net.Http.HttpClient -ArgumentList (, $handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $current = $Uri
    try {
        for ($redirect = 0; $redirect -le 5; $redirect++) {
            $response = $client.GetAsync($current, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            try {
                $status = [int]$response.StatusCode
                if ($status -in @(301,302,303,307,308)) {
                    if ($redirect -eq 5 -or $null -eq $response.Headers.Location) { throw 'Bootstrap download exceeded its redirect limit.' }
                    $next = if ($response.Headers.Location.IsAbsoluteUri) { $response.Headers.Location } else { New-Object Uri -ArgumentList $current, $response.Headers.Location }
                    if (-not (Test-FreshWinBootstrapUri -Uri $next)) { throw "Bootstrap download redirect is not allowlisted: $next" }
                    $current = $next
                    continue
                }
                if (-not $response.IsSuccessStatusCode) { throw "Bootstrap download failed with HTTP status $status." }
                $declaredLength = $response.Content.Headers.ContentLength
                if ($null -ne $declaredLength -and ([long]$declaredLength -le 0 -or [long]$declaredLength -gt $MaximumBytes)) {
                    throw 'Bootstrap download size is outside the allowed limit.'
                }
                $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $output = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $buffer = New-Object byte[] 65536
                    [long]$total = 0
                    while (($count = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $total += $count
                        if ($total -gt $MaximumBytes) { throw 'Bootstrap download exceeded the allowed size.' }
                        $output.Write($buffer, 0, $count)
                    }
                    if ($total -le 0) { throw 'Bootstrap download returned an empty file.' }
                }
                finally { $output.Dispose(); $input.Dispose() }
                return
            }
            finally { $response.Dispose() }
        }
    }
    finally { $client.Dispose(); $handler.Dispose() }
}

function Read-FreshWinBootstrapMetadata {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][Uri]$MetadataUri)
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.Length -le 0 -or $file.Length -gt 65536 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Release metadata file is invalid.' }
    $strictUtf8 = New-Object Text.UTF8Encoding -ArgumentList $false, $true
    try { $metadata = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName, $strictUtf8)) -ErrorAction Stop }
    catch { throw 'Release metadata is not valid UTF-8 JSON.' }
    $allowed = @('schemaVersion','channel','version','publishedAtUtc','packageUri','sha256','minimumPowerShellVersion','notes')
    if (@($metadata.PSObject.Properties | Where-Object { $allowed -notcontains [string]$_.Name }).Count -gt 0) { throw 'Release metadata contains unsupported properties.' }
    foreach ($name in @('schemaVersion','channel','version','publishedAtUtc','packageUri','sha256','minimumPowerShellVersion')) {
        if ($null -eq $metadata.PSObject.Properties[$name]) { throw "Release metadata is missing '$name'." }
    }
    if ([int]$metadata.schemaVersion -ne 1 -or [string]$metadata.channel -notin @('stable','preview')) { throw 'Release metadata schema or channel is invalid.' }
    $version = $null
    if ([string]$metadata.version -notmatch '^\d+\.\d+\.\d+$' -or -not [version]::TryParse([string]$metadata.version, [ref]$version)) { throw 'Release metadata version is invalid.' }
    $published = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$metadata.publishedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$published)) { throw 'Release metadata timestamp is invalid.' }
    if ([string]$metadata.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Release archive SHA-256 is invalid.' }
    $minimum = $null
    if (-not [version]::TryParse([string]$metadata.minimumPowerShellVersion, [ref]$minimum) -or $minimum -lt [version]'5.1' -or $minimum -gt $PSVersionTable.PSVersion) { throw 'This PowerShell version does not satisfy the release metadata.' }
    try { $packageUri = [Uri][string]$metadata.packageUri } catch { throw 'Release package URI is invalid.' }
    if (-not (Test-FreshWinBootstrapUri -Uri $packageUri)) { throw 'Release package URI is not allowlisted.' }
    if ($MetadataUri.DnsSafeHost.ToLowerInvariant() -ne 'github.com' -or $packageUri.DnsSafeHost.ToLowerInvariant() -ne 'github.com') { throw 'Official release metadata and package must use the GitHub release host.' }
    $expectedLeaf = "FreshWin-$($version.ToString()).zip"
    if (-not $packageUri.AbsolutePath.EndsWith('/' + $expectedLeaf, [StringComparison]::Ordinal)) { throw 'Release package filename does not match its version.' }
    return [pscustomobject]@{ Version=$version.ToString(); PackageUri=$packageUri; Sha256=([string]$metadata.sha256).ToLowerInvariant(); Metadata=$metadata }
}

function Expand-FreshWinBootstrapArchive {
    param([Parameter(Mandatory = $true)][string]$ArchivePath, [Parameter(Mandatory = $true)][string]$DestinationRoot)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    [void][IO.Directory]::CreateDirectory($DestinationRoot)
    $root = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd([char]'\', [char]'/') + [IO.Path]::DirectorySeparatorChar
    $stream = [IO.File]::OpenRead($ArchivePath)
    $archive = $null
    try {
        $archive = New-Object IO.Compression.ZipArchive -ArgumentList $stream, ([IO.Compression.ZipArchiveMode]::Read), $false
        if ($archive.Entries.Count -le 0 -or $archive.Entries.Count -gt 20000) { throw 'Release archive entry count is invalid.' }
        [long]$totalLength = 0
        foreach ($entry in $archive.Entries) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains('\') -or $name.Contains(':') -or $name -match '(^|/)\.\.(/|$)') { throw "Release archive entry path is unsafe: $name" }
            $totalLength += [long]$entry.Length
            if ($totalLength -gt 209715200) { throw 'Release archive expands beyond the allowed size.' }
            $relative = $name.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $target = [IO.Path]::GetFullPath((Join-Path $DestinationRoot $relative))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Release archive entry escapes the staging directory: $name" }
            if ($name.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($target); continue }
            $parent = [IO.Path]::GetDirectoryName($target)
            if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
            $input = $entry.Open()
            $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $input.CopyTo($output) }
            finally { $output.Dispose(); $input.Dispose() }
        }
    }
    catch { throw "Release archive extraction failed: $($_.Exception.Message)" }
    finally { if ($null -ne $archive) { $archive.Dispose() }; $stream.Dispose() }
}

function Test-FreshWinBootstrapPayload {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$ExpectedVersion)
    $Root = [IO.Path]::GetFullPath($Root)
    $manifestPath = Join-Path $Root 'release-manifest.json'
    if (-not [IO.File]::Exists($manifestPath)) { throw 'Release payload manifest is missing.' }
    try { $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifestPath, (New-Object Text.UTF8Encoding -ArgumentList $false, $true))) -ErrorAction Stop }
    catch { throw 'Release payload manifest is invalid.' }
    if ([string]$manifest.schemaVersion -cne 'FreshWin.ReleaseManifest/1' -or [string]$manifest.version -cne $ExpectedVersion) { throw 'Release payload manifest version is invalid.' }
    $records = @($manifest.files)
    if ($records.Count -le 0 -or $records.Count -gt 20000) { throw 'Release payload manifest file count is invalid.' }
    $seen = @{}
    foreach ($record in $records) {
        $path = [string]$record.path
        if ($path -notmatch '^[^\\/:\x00]+(?:/[^\\/:\x00]+)*$' -or $path -match '(^|/)\.\.(/|$)' -or $seen.ContainsKey($path.ToLowerInvariant())) { throw "Release manifest path is invalid or duplicated: $path" }
        if ([string]$record.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$record.length -lt 0) { throw "Release manifest record is invalid: $path" }
        $seen[$path.ToLowerInvariant()] = $true
        $filePath = Join-Path $Root $path.Replace('/', [IO.Path]::DirectorySeparatorChar)
        if (-not [IO.File]::Exists($filePath)) { throw "Release payload file is missing: $path" }
        $item = Get-Item -LiteralPath $filePath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or [long]$item.Length -ne [long]$record.length -or (Get-FreshWinBootstrapSha256 $filePath) -cne ([string]$record.sha256).ToLowerInvariant()) { throw "Release payload integrity failed: $path" }
    }
    $actual = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
        $_.FullName.Substring($Root.TrimEnd([char]'\', [char]'/').Length).TrimStart([char]'\', [char]'/').Replace('\','/')
    } | Where-Object { $_ -cne 'release-manifest.json' })
    if ($actual.Count -ne $records.Count -or @($actual | Where-Object { -not $seen.ContainsKey($_.ToLowerInvariant()) }).Count -gt 0) { throw 'Release payload manifest is incomplete or the archive contains unexpected files.' }
    foreach ($required in @('FreshWin.ps1','FreshWin.psm1','FreshWin.psd1','bootstrap.ps1','install.ps1','uninstall.ps1','bin/freshwin.cmd','bin/freshwin-uninstall.cmd','installer/Install.Common.ps1')) {
        if (-not $seen.ContainsKey($required.ToLowerInvariant())) { throw "Required runtime file is missing from the release: $required" }
    }
    if (@($actual | Where-Object { $_ -match '^(?:tests|\.git|\.github)(?:/|$)|(?:^|/)\.DS_Store$|\.log$' }).Count -gt 0) { throw 'Release payload contains development or local-state files.' }
    $moduleText = [IO.File]::ReadAllText((Join-Path $Root 'FreshWin.psd1'))
    $match = [regex]::Match($moduleText, "(?m)^\s*ModuleVersion\s*=\s*'([^']+)'\s*$")
    if (-not $match.Success -or $match.Groups[1].Value -cne $ExpectedVersion) { throw 'Release module version does not match release metadata.' }
    return [pscustomobject]@{ IsValid=$true; Version=$ExpectedVersion; FileCount=$records.Count; Root=$Root }
}

function Test-FreshWinBootstrapInstalled {
    param([Parameter(Mandatory = $true)][string]$ExpectedVersion)
    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    $installRoot = [IO.Path]::Combine($programFiles, 'FreshWin')
    $installedManifest = Join-Path $installRoot 'install-manifest.json'
    if (-not [IO.File]::Exists($installedManifest)) { throw 'Protected FreshWin install manifest was not created.' }
    $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($installedManifest)) -ErrorAction Stop
    if ([string]$manifest.Version -cne $ExpectedVersion) { throw 'Installed FreshWin version does not match the verified release.' }
    $powershell = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    $launcher = Join-Path (Join-Path $installRoot 'bin') 'freshwin.cmd'
    $command = '$expected=$env:FRESHWIN_BOOTSTRAP_LAUNCHER;$version=$env:FRESHWIN_BOOTSTRAP_VERSION;$c=@(Get-Command freshwin -CommandType Application -ErrorAction Stop|Where-Object{[IO.Path]::GetFullPath($_.Source)-eq[IO.Path]::GetFullPath($expected)})[0];if($null-eq$c){exit 2};& $c.Source --version --json;$code=$LASTEXITCODE;if($code-ne 0){exit $code}'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $powershell
    $start.Arguments = "-NoLogo -NoProfile -EncodedCommand $encoded"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['Path'] = @([string][Environment]::GetEnvironmentVariable('Path','Machine'),[string][Environment]::GetEnvironmentVariable('Path','User')) -join ';'
    $start.EnvironmentVariables['FRESHWIN_BOOTSTRAP_LAUNCHER'] = $launcher
    $start.EnvironmentVariables['FRESHWIN_BOOTSTRAP_VERSION'] = $ExpectedVersion
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "A fresh non-elevated PowerShell could not resolve FreshWin. $stderr" }
    try { $versionResult = ConvertFrom-Json -InputObject $stdout -ErrorAction Stop } catch { throw 'Installed freshwin --version did not return valid JSON.' }
    if ([string]$versionResult.Version -cne $ExpectedVersion) { throw 'Installed launcher reported the wrong FreshWin version.' }
    return $true
}

function Invoke-FreshWinBootstrap {
    param([Parameter(Mandatory = $true)][Uri]$ReleaseMetadataUri)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'FreshWin supports Windows 10 and Windows 11 only.' }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') { throw 'FreshWin requires Windows PowerShell 5.1 or newer.' }
    if (-not (Test-FreshWinBootstrapUri -Uri $ReleaseMetadataUri) -or $ReleaseMetadataUri.DnsSafeHost.ToLowerInvariant() -ne 'github.com') { throw 'Official release metadata URI is invalid.' }
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('FreshWin-bootstrap-' + [guid]::NewGuid().ToString('N'))
    $metadataPath = Join-Path $temporaryRoot 'release.json'
    $archivePath = Join-Path $temporaryRoot 'release.zip'
    $payloadRoot = Join-Path $temporaryRoot 'payload'
    try {
        [void][IO.Directory]::CreateDirectory($temporaryRoot)
        Write-Host '[FreshWin bootstrap] DOWNLOAD RELEASE METADATA'
        Invoke-FreshWinBootstrapDownload -Uri $ReleaseMetadataUri -DestinationPath $metadataPath -TimeoutSeconds 30 -MaximumBytes 65536
        $release = Read-FreshWinBootstrapMetadata -Path $metadataPath -MetadataUri $ReleaseMetadataUri
        Write-Host '[FreshWin bootstrap] DOWNLOAD VERSIONED ARCHIVE'
        Invoke-FreshWinBootstrapDownload -Uri $release.PackageUri -DestinationPath $archivePath -TimeoutSeconds 60 -MaximumBytes 104857600
        Write-Host '[FreshWin bootstrap] VERIFY SHA-256 / MANIFEST'
        if ((Get-FreshWinBootstrapSha256 $archivePath) -cne $release.Sha256) { throw 'Downloaded release archive failed SHA-256 verification.' }
        Write-Host '[FreshWin bootstrap] EXTRACT TO TEMP'
        Expand-FreshWinBootstrapArchive -ArchivePath $archivePath -DestinationRoot $payloadRoot
        Write-Host '[FreshWin bootstrap] VALIDATE PAYLOAD'
        [void](Test-FreshWinBootstrapPayload -Root $payloadRoot -ExpectedVersion $release.Version)
        Write-Host '[FreshWin bootstrap] INVOKE EXISTING INSTALLER'
        $powershell = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'powershell.exe')
        & $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $payloadRoot 'install.ps1') -SourceRoot $payloadRoot -ReleaseMetadataUri $ReleaseMetadataUri.AbsoluteUri
        if ($LASTEXITCODE -ne 0) { throw "FreshWin installer failed with exit code $LASTEXITCODE." }
        Write-Host '[FreshWin bootstrap] VERIFY PROTECTED INSTALLATION'
        [void](Test-FreshWinBootstrapInstalled -ExpectedVersion $release.Version)
        Write-Host 'FreshWin installed successfully.'
        Write-Host ''
        Write-Host 'Open a new PowerShell and run:'
        Write-Host ''
        Write-Host '    freshwin'
    }
    finally {
        Write-Host '[FreshWin bootstrap] CLEAN TEMP FILES'
        try {
            $fullTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
            $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\', [char]'/') + [IO.Path]::DirectorySeparatorChar
            if ($fullTemporaryRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($fullTemporaryRoot).StartsWith('FreshWin-bootstrap-', [StringComparison]::Ordinal)) {
                if ([IO.Directory]::Exists($fullTemporaryRoot)) { [IO.Directory]::Delete($fullTemporaryRoot, $true) }
            }
        }
        catch { Write-Warning 'FreshWin could not completely remove its temporary bootstrap directory.' }
    }
}

if (-not $LibraryMode) {
    $effectiveMetadataUri = if ([string]::IsNullOrWhiteSpace($MetadataUri)) { $script:FreshWinOfficialMetadataUri } else { $MetadataUri }
    if ($effectiveMetadataUri.StartsWith('__FRESHWIN_', [StringComparison]::Ordinal)) {
        throw 'FreshWin online installation is not published yet. Use the reviewed local install.cmd workflow.'
    }
    Invoke-FreshWinBootstrap -ReleaseMetadataUri ([Uri]$effectiveMetadataUri)
}
