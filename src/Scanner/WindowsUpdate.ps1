function Test-FreshWinRestartPending {
    [CmdletBinding()]
    param()

    if (-not (Test-FreshWinWindows)) { return $null }
    try {
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($null -ne $sessionManager -and @($sessionManager.PendingFileRenameOperations).Count -gt 0) { return $true }
        return $false
    }
    catch {
        return $null
    }
}

function ConvertTo-FreshWinUpdateRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Update
    )

    $categories = @()
    $categorySource = Get-FreshWinObjectProperty -InputObject $Update -Name @('Categories') -Default @()
    foreach ($category in @($categorySource)) {
        $categories += [string](Get-FreshWinObjectProperty -InputObject $category -Name @('Name') -Default $category)
    }
    $title = [string](Get-FreshWinObjectProperty -InputObject $Update -Name @('Title') -Default 'Untitled update')
    $isDriver = $title -match '(?i)driver' -or @($categories | Where-Object { $_ -match '(?i)driver' }).Count -gt 0
    return [pscustomobject][ordered]@{
        Title         = $title
        UpdateId      = Get-FreshWinObjectProperty -InputObject (Get-FreshWinObjectProperty -InputObject $Update -Name @('Identity')) -Name @('UpdateID')
        Revision      = Get-FreshWinObjectProperty -InputObject (Get-FreshWinObjectProperty -InputObject $Update -Name @('Identity')) -Name @('RevisionNumber')
        KBArticleIds  = @((Get-FreshWinObjectProperty -InputObject $Update -Name @('KBArticleIDs') -Default @()))
        Categories    = $categories
        IsDriver      = $isDriver
        RebootRequired = [bool](Get-FreshWinObjectProperty -InputObject $Update -Name @('RebootRequired') -Default $false)
        IsDownloaded  = [bool](Get-FreshWinObjectProperty -InputObject $Update -Name @('IsDownloaded') -Default $false)
        EulaAccepted  = Get-FreshWinObjectProperty -InputObject $Update -Name @('EulaAccepted')
    }
}

function Get-FreshWinWindowsUpdateState {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Updates,

        [AllowNull()]
        [Nullable[bool]]$RestartPending,

        [switch]$IncludeDetails
    )

    $provided = $PSBoundParameters.ContainsKey('Updates') -or $PSBoundParameters.ContainsKey('RestartPending')
    $onWindows = Test-FreshWinWindows
    if (-not $onWindows -and -not $provided) {
        $unsupported = New-FreshWinUnsupportedResult -Component 'WindowsUpdateScanner'
        $unsupported | Add-Member -NotePropertyName PendingCount -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName DriverUpdateCount -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName RestartPending -NotePropertyValue $null
        $unsupported | Add-Member -NotePropertyName Updates -NotePropertyValue @()
        return $unsupported
    }

    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $PSBoundParameters.ContainsKey('Updates')) {
        try {
            $session = New-Object -ComObject Microsoft.Update.Session -ErrorAction Stop
            $searcher = $session.CreateUpdateSearcher()
            $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
            $Updates = @()
            for ($index = 0; $index -lt $result.Updates.Count; $index++) {
                $Updates += $result.Updates.Item($index)
            }
        }
        catch {
            $errors.Add($_.Exception.Message)
            $Updates = @()
        }
    }
    if (-not $PSBoundParameters.ContainsKey('RestartPending')) { $RestartPending = Test-FreshWinRestartPending }

    $records = @()
    foreach ($update in @($Updates)) {
        if ($null -ne $update) { $records += ConvertTo-FreshWinUpdateRecord -Update $update }
    }
    $driverCount = @($records | Where-Object { $_.IsDriver }).Count
    $status = 'Ready'
    if ($errors.Count -gt 0 -and $records.Count -eq 0) { $status = 'Unknown' }
    elseif ($records.Count -gt 0 -or $RestartPending -eq $true) { $status = 'Attention' }
    elseif (-not $onWindows) { $status = 'Fixture' }

    return [pscustomobject][ordered]@{
        Component         = 'WindowsUpdateScanner'
        IsSupported       = $onWindows
        Supported         = $onWindows
        IsLive            = ($onWindows -and -not $provided)
        Status            = $status
        Platform          = Get-FreshWinPlatformName
        PendingCount      = $records.Count
        DriverUpdateCount = $driverCount
        RestartPending    = $RestartPending
        Updates           = $(if ($IncludeDetails -or $provided) { $records } else { @() })
        Query              = 'IsInstalled=0 and IsHidden=0'
        MutationPerformed = $false
        Errors            = $errors.ToArray()
    }
}
