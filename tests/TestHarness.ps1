Set-StrictMode -Version Latest

$script:FreshWinRegisteredTests = @()
$script:FreshWinTestContext = [pscustomobject]@{
    IncludeWindowsIntegration = $false
    ProjectRoot               = $null
}

function Add-FreshWinTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [string]$Category = 'Unit',
        [ValidateSet('Any', 'Windows', 'WindowsLive')][string]$Platform = 'Any'
    )

    $script:FreshWinRegisteredTests += [pscustomobject]@{
        Name        = $Name
        Category    = $Category
        Platform    = $Platform
        ScriptBlock = $ScriptBlock
    }
}

function Assert-FreshWinTrue {
    param([AllowNull()][object]$Actual, [string]$Because = 'Expected a truthy value.')
    if (-not [bool]$Actual) { throw $Because }
}

function Assert-FreshWinFalse {
    param([AllowNull()][object]$Actual, [string]$Because = 'Expected a false value.')
    if ([bool]$Actual) { throw $Because }
}

function Assert-FreshWinEqual {
    param([AllowNull()][object]$Expected, [AllowNull()][object]$Actual, [string]$Because)
    if ($Expected -ne $Actual) {
        $message = "Expected '$Expected' but received '$Actual'."
        if ($Because) { $message += " $Because" }
        throw $message
    }
}

function Assert-FreshWinNull {
    param([AllowNull()][object]$Actual, [string]$Because = 'Expected null.')
    if ($null -ne $Actual) { throw "$Because Received '$Actual'." }
}

function Assert-FreshWinNotNull {
    param([AllowNull()][object]$Actual, [string]$Because = 'Expected a non-null value.')
    if ($null -eq $Actual) { throw $Because }
}

function Assert-FreshWinMatch {
    param([AllowNull()][object]$Actual, [Parameter(Mandatory = $true)][string]$Pattern, [string]$Because)
    if ([string]$Actual -notmatch $Pattern) {
        $message = "Value '$Actual' did not match /$Pattern/."
        if ($Because) { $message += " $Because" }
        throw $message
    }
}

function Get-FreshWinTestPowerShellExecutable {
    $current = Get-Process -Id $PID -ErrorAction Stop
    $candidate = [string]$current.Path
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and [IO.File]::Exists($candidate)) {
        return [IO.Path]::GetFullPath($candidate)
    }
    $names = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { @('pwsh.exe','powershell.exe') } else { @('pwsh') }
    foreach ($name in $names) {
        $path = Join-Path $PSHOME $name
        if ([IO.File]::Exists($path)) { return [IO.Path]::GetFullPath($path) }
    }
    throw 'The current PowerShell executable could not be resolved for an isolated child-process test.'
}

function ConvertTo-FreshWinTestNativeArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + ([regex]::Replace($Value, '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-FreshWinTestPowerShellProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Get-FreshWinTestPowerShellExecutable
    $start.Arguments = (@('-NoLogo','-NoProfile') + @($Arguments) | ForEach-Object { ConvertTo-FreshWinTestNativeArgument -Value ([string]$_) }) -join ' '
    $start.WorkingDirectory = [IO.Path]::GetFullPath($ProjectRoot)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode=[int]$process.ExitCode; Stdout=$stdout; Stderr=$stderr; Executable=$start.FileName; WorkingDirectory=$start.WorkingDirectory }
}

function Assert-FreshWinCount {
    param([Parameter(Mandatory = $true)][int]$Expected, [AllowNull()][object[]]$Actual, [string]$Because)
    $actualCount = @($Actual).Count
    if ($Expected -ne $actualCount) {
        $message = "Expected $Expected item(s), received $actualCount."
        if ($Because) { $message += " $Because" }
        throw $message
    }
}

function Assert-FreshWinContains {
    param([AllowNull()][object[]]$Collection, [AllowNull()][object]$Expected, [string]$Because)
    if (@($Collection) -notcontains $Expected) {
        $message = "Collection did not contain '$Expected'."
        if ($Because) { $message += " $Because" }
        throw $message
    }
}

