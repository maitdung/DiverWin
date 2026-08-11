Set-StrictMode -Version Latest

$script:FreshWinSupportedLocales = @('en-US', 'vi-VN', 'zh-CN', 'ja-JP')

function Get-FreshWinSupportedLocale {
    [CmdletBinding()]
    param()

    return @($script:FreshWinSupportedLocales)
}

function Get-FreshWinPaths {
    [CmdletBinding()]
    param(
        [string]$LocalAppDataRoot,
        [string]$TemporaryRoot
    )

    if ([string]::IsNullOrWhiteSpace($LocalAppDataRoot)) {
        $LocalAppDataRoot = $env:LOCALAPPDATA
    }
    if ([string]::IsNullOrWhiteSpace($LocalAppDataRoot)) {
        $LocalAppDataRoot = [System.Environment]::GetFolderPath(
            [System.Environment+SpecialFolder]::LocalApplicationData
        )
    }
    if ([string]::IsNullOrWhiteSpace($LocalAppDataRoot)) {
        throw 'LOCALAPPDATA is unavailable. FreshWin cannot choose a safe data directory.'
    }

    if ([string]::IsNullOrWhiteSpace($TemporaryRoot)) {
        $TemporaryRoot = $env:TEMP
    }
    if ([string]::IsNullOrWhiteSpace($TemporaryRoot)) {
        $TemporaryRoot = [System.IO.Path]::GetTempPath()
    }
    if ([string]::IsNullOrWhiteSpace($TemporaryRoot)) {
        throw 'The operating system temporary directory is unavailable.'
    }

    $appRoot = Join-Path ([System.IO.Path]::GetFullPath($LocalAppDataRoot)) 'FreshWin'
    $tempRoot = Join-Path ([System.IO.Path]::GetFullPath($TemporaryRoot)) 'FreshWin'

    return [PSCustomObject]@{
        AppRoot       = $appRoot
        ConfigPath    = Join-Path $appRoot 'config.json'
        Logs          = Join-Path $appRoot 'logs'
        Cache         = Join-Path $appRoot 'cache'
        State         = Join-Path $appRoot 'state'
        Updates       = Join-Path $appRoot 'updates'
        TemporaryRoot = $tempRoot
    }
}

function Get-FreshWinUserDownloadsPath {
    [CmdletBinding()]
    param([scriptblock]$KnownFolderProvider)

    $downloadsPath = $null
    if ($null -ne $KnownFolderProvider) {
        $downloadsPath = & $KnownFolderProvider
    }
    elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $key = $null
        try {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
                'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
                $false
            )
            if ($null -ne $key) {
                $downloadsPath = $key.GetValue(
                    '{374DE290-123F-4565-9164-39C4925E467B}',
                    $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                )
            }
        }
        finally { if ($null -ne $key) { $key.Dispose() } }
    }
    if ([string]::IsNullOrWhiteSpace([string]$downloadsPath)) {
        throw 'The current user Downloads known folder could not be resolved.'
    }
    $expanded = [Environment]::ExpandEnvironmentVariables([string]$downloadsPath)
    if ($expanded -match '[\x00\r\n]' -or -not [IO.Path]::IsPathRooted($expanded) -or
        $expanded.StartsWith('\\') -or $expanded.StartsWith('//')) {
        throw 'The current user Downloads known folder is not an absolute local path.'
    }
    return [IO.Path]::GetFullPath($expanded)
}

function Get-FreshWinRetainedArtifactDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Installers','Drivers','Exports','Backups')]
        [string]$Category,
        [string]$DownloadsPath,
        [scriptblock]$KnownFolderProvider
    )

    $downloads = if ([string]::IsNullOrWhiteSpace($DownloadsPath)) {
        Get-FreshWinUserDownloadsPath -KnownFolderProvider $KnownFolderProvider
    } else {
        $requestedDownloadsPath = $DownloadsPath
        $explicitPathProvider = { $requestedDownloadsPath }.GetNewClosure()
        Get-FreshWinUserDownloadsPath -KnownFolderProvider $explicitPathProvider
    }
    return [IO.Path]::GetFullPath((Join-Path (Join-Path $downloads 'FreshWin') $Category))
}

