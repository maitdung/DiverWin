Set-StrictMode -Version Latest

$script:FreshWinLocalizationContext = $null

function Get-FreshWinDefaultLocalesPath {
    [CmdletBinding()]
    param()

    $sourceDirectory = Split-Path -Parent $PSScriptRoot
    $projectDirectory = Split-Path -Parent $sourceDirectory
    return Join-Path $projectDirectory 'locales'
}

function Import-FreshWinLocaleFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    return Read-FreshWinJsonFile -Path $Path
}

function Initialize-FreshWinLocalization {
    [CmdletBinding()]
    param(
        [ValidateSet('en-US', 'vi-VN', 'zh-CN', 'ja-JP')]
        [string]$Locale = 'en-US',

        [string]$LocalesPath
    )

    if ([string]::IsNullOrWhiteSpace($LocalesPath)) {
        $LocalesPath = Get-FreshWinDefaultLocalesPath
    }

    $localeDirectory = [System.IO.Path]::GetFullPath($LocalesPath)
    $fallbackPath = Join-Path $localeDirectory 'en-US.json'
    if (-not [System.IO.File]::Exists($fallbackPath)) {
        throw "The canonical English locale is missing: $fallbackPath"
    }

    $fallbackStrings = Import-FreshWinLocaleFile -Path $fallbackPath
    $selectedStrings = $fallbackStrings
    $selectedPath = Join-Path $localeDirectory "$Locale.json"
    $usedFallbackFile = $false

    if ($Locale -ne 'en-US') {
        if ([System.IO.File]::Exists($selectedPath)) {
            $selectedStrings = Import-FreshWinLocaleFile -Path $selectedPath
        }
        else {
            $usedFallbackFile = $true
        }
    }

    $context = [PSCustomObject]@{
        Locale             = $Locale
        FallbackLocale     = 'en-US'
        LocalesPath        = $localeDirectory
        Strings            = $selectedStrings
        FallbackStrings    = $fallbackStrings
        UsedFallbackLocale = $usedFallbackFile
    }

    $script:FreshWinLocalizationContext = $context
    return $context
}

function Get-FreshWinLocalizationContext {
    [CmdletBinding()]
    param()

    if ($null -eq $script:FreshWinLocalizationContext) {
        throw 'Localization has not been initialized. Call Initialize-FreshWinLocalization first.'
    }

    return $script:FreshWinLocalizationContext
}

function Resolve-FreshWinLocalizationValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Root,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Key
    )

    $current = $Root
    foreach ($segment in $Key.Split('.')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or
            -not (Test-FreshWinHasProperty -InputObject $current -Name $segment)) {
            return $null
        }

        $current = Get-FreshWinPropertyValue -InputObject $current -Name $segment
    }

    return $current
}

function Get-FreshWinString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        [AllowNull()]
        [object]$Context = $null,

        [AllowNull()]
        [string]$Default = $null,

        [AllowNull()]
        [object[]]$FormatArguments = @()
    )

    if ($null -eq $Context) {
        $Context = Get-FreshWinLocalizationContext
    }

    $value = Resolve-FreshWinLocalizationValue -Root $Context.Strings -Key $Key
    if ($null -eq $value) {
        $value = Resolve-FreshWinLocalizationValue -Root $Context.FallbackStrings -Key $Key
    }
    if ($null -eq $value) {
        if ($null -ne $Default) {
            $value = $Default
        }
        else {
            $value = $Key
        }
    }

    $text = [string]$value
    if ($null -ne $FormatArguments -and $FormatArguments.Count -gt 0) {
        try {
            $text = $text -f $FormatArguments
        }
        catch {
            throw "Localization format error for key '$Key': $($_.Exception.Message)"
        }
    }

    return $text
}

function Set-FreshWinLocale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('en-US', 'vi-VN', 'zh-CN', 'ja-JP')]
        [string]$Locale,

        [string]$LocalesPath
    )

    return Initialize-FreshWinLocalization -Locale $Locale -LocalesPath $LocalesPath
}
