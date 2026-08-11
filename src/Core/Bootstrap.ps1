Set-StrictMode -Version Latest

function Initialize-FreshWinRuntime {
    [CmdletBinding()]
    param(
        [string]$ProjectRoot = (Get-FreshWinProjectRoot),
        [AllowNull()][object]$Config,
        [AllowNull()][object]$Paths,
        [AllowNull()][object]$Catalog,
        [switch]$ReadOnly,
        [switch]$VerboseTerminal,
        [switch]$AllowInvalidCatalog
    )

    $root = [IO.Path]::GetFullPath($ProjectRoot)
    if (-not [IO.Directory]::Exists($root)) { throw "FreshWin project root was not found: $root" }
    if ($null -eq $Paths) { $Paths = Get-FreshWinPaths }
    if ($null -eq $Config) { $Config = Get-FreshWinConfig }
    $Config = ConvertTo-FreshWinConfig -InputObject $Config
    $locale = if ([string]::IsNullOrWhiteSpace([string]$Config.locale)) { 'en-US' } else { [string]$Config.locale }
    $localization = Initialize-FreshWinLocalization -Locale $locale -LocalesPath (Join-Path $root 'locales')

    $logger = $null
    if (-not $ReadOnly) {
        [void](Initialize-FreshWinEnvironment -Paths $Paths)
        $logger = Initialize-FreshWinLogger -LogDirectory ([string]$Paths.Logs) -Version (Get-FreshWinVersion) -VerboseTerminal:($VerboseTerminal -or [bool]$Config.ui.verbose)
    }
    if ($null -eq $Catalog) { $Catalog = Import-FreshWinPackageCatalog -Path (Join-Path $root 'catalog') }
    if (-not [bool]$Catalog.IsValid -and -not $AllowInvalidCatalog) {
        throw "FreshWin catalog validation failed: $(@($Catalog.Errors.Error) -join ' ')"
    }
    [void](Initialize-FreshWinAssistant)

    return [pscustomobject][ordered]@{
        Version          = Get-FreshWinVersion
        ProjectRoot      = $root
        Platform         = Get-FreshWinPlatformName
        WindowsSupported = Test-FreshWinWindows
        ReadOnly         = [bool]$ReadOnly
        Paths            = $Paths
        Config           = $Config
        Locale           = $locale
        Localization     = $localization
        Logger           = $logger
        Catalog          = $Catalog
        CatalogValid     = [bool]$Catalog.IsValid
        InitializedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
}
