Add-FreshWinTest -Name 'Module manifest is the single authoritative FreshWin version source' -Category 'Distribution' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'FreshWin.psd1')
    Assert-FreshWinEqual ([string]$manifest.ModuleVersion) (Get-FreshWinVersion)
    $common = [IO.File]::ReadAllText((Join-Path $root 'src\Core\Common.ps1'))
    Assert-FreshWinMatch $common 'Import-PowerShellDataFile'
    Assert-FreshWinFalse ($common -match '\$script:FreshWinVersion\s*=\s*''\d') -Because 'The runtime version must not be duplicated as a literal.'
}

Add-FreshWinTest -Name 'Release creation is deterministic complete and excludes development state' -Category 'Distribution' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $root = $script:FreshWinTestContext.ProjectRoot
        $version = Get-FreshWinVersion
        $first = Join-Path $temporary ('First release - T' + [char]0x1EA3 + 'i xu' + [char]0x1ED1 + 'ng')
        $second = Join-Path $temporary 'Second release'
        $published = [DateTimeOffset]'2026-08-11T00:00:00Z'
        $one = & (Join-Path $root 'tools\New-FreshWinRelease.ps1') -OutputDirectory $first -Repository 'example/FreshWin' -PublishedAtUtc $published
        $two = & (Join-Path $root 'tools\New-FreshWinRelease.ps1') -OutputDirectory $second -Repository 'example/FreshWin' -PublishedAtUtc $published
        Assert-FreshWinEqual $one.ArchiveSha256 $two.ArchiveSha256
        Assert-FreshWinEqual (Get-FreshWinVersion) $one.Version
        foreach ($name in @("FreshWin-$version.zip","FreshWin-$version.sha256",'FreshWin-stable.release.json','bootstrap.ps1')) {
            Assert-FreshWinTrue ([IO.File]::Exists((Join-Path $first $name))) -Because "Release asset is missing: $name"
        }
        $checksum = ([IO.File]::ReadAllText((Join-Path $first "FreshWin-$version.sha256"))).Trim()
        Assert-FreshWinMatch $checksum ('^' + [regex]::Escape($one.ArchiveSha256) + ' \*' + [regex]::Escape("FreshWin-$version.zip") + '$')
        $generatedBootstrap = [IO.File]::ReadAllText((Join-Path $first 'bootstrap.ps1'))
        Assert-FreshWinFalse ($generatedBootstrap -match '__FRESHWIN_OFFICIAL_METADATA_URL__')
        Assert-FreshWinMatch $generatedBootstrap 'https://github\.com/example/FreshWin/releases/latest/download/FreshWin-stable\.release\.json'

        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        $stream = [IO.File]::OpenRead($one.ArchivePath)
        $zip = New-Object IO.Compression.ZipArchive -ArgumentList $stream, ([IO.Compression.ZipArchiveMode]::Read), $false
        try { $entries = @($zip.Entries | ForEach-Object { [string]$_.FullName }) }
        finally { $zip.Dispose(); $stream.Dispose() }
        foreach ($required in @('FreshWin.ps1','FreshWin.psm1','FreshWin.psd1','bootstrap.ps1','install.ps1','uninstall.ps1','bin/freshwin.cmd','bin/freshwin-uninstall.cmd','release-manifest.json')) {
            Assert-FreshWinTrue ($entries -ccontains $required) -Because "Release archive is missing $required."
        }
        Assert-FreshWinFalse (@($entries | Where-Object { $_ -match '^(?:tests|\.git|\.github)(?:/|$)|\.log$|(?:^|/)\.DS_Store$' }).Count -gt 0)
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Bootstrap rejects corrupt incomplete and wrong-version release payloads' -Category 'Distribution' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $root = $script:FreshWinTestContext.ProjectRoot
        $release = & (Join-Path $root 'tools\New-FreshWinRelease.ps1') -OutputDirectory (Join-Path $temporary 'release') -Repository 'example/FreshWin' -PublishedAtUtc ([DateTimeOffset]'2026-08-11T00:00:00Z')
        . (Join-Path $root 'bootstrap.ps1') -LibraryMode

        $validRoot = Join-Path $temporary 'valid payload'
        Expand-FreshWinBootstrapArchive -ArchivePath $release.ArchivePath -DestinationRoot $validRoot
        $valid = Test-FreshWinBootstrapPayload -Root $validRoot -ExpectedVersion $release.Version
        Assert-FreshWinTrue $valid.IsValid
        Assert-FreshWinEqual $release.PayloadFileCount $valid.FileCount

        $tamperedRoot = Join-Path $temporary 'tampered payload'
        Expand-FreshWinBootstrapArchive -ArchivePath $release.ArchivePath -DestinationRoot $tamperedRoot
        [IO.File]::AppendAllText((Join-Path $tamperedRoot 'FreshWin.ps1'), 'tampered')
        Assert-FreshWinThrows { Test-FreshWinBootstrapPayload -Root $tamperedRoot -ExpectedVersion $release.Version } 'integrity'

        $missingRoot = Join-Path $temporary 'missing payload'
        Expand-FreshWinBootstrapArchive -ArchivePath $release.ArchivePath -DestinationRoot $missingRoot
        [IO.File]::Delete((Join-Path $missingRoot 'FreshWin.ps1'))
        Assert-FreshWinThrows { Test-FreshWinBootstrapPayload -Root $missingRoot -ExpectedVersion $release.Version } 'missing'
        Assert-FreshWinThrows { Test-FreshWinBootstrapPayload -Root $validRoot -ExpectedVersion '9.9.9' } 'version'

        $corrupt = Join-Path $temporary 'corrupt.zip'
        [IO.File]::WriteAllBytes($corrupt, [byte[]](1,2,3,4,5))
        Assert-FreshWinThrows { Expand-FreshWinBootstrapArchive -ArchivePath $corrupt -DestinationRoot (Join-Path $temporary 'corrupt output') } 'extraction'
        Assert-FreshWinThrows { Invoke-FreshWinBootstrapDownload -Uri ([Uri]'https://example.invalid/FreshWin.zip') -DestinationPath (Join-Path $temporary 'blocked.zip') } 'allowlisted'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Release metadata binds version archive hash and stable update endpoint' -Category 'Distribution' -ScriptBlock {
    $temporary = New-FreshWinTestDirectory
    try {
        $root = $script:FreshWinTestContext.ProjectRoot
        $release = & (Join-Path $root 'tools\New-FreshWinRelease.ps1') -OutputDirectory $temporary -Repository 'example/FreshWin' -PublishedAtUtc ([DateTimeOffset]'2026-08-11T00:00:00Z')
        . (Join-Path $root 'bootstrap.ps1') -LibraryMode
        $metadataUri = [Uri]'https://github.com/example/FreshWin/releases/latest/download/FreshWin-stable.release.json'
        $metadata = Read-FreshWinBootstrapMetadata -Path $release.MetadataPath -MetadataUri $metadataUri
        Assert-FreshWinEqual $release.Version $metadata.Version
        Assert-FreshWinEqual $release.ArchiveSha256 $metadata.Sha256
        Assert-FreshWinEqual "https://github.com/example/FreshWin/releases/download/v$($release.Version)/FreshWin-$($release.Version).zip" $metadata.PackageUri.AbsoluteUri

        $wrong = ConvertFrom-Json ([IO.File]::ReadAllText($release.MetadataPath))
        $wrong.version = '9.9.9'
        $wrongPath = Join-Path $temporary 'wrong.release.json'
        [IO.File]::WriteAllText($wrongPath, (ConvertTo-Json $wrong -Depth 5), (New-Object Text.UTF8Encoding -ArgumentList $false))
        Assert-FreshWinThrows { Read-FreshWinBootstrapMetadata -Path $wrongPath -MetadataUri $metadataUri } 'filename does not match'
    }
    finally { Remove-FreshWinTestDirectory $temporary }
}

