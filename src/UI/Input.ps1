Set-StrictMode -Version 2.0

function Read-FreshWinInput {
    [CmdletBinding()]
    param(
        [string]$Prompt = 'Select',
        [switch]$AllowEmpty
    )

    while ($true) {
        try { $value = Read-Host "$Prompt >" } catch { return $null }
        if ($AllowEmpty -or -not [string]::IsNullOrWhiteSpace($value)) { return $value }
        Write-Host 'Enter a selection or command.' -ForegroundColor Yellow
    }
}

function Test-FreshWinLocalAbsolutePath {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00\r\n]' -or
        -not [System.IO.Path]::IsPathRooted($Path)) { return $false }

    # UNC, SMB-style, Win32 device, extended-length, and NT object-manager
    # namespaces are never valid checkpoint locations. The same check is kept
    # on non-Windows hosts so command-line fixtures cannot normalize them away.
    if ($Path.StartsWith('\\') -or $Path.StartsWith('//') -or
        $Path -match '^(?i:\\(?:Device|GLOBALROOT|\?\?)[\\/])') { return $false }

    try { $fullPath = [System.IO.Path]::GetFullPath($Path) }
    catch { return $false }
    if ($fullPath.StartsWith('\\') -or $fullPath.StartsWith('//')) { return $false }

    $isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if (-not $isWindowsHost) { return $fullPath.StartsWith('/') -and -not $fullPath.StartsWith('//') }

    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root) -or $root -notmatch '^[A-Za-z]:[\\/]$') { return $false }
    $driveName = $root.Substring(0, 1)
    $drive = Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($null -eq $drive) { return $false }
    $displayRootProperty = $drive.PSObject.Properties['DisplayRoot']
    $displayRoot = if ($null -ne $displayRootProperty) { [string]$displayRootProperty.Value } else { '' }
    if ($displayRoot.StartsWith('\\') -or $displayRoot.StartsWith('//') -or
        ([string]$drive.Root).StartsWith('\\') -or ([string]$drive.Root).StartsWith('//')) { return $false }
    try {
        if ((New-Object System.IO.DriveInfo($root)).DriveType -eq [System.IO.DriveType]::Network) { return $false }
    }
    catch { return $false }
    return $true
}

