function Get-FreshWinPlatformName {
    [CmdletBinding()]
    param()

    $isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    if ($null -ne $isWindowsVariable) {
        if ([bool]$isWindowsVariable.Value) { return 'Windows' }
        $isMacOSVariable = Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue
        if ($null -ne $isMacOSVariable -and [bool]$isMacOSVariable.Value) { return 'macOS' }
        return 'Linux'
    }

    if ($env:OS -eq 'Windows_NT' -or [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return 'Windows'
    }

    try {
        if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
                [Runtime.InteropServices.OSPlatform]::OSX)) {
            return 'macOS'
        }
    }
    catch {
        # RuntimeInformation is unavailable on some older PowerShell hosts.
    }

    return 'Linux'
}

function Test-FreshWinWindows {
    [CmdletBinding()]
    param()

    return (Get-FreshWinPlatformName) -eq 'Windows'
}

function Test-FreshWinAdministrator {
    [CmdletBinding()]
    param()

    if (-not (Test-FreshWinWindows)) {
        return $false
    }

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function ConvertTo-FreshWinArchitecture {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Architecture
    )

    if ([string]::IsNullOrWhiteSpace($Architecture)) {
        return 'Unknown'
    }

    switch -Regex ($Architecture.Trim()) {
        '^(AMD64|x64|64-bit|64 bit)$' { return 'x64' }
        '^(ARM64|AArch64)$' { return 'ARM64' }
        '^(x86|i[3-6]86|32-bit|32 bit)$' { return 'x86' }
        default { return $Architecture.Trim() }
    }
}

function New-FreshWinUnsupportedResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Component,

        [string]$Reason
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        $Reason = "$Component is supported only on Windows 10 and Windows 11."
    }

    return [pscustomobject][ordered]@{
        Component   = $Component
        IsSupported = $false
        Supported   = $false
        IsLive      = $false
        Status      = 'Unsupported'
        Platform    = Get-FreshWinPlatformName
        Reason      = $Reason
        Error       = $null
    }
}

function Get-FreshWinObjectProperty {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Name,

        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    foreach ($candidate in $Name) {
        $property = $InputObject.PSObject.Properties[$candidate]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }
    return $Default
}