Add-FreshWinTest -Name 'Bootstrap update and uninstall preserve protected distribution boundaries' -Category 'Distribution' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $bootstrap = [IO.File]::ReadAllText((Join-Path $root 'bootstrap.ps1'))
    $installer = [IO.File]::ReadAllText((Join-Path $root 'install.ps1'))
    $updater = [IO.File]::ReadAllText((Join-Path $root 'src\Core\Update.ps1'))
    $uninstaller = [IO.File]::ReadAllText((Join-Path $root 'uninstall.ps1'))
    Assert-FreshWinMatch $bootstrap 'DOWNLOAD RELEASE METADATA[\s\S]*DOWNLOAD VERSIONED ARCHIVE[\s\S]*VERIFY SHA-256 / MANIFEST[\s\S]*EXTRACT TO TEMP[\s\S]*VALIDATE PAYLOAD[\s\S]*INVOKE EXISTING INSTALLER[\s\S]*VERIFY PROTECTED INSTALLATION[\s\S]*CLEAN TEMP FILES'
    Assert-FreshWinMatch $bootstrap 'TimeoutSeconds'
    Assert-FreshWinFalse ($bootstrap -match '(?i)ServicePointManager|CertificateValidationCallback|Set-ExecutionPolicy')
    Assert-FreshWinMatch $installer 'ReleaseMetadataUri'
    Assert-FreshWinMatch $updater 'Invoke-FreshWinCoreUpdate[\s\S]*ShouldProcess[\s\S]*Save-FreshWinUpdatePackage[\s\S]*Test-FreshWinBootstrapPayload[\s\S]*install\.ps1'
    Assert-FreshWinMatch $updater 'finally[\s\S]*FreshWin-update-'
    Assert-FreshWinMatch $uninstaller 'Remove-FreshWinPathEntryValue'
    Assert-FreshWinFalse ($uninstaller -match '(?i)LOCALAPPDATA|Downloads\\FreshWin')
}
