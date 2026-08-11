Set-StrictMode -Version Latest

$script:FreshWinAssistantProviders = @{}
$script:FreshWinAllowedAssistantActions = @(
    'queue_install', 'queue_update', 'search_package', 'scan_drivers', 'get_hardware',
    'get_missing', 'recommend_profile', 'backup_drivers', 'get_status', 'run_diagnostics',
    'list_installed_packages', 'list_drivers', 'list_updates', 'open_section', 'show_help'
)

function New-FreshWinAssistantIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Intent,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Action,

        [string[]]$Targets = @(),
        [AllowNull()]
        [object]$Parameters = $null,
        [bool]$RequiresConfirmation = $false,
        [string]$RawInput,
        [string]$Provider = 'deterministic'
    )

    if ($null -eq $Parameters) {
        $Parameters = [PSCustomObject]@{}
    }
    return [PSCustomObject]@{
        schemaVersion        = 1
        isValid              = $true
        intent               = $Intent
        action               = $Action
        targets              = @($Targets)
        parameters           = $Parameters
        requiresConfirmation = $RequiresConfirmation
        provider             = $Provider
        rawInput             = $RawInput
        error                = $null
    }
}

function New-FreshWinInvalidAssistantIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ErrorMessage,
        [string]$RawInput,
        [string]$Provider = 'deterministic'
    )

    return [PSCustomObject]@{
        schemaVersion        = 1
        isValid              = $false
        intent               = 'Unknown'
        action               = $null
        targets              = @()
        parameters           = [PSCustomObject]@{}
        requiresConfirmation = $false
        provider             = $Provider
        rawInput             = $RawInput
        error                = $ErrorMessage
    }
}

function ConvertTo-FreshWinAssistantTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $normalized = $Text.ToLowerInvariant()
    $aliases = [ordered]@{
        'visual studio code' = 'vscode'
        'google chrome'      = 'chrome'
        'telegram desktop'   = 'telegram'
        'node.js lts'        = 'nodejs-lts'
        'node js lts'        = 'nodejs-lts'
        'github desktop'     = 'github-desktop'
        'github cli'         = 'github-cli'
        'docker desktop'     = 'docker-desktop'
        'jetbrains toolbox'  = 'jetbrains-toolbox'
    }
    foreach ($alias in $aliases.Keys) {
        $normalized = [System.Text.RegularExpressions.Regex]::Replace(
            $normalized,
            '\b' + [System.Text.RegularExpressions.Regex]::Escape($alias) + '\b',
            [string]$aliases[$alias],
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, '\s+and\s+', ',')
    $tokens = [System.Text.RegularExpressions.Regex]::Split($normalized.Trim(), '[,;\s]+')
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($token in $tokens) {
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        if ($token -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$') {
            throw "Invalid package identifier '$token'."
        }
        if (-not $targets.Contains($token)) {
            $targets.Add($token)
        }
    }
    if ($targets.Count -gt 50) {
        throw 'A single assistant command can target at most 50 packages.'
    }
    return $targets.ToArray()
}

