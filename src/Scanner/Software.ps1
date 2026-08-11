if (-not (Get-Variable -Name FreshWinSoftwareInventoryCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:FreshWinSoftwareInventoryCache = $null
}
if (-not (Get-Variable -Name FreshWinSoftwareInventoryLastStatus -Scope Script -ErrorAction SilentlyContinue)) {
    $script:FreshWinSoftwareInventoryLastStatus = $null
}
if (-not (Get-Variable -Name FreshWinSoftwareInventoryCacheIncludesUpdates -Scope Script -ErrorAction SilentlyContinue)) {
    $script:FreshWinSoftwareInventoryCacheIncludesUpdates = $false
}
if (-not (Get-Variable -Name FreshWinRegistryInventoryLastStatus -Scope Script -ErrorAction SilentlyContinue)) {
    $script:FreshWinRegistryInventoryLastStatus = $null
}
if (-not (Get-Variable -Name FreshWinAppxInventoryLastStatus -Scope Script -ErrorAction SilentlyContinue)) {
    $script:FreshWinAppxInventoryLastStatus = $null
}

function Clear-FreshWinSoftwareInventoryCache {
    [CmdletBinding()]
    param()

    $script:FreshWinSoftwareInventoryCache = $null
    $script:FreshWinSoftwareInventoryCacheIncludesUpdates = $false
    $script:FreshWinSoftwareInventoryLastStatus = $null
    $script:FreshWinRegistryInventoryLastStatus = $null
    $script:FreshWinAppxInventoryLastStatus = $null
}

function Remove-FreshWinTerminalControlSequence {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    return $Text -replace "`e\[[0-9;?]*[ -/]*[@-~]", '' -replace "`r", ''
}

function Get-FreshWinWingetJsonPackageNodes {
    param([AllowNull()][object]$InputObject)

    $results = New-Object System.Collections.Generic.List[object]
    if ($null -eq $InputObject -or $InputObject -is [string]) { return $results.ToArray() }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [System.Collections.IDictionary] -and $InputObject -isnot [pscustomobject]) {
        foreach ($item in $InputObject) {
            foreach ($node in @(Get-FreshWinWingetJsonPackageNodes -InputObject $item)) { $results.Add($node) }
        }
        return $results.ToArray()
    }

    $id = Get-FreshWinObjectProperty -InputObject $InputObject -Name @('PackageIdentifier', 'PackageId', 'Id')
    $name = Get-FreshWinObjectProperty -InputObject $InputObject -Name @('PackageName', 'Name', 'DisplayName')
    $version = Get-FreshWinObjectProperty -InputObject $InputObject -Name @('InstalledVersion', 'Version')
    if ($null -ne $id -and ($null -ne $name -or $null -ne $version)) {
        $results.Add($InputObject)
        return $results.ToArray()
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if ($property.Name -match '^(PS|Count|Length)') { continue }
        foreach ($node in @(Get-FreshWinWingetJsonPackageNodes -InputObject $property.Value)) { $results.Add($node) }
    }
    return $results.ToArray()
}