function Get-FreshWinDefaultArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Installers','Drivers','Exports','Backups')]
        [string]$Category,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
        [string]$FileName,
        [string]$DownloadsPath,
        [scriptblock]$KnownFolderProvider
    )

    $directory = Get-FreshWinRetainedArtifactDirectory -Category $Category -DownloadsPath $DownloadsPath -KnownFolderProvider $KnownFolderProvider
    return [IO.Path]::GetFullPath((Join-Path $directory $FileName))
}

function Initialize-FreshWinEnvironment {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Paths = $null
    )

    if ($null -eq $Paths) {
        $Paths = Get-FreshWinPaths
    }

    $required = @('AppRoot', 'Logs', 'Cache', 'State', 'Updates', 'TemporaryRoot')
    foreach ($propertyName in $required) {
        $directory = [string](Get-FreshWinPropertyValue -InputObject $Paths -Name $propertyName)
        if ([string]::IsNullOrWhiteSpace($directory)) {
            throw "FreshWin path '$propertyName' is missing."
        }

        if (-not [System.IO.Directory]::Exists($directory)) {
            [void][System.IO.Directory]::CreateDirectory($directory)
        }
    }

    return $Paths
}

function New-FreshWinConfig {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Locale = $null
    )

    if (-not [string]::IsNullOrWhiteSpace($Locale) -and
        $script:FreshWinSupportedLocales -notcontains $Locale) {
        throw "Unsupported locale '$Locale'."
    }

    return [PSCustomObject]@{
        schemaVersion    = 1
        locale           = $Locale
        languageSelected = -not [string]::IsNullOrWhiteSpace($Locale)
        ui               = [PSCustomObject]@{
            compactMode = $false
            unicode     = $true
            verbose     = $false
        }
        execution        = [PSCustomObject]@{
            maxRetries       = 2
            retryDelaySeconds = 2
        }
        updates          = [PSCustomObject]@{
            channel      = 'stable'
            metadataUri  = $null
            allowedHosts = @()
        }
    }
}