function ConvertFrom-FreshWinCommandLine {
    [CmdletBinding()]
    param([string[]]$Arguments)

    $tokens = @($Arguments | Where-Object { $null -ne $_ })
    $result = [ordered]@{
        Valid          = $true
        Mode           = if ($tokens.Count -eq 0) { 'Interactive' } else { 'Command' }
        Command        = if ($tokens.Count -eq 0) { 'interactive' } else { ([string]$tokens[0]).ToLowerInvariant() }
        Values         = @()
        DryRun         = $false
        VerboseOutput  = $false
        Compact        = $false
        ResumePath     = $null
        ElevatedHelper = $false
        Json           = $false
        Yes            = $false
        IncludeUpdates = $false
        Retry          = $false
        RegisterResume = $false
        Locale         = $null
        Profile        = $null
        OutputPath     = $null
        CheckpointHash = $null
        CallerSid      = $null
        HandoffId      = $null
        Error          = $null
    }

    $positionals = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = [string]$tokens[$index]
        switch ($token.ToLowerInvariant()) {
            '--dry-run' { $result.DryRun = $true }
            '--help' { $positionals.Add('help') }
            '-h' { $positionals.Add('help') }
            '--version' { $positionals.Add('version') }
            '-v' { $positionals.Add('version') }
            '--verbose' { $result.VerboseOutput = $true }
            '--compact' { $result.Compact = $true }
            '--elevated-helper' { $result.ElevatedHelper = $true }
            '--json' { $result.Json = $true }
            '--yes' { $result.Yes = $true }
            '-y' { $result.Yes = $true }
            '--include-updates' { $result.IncludeUpdates = $true }
            '--retry' { $result.Retry = $true }
            '--register-resume' { $result.RegisterResume = $true }
            '--locale' {
                if ($index + 1 -ge $tokens.Count) { $result.Valid = $false; $result.Error = '--locale requires a locale name.'; break }
                $index++
                $locale = [string]$tokens[$index]
                if ($locale -notin @('en-US', 'vi-VN', 'zh-CN', 'ja-JP')) { $result.Valid = $false; $result.Error = "Unsupported locale '$locale'."; break }
                $result.Locale = $locale
            }
            '--profile' {
                if ($index + 1 -ge $tokens.Count) { $result.Valid = $false; $result.Error = '--profile requires a profile ID.'; break }
                $index++
                $profile = ([string]$tokens[$index]).ToLowerInvariant()
                if ($profile -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { $result.Valid = $false; $result.Error = 'Profile ID is invalid.'; break }
                $result.Profile = $profile
            }
            '--output' {
                if ($index + 1 -ge $tokens.Count) { $result.Valid = $false; $result.Error = '--output requires a path.'; break }
                $index++
                $result.OutputPath = [string]$tokens[$index]
            }
            '--resume' {
                if ($index + 1 -ge $tokens.Count) { $result.Valid = $false; $result.Error = '--resume requires a checkpoint path.'; break }
                $index++
                $resumePath = [string]$tokens[$index]
                if (-not (Test-FreshWinLocalAbsolutePath -Path $resumePath)) {
                    $result.Valid = $false; $result.Error = 'Resume path must be an absolute local path.'; break
                }
                $result.ResumePath = [System.IO.Path]::GetFullPath($resumePath)
            }
            '--checkpoint-hash' {
                if ($index + 1 -ge $tokens.Count) { $result.Valid = $false; $result.Error = '--checkpoint-hash requires a SHA-256 value.'; break }
                $index++
                $checkpointHash = ([string]$tokens[$index]).ToLowerInvariant()
                if ($checkpointHash -notmatch '^[a-f0-9]{64}$') { $result.Valid = $false; $result.Error = 'Checkpoint hash must be 64 hexadecimal characters.'; break }
                $result.CheckpointHash = $checkpointHash
            }
            '--caller-sid' {
                if ($index + 1 -ge $tokens.Count) { $result.Valid = $false; $result.Error = '--caller-sid requires a Windows SID.'; break }
                $index++
                $callerSid = [string]$tokens[$index]
                if ($callerSid.Length -gt 184 -or $callerSid -notmatch '^S-\d-\d+(?:-\d+){1,15}$') {
                    $result.Valid = $false; $result.Error = 'Caller SID is invalid.'; break
                }
                $result.CallerSid = $callerSid
            }
            '--handoff-id' {
                if ($index + 1 -ge $tokens.Count) { $result.Valid = $false; $result.Error = '--handoff-id requires a 32-character identifier.'; break }
                $index++
                $handoffId = ([string]$tokens[$index]).ToLowerInvariant()
                if ($handoffId -notmatch '^[a-f0-9]{32}$') { $result.Valid = $false; $result.Error = 'Handoff ID must be 32 hexadecimal characters.'; break }
                $result.HandoffId = $handoffId
            }
            default {
                if ($token.StartsWith('-')) { $result.Valid = $false; $result.Error = "Unknown option '$token'."; break }
                $positionals.Add($token)
            }
        }
        if (-not $result.Valid) { break }
    }

    if ($positionals.Count -gt 0) {
        $result.Mode = 'Command'
        $result.Command = $positionals[0].ToLowerInvariant()
        if ($positionals.Count -gt 1) { $result.Values = @($positionals | Select-Object -Skip 1) }
    }
    elseif ($result.ResumePath) {
        $result.Mode = 'Resume'
        $result.Command = 'resume'
    }
    elseif ($tokens.Count -gt 0 -and $result.Command -notin @('--dry-run', '--verbose', '--compact')) {
        # A switch-only invocation remains interactive with its selected options.
        $result.Mode = 'Interactive'
        $result.Command = 'interactive'
    }
    else {
        $result.Mode = 'Interactive'
        $result.Command = 'interactive'
    }

    if ($result.Valid -and $result.Command -eq 'resume' -and
        [string]::IsNullOrWhiteSpace([string]$result.ResumePath) -and @($result.Values).Count -eq 1) {
        $positionalResumePath = [string]$result.Values[0]
        if (-not (Test-FreshWinLocalAbsolutePath -Path $positionalResumePath)) {
            $result.Valid = $false
            $result.Error = 'Resume path must be an absolute local path.'
        }
        else { $result.Values = @([System.IO.Path]::GetFullPath($positionalResumePath)) }
    }

    if ($result.Valid -and $result.ElevatedHelper -and
        ([string]::IsNullOrWhiteSpace([string]$result.ResumePath) -or
         [string]::IsNullOrWhiteSpace([string]$result.CheckpointHash) -or
         [string]::IsNullOrWhiteSpace([string]$result.CallerSid) -or
         [string]::IsNullOrWhiteSpace([string]$result.HandoffId))) {
        $result.Valid = $false
        $result.Error = '--elevated-helper requires --resume, --checkpoint-hash, --caller-sid, and --handoff-id.'
    }
    elseif ($result.Valid -and -not $result.ElevatedHelper -and -not [string]::IsNullOrWhiteSpace([string]$result.CallerSid)) {
        $result.Valid = $false
        $result.Error = '--caller-sid is reserved for the controlled elevation helper.'
    }
    elseif ($result.Valid -and -not $result.ElevatedHelper -and -not [string]::IsNullOrWhiteSpace([string]$result.HandoffId)) {
        $result.Valid = $false
        $result.Error = '--handoff-id is reserved for the controlled elevation helper.'
    }

    return [pscustomobject]$result
}

function ConvertTo-FreshWinPackageIdList {
    [CmdletBinding()]
    param([string[]]$Tokens)

    $text = ($Tokens -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $text = $text -replace '(?i)\s+and\s+', ','
    $ids = @($text -split '[,;\s]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if (@($ids | Where-Object { $_ -notmatch '^[a-z0-9][a-z0-9._-]{1,79}$' }).Count -gt 0) {
        throw 'Package names may contain only letters, numbers, periods, underscores, and hyphens.'
    }
    return @($ids | Select-Object -Unique)
}