function ConvertFrom-FreshWinWingetOutput {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Output,

        [ValidateSet('Installed', 'Upgrade')]
        [string]$Mode = 'Installed'
    )

    $script:FreshWinWingetLastParseStatus = [pscustomobject]@{
        Recognized = $false
        Format     = 'Empty'
        RecordCount = 0
        Reason     = 'WinGet returned no parseable output; an empty result was not proven.'
    }
    if ($null -eq $Output) { return @() }
    $text = if ($Output -is [System.Array]) { (@($Output) -join "`n") } else { [string]$Output }
    $text = Remove-FreshWinTerminalControlSequence -Text $text
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    $trimmed = $text.Trim()
    $recognizedNoResult = if ($Mode -eq 'Upgrade') {
        $trimmed -match '(?i)^(?:No applicable upgrade found|No package found(?: matching input criteria)?)\.?\s*$'
    }
    else {
        $trimmed -match '(?i)^(?:No installed package found(?: matching input criteria)?|No package found(?: matching input criteria)?)\.?\s*$'
    }
    if ($recognizedNoResult) {
        $script:FreshWinWingetLastParseStatus = [pscustomobject]@{
            Recognized = $true
            Format     = 'NoResults'
            RecordCount = 0
            Reason     = 'WinGet explicitly reported that no matching records were available.'
        }
        return @()
    }
    if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
        try {
            $json = $trimmed | ConvertFrom-Json -ErrorAction Stop
            $jsonRecords = @()
            foreach ($package in @(Get-FreshWinWingetJsonPackageNodes -InputObject $json)) {
                $id = [string](Get-FreshWinObjectProperty -InputObject $package -Name @('PackageIdentifier', 'PackageId', 'Id'))
                $name = [string](Get-FreshWinObjectProperty -InputObject $package -Name @('PackageName', 'Name', 'DisplayName') -Default $id)
                $installedVersion = Get-FreshWinObjectProperty -InputObject $package -Name @('InstalledVersion', 'Version')
                $availableVersion = Get-FreshWinObjectProperty -InputObject $package -Name @('AvailableVersion', 'Available')
                $jsonRecords += [pscustomobject][ordered]@{
                    Name             = $name
                    DisplayName      = $name
                    Version          = $installedVersion
                    WingetId         = $id
                    PackageId        = $id
                    Source           = 'Winget'
                    Repository       = Get-FreshWinObjectProperty -InputObject $package -Name @('Source', 'SourceName')
                    UpdateAvailable  = ($Mode -eq 'Upgrade' -or -not [string]::IsNullOrWhiteSpace([string]$availableVersion))
                    AvailableVersion = $availableVersion
                    State            = 'Installed'
                    DetectionSources = @('Winget')
                    IsLive           = $false
                    PlatformSupported = Test-FreshWinWindows
                }
            }
            $script:FreshWinWingetLastParseStatus = if ($jsonRecords.Count -gt 0) {
                [pscustomobject]@{
                    Recognized = $true
                    Format     = 'Json'
                    RecordCount = $jsonRecords.Count
                    Reason     = 'WinGet JSON output was parsed.'
                }
            }
            else {
                [pscustomobject]@{
                    Recognized = $false
                    Format     = 'Json'
                    RecordCount = 0
                    Reason     = 'WinGet JSON contained no package records; an empty result was not explicitly proven.'
                }
            }
            return $jsonRecords
        }
        catch {
            $script:FreshWinWingetLastParseStatus = [pscustomobject]@{
                Recognized = $false
                Format     = 'Json'
                RecordCount = 0
                Reason     = 'WinGet returned malformed or unsupported JSON output.'
            }
            return @()
        }
    }

    $lines = @($text -split "`n" | ForEach-Object { $_.TrimEnd() })
    $headerIndex = -1
    $idIndex = -1
    $versionIndex = -1
    $availableIndex = -1
    $sourceIndex = -1
    $tableDataIndex = -1
    $localizedColumnStarts = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -match '(?i)^\s*Name\s+' -and $line -match '(?i)\bId\b' -and $line -match '(?i)\bVersion\b') {
            $headerIndex = $index
            $idIndex = $line.IndexOf('Id', [StringComparison]::OrdinalIgnoreCase)
            $versionIndex = $line.IndexOf('Version', [StringComparison]::OrdinalIgnoreCase)
            $availableIndex = $line.IndexOf('Available', [StringComparison]::OrdinalIgnoreCase)
            $sourceIndex = $line.IndexOf('Source', [StringComparison]::OrdinalIgnoreCase)
            $tableDataIndex = $index + 1
            break
        }
    }
    if ($headerIndex -lt 0) {
        # WinGet localizes its table headings but preserves the column order and
        # dash-run separator. Infer the layout from that separator instead of
        # treating every non-English Windows installation as unknown. Package
        # identifiers are still required to be complete, untruncated tokens.
        for ($index = 1; $index -lt $lines.Count; $index++) {
            $separator = [string]$lines[$index]
            $runs = @()
            if ($separator -match '^\s*-{2,}(?:\s{2,}-{2,}){2,4}\s*$') {
                $runs = @([regex]::Matches($separator, '-{2,}'))
            }
            elseif ($separator -match '^\s*-{10,}\s*$') {
                # Some WinGet versions render one continuous rule even when
                # localized headings retain two-or-more-space column gaps.
                # Derive starts from those bounded header gaps.
                $headerFields = @([regex]::Matches([string]$lines[$index - 1], '\S.*?(?=\s{2,}|$)'))
                if ($headerFields.Count -ge 3 -and $headerFields.Count -le 5) { $runs = $headerFields }
            }
            if ($runs.Count -lt 3 -or $runs.Count -gt 5) { continue }
            $headerIndex = $index - 1
            $tableDataIndex = $index + 1
            $localizedColumnStarts = @($runs | ForEach-Object { [int]$_.Index })
            break
        }
    }
    $localizedLayout = $localizedColumnStarts.Count -ge 3
    if ($headerIndex -lt 0 -or (-not $localizedLayout -and ($idIndex -le 0 -or $versionIndex -le $idIndex))) {
        $script:FreshWinWingetLastParseStatus = [pscustomobject]@{
            Recognized = $false
            Format     = 'Table'
            RecordCount = 0
            Reason     = 'WinGet table columns were not recognized; inventory cannot be considered complete.'
        }
        return @()
    }

    $records = @()
    $truncatedIdentifierFound = $false
    for ($index = $tableDataIndex; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*-{3,}\s*$') { continue }

        if ($line -match '(?:\.{3}|…)' ) {
            # WinGet marks clipped cells with an ellipsis. A clipped display
            # name is harmless, but a row cannot safely establish package
            # identity when it is impossible to prove which cell was clipped.
            $truncatedIdentifierFound = $true
            break
        }

        if ($localizedLayout) {
            $idMatch = [regex]::Match($line, '(?<![A-Za-z0-9._+\-])(?<id>[A-Za-z0-9][A-Za-z0-9_+\-]*(?:\.[A-Za-z0-9][A-Za-z0-9_+\-]*)+)(?=\s{2,})')
            if (-not $idMatch.Success) { continue }
            $actualIdIndex = $idMatch.Groups['id'].Index
            $adjustedStarts = @($localizedColumnStarts | ForEach-Object {
                $actualIdIndex + ([int]$_ - [int]$localizedColumnStarts[1])
            })
            $minimumLength = [int]$adjustedStarts[-1] + 1
            $padded = $line.PadRight([Math]::Max($line.Length, $minimumLength))
            $idIndex = [int]$adjustedStarts[1]
            $versionIndex = [int]$adjustedStarts[2]
            $availableIndex = if ($adjustedStarts.Count -eq 5) { [int]$adjustedStarts[3] } else { -1 }
            $sourceIndex = if ($adjustedStarts.Count -ge 4) { [int]$adjustedStarts[-1] } else { -1 }
            $name = $padded.Substring(0, $idIndex).Trim()
            $id = $idMatch.Groups['id'].Value
        }
        else {
            if ($line.Length -le $idIndex) { continue }
            $requiredLength = $versionIndex + 1
            if ($availableIndex -ge 0) { $requiredLength = [Math]::Max($requiredLength, ($availableIndex + 1)) }
            if ($sourceIndex -ge 0) { $requiredLength = [Math]::Max($requiredLength, ($sourceIndex + 1)) }
            if ($idIndex -lt 0 -or $versionIndex -le $idIndex -or $requiredLength -le 0) {
                $truncatedIdentifierFound = $true
                break
            }
            $padded = $line.PadRight([Math]::Max($line.Length, $requiredLength))
            $name = $padded.Substring(0, $idIndex).Trim()
            $id = $padded.Substring($idIndex, $versionIndex - $idIndex).Trim()
        }

        $versionEnd = $padded.Length
        if ($availableIndex -gt $versionIndex) { $versionEnd = $availableIndex }
        elseif ($sourceIndex -gt $versionIndex) { $versionEnd = $sourceIndex }
        if ($versionIndex -lt 0 -or $versionIndex -ge $padded.Length -or
            $versionEnd -le $versionIndex -or $versionEnd -gt $padded.Length) {
            $truncatedIdentifierFound = $true
            break
        }
        $version = $padded.Substring($versionIndex, $versionEnd - $versionIndex).Trim()
        if ([string]::IsNullOrWhiteSpace($version)) {
            $truncatedIdentifierFound = $true
            break
        }
        $available = $null
        if ($availableIndex -gt $versionIndex) {
            $availableEnd = $(if ($sourceIndex -gt $availableIndex) { $sourceIndex } else { $padded.Length })
            if ($availableIndex -lt 0 -or $availableIndex -ge $padded.Length -or
                $availableEnd -le $availableIndex -or $availableEnd -gt $padded.Length) {
                $truncatedIdentifierFound = $true
                break
            }
            $available = $padded.Substring($availableIndex, $availableEnd - $availableIndex).Trim()
        }
        $repository = $null
        if ($sourceIndex -gt $versionIndex -and $padded.Length -gt $sourceIndex) { $repository = $padded.Substring($sourceIndex).Trim() }

        if ([string]::IsNullOrWhiteSpace($id) -or $id -match '^[-]+$') { continue }
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_+\-]*(?:\.[A-Za-z0-9][A-Za-z0-9_+\-]*)+$') {
            $truncatedIdentifierFound = $true
            break
        }
        if ($name -match '(?i)^(Name|The following packages)') { continue }
        $records += [pscustomobject][ordered]@{
            Name              = $name
            DisplayName       = $name
            Version           = $version
            WingetId          = $id
            PackageId         = $id
            Source            = 'Winget'
            Repository        = $repository
            UpdateAvailable   = ($Mode -eq 'Upgrade' -or -not [string]::IsNullOrWhiteSpace([string]$available))
            AvailableVersion  = $available
            State             = 'Installed'
            DetectionSources  = @('Winget')
            IsLive            = $false
            PlatformSupported = Test-FreshWinWindows
        }
    }
    if ($truncatedIdentifierFound) {
        $script:FreshWinWingetLastParseStatus = [pscustomobject]@{
            Recognized = $false
            Format     = 'Table'
            RecordCount = 0
            Reason     = 'WinGet table output contains a truncated or invalid package identifier; inventory cannot be considered complete.'
        }
        return @()
    }
    if ($records.Count -eq 0) {
        $script:FreshWinWingetLastParseStatus = [pscustomobject]@{
            Recognized = $false
            Format     = 'Table'
            RecordCount = 0
            Reason     = 'The WinGet table layout was recognized, but no complete package record was present; an empty result was not explicitly proven.'
        }
        return @()
    }
    $script:FreshWinWingetLastParseStatus = [pscustomobject]@{
        Recognized = $true
        Format     = 'Table'
        RecordCount = $records.Count
        Reason     = 'WinGet table output was parsed.'
    }
    return $records
}

function Get-FreshWinWingetInventoryVersionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WingetPath,
        [scriptblock]$VersionProvider
    )

    $minimumVersion = [version]'1.29.0'
    try {
        $result = if ($null -ne $VersionProvider) {
            & $VersionProvider $WingetPath
        }
        else {
            Invoke-FreshWinProcess -FilePath $WingetPath -ArgumentList @('--version') `
                -TimeoutSeconds 30 -ExpectedExitCodes @(0)
        }
        if ($null -eq $result) { throw 'WinGet returned no version result.' }

        $succeededProperty = $result.PSObject.Properties['Succeeded']
        if ($null -ne $succeededProperty -and -not [bool]$succeededProperty.Value) {
            $exitCode = Get-FreshWinObjectProperty -InputObject $result -Name @('ExitCode', 'Code')
            throw "WinGet version query exited with code $exitCode."
        }
        $versionText = if ($result -is [string]) { [string]$result } else {
            @(
                [string](Get-FreshWinObjectProperty -InputObject $result -Name @('StandardOutput', 'StdOut')),
                [string](Get-FreshWinObjectProperty -InputObject $result -Name @('StandardError', 'StdErr'))
            ) -join ' '
        }
        $match = [regex]::Match($versionText, '(?i)(?:^|\s)v?(?<version>\d+\.\d+(?:\.\d+){0,2})(?=$|[\s-])')
        if (-not $match.Success) { throw 'WinGet returned an unrecognized version string.' }

        $version = [version]$match.Groups['version'].Value
        $supported = $version -ge $minimumVersion
        return [pscustomobject]@{
            Supported = $supported
            Version = $version.ToString()
            MinimumVersion = $minimumVersion.ToString()
            Reason = if ($supported) { $null } else {
                "WinGet $version is too old for safe redirected inventory. Update Microsoft App Installer to WinGet $minimumVersion or newer; earlier clients can truncate package identifiers."
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Supported = $false
            Version = $null
            MinimumVersion = $minimumVersion.ToString()
            Reason = "WinGet version could not be verified: $($_.Exception.Message) FreshWin requires WinGet $minimumVersion or newer for non-truncated redirected inventory."
        }
    }
}

function Get-FreshWinWingetInventoryExitPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('list', 'upgrade')][string]$Operation)

    # WinGet uses HRESULTs for healthy empty queries. Treating these as
    # provider failures would turn a clean/up-to-date host into Unknown.
    $emptyExitCodes = if ($Operation -eq 'upgrade') {
        @(-1978335189, -1978335212) # UPDATE_NOT_APPLICABLE, NO_APPLICATIONS_FOUND
    } else {
        @(-1978335212) # NO_APPLICATIONS_FOUND
    }
    return [pscustomobject]@{
        ExpectedExitCodes = [int[]](@(0) + $emptyExitCodes)
        EmptyExitCodes = [int[]]$emptyExitCodes
    }
}

function ConvertFrom-FreshWinWingetQueryEvidence {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Query,
        [Parameter(Mandatory = $true)][ValidateSet('Installed', 'Upgrade')][string]$Mode
    )

    $operation = if ($Mode -eq 'Upgrade') { 'upgrade' } else { 'list' }
    $emptyResult = [bool](Get-FreshWinObjectProperty -InputObject $Query -Name @('EmptyResult') -Default $false)
    if ($emptyResult) {
        $exitCode = Get-FreshWinObjectProperty -InputObject $Query -Name @('ExitCode')
        $exitPolicy = Get-FreshWinWingetInventoryExitPolicy -Operation $operation
        if ($null -ne $exitCode -and [int]$exitCode -in @($exitPolicy.EmptyExitCodes)) {
            $script:FreshWinWingetLastParseStatus = [pscustomobject]@{
                Recognized = $true
                Format = 'EmptyResult'
                RecordCount = 0
                Reason = "WinGet $operation returned an allowlisted healthy-empty HRESULT."
            }
            return @()
        }

        $script:FreshWinWingetLastParseStatus = [pscustomobject]@{
            Recognized = $false
            Format = 'EmptyResult'
            RecordCount = 0
            Reason = "WinGet $operation reported empty-result evidence with an exit code that is not allowlisted for this operation."
        }
        return @()
    }

    $output = Get-FreshWinObjectProperty -InputObject $Query -Name @('Output')
    return @(ConvertFrom-FreshWinWingetOutput -Output $output -Mode $Mode)
}

function Invoke-FreshWinWingetInventoryQuery {
    [CmdletBinding()]
    param(
        [ValidateSet('list', 'upgrade')]
        [string]$Operation = 'list',

        [ValidateRange(5, 300)]
        [int]$TimeoutSeconds = 60
    )

    if (-not (Test-FreshWinWindows)) {
        return [pscustomobject]@{ Available = $false; ExitCode = $null; Output = @(); Error = 'WinGet is unavailable on this platform.'; TimedOut = $false; EmptyResult = $false }
    }
    if ($null -eq (Get-Command -Name Resolve-FreshWinTrustedWingetPath -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; ExitCode = $null; Output = @(); Error = 'The trusted WinGet resolver is not loaded.'; TimedOut = $false; EmptyResult = $false }
    }
    $wingetPath = Resolve-FreshWinTrustedWingetPath
    if ([string]::IsNullOrWhiteSpace($wingetPath)) {
        return [pscustomobject]@{ Available = $false; ExitCode = $null; Output = @(); Error = 'A trusted Microsoft App Installer WinGet executable was not found.'; TimedOut = $false; EmptyResult = $false }
    }
    if ($null -eq (Get-Command -Name Invoke-FreshWinProcess -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; ExitCode = $null; Output = @(); Error = 'The bounded FreshWin process runner is not loaded.'; TimedOut = $false; EmptyResult = $false }
    }
    if ($null -eq (Get-Command -Name Test-FreshWinTrustedWingetSource -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; ExitCode = $null; Output = @(); Error = 'The trusted WinGet source validator is not loaded.'; TimedOut = $false; EmptyResult = $false }
    }
    $versionState = Get-FreshWinWingetInventoryVersionState -WingetPath $wingetPath
    if (-not [bool]$versionState.Supported) {
        return [pscustomobject]@{ Available = $false; ExitCode = $null; Output = @(); Error = [string]$versionState.Reason; TimedOut = $false; EmptyResult = $false }
    }
    $sourceTrust = Test-FreshWinTrustedWingetSource -SourceName winget -WingetPath $wingetPath
    if (-not [bool]$sourceTrust.Trusted) {
        return [pscustomobject]@{ Available = $false; ExitCode = $null; Output = @(); Error = [string]$sourceTrust.Reason; TimedOut = $false; EmptyResult = $false }
    }

    # Inventory is read-only and must not persist source-agreement acceptance.
    # Query only the separately validated community source. An unrelated
    # Microsoft Store agreement must not make community-package inventory
    # unavailable or turn known negatives into Unknown.
    $arguments = @($Operation, '--source', 'winget', '--disable-interactivity')
    try {
        $exitPolicy = Get-FreshWinWingetInventoryExitPolicy -Operation $Operation
        $processResult = Invoke-FreshWinProcess -FilePath $wingetPath -ArgumentList $arguments `
            -TimeoutSeconds $TimeoutSeconds -ExpectedExitCodes ([int[]]$exitPolicy.ExpectedExitCodes)
        $emptyResult = $processResult.ExitCode -in @($exitPolicy.EmptyExitCodes)
        $output = @()
        if (-not $emptyResult -and -not [string]::IsNullOrWhiteSpace([string]$processResult.StandardOutput)) {
            $output = @([string]$processResult.StandardOutput -split '\r?\n')
        }
        if (-not $emptyResult -and -not [string]::IsNullOrWhiteSpace([string]$processResult.StandardError)) {
            $output += @([string]$processResult.StandardError -split '\r?\n')
        }
        $errorMessage = $null
        if ($processResult.TimedOut) { $errorMessage = "WinGet inventory exceeded the $TimeoutSeconds second timeout." }
        elseif (-not $processResult.Succeeded) { $errorMessage = "WinGet exited with code $($processResult.ExitCode)." }
        return [pscustomobject]@{
            Available = [bool]$processResult.Succeeded
            ExitCode  = $processResult.ExitCode
            Output    = $output
            Error     = $errorMessage
            TimedOut  = [bool]$processResult.TimedOut
            EmptyResult = $emptyResult
        }
    }
    catch {
        return [pscustomobject]@{ Available = $false; ExitCode = $null; Output = @(); Error = $_.Exception.Message; TimedOut = $false; EmptyResult = $false }
    }
}