function Assert-FreshWinSetEqual {
    param([AllowNull()][object[]]$Expected, [AllowNull()][object[]]$Actual, [string]$Because)
    $expectedValues = @($Expected | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $actualValues = @($Actual | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $difference = @(Compare-Object -ReferenceObject $expectedValues -DifferenceObject $actualValues)
    if ($difference.Count -gt 0) {
        $differenceText = @($difference | ForEach-Object { "$($_.SideIndicator)$($_.InputObject)" }) -join ', '
        $message = "Sets differ: $differenceText."
        if ($Because) { $message += " $Because" }
        throw $message
    }
}

function Assert-FreshWinThrows {
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock, [string]$Pattern, [string]$Because)
    $caught = $null
    try { & $ScriptBlock } catch { $caught = $_ }
    if ($null -eq $caught) {
        $message = 'Expected an exception, but the operation completed.'
        if ($Because) { $message += " $Because" }
        throw $message
    }
    if ($Pattern -and $caught.Exception.Message -notmatch $Pattern) {
        throw "Exception '$($caught.Exception.Message)' did not match /$Pattern/."
    }
}

function Assert-FreshWinDoesNotThrow {
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock, [string]$Because)
    try { & $ScriptBlock } catch {
        $message = "Unexpected exception: $($_.Exception.Message)"
        if ($Because) { $message += " $Because" }
        throw $message
    }
}

function Skip-FreshWinTest {
    param([Parameter(Mandatory = $true)][string]$Reason)
    throw "__FRESHWIN_SKIP__:$Reason"
}

function New-FreshWinTestDirectory {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('FreshWin-Test-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($path)
    return $path
}

function Remove-FreshWinTestDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $fullPath.StartsWith($temporaryRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($fullPath) -notmatch '^FreshWin-Test-[a-f0-9]{32}$') {
        throw "Refusing to remove non-test path '$fullPath'."
    }
    if ([System.IO.Directory]::Exists($fullPath)) {
        [System.IO.Directory]::Delete($fullPath, $true)
    }
}

function Invoke-FreshWinRegisteredTests {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [switch]$IncludeWindowsIntegration,
        [string]$NamePattern
    )

    $script:FreshWinTestContext.ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    $script:FreshWinTestContext.IncludeWindowsIntegration = [bool]$IncludeWindowsIntegration
    $isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $passed = 0
    $failed = 0
    $skipped = 0
    $startedAt = [DateTimeOffset]::UtcNow

    foreach ($test in @($script:FreshWinRegisteredTests)) {
        if ($NamePattern -and $test.Name -notmatch $NamePattern) { continue }
        $skipReason = $null
        if ($test.Platform -eq 'Windows' -and -not $isWindowsHost) {
            $skipReason = 'requires Windows'
        }
        elseif ($test.Platform -eq 'WindowsLive' -and -not $isWindowsHost) {
            $skipReason = 'requires Windows; no Windows result is inferred on this host'
        }
        elseif ($test.Platform -eq 'WindowsLive' -and -not $IncludeWindowsIntegration) {
            $skipReason = 'live Windows integration is opt-in (-IncludeWindowsIntegration)'
        }

        if ($skipReason) {
            $skipped++
            Write-Host "[SKIP] [$($test.Category)] $($test.Name) -- $skipReason" -ForegroundColor Yellow
            continue
        }

        try {
            & $test.ScriptBlock
            $passed++
            Write-Host "[PASS] [$($test.Category)] $($test.Name)" -ForegroundColor Green
        }
        catch {
            if ($_.Exception.Message.StartsWith('__FRESHWIN_SKIP__:')) {
                $skipped++
                Write-Host "[SKIP] [$($test.Category)] $($test.Name) -- $($_.Exception.Message.Substring(18))" -ForegroundColor Yellow
            }
            else {
                $failed++
                Write-Host "[FAIL] [$($test.Category)] $($test.Name)" -ForegroundColor Red
                Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
                if ($_.ScriptStackTrace) { Write-Host "       $($_.ScriptStackTrace -replace "`n", "`n       ")" -ForegroundColor DarkRed }
            }
        }
    }

    $duration = [DateTimeOffset]::UtcNow - $startedAt
    Write-Host ''
    Write-Host "FreshWin tests: $passed passed, $failed failed, $skipped skipped in $([math]::Round($duration.TotalSeconds, 2))s."
    return [pscustomobject]@{ Passed = $passed; Failed = $failed; Skipped = $skipped; Duration = $duration }
}
