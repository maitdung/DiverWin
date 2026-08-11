function New-FreshWinReadinessCheck {
    param(
        [string]$Requirement,
        [ValidateSet('Pass', 'Fail', 'Unknown')]
        [string]$Status,
        [AllowNull()]
        [object]$Observed,
        [string]$Required,
        [string]$Reason
    )

    return [pscustomobject][ordered]@{
        Requirement = $Requirement
        Status      = $Status
        Observed    = $Observed
        Required    = $Required
        Reason      = $Reason
    }
}

function Get-FreshWinWindows11Readiness {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$SystemInfo,

        [AllowNull()]
        [object]$HardwareInfo
    )

    $provided = $PSBoundParameters.ContainsKey('SystemInfo') -or $PSBoundParameters.ContainsKey('HardwareInfo')
    if (-not (Test-FreshWinWindows) -and -not $provided) {
        $unsupported = New-FreshWinUnsupportedResult -Component 'Windows11Readiness'
        $unsupported | Add-Member -NotePropertyName Readiness -NotePropertyValue 'Unsupported'
        $unsupported | Add-Member -NotePropertyName Checks -NotePropertyValue @()
        return $unsupported
    }

    if ($null -eq $SystemInfo) { $SystemInfo = Get-FreshWinSystemInfo }
    if ($null -eq $HardwareInfo) {
        if ($null -ne $SystemInfo.PSObject.Properties['GPUs']) {
            $HardwareInfo = [pscustomobject]@{
                MemoryGB          = $SystemInfo.MemoryGB
                CPUs              = @($SystemInfo.CPUs)
                Storage           = @($SystemInfo.Storage)
                Tpm               = $SystemInfo.Tpm
                FirmwareType      = $SystemInfo.FirmwareType
                SecureBootEnabled = $SystemInfo.SecureBootEnabled
            }
        }
        else { $HardwareInfo = Get-FreshWinHardwareInfo }
    }

    $checks = New-Object System.Collections.Generic.List[object]

    $memoryGB = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('MemoryGB') -Default (Get-FreshWinObjectProperty -InputObject $SystemInfo -Name @('MemoryGB'))
    if ($null -eq $memoryGB) { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Memory' -Status 'Unknown' -Observed $null -Required '4 GB or more' -Reason 'Memory could not be measured.')) }
    elseif ([double]$memoryGB -ge 4) { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Memory' -Status 'Pass' -Observed "$memoryGB GB" -Required '4 GB or more')) }
    else { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Memory' -Status 'Fail' -Observed "$memoryGB GB" -Required '4 GB or more' -Reason 'Insufficient memory.')) }

    $storage = @((Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('Storage') -Default @()))
    $largestDisk = $null
    foreach ($disk in $storage) {
        if ($null -eq $disk.SizeGB) { continue }
        if ($null -eq $largestDisk -or [double]$disk.SizeGB -gt [double]$largestDisk) { $largestDisk = [double]$disk.SizeGB }
    }
    if ($null -eq $largestDisk) { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Storage' -Status 'Unknown' -Observed $null -Required '64 GB or larger device' -Reason 'Storage size could not be measured.')) }
    elseif ($largestDisk -ge 64) { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Storage' -Status 'Pass' -Observed "$largestDisk GB" -Required '64 GB or larger device')) }
    else { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Storage' -Status 'Fail' -Observed "$largestDisk GB" -Required '64 GB or larger device' -Reason 'No storage device meets the minimum size.')) }

    $architecture = [string](Get-FreshWinObjectProperty -InputObject $SystemInfo -Name @('Architecture') -Default 'Unknown')
    if ($architecture -in @('x64', 'ARM64')) { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Architecture' -Status 'Pass' -Observed $architecture -Required 'x64 or ARM64')) }
    elseif ($architecture -eq 'Unknown') { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Architecture' -Status 'Unknown' -Observed $architecture -Required 'x64 or ARM64')) }
    else { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Architecture' -Status 'Fail' -Observed $architecture -Required 'x64 or ARM64' -Reason 'The processor architecture is unsupported by Windows 11.')) }

    $firmwareType = [string](Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('FirmwareType') -Default 'Unknown')
    if ($firmwareType -eq 'UEFI') { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Firmware' -Status 'Pass' -Observed $firmwareType -Required 'UEFI')) }
    elseif ($firmwareType -eq 'BIOS') { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Firmware' -Status 'Fail' -Observed $firmwareType -Required 'UEFI' -Reason 'Legacy BIOS mode is active.')) }
    else { $checks.Add((New-FreshWinReadinessCheck -Requirement 'Firmware' -Status 'Unknown' -Observed $firmwareType -Required 'UEFI')) }

    $secureBoot = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('SecureBootEnabled')
    if ($secureBoot -eq $true) { $checks.Add((New-FreshWinReadinessCheck -Requirement 'SecureBoot' -Status 'Pass' -Observed $true -Required 'Enabled')) }
    elseif ($secureBoot -eq $false) { $checks.Add((New-FreshWinReadinessCheck -Requirement 'SecureBoot' -Status 'Fail' -Observed $false -Required 'Enabled' -Reason 'Secure Boot is not enabled.')) }
    else { $checks.Add((New-FreshWinReadinessCheck -Requirement 'SecureBoot' -Status 'Unknown' -Observed $null -Required 'Enabled')) }

    $tpm = Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('Tpm')
    $tpmPresent = Get-FreshWinObjectProperty -InputObject $tpm -Name @('Present')
    $tpmVersion = [string](Get-FreshWinObjectProperty -InputObject $tpm -Name @('SpecVersion'))
    if ($tpmPresent -eq $false) { $checks.Add((New-FreshWinReadinessCheck -Requirement 'TPM' -Status 'Fail' -Observed 'Not present' -Required 'TPM 2.0' -Reason 'A TPM was not detected.')) }
    elseif ($tpmPresent -eq $true -and $tpmVersion -match '(^|[,\s])2\.0([,\s]|$)') { $checks.Add((New-FreshWinReadinessCheck -Requirement 'TPM' -Status 'Pass' -Observed $tpmVersion -Required 'TPM 2.0')) }
    elseif ($tpmPresent -eq $true -and -not [string]::IsNullOrWhiteSpace($tpmVersion)) { $checks.Add((New-FreshWinReadinessCheck -Requirement 'TPM' -Status 'Fail' -Observed $tpmVersion -Required 'TPM 2.0' -Reason 'TPM 2.0 was not reported.')) }
    else { $checks.Add((New-FreshWinReadinessCheck -Requirement 'TPM' -Status 'Unknown' -Observed $tpmVersion -Required 'TPM 2.0')) }

    $cpus = @((Get-FreshWinObjectProperty -InputObject $HardwareInfo -Name @('CPUs') -Default @()))
    if ($cpus.Count -eq 0) {
        $checks.Add((New-FreshWinReadinessCheck -Requirement 'ProcessorCapacity' -Status 'Unknown' -Observed $null -Required '2 cores, 1 GHz or faster'))
        $checks.Add((New-FreshWinReadinessCheck -Requirement 'ProcessorModel' -Status 'Unknown' -Observed $null -Required 'Microsoft supported processor list' -Reason 'FreshWin does not guess CPU model eligibility.'))
    }
    else {
        $cpu = $cpus[0]
        $cores = Get-FreshWinObjectProperty -InputObject $cpu -Name @('Cores')
        $clock = Get-FreshWinObjectProperty -InputObject $cpu -Name @('MaxClockMHz')
        if ($null -ne $cores -and $null -ne $clock -and [int]$cores -ge 2 -and [int]$clock -ge 1000) {
            $checks.Add((New-FreshWinReadinessCheck -Requirement 'ProcessorCapacity' -Status 'Pass' -Observed "$cores cores, $clock MHz" -Required '2 cores, 1 GHz or faster'))
        }
        elseif ($null -ne $cores -and $null -ne $clock) {
            $checks.Add((New-FreshWinReadinessCheck -Requirement 'ProcessorCapacity' -Status 'Fail' -Observed "$cores cores, $clock MHz" -Required '2 cores, 1 GHz or faster' -Reason 'Processor capacity is below the minimum.'))
        }
        else { $checks.Add((New-FreshWinReadinessCheck -Requirement 'ProcessorCapacity' -Status 'Unknown' -Observed $cpu.Name -Required '2 cores, 1 GHz or faster')) }
        $checks.Add((New-FreshWinReadinessCheck -Requirement 'ProcessorModel' -Status 'Unknown' -Observed $cpu.Name -Required 'Microsoft supported processor list' -Reason 'CPU model allowlists change; verify with Microsoft PC Health Check.'))
    }

    $failed = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count
    $unknown = @($checks | Where-Object { $_.Status -eq 'Unknown' }).Count
    $readiness = 'Ready'
    if ($failed -gt 0) { $readiness = 'NotReady' }
    elseif ($unknown -gt 0) { $readiness = 'ReviewRequired' }

    return [pscustomobject][ordered]@{
        Component   = 'Windows11Readiness'
        IsSupported = (Test-FreshWinWindows)
        Supported   = (Test-FreshWinWindows)
        IsLive      = ((Test-FreshWinWindows) -and -not $provided)
        Status      = $(if (Test-FreshWinWindows) { 'Ready' } else { 'Fixture' })
        Platform    = Get-FreshWinPlatformName
        Readiness   = $readiness
        Ready       = ($readiness -eq 'Ready')
        FailedCount = $failed
        UnknownCount = $unknown
        Checks      = $checks.ToArray()
        Disclaimer  = 'FreshWin never bypasses Windows 11 requirements. Unknown processor-model eligibility must be verified with Microsoft tooling.'
    }
}