function Get-FreshWinRegistrySoftwareInventory {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$RegistryEntries
    )

    $provided = $PSBoundParameters.ContainsKey('RegistryEntries')
    if (-not (Test-FreshWinWindows) -and -not $provided) {
        $script:FreshWinRegistryInventoryLastStatus = [pscustomobject]@{
            Available = $false; Status = 'Unsupported'; Errors = @('Registry software inventory is unavailable on this platform.')
        }
        return @()
    }
    if (-not $provided) {
        $RegistryEntries = @()
        $registryErrors = New-Object System.Collections.Generic.List[string]
        $uninstallRoots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        foreach ($root in $uninstallRoots) {
            try {
                $basePath = $root.Substring(0, $root.Length - 2)
                if (Test-Path -LiteralPath $basePath -PathType Container -ErrorAction Stop) {
                    $RegistryEntries += @(Get-ItemProperty -Path $root -ErrorAction Stop)
                }
            }
            catch {
                $registryErrors.Add("Registry inventory failed for '$root': $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)")
            }
        }
        $script:FreshWinRegistryInventoryLastStatus = [pscustomobject]@{
            Available = $registryErrors.Count -eq 0
            Status = $(if ($registryErrors.Count -eq 0) { 'Ready' } elseif ($RegistryEntries.Count -gt 0) { 'Partial' } else { 'Unknown' })
            Errors = $registryErrors.ToArray()
        }
    }
    else {
        $script:FreshWinRegistryInventoryLastStatus = [pscustomobject]@{
            Available = $true; Status = 'Fixture'; Errors = @()
        }
    }

    $records = @()
    foreach ($entry in @($RegistryEntries)) {
        if ($null -eq $entry) { continue }
        $displayName = [string](Get-FreshWinObjectProperty -InputObject $entry -Name @('DisplayName', 'Name'))
        if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
        $systemComponent = Get-FreshWinObjectProperty -InputObject $entry -Name @('SystemComponent') -Default 0
        if ([int]$systemComponent -eq 1) { continue }
        $records += [pscustomobject][ordered]@{
            Name              = $displayName
            DisplayName       = $displayName
            Version           = Get-FreshWinObjectProperty -InputObject $entry -Name @('DisplayVersion', 'Version')
            WingetId          = $null
            PackageId         = $null
            Source            = 'Registry'
            Repository        = $null
            Publisher         = Get-FreshWinObjectProperty -InputObject $entry -Name @('Publisher')
            InstallLocation   = Get-FreshWinObjectProperty -InputObject $entry -Name @('InstallLocation')
            RegistryKey       = Get-FreshWinObjectProperty -InputObject $entry -Name @('PSChildName', 'RegistryKey')
            RegistryPath      = Get-FreshWinObjectProperty -InputObject $entry -Name @('PSPath', 'RegistryPath')
            UpdateAvailable   = $false
            AvailableVersion  = $null
            State             = 'Installed'
            DetectionSources  = @('Registry')
            IsLive            = ((Test-FreshWinWindows) -and -not $provided)
            PlatformSupported = Test-FreshWinWindows
        }
    }
    return $records
}