function ConvertFrom-FreshWinAssistantCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InputText
    )

    $rawInput = $InputText
    $text = $InputText.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return New-FreshWinInvalidAssistantIntent -ErrorMessage 'Enter a FreshWin command.' -RawInput $rawInput
    }
    if ($text.Length -gt 512) {
        return New-FreshWinInvalidAssistantIntent -ErrorMessage 'The command is too long.' -RawInput $rawInput
    }
    if ($text.IndexOf([char]0) -ge 0 -or $text -match '[\r\n]') {
        return New-FreshWinInvalidAssistantIntent -ErrorMessage 'Commands must contain one line of text.' -RawInput $rawInput
    }

    $lower = $text.ToLowerInvariant()
    try {
        if ($lower -match '^install\s+(.+)$') {
            $targets = @(ConvertTo-FreshWinAssistantTargets -Text $Matches[1])
            if ($targets.Count -eq 0) {
                throw 'Specify at least one package to install.'
            }
            return New-FreshWinAssistantIntent -Intent 'InstallPackages' -Action 'queue_install' `
                -Targets $targets -RequiresConfirmation $true -RawInput $rawInput
        }

        if ($lower -match '^update(?:\s+(.+))?$') {
            $targets = @()
            if (-not [string]::IsNullOrWhiteSpace([string]$Matches[1])) {
                $targets = @(ConvertTo-FreshWinAssistantTargets -Text $Matches[1])
            }
            return New-FreshWinAssistantIntent -Intent 'UpdatePackages' -Action 'queue_update' `
                -Targets $targets -RequiresConfirmation $true -RawInput $rawInput
        }

        if ($lower -match '^(?:find|search)\s+(.+)$') {
            $query = $Matches[1].Trim()
            if ($query.Length -gt 128 -or $query -notmatch '^[\p{L}\p{N} ._+\-]+$') {
                throw 'Search text contains unsupported characters.'
            }
            return New-FreshWinAssistantIntent -Intent 'SearchPackages' -Action 'search_package' `
                -Parameters ([PSCustomObject]@{ query = $query }) -RawInput $rawInput
        }

        if ($lower -match '^(?:scan\s+drivers|drivers\s+scan)$') {
            return New-FreshWinAssistantIntent -Intent 'ScanDrivers' -Action 'scan_drivers' -RawInput $rawInput
        }

        if ($lower -match '^(?:show\s+(?:my\s+)?gpu|gpu)$') {
            return New-FreshWinAssistantIntent -Intent 'ShowHardware' -Action 'get_hardware' `
                -Parameters ([PSCustomObject]@{ scope = 'gpu' }) -RawInput $rawInput
        }

        if ($lower -match '^(?:show\s+(?:my\s+)?hardware|show\s+system|hardware|system\s+info)$') {
            return New-FreshWinAssistantIntent -Intent 'ShowHardware' -Action 'get_hardware' `
                -Parameters ([PSCustomObject]@{ scope = 'all' }) -RawInput $rawInput
        }

        if ($lower -match '^(?:what\s+is\s+missing|what''s\s+missing|missing)$') {
            return New-FreshWinAssistantIntent -Intent 'GetMissingItems' -Action 'get_missing' -RawInput $rawInput
        }

        if ($lower -match '^(?:(gaming|developer|essential|work)\s+setup|setup\s+(gaming|developer|essential|work)|profile\s+(gaming|developer|essential|work|full|custom))$') {
            $profile = @($Matches[1], $Matches[2], $Matches[3]) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
            return New-FreshWinAssistantIntent -Intent 'PlanProfile' -Action 'recommend_profile' `
                -Targets @([string]$profile) `
                -Parameters ([PSCustomObject]@{ profile = [string]$profile }) `
                -RequiresConfirmation $true -RawInput $rawInput
        }

        if ($lower -match '^(?:backup\s+drivers|backup-drivers)$') {
            return New-FreshWinAssistantIntent -Intent 'BackupDrivers' -Action 'backup_drivers' `
                -RequiresConfirmation $true -RawInput $rawInput
        }

        if ($lower -eq 'status') {
            return New-FreshWinAssistantIntent -Intent 'ShowStatus' -Action 'get_status' -RawInput $rawInput
        }
        if ($lower -eq 'doctor') {
            return New-FreshWinAssistantIntent -Intent 'RunDiagnostics' -Action 'run_diagnostics' -RawInput $rawInput
        }
        if ($lower -eq 'apps') {
            return New-FreshWinAssistantIntent -Intent 'ListApplications' -Action 'list_installed_packages' -RawInput $rawInput
        }
        if ($lower -eq 'drivers') {
            return New-FreshWinAssistantIntent -Intent 'ListDrivers' -Action 'list_drivers' -RawInput $rawInput
        }
        if ($lower -eq 'updates') {
            return New-FreshWinAssistantIntent -Intent 'ListUpdates' -Action 'list_updates' -RawInput $rawInput
        }
        if ($lower -in @('gaming', 'developer')) {
            return New-FreshWinAssistantIntent -Intent 'OpenSection' -Action 'open_section' `
                -Targets @($lower) -Parameters ([PSCustomObject]@{ section = $lower }) -RawInput $rawInput
        }
        if ($lower -in @('help', '?')) {
            return New-FreshWinAssistantIntent -Intent 'ShowHelp' -Action 'show_help' -RawInput $rawInput
        }
    }
    catch {
        return New-FreshWinInvalidAssistantIntent -ErrorMessage $_.Exception.Message -RawInput $rawInput
    }

    return New-FreshWinInvalidAssistantIntent `
        -ErrorMessage 'Command not recognized. Try help, install, search, status, doctor, or scan drivers.' `
        -RawInput $rawInput
}

