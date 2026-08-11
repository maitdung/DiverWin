function ConvertTo-FreshWinLicenseStatus {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$LicenseStatus
    )

    switch ([int]$LicenseStatus) {
        0 { return 'Unlicensed' }
        1 { return 'Licensed' }
        2 { return 'OOBGrace' }
        3 { return 'OOTGrace' }
        4 { return 'NonGenuineGrace' }
        5 { return 'Notification' }
        6 { return 'ExtendedGrace' }
        default { return 'Unknown' }
    }
}

function Get-FreshWinActivationStatus {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Licenses
    )

    $provided = $PSBoundParameters.ContainsKey('Licenses')
    $onWindows = Test-FreshWinWindows
    if (-not $onWindows -and -not $provided) {
        $unsupported = New-FreshWinUnsupportedResult -Component 'ActivationScanner'
        $unsupported | Add-Member -NotePropertyName ActivationStatus -NotePropertyValue 'Unsupported'
        $unsupported | Add-Member -NotePropertyName IsActivated -NotePropertyValue $null
        return $unsupported
    }

    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $provided) {
        try {
            $windowsApplicationId = '55c92734-d682-4d71-983e-d6ec3f16059f'
            $Licenses = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='$windowsApplicationId' AND PartialProductKey IS NOT NULL" -ErrorAction Stop)
        }
        catch { $errors.Add($_.Exception.Message); $Licenses = @() }
    }

    $records = @()
    foreach ($license in @($Licenses)) {
        if ($null -eq $license) { continue }
        $mappedStatus = ConvertTo-FreshWinLicenseStatus -LicenseStatus (Get-FreshWinObjectProperty -InputObject $license -Name @('LicenseStatus') -Default -1)
        $records += [pscustomobject][ordered]@{
            Name                  = Get-FreshWinObjectProperty -InputObject $license -Name @('Name')
            Description           = Get-FreshWinObjectProperty -InputObject $license -Name @('Description')
            ActivationStatus      = $mappedStatus
            IsActivated           = $mappedStatus -eq 'Licensed'
            PartialProductKey     = Get-FreshWinObjectProperty -InputObject $license -Name @('PartialProductKey')
            GracePeriodMinutes    = Get-FreshWinObjectProperty -InputObject $license -Name @('GracePeriodRemaining')
            ProductKeyChannel     = Get-FreshWinObjectProperty -InputObject $license -Name @('ProductKeyChannel')
        }
    }

    $licensed = @($records | Where-Object { $_.IsActivated })
    $activationStatus = 'Unknown'
    $isActivated = $null
    if ($records.Count -gt 0) {
        $isActivated = $licensed.Count -gt 0
        $activationStatus = $(if ($isActivated) { 'Licensed' } else { $records[0].ActivationStatus })
    }
    $status = $(if ($errors.Count -gt 0 -and $records.Count -eq 0) { 'Unknown' } elseif (-not $onWindows) { 'Fixture' } elseif ($isActivated -eq $true) { 'Ready' } else { 'Attention' })

    return [pscustomobject][ordered]@{
        Component         = 'ActivationScanner'
        IsSupported       = $onWindows
        Supported         = $onWindows
        IsLive            = ($onWindows -and -not $provided)
        Status            = $status
        Platform          = Get-FreshWinPlatformName
        ActivationStatus  = $activationStatus
        IsActivated       = $isActivated
        Licenses          = $records
        MutationPerformed = $false
        OfficialAction    = 'ms-settings:activation'
        Errors            = $errors.ToArray()
    }
}