function Get-FreshWinAppxSoftwareInventory {
    [CmdletBinding()]
    param([AllowNull()][object[]]$AppxPackages)

    $provided = $PSBoundParameters.ContainsKey('AppxPackages')
    if (-not (Test-FreshWinWindows) -and -not $provided) {
        $script:FreshWinAppxInventoryLastStatus = [pscustomobject]@{
            Available=$false; Status='Unsupported'; Errors=@('AppX inventory is unavailable on this platform.')
        }
        return @()
    }
    if (-not $provided) {
        try {
            $AppxPackages = @(Get-AppxPackage -ErrorAction Stop)
            if ($AppxPackages.Count -gt 20000) { throw 'AppX inventory exceeded the 20000-record safety limit.' }
            $script:FreshWinAppxInventoryLastStatus = [pscustomobject]@{ Available=$true; Status='Ready'; Errors=@() }
        }
        catch {
            $script:FreshWinAppxInventoryLastStatus = [pscustomobject]@{
                Available=$false; Status='Unknown'
                Errors=@("AppX inventory failed: $(Protect-FreshWinSensitiveText -Text $_.Exception.Message)")
            }
            return @()
        }
    }
    else {
        $script:FreshWinAppxInventoryLastStatus = [pscustomobject]@{ Available=$true; Status='Fixture'; Errors=@() }
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($AppxPackages)) {
        if ($null -eq $package) { continue }
        $name = [string](Get-FreshWinObjectProperty -InputObject $package -Name @('Name'))
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,199}$') { continue }
        $displayName = [string](Get-FreshWinObjectProperty -InputObject $package -Name @('DisplayName') -Default $name)
        if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $name }
        $records.Add([pscustomobject][ordered]@{
            Name              = $displayName
            DisplayName       = $displayName
            Version           = Get-FreshWinObjectProperty -InputObject $package -Name @('Version')
            WingetId          = $null
            PackageId         = $null
            AppxName          = $name
            PackageFamilyName = Get-FreshWinObjectProperty -InputObject $package -Name @('PackageFamilyName')
            Source            = 'Appx'
            Repository        = 'msstore'
            UpdateAvailable   = $false
            AvailableVersion  = $null
            State             = 'Installed'
            DetectionSources  = @('Appx')
            IsLive            = ((Test-FreshWinWindows) -and -not $provided)
            PlatformSupported = Test-FreshWinWindows
        })
    }
    return $records.ToArray()
}

function Get-FreshWinDefaultKnownPaths {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{ Name = 'Google Chrome'; PackageId = 'Google.Chrome'; Paths = @('%ProgramFiles%\Google\Chrome\Application\chrome.exe', '%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe', '%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe') },
        [pscustomobject]@{ Name = 'Visual Studio Code'; PackageId = 'Microsoft.VisualStudioCode'; Paths = @('%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe', '%ProgramFiles%\Microsoft VS Code\Code.exe') },
        [pscustomobject]@{ Name = 'Discord'; PackageId = 'Discord.Discord'; Paths = @('%LOCALAPPDATA%\Discord\Update.exe') },
        [pscustomobject]@{ Name = 'UniKey'; PackageId = 'UniKey.UniKey'; Paths = @('%ProgramFiles%\UniKey\UniKeyNT.exe', '%ProgramFiles(x86)%\UniKey\UniKeyNT.exe') },
        [pscustomobject]@{ Name = 'WinRAR'; PackageId = 'RARLab.WinRAR'; Paths = @('%ProgramFiles%\WinRAR\WinRAR.exe', '%ProgramFiles(x86)%\WinRAR\WinRAR.exe') }
    )
}