function Find-FreshWinForbiddenIntentProperty {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,
        [int]$Depth = 0
    )

    # Provider output is untrusted.  Treat excessive nesting as invalid instead
    # of silently stopping the inspection, otherwise a forbidden executable
    # field can be hidden below the traversal limit.
    if ($Depth -gt 20) {
        return '__maximumDepthExceeded__'
    }
    if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject -is [ValueType]) {
        return $null
    }
    $forbidden = @('command', 'commandLine', 'script', 'powershell', 'executable', 'arguments', 'shell')
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ($forbidden -contains ([string]$key).ToLowerInvariant()) {
                return [string]$key
            }
            try {
                $dictionaryValue = $InputObject[$key]
            }
            catch {
                return '__unreadableProperty__'
            }
            $nested = Find-FreshWinForbiddenIntentProperty -InputObject $dictionaryValue -Depth ($Depth + 1)
            if ($null -ne $nested) { return $nested }
        }
        return $null
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        foreach ($item in $InputObject) {
            $nested = Find-FreshWinForbiddenIntentProperty -InputObject $item -Depth ($Depth + 1)
            if ($null -ne $nested) { return $nested }
        }
        return $null
    }
    foreach ($property in $InputObject.PSObject.Properties) {
        if ($forbidden -contains $property.Name.ToLowerInvariant()) {
            return $property.Name
        }
        try {
            $propertyValue = $property.Value
        }
        catch {
            return '__unreadableProperty__'
        }
        $nested = Find-FreshWinForbiddenIntentProperty -InputObject $propertyValue -Depth ($Depth + 1)
        if ($null -ne $nested) { return $nested }
    }
    return $null
}

function Test-FreshWinAssistantIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$IntentObject
    )

    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $IntentObject) {
        $errors.Add('Provider returned no intent.')
    }
    else {
        $action = [string](Get-FreshWinPropertyValue -InputObject $IntentObject -Name 'action' -Default '')
        $intentName = [string](Get-FreshWinPropertyValue -InputObject $IntentObject -Name 'intent' -Default '')
        if ([string]::IsNullOrWhiteSpace($intentName)) {
            $errors.Add('Intent name is missing.')
        }
        if ($script:FreshWinAllowedAssistantActions -notcontains $action) {
            $errors.Add("Action '$action' is not in the FreshWin allowlist.")
        }
        $targets = @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $IntentObject -Name 'targets' -Default @()))
        if ($targets.Count -gt 50) {
            $errors.Add('Intent contains too many targets.')
        }
        foreach ($target in $targets) {
            if ([string]$target -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$') {
                $errors.Add("Intent target '$target' is invalid.")
            }
        }
        $hasConfirmation = Test-FreshWinHasProperty -InputObject $IntentObject -Name 'requiresConfirmation'
        $confirmationValue = Get-FreshWinPropertyValue -InputObject $IntentObject -Name 'requiresConfirmation' -Default $null
        if (-not $hasConfirmation -or $confirmationValue -isnot [bool]) {
            $errors.Add('requiresConfirmation must be an explicit Boolean value.')
        }
        elseif ($action -in @('queue_install', 'queue_update', 'backup_drivers', 'recommend_profile') -and
            -not [bool]$confirmationValue) {
            $errors.Add("Action '$action' requires explicit confirmation.")
        }

        $forbiddenProperty = Find-FreshWinForbiddenIntentProperty -InputObject $IntentObject
        if ($forbiddenProperty -eq '__maximumDepthExceeded__') {
            $errors.Add('Provider output exceeds the maximum safe nesting depth.')
        }
        elseif ($forbiddenProperty -eq '__unreadableProperty__') {
            $errors.Add('Provider output contains a property that could not be safely inspected.')
        }
        elseif ($null -ne $forbiddenProperty) {
            $errors.Add("Provider output contains forbidden property '$forbiddenProperty'.")
        }
    }

    return [PSCustomObject]@{
        IsValid = $errors.Count -eq 0
        Errors  = $errors.ToArray()
    }
}

