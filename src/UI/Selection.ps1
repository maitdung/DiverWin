Set-StrictMode -Version 2.0

function ConvertFrom-FreshWinSelection {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$InputText,
        [int[]]$AvailableIds,
        [AllowNull()][hashtable]$CommandMap,
        [AllowNull()][string[]]$AllowedCommands,
        [ValidateRange(1, 1000)][int]$MaximumSelectionCount = 200
    )

    $result = [ordered]@{
        Valid        = $false
        Values       = @()
        Command      = $null
        SearchTerm   = $null
        Normalized   = ''
        ErrorKey     = $null
        ErrorMessage = $null
    }
    if ([string]::IsNullOrWhiteSpace($InputText)) {
        $result.ErrorKey = 'input.empty'
        $result.ErrorMessage = 'Enter a selection or command.'
        return [pscustomobject]$result
    }

    $text = $InputText.Trim()
    $effectiveCommandMap = if ($null -ne $CommandMap) { $CommandMap } else {
        @{
            'M' = 'MISSING'; 'U' = 'UPDATES'; 'A' = 'ALL'; 'R' = 'RECOMMENDED'
            '?' = 'HELP'; '0' = 'BACK'; 'B' = 'BACK'; 'Q' = 'BACK'
        }
    }
    $commandIsAllowed = {
        param([string]$Name)
        return $null -eq $AllowedCommands -or $AllowedCommands.Count -eq 0 -or $AllowedCommands -contains $Name
    }
    if ($text.StartsWith('/')) {
        $query = $text.Substring(1).Trim()
        if ([string]::IsNullOrWhiteSpace($query)) {
            $result.ErrorKey = 'input.searchEmpty'
            $result.ErrorMessage = 'Enter a search term after /.'
            return [pscustomobject]$result
        }
        if ($query.Length -gt 100 -or $query -match '[\x00-\x1F]') {
            $result.ErrorKey = 'input.searchInvalid'
            $result.ErrorMessage = 'The search term is too long or contains control characters.'
            return [pscustomobject]$result
        }
        if (-not (& $commandIsAllowed 'SEARCH')) {
            $result.ErrorKey = 'input.commandNotAvailable'
            $result.ErrorMessage = 'Search is not available on this page.'
            return [pscustomobject]$result
        }
        $result.Valid = $true
        $result.Command = 'SEARCH'
        $result.SearchTerm = $query
        $result.Normalized = '/' + $query
        return [pscustomobject]$result
    }

    $command = $text.ToUpperInvariant()
    if ($effectiveCommandMap.ContainsKey($command)) {
        $mappedCommand = [string]$effectiveCommandMap[$command]
        if (-not (& $commandIsAllowed $mappedCommand)) {
            $result.ErrorKey = 'input.commandNotAvailable'
            $result.ErrorMessage = "Command '$command' is not available on this page."
            return [pscustomobject]$result
        }
        $result.Valid = $true
        $result.Command = $mappedCommand
        $result.Normalized = $command
        return [pscustomobject]$result
    }

    if ($text -match '[^0-9,;\-\s]') {
        $result.ErrorKey = 'input.invalidCharacters'
        $result.ErrorMessage = 'Use numbers, commas, spaces, semicolons, or ranges such as 2-5.'
        return [pscustomobject]$result
    }
    if ($text -match '^[,;\-]' -or $text -match '[,;\-]$' -or $text -match '[,;]\s*[,;]') {
        $result.ErrorKey = 'input.malformed'
        $result.ErrorMessage = 'The selection contains an empty or incomplete item.'
        return [pscustomobject]$result
    }

    $normalizedRanges = [regex]::Replace($text, '\s*-\s*', '-')
    $tokens = @($normalizedRanges -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($tokens.Count -eq 0) {
        $result.ErrorKey = 'input.malformed'
        $result.ErrorMessage = 'No numeric selection was found.'
        return [pscustomobject]$result
    }

    $values = New-Object System.Collections.Generic.List[int]
    foreach ($token in $tokens) {
        if ($token -match '^(\d+)-(\d+)$') {
            $start = [int64]$matches[1]
            $end = [int64]$matches[2]
            if ($start -gt [int]::MaxValue -or $end -gt [int]::MaxValue -or $start -gt $end) {
                $result.ErrorKey = 'input.invalidRange'
                $result.ErrorMessage = "Range '$token' is invalid. Use a low-to-high range such as 2-5."
                return [pscustomobject]$result
            }
            if (($end - $start + 1) -gt $MaximumSelectionCount) {
                $result.ErrorKey = 'input.tooMany'
                $result.ErrorMessage = 'The range selects too many items.'
                return [pscustomobject]$result
            }
            for ($number = [int]$start; $number -le [int]$end; $number++) {
                if (-not $values.Contains($number)) { $values.Add($number) }
                if ($values.Count -gt $MaximumSelectionCount) {
                    $result.ErrorKey = 'input.tooMany'
                    $result.ErrorMessage = "Select no more than $MaximumSelectionCount items at once."
                    return [pscustomobject]$result
                }
            }
        }
        elseif ($token -match '^\d+$') {
            $number64 = [int64]$token
            if ($number64 -gt [int]::MaxValue) {
                $result.ErrorKey = 'input.outOfRange'
                $result.ErrorMessage = "Selection '$token' is outside the supported range."
                return [pscustomobject]$result
            }
            $number = [int]$number64
            if (-not $values.Contains($number)) { $values.Add($number) }
        }
        else {
            $result.ErrorKey = 'input.malformed'
            $result.ErrorMessage = "Selection item '$token' is malformed."
            return [pscustomobject]$result
        }
    }

    if ($values.Count -gt $MaximumSelectionCount) {
        $result.ErrorKey = 'input.tooMany'
        $result.ErrorMessage = "Select no more than $MaximumSelectionCount items at once."
        return [pscustomobject]$result
    }
    if (-not (& $commandIsAllowed 'SELECT')) {
        $result.ErrorKey = 'input.commandNotAvailable'
        $result.ErrorMessage = 'Numeric selection is not available on this page.'
        return [pscustomobject]$result
    }
    if ($PSBoundParameters.ContainsKey('AvailableIds')) {
        $unavailable = @($values | Where-Object { $AvailableIds -notcontains $_ })
        if ($unavailable.Count -gt 0) {
            $result.ErrorKey = 'input.notAvailable'
            $result.ErrorMessage = "These IDs are not available on this page: $($unavailable -join ', ')."
            return [pscustomobject]$result
        }
    }

    $result.Valid = $true
    $result.Values = @($values)
    $result.Command = 'SELECT'
    $result.Normalized = ($values -join ',')
    return [pscustomobject]$result
}