function Get-FreshWinKnownPathSoftwareInventory {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$KnownPaths
    )

    if (-not $PSBoundParameters.ContainsKey('KnownPaths')) { $KnownPaths = Get-FreshWinDefaultKnownPaths }
    $records = @()
    foreach ($definition in @($KnownPaths)) {
        if ($null -eq $definition) { continue }
        foreach ($pathTemplate in @((Get-FreshWinObjectProperty -InputObject $definition -Name @('Paths', 'KnownPaths') -Default @()))) {
            if ([string]::IsNullOrWhiteSpace([string]$pathTemplate)) { continue }
            if ($null -eq (Get-Command -Name Expand-FreshWinKnownPath -ErrorAction SilentlyContinue)) { continue }
            $expandedPath = Expand-FreshWinKnownPath -Path ([string]$pathTemplate)
            if ([string]::IsNullOrWhiteSpace($expandedPath)) { continue }
            if ($null -ne (Get-Command -Name Test-FreshWinKnownPathLeaf -ErrorAction SilentlyContinue)) {
                if (-not (Test-FreshWinKnownPathLeaf -Path $expandedPath)) { continue }
            }
            elseif (-not [System.IO.File]::Exists($expandedPath) -or
                (([System.IO.File]::GetAttributes($expandedPath) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { continue }
            $version = $null
            try { $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($expandedPath).ProductVersion } catch { }
            $packageId = [string](Get-FreshWinObjectProperty -InputObject $definition -Name @('PackageId', 'Id'))
            $records += [pscustomobject][ordered]@{
                Name              = [string](Get-FreshWinObjectProperty -InputObject $definition -Name @('Name', 'DisplayName') -Default $packageId)
                DisplayName       = [string](Get-FreshWinObjectProperty -InputObject $definition -Name @('DisplayName', 'Name') -Default $packageId)
                Version           = $version
                WingetId          = Get-FreshWinObjectProperty -InputObject $definition -Name @('WingetId')
                PackageId         = $packageId
                Source            = 'KnownPath'
                Repository        = $null
                ExecutablePath    = $expandedPath
                UpdateAvailable   = $false
                AvailableVersion  = $null
                State             = 'Installed'
                DetectionSources  = @('KnownPath')
                IsLive            = $true
                PlatformSupported = Test-FreshWinWindows
            }
            break
        }
    }
    return $records
}

function Get-FreshWinSoftwareIdentityKey {
    param([Parameter(Mandatory = $true)][object]$Record)
    $packageId = [string](Get-FreshWinObjectProperty -InputObject $Record -Name @('WingetId', 'PackageId'))
    if (-not [string]::IsNullOrWhiteSpace($packageId)) { return 'id:' + $packageId.Trim().ToLowerInvariant() }
    $appxName = [string](Get-FreshWinObjectProperty -InputObject $Record -Name @('AppxName'))
    if (-not [string]::IsNullOrWhiteSpace($appxName)) { return 'appx:' + $appxName.Trim().ToLowerInvariant() }
    $name = [string](Get-FreshWinObjectProperty -InputObject $Record -Name @('DisplayName', 'Name'))
    return 'name:' + (($name.ToLowerInvariant()) -replace '[^a-z0-9]+', '')
}

function Merge-FreshWinSoftwareInventory {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $byKey = @{}
    $nameKeys = @{}
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $key = Get-FreshWinSoftwareIdentityKey -Record $record
        $nameKey = 'name:' + (([string]$record.DisplayName).ToLowerInvariant() -replace '[^a-z0-9]+', '')
        if (-not $byKey.ContainsKey($key) -and $nameKeys.ContainsKey($nameKey)) { $key = $nameKeys[$nameKey] }
        if (-not $byKey.ContainsKey($key)) {
            $clone = [pscustomobject][ordered]@{
                Name              = [string](Get-FreshWinObjectProperty -InputObject $record -Name @('Name', 'DisplayName'))
                DisplayName       = [string](Get-FreshWinObjectProperty -InputObject $record -Name @('DisplayName', 'Name'))
                Version           = Get-FreshWinObjectProperty -InputObject $record -Name @('Version')
                WingetId          = Get-FreshWinObjectProperty -InputObject $record -Name @('WingetId')
                PackageId         = Get-FreshWinObjectProperty -InputObject $record -Name @('PackageId', 'WingetId')
                AppxName          = Get-FreshWinObjectProperty -InputObject $record -Name @('AppxName')
                PackageFamilyName = Get-FreshWinObjectProperty -InputObject $record -Name @('PackageFamilyName')
                Source            = Get-FreshWinObjectProperty -InputObject $record -Name @('Source')
                DetectionSources  = @((Get-FreshWinObjectProperty -InputObject $record -Name @('DetectionSources') -Default @($record.Source)))
                Publisher         = Get-FreshWinObjectProperty -InputObject $record -Name @('Publisher')
                InstallLocation   = Get-FreshWinObjectProperty -InputObject $record -Name @('InstallLocation', 'ExecutablePath')
                UpdateAvailable   = [bool](Get-FreshWinObjectProperty -InputObject $record -Name @('UpdateAvailable') -Default $false)
                AvailableVersion  = Get-FreshWinObjectProperty -InputObject $record -Name @('AvailableVersion')
                State             = Get-FreshWinObjectProperty -InputObject $record -Name @('State') -Default 'Installed'
                IsLive            = [bool](Get-FreshWinObjectProperty -InputObject $record -Name @('IsLive') -Default $false)
                PlatformSupported = [bool](Get-FreshWinObjectProperty -InputObject $record -Name @('PlatformSupported') -Default (Test-FreshWinWindows))
            }
            $byKey[$key] = $clone
            $nameKeys[$nameKey] = $key
            continue
        }

        $existing = $byKey[$key]
        foreach ($propertyName in @('Version', 'WingetId', 'PackageId', 'AppxName', 'PackageFamilyName', 'Publisher', 'InstallLocation', 'AvailableVersion')) {
            $incoming = Get-FreshWinObjectProperty -InputObject $record -Name @($propertyName)
            if ($null -ne $incoming -and -not [string]::IsNullOrWhiteSpace([string]$incoming)) {
                if ($propertyName -in @('WingetId', 'PackageId', 'AvailableVersion') -or $null -eq $existing.$propertyName -or [string]::IsNullOrWhiteSpace([string]$existing.$propertyName)) {
                    $existing.$propertyName = $incoming
                }
            }
        }
        $existing.UpdateAvailable = $existing.UpdateAvailable -or [bool](Get-FreshWinObjectProperty -InputObject $record -Name @('UpdateAvailable') -Default $false)
        $existing.IsLive = $existing.IsLive -or [bool](Get-FreshWinObjectProperty -InputObject $record -Name @('IsLive') -Default $false)
        $existing.PlatformSupported = $existing.PlatformSupported -or [bool](Get-FreshWinObjectProperty -InputObject $record -Name @('PlatformSupported') -Default $false)
        $sources = @($existing.DetectionSources) + @((Get-FreshWinObjectProperty -InputObject $record -Name @('DetectionSources') -Default @($record.Source)))
        $existing.DetectionSources = @($sources | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        if ($existing.DetectionSources -contains 'Winget') { $existing.Source = 'Winget' }
    }
    return @($byKey.Values | Sort-Object DisplayName)
}

function Get-FreshWinSoftwareInventory {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$WingetOutput,

        [AllowNull()]
        [object]$WingetUpgradeOutput,

        [AllowNull()]
        [object[]]$RegistryEntries,

        [AllowNull()]
        [object[]]$KnownPaths,

        [AllowNull()]
        [object[]]$AppxPackages,

        [scriptblock]$WingetQueryProvider,

        [switch]$SkipWinget,

        [switch]$SkipRegistry,

        [switch]$SkipKnownPaths,

        [switch]$SkipAppx,

        [switch]$IncludeUpdates,

        [switch]$Refresh
    )

    $provided = $PSBoundParameters.ContainsKey('WingetOutput') -or
        $PSBoundParameters.ContainsKey('WingetUpgradeOutput') -or
        $PSBoundParameters.ContainsKey('WingetQueryProvider') -or
        $PSBoundParameters.ContainsKey('RegistryEntries') -or
        $PSBoundParameters.ContainsKey('KnownPaths') -or
        $PSBoundParameters.ContainsKey('AppxPackages')
    if (-not (Test-FreshWinWindows) -and -not $provided) {
        $unsupported = New-FreshWinUnsupportedResult -Component 'SoftwareInventory'
        $unsupported | Add-Member -NotePropertyName Name -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName DisplayName -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName Version -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName WingetId -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName PackageId -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName Source -NotePropertyValue 'Unsupported'
        $unsupported | Add-Member -NotePropertyName UpdateAvailable -NotePropertyValue $false
        $unsupported | Add-Member -NotePropertyName AvailableVersion -NotePropertyValue $null
        $script:FreshWinSoftwareInventoryLastStatus = [pscustomobject]@{
            Available = $false; Status = 'Unsupported'; Errors = @('Software inventory is unavailable on this platform.')
        }
        return @($unsupported)
    }

    $useCache = -not $provided -and -not $Refresh -and
        (-not [bool]$IncludeUpdates -or [bool]$script:FreshWinSoftwareInventoryCacheIncludesUpdates)
    if ($useCache -and $null -ne $script:FreshWinSoftwareInventoryCache) {
        return @($script:FreshWinSoftwareInventoryCache)
    }

    $records = @()
    $inventoryErrors = New-Object System.Collections.Generic.List[string]
    $updateErrors = New-Object System.Collections.Generic.List[string]
    $updatesAvailable = $null
    if (-not $SkipWinget) {
        if ($PSBoundParameters.ContainsKey('WingetOutput')) {
            $wingetRecords = @(ConvertFrom-FreshWinWingetOutput -Output $WingetOutput -Mode Installed)
            if (-not [bool]$script:FreshWinWingetLastParseStatus.Recognized) {
                $inventoryErrors.Add([string]$script:FreshWinWingetLastParseStatus.Reason)
            }
            else { $records += $wingetRecords }
        }
        else {
            $query = if ($null -ne $WingetQueryProvider) { & $WingetQueryProvider 'list' } else { Invoke-FreshWinWingetInventoryQuery -Operation list }
            if ([bool](Get-FreshWinObjectProperty -InputObject $query -Name @('Available') -Default $false)) {
                $wingetRecords = @(ConvertFrom-FreshWinWingetQueryEvidence -Query $query -Mode Installed)
                if (-not [bool]$script:FreshWinWingetLastParseStatus.Recognized) {
                    $inventoryErrors.Add([string]$script:FreshWinWingetLastParseStatus.Reason)
                }
                else { $records += $wingetRecords }
            }
            else {
                $queryError = [string](Get-FreshWinObjectProperty -InputObject $query -Name @('Error'))
                if (-not [string]::IsNullOrWhiteSpace($queryError)) { $inventoryErrors.Add($queryError) }
            }
        }

        if ($IncludeUpdates -or $PSBoundParameters.ContainsKey('WingetUpgradeOutput')) {
            if ($PSBoundParameters.ContainsKey('WingetUpgradeOutput')) {
                $upgradeRecords = @(ConvertFrom-FreshWinWingetOutput -Output $WingetUpgradeOutput -Mode Upgrade)
                if (-not [bool]$script:FreshWinWingetLastParseStatus.Recognized) {
                    $updateErrors.Add([string]$script:FreshWinWingetLastParseStatus.Reason)
                    $updatesAvailable = $false
                    $upgradeRecords = @()
                }
                else { $updatesAvailable = $true }
            }
            else {
                $upgradeQuery = if ($null -ne $WingetQueryProvider) { & $WingetQueryProvider 'upgrade' } else { Invoke-FreshWinWingetInventoryQuery -Operation upgrade }
                if ([bool](Get-FreshWinObjectProperty -InputObject $upgradeQuery -Name @('Available') -Default $false)) {
                    $upgradeRecords = @(ConvertFrom-FreshWinWingetQueryEvidence -Query $upgradeQuery -Mode Upgrade)
                    if (-not [bool]$script:FreshWinWingetLastParseStatus.Recognized) {
                        $updateErrors.Add([string]$script:FreshWinWingetLastParseStatus.Reason)
                        $updatesAvailable = $false
                        $upgradeRecords = @()
                    }
                    else { $updatesAvailable = $true }
                }
                else { $upgradeRecords = @(); $updatesAvailable = $false }
                if (-not [bool](Get-FreshWinObjectProperty -InputObject $upgradeQuery -Name @('Available') -Default $false)) {
                    $upgradeError = [string](Get-FreshWinObjectProperty -InputObject $upgradeQuery -Name @('Error'))
                    if (-not [string]::IsNullOrWhiteSpace($upgradeError)) { $updateErrors.Add($upgradeError) }
                }
            }
            $records += $upgradeRecords
        }
    }
    if (-not $SkipRegistry) {
        if ($PSBoundParameters.ContainsKey('RegistryEntries')) { $registryRecords = @(Get-FreshWinRegistrySoftwareInventory -RegistryEntries $RegistryEntries) }
        else { $registryRecords = @(Get-FreshWinRegistrySoftwareInventory) }
        $records += $registryRecords
        if ($null -ne $script:FreshWinRegistryInventoryLastStatus -and -not [bool]$script:FreshWinRegistryInventoryLastStatus.Available) {
            foreach ($registryError in @($script:FreshWinRegistryInventoryLastStatus.Errors)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$registryError)) { $inventoryErrors.Add([string]$registryError) }
            }
        }
    }
    if (-not $SkipKnownPaths) {
        if ($PSBoundParameters.ContainsKey('KnownPaths')) { $records += @(Get-FreshWinKnownPathSoftwareInventory -KnownPaths $KnownPaths) }
        else { $records += @(Get-FreshWinKnownPathSoftwareInventory) }
    }

    $appxScanned = $false
    if (-not $SkipAppx -and ($PSBoundParameters.ContainsKey('AppxPackages') -or -not $provided)) {
        $appxScanned = $true
        if ($PSBoundParameters.ContainsKey('AppxPackages')) { $records += @(Get-FreshWinAppxSoftwareInventory -AppxPackages $AppxPackages) }
        else { $records += @(Get-FreshWinAppxSoftwareInventory) }
    }

    $merged = @(Merge-FreshWinSoftwareInventory -Records $records)
    if (-not $provided) {
        foreach ($record in $merged) { $record.IsLive = $true }
        $script:FreshWinSoftwareInventoryCache = $merged
        $script:FreshWinSoftwareInventoryCacheIncludesUpdates = [bool]$IncludeUpdates
    }
    $appxAvailable = if ($appxScanned -and $null -ne $script:FreshWinAppxInventoryLastStatus) {
        [bool]$script:FreshWinAppxInventoryLastStatus.Available
    } else { $null }
    $appxErrors = @(if ($appxScanned -and $null -ne $script:FreshWinAppxInventoryLastStatus) {
        @($script:FreshWinAppxInventoryLastStatus.Errors)
    })
    $allErrors = @($inventoryErrors.ToArray()) + @($updateErrors.ToArray()) + @($appxErrors)
    $ancillaryErrors = $updateErrors.Count + $appxErrors.Count
    $script:FreshWinSoftwareInventoryLastStatus = [pscustomobject]@{
        Available = $inventoryErrors.Count -eq 0
        AppxAvailable = $appxAvailable
        UpdatesAvailable = $updatesAvailable
        UpdateSourcesScanned = $(if ($updatesAvailable -eq $true) { @('winget') } else { @() })
        Status    = $(if ($inventoryErrors.Count -eq 0 -and $ancillaryErrors -eq 0) { 'Ready' } elseif ($inventoryErrors.Count -eq 0 -or $merged.Count -gt 0) { 'Partial' } else { 'Unknown' })
        Errors    = $allErrors
    }
    return $merged
}