function Register-FreshWinAssistantProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-z0-9][a-z0-9._-]{0,63}$')]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet('deterministic', 'local-ai', 'openai-compatible', 'gemini-compatible', 'custom')]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Handler,

        [bool]$IsConfigured = $true,
        [switch]$Force
    )

    if ($script:FreshWinAssistantProviders.ContainsKey($Name) -and -not $Force) {
        throw "Assistant provider '$Name' is already registered."
    }
    $provider = [PSCustomObject]@{
        Name          = $Name
        Kind          = $Kind
        IsConfigured  = $IsConfigured
        AllowedOutput = 'FreshWinIntentOnly'
        Handler       = $Handler
    }
    $script:FreshWinAssistantProviders[$Name] = $provider
    return $provider
}

function Initialize-FreshWinAssistant {
    [CmdletBinding()]
    param()

    $handler = {
        param([string]$CommandText)
        ConvertFrom-FreshWinAssistantCommand -InputText $CommandText
    }
    [void](Register-FreshWinAssistantProvider -Name 'deterministic' -Kind 'deterministic' -Handler $handler -Force)
    return $script:FreshWinAssistantProviders['deterministic']
}

function Get-FreshWinAssistantProvider {
    [CmdletBinding()]
    param(
        [string]$Name
    )

    if ($script:FreshWinAssistantProviders.Count -eq 0) {
        [void](Initialize-FreshWinAssistant)
    }
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return @($script:FreshWinAssistantProviders.Values)
    }
    if (-not $script:FreshWinAssistantProviders.ContainsKey($Name)) {
        throw "Assistant provider '$Name' is not registered."
    }
    return $script:FreshWinAssistantProviders[$Name]
}

function Invoke-FreshWinAssistantProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InputText,
        [string]$ProviderName = 'deterministic'
    )

    $provider = Get-FreshWinAssistantProvider -Name $ProviderName
    if (-not $provider.IsConfigured) {
        throw "Assistant provider '$ProviderName' is not configured."
    }

    $output = & $provider.Handler $InputText
    if ($output -is [string] -and $provider.Kind -ne 'deterministic') {
        try {
            $output = ConvertFrom-Json -InputObject $output -ErrorAction Stop
        }
        catch {
            throw "Assistant provider '$ProviderName' returned invalid JSON."
        }
    }

    if (Test-FreshWinHasProperty -InputObject $output -Name 'provider') {
        $output.provider = $ProviderName
    }
    $validation = Test-FreshWinAssistantIntent -IntentObject $output
    $safetyErrors = @($validation.Errors | Where-Object {
        $_ -match 'forbidden property|maximum safe nesting depth|could not be safely inspected'
    })
    # A provider cannot bypass structural safety checks by setting isValid=false.
    # Deterministic parse failures use that flag for ordinary user-input errors,
    # but forbidden execution fields and uninspectable/deep output are rejected at
    # the provider boundary in every case.
    if ($safetyErrors.Count -gt 0 -or
        (-not $validation.IsValid -and [bool](Get-FreshWinPropertyValue -InputObject $output -Name 'isValid' -Default $true))) {
        throw "Assistant provider '$ProviderName' returned an unsafe intent: $($validation.Errors -join ' ')"
    }
    return $output
}
