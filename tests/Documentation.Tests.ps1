Add-FreshWinTest -Name 'Required project and safety documentation is present' -Category 'Documentation' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $required = @(
        'README.md', 'CONTRIBUTING.md', 'docs/ARCHITECTURE.md', 'docs/SAFETY.md',
        'docs/CLI.md', 'docs/CATALOG.md', 'docs/TESTING.md', 'docs/MACOS-LIMITATIONS.md'
    )
    foreach ($relativePath in $required) {
        $path = Join-Path $root $relativePath
        Assert-FreshWinTrue ([System.IO.File]::Exists($path)) -Because "Missing $relativePath."
        Assert-FreshWinTrue (([System.IO.File]::ReadAllText($path)).Length -gt 100) -Because "$relativePath is unexpectedly empty."
    }
}

Add-FreshWinTest -Name 'Relative Markdown links resolve to local files' -Category 'Documentation' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $files = @(Get-Item (Join-Path $root 'README.md'), (Join-Path $root 'CONTRIBUTING.md')) +
        @(Get-ChildItem (Join-Path $root 'docs') -Filter '*.md' -File)
    $broken = @()
    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\(([^)]+)\)')) {
            $target = $match.Groups[1].Value.Trim()
            if ($target -match '^(?:https?://|mailto:|#)') { continue }
            $targetPath = ($target -split '#', 2)[0]
            if ([string]::IsNullOrWhiteSpace($targetPath)) { continue }
            $resolved = [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $targetPath))
            if (-not [System.IO.File]::Exists($resolved) -and -not [System.IO.Directory]::Exists($resolved)) {
                $broken += "$($file.Name) -> $target"
            }
        }
    }
    Assert-FreshWinCount 0 $broken ("Broken links: " + ($broken -join ', '))
}

Add-FreshWinTest -Name 'CI is read-only and runs safe plus opt-in Windows-live suites' -Category 'Documentation' -ScriptBlock {
    $workflowPath = Join-Path $script:FreshWinTestContext.ProjectRoot '.github/workflows/test.yml'
    Assert-FreshWinTrue ([System.IO.File]::Exists($workflowPath)) -Because 'Missing CI workflow.'
    $workflow = [System.IO.File]::ReadAllText($workflowPath)
    Assert-FreshWinMatch $workflow '(?m)^permissions:\s*\n\s+contents:\s*read\s*$'
    Assert-FreshWinMatch $workflow 'persist-credentials:\s*false'
    Assert-FreshWinMatch $workflow 'Run-Tests\.ps1'
    Assert-FreshWinMatch $workflow 'IncludeWindowsIntegration'
    Assert-FreshWinFalse ($workflow -match '(?i)secrets\.') -Because 'The test workflow must not request repository secrets.'
}

Add-FreshWinTest -Name 'Testing documentation explicitly forbids fabricated Windows success' -Category 'Documentation' -ScriptBlock {
    $root = $script:FreshWinTestContext.ProjectRoot
    $testing = [System.IO.File]::ReadAllText((Join-Path $root 'docs/TESTING.md'))
    $limitations = [System.IO.File]::ReadAllText((Join-Path $root 'docs/MACOS-LIMITATIONS.md'))
    Assert-FreshWinMatch $testing '(?i)skipped.*never.*passed|must never be reported as passed'
    Assert-FreshWinMatch $limitations '(?i)cannot prove|must not be presented as a Windows pass'
}