function Get-FreshWinSoftwareInventorySnapshot {
    [CmdletBinding()]
    param(
        [switch]$Refresh,
        [switch]$IncludeUpdates
    )

    $items = @(Get-FreshWinSoftwareInventory -Refresh:$Refresh -IncludeUpdates:$IncludeUpdates)
    $unsupported = $items.Count -eq 1 -and
        [string](Get-FreshWinObjectProperty -InputObject $items[0] -Name @('Status')) -eq 'Unsupported'
    $lastStatus = $script:FreshWinSoftwareInventoryLastStatus
    $snapshotStatus = if ($unsupported) { 'Unsupported' }
        elseif ($null -ne $lastStatus) { [string]$lastStatus.Status }
        else { 'Ready' }
    return [pscustomobject][ordered]@{
        Component       = 'SoftwareInventory'
        IsSupported     = -not $unsupported
        Supported       = -not $unsupported
        IsLive          = -not $unsupported
        Status          = $snapshotStatus
        Platform        = Get-FreshWinPlatformName
        ItemCount       = $(if ($unsupported) { 0 } else { $items.Count })
        UpdateCount     = $(if ($unsupported) { 0 } else { @($items | Where-Object { $_.UpdateAvailable }).Count })
        UpdatesScanned  = $(if (-not [bool]$IncludeUpdates -or $unsupported -or $null -eq $lastStatus -or $null -eq $lastStatus.PSObject.Properties['UpdatesAvailable']) { $false } else { [bool]$lastStatus.UpdatesAvailable })
        UpdateSourcesScanned = $(if (-not [bool]$IncludeUpdates -or $unsupported -or $null -eq $lastStatus) { @() } else {
            @((Get-FreshWinPropertyValue -InputObject $lastStatus -Name 'UpdateSourcesScanned' -Default @()) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
        })
        Items           = $(if ($unsupported) { @() } else { $items })
        CacheRefreshed  = [bool]$Refresh
        Available       = $(if ($unsupported) { $false } elseif ($null -ne $lastStatus) { [bool]$lastStatus.Available } else { $true })
        AppxAvailable   = $(if ($unsupported -or $null -eq $lastStatus -or $null -eq $lastStatus.PSObject.Properties['AppxAvailable']) { $null } else { $lastStatus.AppxAvailable })
        Errors          = $(if ($null -ne $lastStatus) { @($lastStatus.Errors) } else { @() })
    }
}