function ConvertTo-FreshWinConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    $defaults = New-FreshWinConfig
    $schemaVersion = [int](Get-FreshWinPropertyValue -InputObject $InputObject -Name 'schemaVersion' -Default 1)
    if ($schemaVersion -ne 1) { throw "Unsupported configuration schema version '$schemaVersion'." }
    $locale = [string](Get-FreshWinPropertyValue -InputObject $InputObject -Name 'locale' -Default $null)
    if ([string]::IsNullOrWhiteSpace($locale)) {
        $locale = $null
    }
    elseif ($script:FreshWinSupportedLocales -notcontains $locale) {
        throw "Configuration contains unsupported locale '$locale'."
    }

    $inputUi = Get-FreshWinPropertyValue -InputObject $InputObject -Name 'ui' -Default $null
    $inputExecution = Get-FreshWinPropertyValue -InputObject $InputObject -Name 'execution' -Default $null
    $inputUpdates = Get-FreshWinPropertyValue -InputObject $InputObject -Name 'updates' -Default $null

    $maxRetries = [int](Get-FreshWinPropertyValue -InputObject $inputExecution -Name 'maxRetries' -Default $defaults.execution.maxRetries)
    $retryDelay = [int](Get-FreshWinPropertyValue -InputObject $inputExecution -Name 'retryDelaySeconds' -Default $defaults.execution.retryDelaySeconds)
    if ($maxRetries -lt 0 -or $maxRetries -gt 10) {
        throw 'execution.maxRetries must be between 0 and 10.'
    }
    if ($retryDelay -lt 0 -or $retryDelay -gt 300) {
        throw 'execution.retryDelaySeconds must be between 0 and 300.'
    }

    $allowedHosts = @(
        @(ConvertTo-FreshWinArray (
            Get-FreshWinPropertyValue -InputObject $inputUpdates -Name 'allowedHosts' -Default @()
        )) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    )
    if ($allowedHosts.Count -gt 32 -or @($allowedHosts | Where-Object { $_ -notmatch '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$' }).Count -gt 0) {
        throw 'updates.allowedHosts contains too many entries or an invalid DNS host name.'
    }

    $channel = [string](Get-FreshWinPropertyValue -InputObject $inputUpdates -Name 'channel' -Default $defaults.updates.channel)
    if ($channel -notin @('stable', 'preview')) { throw "Unsupported update channel '$channel'." }
    $metadataUri = Get-FreshWinPropertyValue -InputObject $inputUpdates -Name 'metadataUri' -Default $defaults.updates.metadataUri
    if ($null -ne $metadataUri -and -not [string]::IsNullOrWhiteSpace([string]$metadataUri)) {
        try { $parsedMetadataUri = [Uri]([string]$metadataUri) } catch { throw 'updates.metadataUri must be an absolute HTTPS URI.' }
        if (-not $parsedMetadataUri.IsAbsoluteUri -or $parsedMetadataUri.Scheme -ne 'https' -or
            $allowedHosts -notcontains $parsedMetadataUri.DnsSafeHost.ToLowerInvariant()) {
            throw 'updates.metadataUri must use HTTPS and its exact host must appear in updates.allowedHosts.'
        }
        $metadataUri = $parsedMetadataUri.AbsoluteUri
    }
    else { $metadataUri = $null }

    foreach ($booleanSetting in @(
        [pscustomobject]@{ Parent = $inputUi; Name = 'compactMode' },
        [pscustomobject]@{ Parent = $inputUi; Name = 'unicode' },
        [pscustomobject]@{ Parent = $inputUi; Name = 'verbose' }
    )) {
        $settingValue = Get-FreshWinPropertyValue -InputObject $booleanSetting.Parent -Name $booleanSetting.Name -Default $null
        if ($null -ne $settingValue -and $settingValue -isnot [bool]) { throw "ui.$($booleanSetting.Name) must be boolean." }
    }

    return [PSCustomObject]@{
        schemaVersion    = 1
        locale           = $locale
        languageSelected = -not [string]::IsNullOrWhiteSpace($locale)
        ui               = [PSCustomObject]@{
            compactMode = [bool](Get-FreshWinPropertyValue -InputObject $inputUi -Name 'compactMode' -Default $defaults.ui.compactMode)
            unicode     = [bool](Get-FreshWinPropertyValue -InputObject $inputUi -Name 'unicode' -Default $defaults.ui.unicode)
            verbose     = [bool](Get-FreshWinPropertyValue -InputObject $inputUi -Name 'verbose' -Default $defaults.ui.verbose)
        }
        execution        = [PSCustomObject]@{
            maxRetries        = $maxRetries
            retryDelaySeconds = $retryDelay
        }
        updates          = [PSCustomObject]@{
            channel      = $channel
            metadataUri  = $metadataUri
            allowedHosts = @($allowedHosts)
        }
    }
}

function Save-FreshWinConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = (Get-FreshWinPaths).ConfigPath
    }

    $normalized = ConvertTo-FreshWinConfig -InputObject $Config
    [void](Write-FreshWinJsonFile -Path $Path -Value $normalized -Depth 12 -Atomic)
    return $normalized
}

function Get-FreshWinConfig {
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$CreateIfMissing
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = (Get-FreshWinPaths).ConfigPath
    }

    if (-not [System.IO.File]::Exists([System.IO.Path]::GetFullPath($Path))) {
        $config = New-FreshWinConfig
        if ($CreateIfMissing) {
            return Save-FreshWinConfig -Config $config -Path $Path
        }

        return $config
    }

    $raw = Read-FreshWinJsonFile -Path $Path
    return ConvertTo-FreshWinConfig -InputObject $raw
}

function Set-FreshWinConfigLocale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('en-US', 'vi-VN', 'zh-CN', 'ja-JP')]
        [string]$Locale,

        [string]$Path
    )

    $config = Get-FreshWinConfig -Path $Path
    $config.locale = $Locale
    $config.languageSelected = $true
    return Save-FreshWinConfig -Config $config -Path $Path
}

function Set-FreshWinConfigCompactMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$CompactMode,

        [string]$Path
    )

    $config = Get-FreshWinConfig -Path $Path
    $config.ui.compactMode = $CompactMode
    return Save-FreshWinConfig -Config $config -Path $Path
}
