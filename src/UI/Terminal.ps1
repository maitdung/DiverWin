Set-StrictMode -Version 2.0

$script:FreshWinTerminalCompactMode = $false

function Initialize-FreshWinTerminalEncoding {
    [CmdletBinding()]
    param()

    # Windows PowerShell 5.1 otherwise inherits the active OEM code page.
    # Use UTF-8 explicitly for both managed console I/O and native-process
    # pipeline encoding before the first interactive page is rendered.
    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $global:OutputEncoding = $utf8
}

function New-FreshWinTerminalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Label
    )
    return [pscustomobject]@{ Key = $Key; Label = $Label }
}

function New-FreshWinTerminalItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$Badge,
        [string]$Detail,
        [AllowNull()][object]$Value = $null
    )
    return [pscustomobject]@{ Key = $Key; Label = $Label; Badge = $Badge; Detail = $Detail; Value = $Value }
}

function New-FreshWinTerminalPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Breadcrumb,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Description,
        [AllowNull()][object[]]$Items = @(),
        [AllowNull()][string[]]$Status = @(),
        [AllowNull()][string[]]$ContextHelp = @(),
        [AllowNull()][object[]]$Commands = @(),
        [string]$Prompt = $(Get-FreshWinTerminalString -Key 'terminal.common.selectOption' -Default 'Select an option.')
    )
    return [pscustomobject][ordered]@{
        Breadcrumb = @($Breadcrumb)
        Title = $Title
        Description = $Description
        Items = @($Items)
        Status = @($Status)
        ContextHelp = @($ContextHelp)
        Commands = @($Commands)
        Prompt = $Prompt
    }
}

function ConvertTo-FreshWinTerminalSafeText {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value) -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ''
}

function Get-FreshWinTerminalString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Default,
        [AllowNull()][object[]]$FormatArguments = @()
    )
    try { return Get-FreshWinString -Key $Key -Default $Default -FormatArguments $FormatArguments }
    catch {
        if ($null -ne $FormatArguments -and $FormatArguments.Count -gt 0) {
            try { return $Default -f $FormatArguments } catch { }
        }
        return $Default
    }
}

function Split-FreshWinTerminalText {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [ValidateRange(20, 240)][int]$Width = 92
    )
    if ([string]::IsNullOrEmpty($Text)) { return @('') }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($sourceLine in @($Text -split '\r?\n')) {
        $remaining = ConvertTo-FreshWinTerminalSafeText $sourceLine
        if ($remaining.Length -eq 0) { $result.Add(''); continue }
        while ($remaining.Length -gt $Width) {
            $searchIndex = [Math]::Min($Width, ($remaining.Length - 1))
            $breakAt = $remaining.LastIndexOf([char]' ', $searchIndex)
            if ($breakAt -lt [Math]::Floor($Width / 2)) {
                $breakAt = [Math]::Min($Width, $remaining.Length)
            }
            if ($breakAt -le 0 -or $breakAt -gt $remaining.Length) {
                throw 'Terminal text wrapping could not determine a valid forward boundary.'
            }
            $headLength = [Math]::Min($breakAt, $remaining.Length)
            $result.Add($remaining.Substring(0, $headLength).TrimEnd())
            $remaining = $remaining.Substring($headLength).TrimStart()
        }
        $result.Add($remaining)
    }
    return $result.ToArray()
}

function Format-FreshWinTerminalPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [ValidateRange(60, 140)][int]$Width = 92
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $border = '=' * $Width
    $minor = '-' * $Width
    $lines.Add($border)
    $lines.Add((' FreshWin {0}' -f (Get-FreshWinVersion)))
    $lines.Add((' {0}: {1}' -f (Get-FreshWinTerminalString 'terminal.renderer.breadcrumb' 'Breadcrumb'), (@($Page.Breadcrumb) -join ' > ')))
    $lines.Add($minor)
    $lines.Add((' {0}' -f (ConvertTo-FreshWinTerminalSafeText $Page.Title)))
    foreach ($line in @(Split-FreshWinTerminalText -Text ([string]$Page.Description) -Width ($Width - 2))) {
        $lines.Add((' {0}' -f $line))
    }

    foreach ($statusLine in @($Page.Status)) {
        foreach ($line in @(Split-FreshWinTerminalText -Text ([string]$statusLine) -Width ($Width - 5))) {
            $lines.Add(('  * {0}' -f $line))
        }
    }

    if (@($Page.Items).Count -gt 0) {
        $lines.Add('')
        foreach ($item in @($Page.Items)) {
            $key = ConvertTo-FreshWinTerminalSafeText $item.Key
            $badge = ConvertTo-FreshWinTerminalSafeText $item.Badge
            $label = ConvertTo-FreshWinTerminalSafeText $item.Label
            $prefix = (' [{0}]' -f $key).PadRight(7)
            if (-not [string]::IsNullOrWhiteSpace($badge)) { $prefix += (' {0}' -f $badge).PadRight(7) }
            else { $prefix += '       ' }
            $available = [Math]::Max(20, $Width - $prefix.Length)
            $labelLines = @(Split-FreshWinTerminalText -Text $label -Width $available)
            $lines.Add($prefix + $labelLines[0])
            foreach ($continued in @($labelLines | Select-Object -Skip 1)) { $lines.Add((' ' * $prefix.Length) + $continued) }
            if (-not [string]::IsNullOrWhiteSpace([string]$item.Detail)) {
                foreach ($detailLine in @(Split-FreshWinTerminalText -Text ([string]$item.Detail) -Width ($Width - 8))) {
                    $lines.Add(('        {0}' -f $detailLine))
                }
            }
        }
    }

    $lines.Add('')
    if (-not [bool]$script:FreshWinTerminalCompactMode) {
        $lines.Add((' {0}' -f (Get-FreshWinTerminalString 'terminal.renderer.contextHelp' 'Context help')))
        if (@($Page.ContextHelp).Count -eq 0) { $lines.Add(('  - {0}' -f (Get-FreshWinTerminalString 'terminal.renderer.noHelp' 'No additional help is available on this page.'))) }
        else {
            foreach ($help in @($Page.ContextHelp)) {
                foreach ($helpLine in @(Split-FreshWinTerminalText -Text ([string]$help) -Width ($Width - 4))) {
                    $lines.Add(('  - {0}' -f $helpLine))
                }
            }
        }
    }

    $lines.Add((' {0}' -f (Get-FreshWinTerminalString 'terminal.renderer.commands' 'Commands')))
    if (@($Page.Commands).Count -eq 0) { $lines.Add(('  ({0})' -f (Get-FreshWinTerminalString 'terminal.renderer.none' 'none'))) }
    else {
        $commandText = @($Page.Commands | ForEach-Object { '[{0}] {1}' -f $_.Key, $_.Label }) -join '   '
        foreach ($commandLine in @(Split-FreshWinTerminalText -Text $commandText -Width ($Width - 2))) {
            $lines.Add((' {0}' -f $commandLine))
        }
    }
    $lines.Add($minor)
    $lines.Add((' {0} > {1}' -f (Get-FreshWinTerminalString 'terminal.renderer.prompt' 'Input'), (ConvertTo-FreshWinTerminalSafeText $Page.Prompt)))
    $lines.Add($border)
    return $lines.ToArray()
}

function Write-FreshWinTerminalPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [ValidateRange(60, 140)][int]$Width = 92,
        [scriptblock]$OutputWriter,
        [switch]$Clear
    )
    if ($Clear -and $null -eq $OutputWriter) { try { [Console]::Clear() } catch { } }
    $rendered = @(Format-FreshWinTerminalPage -Page $Page -Width $Width)
    foreach ($line in $rendered) {
        if ($null -ne $OutputWriter) { & $OutputWriter $line }
        else { Write-Host $line }
    }
    return $rendered
}

function Read-FreshWinTerminalInput {
    [CmdletBinding()]
    param([string]$Prompt, [scriptblock]$InputProvider)
    if ($null -ne $InputProvider) { return & $InputProvider $Prompt }
    return Read-FreshWinInput -Prompt $Prompt -AllowEmpty
}

function Write-FreshWinStartupFailureDiagnostic {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ErrorRecord,
        [scriptblock]$OutputWriter
    )

    try {
        $exception = $null
        try { $exception = $ErrorRecord.Exception } catch { }
        $invocation = $null
        try { $invocation = $ErrorRecord.InvocationInfo } catch { }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('FreshWin startup diagnostic')
        try { $lines.Add('ExceptionType: ' + $(if ($null -ne $exception) { $exception.GetType().FullName } else { '<unavailable>' })) } catch { $lines.Add('ExceptionType: <unavailable>') }
        try { $lines.Add('Message: ' + [string]$exception.Message) } catch { $lines.Add('Message: <unavailable>') }
        try { $lines.Add('ScriptStackTrace: ' + [string]$ErrorRecord.ScriptStackTrace) } catch { $lines.Add('ScriptStackTrace: <unavailable>') }
        try { $lines.Add('InvocationInfo: ' + [string]$invocation.PositionMessage) } catch { $lines.Add('InvocationInfo: <unavailable>') }
        try { $lines.Add('File: ' + [string]$invocation.ScriptName) } catch { $lines.Add('File: <unavailable>') }
        try { $lines.Add('Line: ' + [string]$invocation.ScriptLineNumber) } catch { $lines.Add('Line: <unavailable>') }
        try { $lines.Add('Function: ' + [string]$invocation.MyCommand.Name) } catch { $lines.Add('Function: <unavailable>') }
        foreach ($line in $lines) {
            try {
                if ($null -ne $OutputWriter) { & $OutputWriter ([string]$line) }
                else { [Console]::Error.WriteLine([string]$line) }
            }
            catch {
                try { Write-Host ([string]$line) } catch { }
            }
        }
    }
    catch {
        try { [Console]::Error.WriteLine('FreshWin startup diagnostic was unavailable.') } catch { }
    }
}

function Get-FreshWinTerminalHomeEntries {
    [CmdletBinding()]
    param()
    return @(
        (New-FreshWinTerminalItem -Key '1' -Label (Get-FreshWinTerminalString 'terminal.home.entries.quick.label' 'Quick Setup') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.quick.detail' 'Curated essential, work, gaming, developer, and full profiles.') -Value 'quick-setup'),
        (New-FreshWinTerminalItem -Key '2' -Label (Get-FreshWinTerminalString 'terminal.home.entries.drivers.label' 'Drivers & Hardware') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.drivers.detail' 'Inspect hardware and device health; use official driver guidance.') -Value 'drivers-hardware'),
        (New-FreshWinTerminalItem -Key '3' -Label (Get-FreshWinTerminalString 'terminal.home.entries.applications.label' 'Applications') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.applications.detail' 'Browse everyday, communication, creative, and utility applications.') -Value 'applications'),
        (New-FreshWinTerminalItem -Key '4' -Label (Get-FreshWinTerminalString 'terminal.home.entries.gaming.label' 'Gaming') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.gaming.detail' 'Game launchers, communication, streaming, and hardware tools.') -Value 'gaming'),
        (New-FreshWinTerminalItem -Key '5' -Label (Get-FreshWinTerminalString 'terminal.home.entries.developer.label' 'Developer') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.developer.detail' 'Editors, version control, cloud, database, API, and container tools.') -Value 'developer'),
        (New-FreshWinTerminalItem -Key '6' -Label (Get-FreshWinTerminalString 'terminal.home.entries.security.label' 'Security & Protection') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.security.detail' 'Review trusted security and antimalware workflows.') -Value 'security'),
        (New-FreshWinTerminalItem -Key '7' -Label (Get-FreshWinTerminalString 'terminal.home.entries.runtimes.label' 'Windows & Runtimes') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.runtimes.detail' 'Windows features, language runtimes, SDKs, and system dependencies.') -Value 'windows-runtimes'),
        (New-FreshWinTerminalItem -Key '8' -Label (Get-FreshWinTerminalString 'terminal.home.entries.diagnostics.label' 'Diagnostics & Repair') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.diagnostics.detail' 'Read-only readiness, update, activation, network, and repair state.') -Value 'diagnostics'),
        (New-FreshWinTerminalItem -Key '9' -Label (Get-FreshWinTerminalString 'terminal.home.entries.backup.label' 'Backup / Before Reset') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.backup.detail' 'Export a restorable application profile and review the reset checklist.') -Value 'backup'),
        (New-FreshWinTerminalItem -Key 'A' -Label (Get-FreshWinTerminalString 'terminal.home.entries.assistant.label' 'Assistant') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.assistant.detail' 'Translate a constrained request into a reviewed FreshWin intent.') -Value 'assistant'),
        (New-FreshWinTerminalItem -Key 'L' -Label (Get-FreshWinTerminalString 'terminal.home.entries.language.label' 'Language') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.language.detail' 'Choose the FreshWin interface locale.') -Value 'language'),
        (New-FreshWinTerminalItem -Key 'U' -Label (Get-FreshWinTerminalString 'terminal.home.entries.update.label' 'Update FreshWin') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.update.detail' 'Show the installed version and trusted update guidance.') -Value 'update-freshwin'),
        (New-FreshWinTerminalItem -Key 'H' -Label (Get-FreshWinTerminalString 'terminal.home.entries.about.label' 'About & Support') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.about.detail' 'Version, safety model, help, and local documentation.') -Value 'about'),
        (New-FreshWinTerminalItem -Key '0' -Label (Get-FreshWinTerminalString 'terminal.home.entries.exit.label' 'Exit') -Detail (Get-FreshWinTerminalString 'terminal.home.entries.exit.detail' 'Leave FreshWin without making additional changes.') -Value 'exit')
    )
}

function Get-FreshWinTerminalHomePage {
    [CmdletBinding()]
    param(
        [string]$Notice,
        [AllowNull()][object]$Session
    )
    $status = @()
    if ($null -ne $Session) {
        $system = Get-FreshWinPropertyValue -InputObject $Session -Name 'System' -Default $null
        $network = Get-FreshWinPropertyValue -InputObject $Session -Name 'Network' -Default $null
        $inventory = Get-FreshWinPropertyValue -InputObject $Session -Name 'Inventory' -Default $null
        $osName = [string](Get-FreshWinPropertyValue -InputObject $system -Name 'OSName' -Default (Get-FreshWinPropertyValue -InputObject $system -Name 'OSFamily' -Default 'Unknown'))
        $build = [string](Get-FreshWinPropertyValue -InputObject $system -Name 'BuildNumber' -Default 'Unknown')
        $architecture = [string](Get-FreshWinPropertyValue -InputObject $system -Name 'Architecture' -Default 'Unknown')
        $cpu = [string](Get-FreshWinPropertyValue -InputObject $system -Name 'CPU' -Default 'Unknown')
        $memory = Get-FreshWinPropertyValue -InputObject $system -Name 'MemoryGB' -Default $null
        $gpus = @((Get-FreshWinPropertyValue -InputObject $system -Name 'GPUs' -Default @()) | ForEach-Object { [string](Get-FreshWinPropertyValue -InputObject $_ -Name 'Name' -Default 'Unknown') })
        $gpuText = if ($gpus.Count -gt 0) { $gpus -join ', ' } else { Get-FreshWinTerminalString 'terminal.home.status.unknownGpu' 'Unknown GPU' }
        $internetValue = Get-FreshWinPropertyValue -InputObject $network -Name 'InternetAvailable' -Default $null
        $internetText = if ($internetValue -is [bool]) {
            if ($internetValue) { Get-FreshWinTerminalString 'terminal.home.status.online' 'Online' } else { Get-FreshWinTerminalString 'terminal.home.status.offline' 'Offline' }
        } else { Get-FreshWinTerminalString 'ui.status.unknown' 'Unknown' }
        $adminText = if ([bool](Get-FreshWinPropertyValue -InputObject $system -Name 'Admin' -Default $false)) {
            Get-FreshWinTerminalString 'terminal.home.status.yes' 'Yes'
        } else { Get-FreshWinTerminalString 'terminal.home.status.no' 'No' }
        $inventoryAvailable = [bool](Get-FreshWinPropertyValue -InputObject $inventory -Name 'Available' -Default $false)
        $inventoryItems = @((Get-FreshWinPropertyValue -InputObject $inventory -Name 'Items' -Default @()))
        $updatesScanned = [bool](Get-FreshWinPropertyValue -InputObject $inventory -Name 'UpdatesScanned' -Default $false)
        $updateCount = if ($inventoryAvailable -and $updatesScanned) {
            @($inventoryItems | Where-Object { [bool](Get-FreshWinPropertyValue -InputObject $_ -Name 'UpdateAvailable' -Default $false) }).Count
        } elseif ($inventoryAvailable) { Get-FreshWinTerminalString 'terminal.home.status.updatesNotScanned' 'not scanned' } else { $null }
        $inventoryStatus = [string](Get-FreshWinPropertyValue -InputObject $inventory -Name 'Status' -Default 'Unknown')
        $status += @(
            (Get-FreshWinTerminalString 'terminal.home.status.system' '{0} | build {1} | {2}' @($osName, $build, $architecture)),
            (Get-FreshWinTerminalString 'terminal.home.status.hardware' '{0} | {1} GB RAM | {2}' @($cpu, $memory, $gpuText)),
            (Get-FreshWinTerminalString 'terminal.home.status.session' 'Internet: {0} | Administrator: {1}' @($internetText, $adminText)),
            $(if ($inventoryAvailable) {
                Get-FreshWinTerminalString 'terminal.home.status.inventory' 'Observed applications: {0} | updates: {1}' @($inventoryItems.Count, $updateCount)
            } else {
                Get-FreshWinTerminalString 'terminal.home.status.inventoryUnavailable' 'Software inventory: {0}; installation remains blocked until detection is available.' @($inventoryStatus)
            })
        )
    }
    $status += (Get-FreshWinTerminalString 'terminal.home.sourceTruth' 'Local catalog and observed Windows state remain the source of truth.')
    if (-not [string]::IsNullOrWhiteSpace($Notice)) { $status += $Notice }
    $title = Get-FreshWinTerminalString -Key 'terminal.home.title' -Default 'FreshWin Home'
    $tagline = Get-FreshWinTerminalString -Key 'app.tagline' -Default 'A safe, transparent Windows setup assistant.'
    return New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home')) -Title $title `
        -Description (Get-FreshWinTerminalString 'terminal.home.description' 'Windows Post-Install Toolkit — {0} Choose a center; every change remains planned, reviewed, and independently verified.' @($tagline)) `
        -Items (Get-FreshWinTerminalHomeEntries) -Status $status `
        -ContextHelp @((Get-FreshWinTerminalString 'terminal.home.helpCenters' 'Numbered centers organize setup and recovery work.'), (Get-FreshWinTerminalString 'terminal.home.helpGlobal' 'A, L, U, and H are global product centers; 0 exits.')) `
        -Commands @((New-FreshWinTerminalCommand '1-9' (Get-FreshWinTerminalString 'terminal.home.openCenter' 'Open center')), (New-FreshWinTerminalCommand 'A' (Get-FreshWinTerminalString 'terminal.home.entries.assistant.label' 'Assistant')), (New-FreshWinTerminalCommand 'L' (Get-FreshWinTerminalString 'terminal.home.entries.language.label' 'Language')), (New-FreshWinTerminalCommand 'U' (Get-FreshWinTerminalString 'terminal.home.entries.update.label' 'Update FreshWin')), (New-FreshWinTerminalCommand 'H' (Get-FreshWinTerminalString 'terminal.home.entries.about.label' 'About & Support')), (New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.exit' 'Exit'))) `
        -Prompt (Get-FreshWinTerminalString 'terminal.home.prompt' 'Enter exactly one home key.')
}

function New-FreshWinTerminalSessionContext {
    [CmdletBinding()]
    param([switch]$IncludeUpdates)
    $catalog = Get-FreshWinCliCatalog
    $machine = Get-FreshWinCliSystemContext -IncludeUpdates:$IncludeUpdates
    $profiles = Import-FreshWinProfiles -Catalog $catalog
    if (@($profiles.Errors).Count -gt 0) { throw "Profiles are invalid: $(@($profiles.Errors.Error) -join ' ')" }
    return [pscustomobject]@{
        Catalog = $catalog
        System = $machine.System
        Network = $machine.Network
        Inventory = $machine.Inventory
        Profiles = $profiles
        IncludeUpdates = [bool]$IncludeUpdates
    }
}

function Set-FreshWinTerminalInventoryPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][bool]$IncludeUpdates,
        [scriptblock]$InventoryProvider
    )

    $inventory = if ($null -ne $InventoryProvider) {
        & $InventoryProvider $IncludeUpdates
    }
    else {
        Get-FreshWinSoftwareInventorySnapshot -Refresh -IncludeUpdates:$IncludeUpdates
    }
    if ($null -eq $inventory) { throw 'The software inventory refresh returned no snapshot.' }

    # Commit the policy and its corresponding snapshot together. If refresh
    # fails, the session retains the previous internally consistent state.
    $Session.Inventory = $inventory
    $Session.IncludeUpdates = $IncludeUpdates
    return $inventory
}

function Get-FreshWinTerminalCenterDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('applications','gaming','developer','security','windows-runtimes','updates')][string]$Center)
    switch ($Center) {
        'applications' { return [pscustomobject]@{ Id=$Center; Title=(Get-FreshWinTerminalString 'terminal.centers.applications.title' 'Applications'); Description=(Get-FreshWinTerminalString 'terminal.centers.applications.description' 'Everyday, communication, creative, and utility applications.'); Profile='essential' } }
        'gaming' { return [pscustomobject]@{ Id=$Center; Title=(Get-FreshWinTerminalString 'terminal.centers.gaming.title' 'Gaming'); Description=(Get-FreshWinTerminalString 'terminal.centers.gaming.description' 'Gaming launchers, streaming, communication, and monitoring tools.'); Profile='gaming' } }
        'developer' { return [pscustomobject]@{ Id=$Center; Title=(Get-FreshWinTerminalString 'terminal.centers.developer.title' 'Developer'); Description=(Get-FreshWinTerminalString 'terminal.centers.developer.description' 'Developer tools excluding runtimes and Windows features, which have their own center.'); Profile='developer' } }
        'security' { return [pscustomobject]@{ Id=$Center; Title=(Get-FreshWinTerminalString 'terminal.centers.security.title' 'Security & Protection'); Description=(Get-FreshWinTerminalString 'terminal.centers.security.description' 'Security products may require an official interactive vendor workflow.'); Profile='full-recommended' } }
        'windows-runtimes' { return [pscustomobject]@{ Id=$Center; Title=(Get-FreshWinTerminalString 'terminal.centers.runtimes.title' 'Windows & Runtimes'); Description=(Get-FreshWinTerminalString 'terminal.centers.runtimes.description' 'Windows features, WSL, runtimes, SDKs, and system dependencies.'); Profile='developer' } }
        'updates' { return [pscustomobject]@{ Id=$Center; Title=(Get-FreshWinTerminalString 'terminal.centers.updates.title' 'Community WinGet Updates'); Description=(Get-FreshWinTerminalString 'terminal.centers.updates.description' 'Community WinGet packages for which the observed inventory reports an update; Store updates are outside this scan.'); Profile='full-recommended' } }
    }
}

function Get-FreshWinTerminalCenterPackages {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Catalog, [Parameter(Mandatory = $true)][string]$Center)
    return @($Catalog.Packages | Where-Object {
        $package = $_
        $category = ([string](Get-FreshWinPropertyValue $package 'category' '')).ToLowerInvariant()
        $subcategory = ([string](Get-FreshWinPropertyValue $package 'subcategory' '')).ToLowerInvariant()
        $source = Get-FreshWinPropertyValue $package 'source' ([pscustomobject]@{})
        $sourceType = ([string](Get-FreshWinPropertyValue $source 'type' '')).ToLowerInvariant()
        switch ($Center) {
            'applications' { $sourceType -ne 'windows-feature' -and $category -notin @('gaming','developer','security','runtime') }
            'gaming' { $category -eq 'gaming' }
            'developer' { $category -eq 'developer' -and $subcategory -notin @('runtime','virtualization') }
            'security' { $category -eq 'security' }
            'windows-runtimes' { $sourceType -eq 'windows-feature' -or $category -eq 'runtime' -or $subcategory -in @('runtime','system-runtime','virtualization') }
            'updates' { $sourceType -eq 'winget' }
            default { $false }
        }
    } | Sort-Object subcategory, name, id)
}

function Get-FreshWinTerminalPackageRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][string]$Center,
        [ValidateSet('ALL','MISSING','UPDATES','RECOMMENDED','SEARCH')][string]$Filter = 'ALL',
        [string]$SearchTerm
    )
    $definition = Get-FreshWinTerminalCenterDefinition $Center
    $packages = @(Get-FreshWinTerminalCenterPackages -Catalog $Session.Catalog -Center $Center)
    if ($Filter -eq 'SEARCH') {
        $matches = @(Find-FreshWinPackage -Catalog $Session.Catalog -Query $SearchTerm)
        $matchIds = @($matches | ForEach-Object { [string]$_.id })
        $packages = @($packages | Where-Object { $matchIds -icontains ([string]$_.id) })
    }
    $recommendedIds = @()
    try {
        $recommendedIds = @(Get-FreshWinRecommendations -Catalog $Session.Catalog -SystemInfo $Session.System -Inventory $Session.Inventory -ProfileId $definition.Profile -Profiles $Session.Profiles | ForEach-Object PackageId)
    }
    catch { }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($package in $packages) {
        $compatibility = Get-FreshWinPackageCompatibility -Package $package -SystemInfo $Session.System
        $detection = Get-FreshWinPackageDetection -Package $package -Inventory $Session.Inventory -Compatibility $compatibility
        $recommended = $recommendedIds -icontains ([string]$package.id)
        if ($Filter -eq 'MISSING' -and $detection.State -notin @('NotInstalled','Broken')) { continue }
        if ($Filter -eq 'UPDATES' -and $detection.State -ne 'UpdateAvailable') { continue }
        if ($Filter -eq 'RECOMMENDED' -and -not $recommended) { continue }
        $source = Get-FreshWinPropertyValue $package 'source' ([pscustomobject]@{})
        $sourceType = [string](Get-FreshWinPropertyValue $source 'type' '')
        $section = [string](Get-FreshWinPropertyValue $package 'subcategory' (Get-FreshWinPropertyValue $package 'category' 'other'))
        $description = Get-FreshWinString -Key ([string]$package.descriptionKey) -Default ([string]$package.name)
        $recommendedText = if ($recommended) { Get-FreshWinTerminalString 'terminal.package.recommendedSuffix' ' | recommended' } else { '' }
        $detail = Get-FreshWinTerminalString 'terminal.package.detailWithSection' '{0} | section: {1} | source: {2}{3} | {4}' @($detection.State, $section, $sourceType, $recommendedText, $description)
        $rows.Add([pscustomobject]@{ Package=$package; Detection=$detection; Compatibility=$compatibility; Detail=$detail })
    }
    $number = 0
    return @($rows.ToArray() | ForEach-Object {
        $number++
        New-FreshWinTerminalItem -Key ([string]$number) -Label ([string]$_.Package.name) -Badge ([string]$_.Detection.Badge) -Detail $_.Detail -Value $_
    })
}

function Show-FreshWinTerminalRebootBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CheckpointPath,
        [Parameter(Mandatory = $true)][string]$EntryScriptPath,
        [string]$ExecutionStatus,
        [scriptblock]$InputProvider,
        [scriptblock]$OutputWriter,
        [scriptblock]$ResumeRegistrar
    )

    $resumeCommand = 'powershell.exe -NoLogo -NoProfile -File "{0}" resume "{1}"' -f $EntryScriptPath, $CheckpointPath
    $statusLines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ExecutionStatus)) {
        $statusLines.Add((Get-FreshWinTerminalString 'terminal.plan.resultStatus' 'Status: {0}' @($ExecutionStatus)))
    }
    $statusLines.Add((Get-FreshWinTerminalString 'terminal.plan.rebootCheckpoint' 'Protected checkpoint: {0}' @($CheckpointPath)))
    $statusLines.Add((Get-FreshWinTerminalString 'terminal.plan.rebootCommand' 'After restart, review and run: {0}' @($resumeCommand)))
    $statusLines.Add((Get-FreshWinTerminalString 'terminal.plan.rebootNotRegistered' 'Automatic resume is not registered unless you explicitly choose R.'))
    $page = New-FreshWinTerminalPage `
        -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.plan.rebootTitle' 'Restart required')) `
        -Title (Get-FreshWinTerminalString 'terminal.plan.rebootTitle' 'Restart required') `
        -Description (Get-FreshWinTerminalString 'terminal.plan.rebootDescription' 'FreshWin stopped before the user-scope phase. Restart Windows, then resume from the protected checkpoint.') `
        -Status $statusLines.ToArray() `
        -ContextHelp @((Get-FreshWinTerminalString 'terminal.plan.rebootHelp' 'FreshWin never restarts Windows automatically. Resume rebuilds the plan from the trusted catalog and current state.')) `
        -Commands @(
            (New-FreshWinTerminalCommand 'R' (Get-FreshWinTerminalString 'terminal.plan.rebootRegister' 'Register one-time resume after next sign-in')),
            (New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.return' 'Return'))
        ) `
        -Prompt (Get-FreshWinTerminalString 'terminal.plan.rebootPrompt' 'Choose R to register one-time resume, or 0 to return without registering.')
    [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
    $choiceValue = Read-FreshWinTerminalInput -Prompt 'reboot' -InputProvider $InputProvider
    $choice = if ($null -eq $choiceValue) { '0' } else { ([string]$choiceValue).Trim().ToUpperInvariant() }
    if ($choice -ne 'R') { return [pscustomobject]@{ Registered=$false; CheckpointPath=$CheckpointPath; ResumeCommand=$resumeCommand } }

    try {
        $registration = if ($null -ne $ResumeRegistrar) {
            & $ResumeRegistrar $EntryScriptPath $CheckpointPath
        } else {
            Register-FreshWinResume -EntryScriptPath $EntryScriptPath -CheckpointPath $CheckpointPath -Confirm:$false
        }
        $registered = [bool](Get-FreshWinPropertyValue -InputObject $registration -Name 'Registered' -Default $false)
        $message = if ($registered) {
            Get-FreshWinTerminalString 'terminal.plan.rebootRegistered' 'One-time resume was registered for the next sign-in.'
        } else {
            Get-FreshWinTerminalString 'terminal.plan.rebootRegistrationSkipped' 'One-time resume was not registered.'
        }
    }
    catch {
        $registered = $false
        $message = Get-FreshWinTerminalString 'terminal.plan.rebootRegistrationFailed' 'Resume registration failed: {0}' @((Protect-FreshWinSensitiveText $_.Exception.Message))
    }
    [void](Write-FreshWinTerminalPage -Page (New-FreshWinTerminalPage `
        -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.plan.rebootTitle' 'Restart required')) `
        -Title (Get-FreshWinTerminalString 'terminal.plan.rebootTitle' 'Restart required') `
        -Description $message `
        -Status @((Get-FreshWinTerminalString 'terminal.plan.rebootCheckpoint' 'Protected checkpoint: {0}' @($CheckpointPath))) `
        -Commands @((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.return' 'Return'))) `
        -Prompt (Get-FreshWinTerminalString 'terminal.plan.returnPrompt' 'Return to the center.')) -OutputWriter $OutputWriter)
    return [pscustomobject]@{ Registered=$registered; CheckpointPath=$CheckpointPath; ResumeCommand=$resumeCommand }
}

function Show-FreshWinTerminalExecutionRebootBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$ExecutionResult,
        [AllowNull()][string]$CheckpointPath,
        [AllowNull()][string]$EntryScriptPath,
        [scriptblock]$InputProvider,
        [scriptblock]$OutputWriter,
        [scriptblock]$ResumeRegistrar
    )

    if (-not (Test-FreshWinUiExecutionRequiresReboot -ExecutionResult $ExecutionResult)) { return $null }
    if ([string]::IsNullOrWhiteSpace($CheckpointPath)) { throw 'A checkpoint path is required to render the reboot boundary.' }
    if ([string]::IsNullOrWhiteSpace($EntryScriptPath)) { throw 'The entry script path is required to render the reboot boundary.' }
    return Show-FreshWinTerminalRebootBoundary -CheckpointPath $CheckpointPath -EntryScriptPath $EntryScriptPath `
        -ExecutionStatus ([string](Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Status' -Default '')) `
        -InputProvider $InputProvider -OutputWriter $OutputWriter -ResumeRegistrar $ResumeRegistrar
}

function Write-FreshWinTerminalExecutionPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [AllowNull()][object[]]$Progress = @(),
        [scriptblock]$OutputWriter
    )

    $events = @($Progress)
    $items = @($Plan.Items)
    $latestEvent = if ($events.Count -gt 0) { $events[$events.Count - 1] } else { $null }
    $queueItems = New-Object System.Collections.Generic.List[object]
    $queuePosition = 0
    foreach ($item in $items) {
        $queuePosition++
        $packageEvents = @($events | Where-Object PackageId -eq ([string]$item.PackageId))
        $lastPackageEvent = if ($packageEvents.Count -gt 0) { $packageEvents[$packageEvents.Count - 1] } else { $null }
        $queueState = if ($null -eq $lastPackageEvent) { 'Waiting' }
            elseif ([string]$lastPackageEvent.Stage -eq 'COMPLETE') { [string]$lastPackageEvent.Status }
            else { "[$($lastPackageEvent.StageNumber)/6] $($lastPackageEvent.StageLabel) - $($lastPackageEvent.Status)" }
        $queueItems.Add((New-FreshWinTerminalItem -Key ("$queuePosition/$($items.Count)") `
            -Label ([string](Get-FreshWinPropertyValue -InputObject $item.Package -Name 'name' -Default $item.PackageId)) `
            -Badge ("[$queueState]") -Detail ([string](Get-FreshWinPropertyValue -InputObject $lastPackageEvent -Name 'Detail' -Default '')) -Value $item))
    }

    $stageLines = New-Object System.Collections.Generic.List[string]
    $activeDescription = Get-FreshWinTerminalString 'terminal.execution.preparing' 'Preparing the reviewed execution queue.'
    if ($null -ne $latestEvent) {
        $activeDescription = Get-FreshWinTerminalString 'terminal.execution.active' 'Executing {0}.' @([string]$latestEvent.Name)
        $activeEvents = @($events | Where-Object PackageId -eq ([string]$latestEvent.PackageId))
        foreach ($definition in @(Get-FreshWinExecutionStageDefinitions)) {
            $matches = @($activeEvents | Where-Object Stage -eq ([string]$definition.Id))
            $stageEvent = if ($matches.Count -gt 0) { $matches[$matches.Count - 1] } else { $null }
            $stageStatus = if ($null -eq $stageEvent) { 'Waiting' } else { [string]$stageEvent.Status }
            $detail = [string](Get-FreshWinPropertyValue -InputObject $stageEvent -Name 'Detail' -Default '')
            $suffix = if ($detail) { " $detail" } else { '' }
            $stageLines.Add(("[{0}/6] {1,-28} [{2}]{3}" -f $definition.Number, $definition.Label, $stageStatus, $suffix))
        }
    }

    $page = New-FreshWinTerminalPage `
        -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.execution.breadcrumb' 'Execution')) `
        -Title (Get-FreshWinTerminalString 'terminal.execution.title' 'Executing reviewed plan') `
        -Description $activeDescription -Items $queueItems.ToArray() -Status $stageLines.ToArray() `
        -ContextHelp @(
            (Get-FreshWinTerminalString 'terminal.execution.noPercent' 'FreshWin shows deterministic stages; it does not invent a percentage when the backend supplies none.'),
            (Get-FreshWinTerminalString 'terminal.execution.verification' 'A successful process exit is not reported as installed until post-install detection succeeds.')
        ) -Commands @() -Prompt (Get-FreshWinTerminalString 'terminal.execution.wait' 'Execution is in progress. No input is required.')
    [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter -Clear)
}

function Get-FreshWinTerminalCurrentLogPath {
    [CmdletBinding()]
    param()

    try {
        $paths = Get-FreshWinPaths
        $logDirectory = [string](Get-FreshWinPropertyValue -InputObject $paths -Name 'Logs' -Default '')
        if (-not $logDirectory) { return '' }
        return Join-Path $logDirectory ('freshwin-{0}.jsonl' -f (Get-Date).ToString('yyyy-MM-dd'))
    }
    catch { return '' }
}

function Show-FreshWinTerminalExecutionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$ExecutionResult,
        [scriptblock]$InputProvider,
        [scriptblock]$OutputWriter
    )

    $report = New-FreshWinExecutionReport -ExecutionResult $ExecutionResult -Progress @(
        Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Progress' -Default @()
    )
    $hasFailure = @($report.Items | Where-Object Outcome -in @('Failed', 'Manual', 'Unknown verification')).Count -gt 0
    $notice = ''
    while ($true) {
        $resultItems = @($report.Items | ForEach-Object {
            $source = if ([string]$_.Source) { " Source: $($_.Source)." } else { '' }
            $stage = if ([string]$_.FailedStage) { " Failed stage: $($_.FailedStage)." } else { '' }
            $exit = if ($null -ne $_.ExitCode) { " Exit code: $($_.ExitCode)." } else { '' }
            $outcomeBadge = if ([bool]$_.Verified -and [string]$_.Outcome -in @('Installed', 'Updated')) {
                "[$($_.Outcome) - VERIFIED]"
            } else { "[$($_.Outcome)]" }
            New-FreshWinTerminalItem -Key ([string]$_.PackageId) -Label ([string]$_.Name) -Badge $outcomeBadge `
                -Detail ("$($_.Reason)$stage$source$exit") -Value $_
        })
        $commands = New-Object System.Collections.Generic.List[object]
        if ($hasFailure) {
            $commands.Add((New-FreshWinTerminalCommand 'R' (Get-FreshWinTerminalString 'terminal.execution.retry' 'Retry through a newly reviewed plan')))
            $commands.Add((New-FreshWinTerminalCommand 'D' (Get-FreshWinTerminalString 'terminal.execution.details' 'View failure details')))
            $commands.Add((New-FreshWinTerminalCommand 'L' (Get-FreshWinTerminalString 'terminal.execution.log' 'View log location')))
            $commands.Add((New-FreshWinTerminalCommand 'S' (Get-FreshWinTerminalString 'terminal.execution.skip' 'Skip failed items and return')))
        }
        $commands.Add((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.return' 'Return')))
        $status = @(
            (Get-FreshWinTerminalString 'terminal.plan.resultStatus' 'Status: {0}' @($report.Status)),
            (Get-FreshWinTerminalString 'terminal.plan.resultSucceeded' 'Succeeded: {0}' @($report.Summary.Succeeded)),
            (Get-FreshWinTerminalString 'terminal.plan.resultSkipped' 'Skipped: {0}' @($report.Summary.Skipped)),
            (Get-FreshWinTerminalString 'terminal.plan.resultFailed' 'Failed: {0}' @($report.Summary.Failed)),
            (Get-FreshWinTerminalString 'terminal.plan.resultUnknown' 'Unknown verification: {0}' @($report.Summary.UnknownVerification))
        )
        if ($notice) { $status += $notice }
        $page = New-FreshWinTerminalPage `
            -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.plan.resultsBreadcrumb' 'Results')) `
            -Title (Get-FreshWinTerminalString 'terminal.plan.resultsTitle' 'Execution Results') `
            -Description (Get-FreshWinTerminalString 'terminal.plan.resultsDescription' 'Process completion and independent verification are reported separately.') `
            -Items $resultItems -Status $status `
            -ContextHelp @((Get-FreshWinTerminalString 'terminal.execution.resultOwnsScreen' 'This result remains visible until you explicitly choose an action.')) `
            -Commands $commands.ToArray() -Prompt $(if ($hasFailure) {
                Get-FreshWinTerminalString 'terminal.execution.failurePrompt' 'Choose Retry, Details, Log, Skip, or Back.'
            } else { Get-FreshWinTerminalString 'terminal.execution.successPrompt' 'Press Enter or choose 0 to return.' })
        [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter -Clear)
        $choiceValue = Read-FreshWinTerminalInput -Prompt 'execution-result' -InputProvider $InputProvider
        if ($null -eq $choiceValue) { return [pscustomobject]@{ Action='Back'; Report=$report } }
        $choice = ([string]$choiceValue).Trim().ToUpperInvariant()
        if (-not $hasFailure -and $choice.Length -eq 0) { return [pscustomobject]@{ Action='Back'; Report=$report } }
        if ($choice -in @('0', 'B', 'S')) { return [pscustomobject]@{ Action='Back'; Report=$report } }
        if ($hasFailure -and $choice -eq 'R') { return [pscustomobject]@{ Action='Retry'; Report=$report } }
        if ($hasFailure -and $choice -eq 'D') {
            $failureDetails = @($report.Items | Where-Object Outcome -in @('Failed', 'Manual', 'Unknown verification') | ForEach-Object {
                $outputText = if ([string]$_.OutputSummary) { " Output: $($_.OutputSummary)" } else { '' }
                "$($_.PackageId): stage=$($_.FailedStage); source=$($_.Source); exit=$($_.ExitCode); reason=$($_.Reason).$outputText"
            })
            $notice = $failureDetails -join ' '
            continue
        }
        if ($hasFailure -and $choice -eq 'L') {
            $logPath = Get-FreshWinTerminalCurrentLogPath
            $notice = if ($logPath) { "FreshWin log: $logPath" } else { 'No persistent log path is available for this execution.' }
            continue
        }
        $notice = Get-FreshWinTerminalString 'terminal.execution.invalidResultCommand' 'Choose one of the displayed result actions.'
    }
}

function Invoke-FreshWinTerminalPlanWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][string[]]$PackageIds,
        [scriptblock]$InputProvider,
        [scriptblock]$OutputWriter,
        [scriptblock]$InventoryProvider,
        [scriptblock]$SystemInfoProvider,
        [scriptblock]$ProcessInvoker,
        [scriptblock]$SourceResolver,
        [scriptblock]$FeatureVerifier,
        [string]$EntryScriptPath,
        [switch]$DryRun
    )
    $updatePolicy = if ($Session.IncludeUpdates) { 'include-updates' } else { 'missing-only' }
    $plan = New-FreshWinInstallPlan -PackageIds $PackageIds -Catalog $Session.Catalog -SystemInfo $Session.System -Inventory $Session.Inventory `
        -UpdatePolicy $updatePolicy -DryRun:$DryRun -SourceResolver $SourceResolver -FeatureVerifier $FeatureVerifier
    $planItems = @()
    $index = 0
    foreach ($item in @($plan.Items)) {
        $index++
        $planItems += New-FreshWinTerminalItem -Key ([string]$index) -Label ("$($item.Action) $($item.PackageId)") -Badge ("[$($item.SafetyLevel)]") -Detail ([string]$item.Reason) -Value $item
    }
    $actionable = @($plan.Items | Where-Object Action -in @('INSTALL','UPDATE','REPAIR'))
    $reviewNotice = $null
    while ($true) {
        $commands = New-Object System.Collections.Generic.List[object]
        if ($actionable.Count -gt 0) {
            if ($DryRun) { $commands.Add((New-FreshWinTerminalCommand 'ENTER' (Get-FreshWinTerminalString 'terminal.plan.validateDryRun' 'Validate dry run'))) }
            else { $commands.Add((New-FreshWinTerminalCommand 'YES' (Get-FreshWinTerminalString 'terminal.plan.executeReviewed' 'Execute reviewed plan'))) }
        }
        $commands.Add((New-FreshWinTerminalCommand 'S' (Get-FreshWinTerminalString 'terminal.plan.save' 'Save plan')))
        $commands.Add((New-FreshWinTerminalCommand 'E' (Get-FreshWinTerminalString 'terminal.plan.edit' 'Edit selection')))
        $commands.Add((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'ui.actions.cancel' 'Cancel')))
        $reviewStatus = @(
            (Get-FreshWinTerminalString 'terminal.plan.actionable' 'Actionable items: {0}' @($actionable.Count)),
            (Get-FreshWinTerminalString 'terminal.plan.restartLikely' 'Restart likely: {0}' @($plan.RebootLikely))
        )
        if (-not [string]::IsNullOrWhiteSpace([string]$reviewNotice)) { $reviewStatus += [string]$reviewNotice }
        $prompt = if ($actionable.Count -eq 0) {
            Get-FreshWinTerminalString 'terminal.plan.reviewOnlyPrompt' 'Choose S to save, E to edit the selection, or 0 to cancel.'
        } elseif ($DryRun) {
            Get-FreshWinTerminalString 'terminal.plan.dryPrompt' 'Press Enter to validate, S to preview saving, E to edit, or 0 to cancel.'
        } else {
            Get-FreshWinTerminalString 'terminal.plan.executePrompt' 'Type YES exactly to execute, S to save, E to edit, or 0 to cancel.'
        }
        $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.plan.reviewBreadcrumb' 'Plan review')) -Title (Get-FreshWinTerminalString 'terminal.plan.title' 'Installation Plan') `
            -Description (Get-FreshWinTerminalString 'terminal.plan.description' 'This plan was built by the shared dependency-first planner. Blocked and manual items are not executed.') `
            -Items $planItems -Status $reviewStatus `
            -ContextHelp @((Get-FreshWinTerminalString 'terminal.plan.helpReview' 'Review every action and reason.'), (Get-FreshWinTerminalString 'terminal.plan.helpTrusted' 'FreshWin executes only typed arguments resolved from the trusted catalog.')) `
            -Commands $commands.ToArray() -Prompt $prompt
        [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)

        $confirmationValue = Read-FreshWinTerminalInput -Prompt 'confirm' -InputProvider $InputProvider
        if ($null -eq $confirmationValue) { return [pscustomobject]@{ Status='Cancelled'; Plan=$plan; Result=$null } }
        $confirmation = [string]$confirmationValue
        $reviewCommand = $confirmation.Trim().ToUpperInvariant()
        if ($reviewCommand -eq '0') { return [pscustomobject]@{ Status='Cancelled'; Plan=$plan; Result=$null } }
        if ($reviewCommand -eq 'E') { return [pscustomobject]@{ Status='EditRequested'; Plan=$plan; Result=$null } }
        if ($reviewCommand -eq 'S') {
            try {
                $candidatePath = [string](Read-FreshWinTerminalInput -Prompt (Get-FreshWinTerminalString 'terminal.plan.savePrompt' 'Enter a new absolute .json path for the plan.') -InputProvider $InputProvider)
                if ([string]::IsNullOrWhiteSpace($candidatePath)) { throw 'A plan output path is required.' }
                $savePath = Resolve-FreshWinCliNewOutputPath -Path $candidatePath.Trim() -AllowedExtensions @('.json')
                if ($DryRun) {
                    $reviewNotice = Get-FreshWinTerminalString 'terminal.plan.savePreview' 'Dry-run preview: the plan would be saved to {0}; no file was written.' @($savePath)
                } else {
                    $terminalContextIsAdmin = [bool](Get-FreshWinPropertyValue -InputObject $Session.System -Name 'Admin' -Default (Get-FreshWinPropertyValue -InputObject $Session.System -Name 'IsAdministrator' -Default $false))
                    if ($terminalContextIsAdmin) { throw 'Save plans from a non-elevated FreshWin session to avoid privileged writes to user-selected paths.' }
                    [void](Save-FreshWinInstallPlan -Plan $plan -Path $savePath)
                    $reviewNotice = Get-FreshWinTerminalString 'terminal.plan.saved' 'Plan saved to {0}.' @($savePath)
                }
            }
            catch { $reviewNotice = Get-FreshWinTerminalString 'terminal.plan.saveFailed' 'Plan was not saved: {0}' @((Protect-FreshWinSensitiveText $_.Exception.Message)) }
            continue
        }
        if ($actionable.Count -eq 0) {
            $reviewNotice = Get-FreshWinTerminalString 'terminal.plan.noActionable' 'There are no executable actions in this plan.'
            continue
        }
        if (($DryRun -and $reviewCommand.Length -eq 0) -or (-not $DryRun -and $confirmation -ceq 'YES')) { break }
        $reviewNotice = Get-FreshWinTerminalString 'terminal.plan.confirmationInvalid' 'Confirmation was not accepted; review the displayed commands.'
    }

    $terminalContextIsAdmin = [bool](Get-FreshWinPropertyValue -InputObject $Session.System -Name 'Admin' -Default (Get-FreshWinPropertyValue -InputObject $Session.System -Name 'IsAdministrator' -Default $false))
    $workflowInventoryProvider = {
        $snapshot = if ($null -ne $InventoryProvider) { & $InventoryProvider ([bool]$Session.IncludeUpdates) }
            else { Get-FreshWinSoftwareInventorySnapshot -Refresh -IncludeUpdates:$Session.IncludeUpdates }
        if ($null -eq $snapshot) { throw 'The software inventory refresh returned no snapshot.' }
        $Session.Inventory = $snapshot
        return $snapshot
    }
    $workflowSystemInfoProvider = {
        $snapshot = if ($null -ne $SystemInfoProvider) { & $SystemInfoProvider } else { Get-FreshWinSystemInfo }
        if ($null -eq $snapshot) { throw 'The system-information refresh returned no snapshot.' }
        $Session.System = $snapshot
        return $snapshot
    }
    $checkpointPath = if ($DryRun) { $null }
        elseif ($terminalContextIsAdmin) { Get-FreshWinProtectedCheckpointPath }
        else { Get-FreshWinDefaultCheckpointPath }
    $elevation = Get-FreshWinPlanElevationRequirement -Plan $plan
    $terminalProgress = New-Object System.Collections.Generic.List[object]
    $terminalProgressCallback = {
        param($progressEvent)
        $terminalProgress.Add($progressEvent)
        Write-FreshWinTerminalExecutionPage -Plan $plan -Progress $terminalProgress.ToArray() -OutputWriter $OutputWriter
    }
    Write-FreshWinTerminalExecutionPage -Plan $plan -Progress @() -OutputWriter $OutputWriter
    if ($elevation.Required -and -not [bool]$Session.System.Admin -and -not $DryRun) {
        if ([string]::IsNullOrWhiteSpace($EntryScriptPath)) { throw 'The entry script path is required for controlled elevation.' }
        $elevated = Invoke-FreshWinElevatedResume -Plan $plan -EntryScriptPath $EntryScriptPath -CheckpointPath $checkpointPath -Wait -Confirm:$false
        $elevatedStarted = [bool](Get-FreshWinPropertyValue -InputObject $elevated -Name 'Started' -Default $false)
        $elevatedExitCode = Get-FreshWinPropertyValue -InputObject $elevated -Name 'ProcessExitCode' -Default $null
        $childResult = Get-FreshWinPropertyValue -InputObject $elevated -Name 'ChildResult' -Default $null
        $childResultMatches = $null -ne $childResult -and [string](Get-FreshWinPropertyValue $childResult 'planId' '') -eq [string]$plan.Id
        $childStatus = [string](Get-FreshWinPropertyValue $childResult 'status' '')
        $elevatedSucceeded = $elevatedStarted -and $null -ne $elevatedExitCode -and [int]$elevatedExitCode -eq 0 -and
            $childResultMatches -and $childStatus -in @('Succeeded','RebootRequired')
        $protectedCheckpointPath = [string](Get-FreshWinPropertyValue -InputObject $elevated -Name 'ProtectedCheckpointPath' -Default '')
        $elevatedCheckpoint = $null
        if (-not [string]::IsNullOrWhiteSpace($protectedCheckpointPath)) {
            try { $elevatedCheckpoint = Get-FreshWinExecutionCheckpoint -Path $protectedCheckpointPath } catch { $elevatedCheckpoint = $null }
        }
        $checkpointMatches = $null -ne $elevatedCheckpoint -and [string]$elevatedCheckpoint.planId -eq [string]$plan.Id
        if ($checkpointMatches -and ([string]$elevatedCheckpoint.status -eq 'REBOOT_REQUIRED' -or
            (Test-FreshWinCheckpointRequiresReboot -Checkpoint $elevatedCheckpoint))) {
            $resumeRegistration = Show-FreshWinTerminalRebootBoundary -CheckpointPath $protectedCheckpointPath `
                -EntryScriptPath $EntryScriptPath -ExecutionStatus ([string]$elevatedCheckpoint.status) `
                -InputProvider $InputProvider -OutputWriter $OutputWriter
            return [pscustomobject]@{
                Status='REBOOT_REQUIRED'; ExecutionStatus=[string]$elevatedCheckpoint.status
                Plan=$plan; Result=$elevated; CheckpointPath=$protectedCheckpointPath
                ResumeRegistration=$resumeRegistration; ExecutionSucceeded=$elevatedSucceeded
            }
        }
        if (-not $elevatedSucceeded) {
            $childResultError = [string](Get-FreshWinPropertyValue $elevated 'ChildResultError' '')
            $fallbackReason = if ($childResultError) { "The protected child result could not be read: $childResultError" }
                elseif ($null -eq $childResult) { 'The elevated child exited before it could publish a protected execution result.' }
                else { 'The administrator-authorized execution helper did not complete successfully.' }
            $execution = New-FreshWinElevatedFailureExecutionResult -Plan $plan -ChildResult $childResult `
                -ChildExitCode $elevatedExitCode -Progress $terminalProgress.ToArray() -FallbackReason $fallbackReason
            $resultChoice = Show-FreshWinTerminalExecutionResult -ExecutionResult $execution -InputProvider $InputProvider -OutputWriter $OutputWriter
            if ($resultChoice.Action -eq 'Retry') {
                return Invoke-FreshWinTerminalPlanWorkflow -Session $Session -PackageIds $PackageIds -InputProvider $InputProvider `
                    -OutputWriter $OutputWriter -InventoryProvider $InventoryProvider -SystemInfoProvider $SystemInfoProvider `
                    -ProcessInvoker $ProcessInvoker -SourceResolver $SourceResolver -FeatureVerifier $FeatureVerifier `
                    -EntryScriptPath $EntryScriptPath -DryRun:$DryRun
            }
            return [pscustomobject]@{ Status='ElevationFailed'; Plan=$plan; Result=$elevated; Execution=$execution }
        }
        if ([string]::IsNullOrWhiteSpace($protectedCheckpointPath)) { throw 'The elevated helper did not report its protected checkpoint path.' }
        if (-not $checkpointMatches) { throw 'The elevated helper checkpoint is missing or does not match the reviewed plan.' }
        [void](& $workflowSystemInfoProvider)
        [void](& $workflowInventoryProvider)
        $plan = Restore-FreshWinPlanFromCheckpoint -Checkpoint $elevatedCheckpoint -Catalog $Session.Catalog -SystemInfo $Session.System -Inventory $Session.Inventory
        $execution = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $Session.Catalog -SystemInfo $Session.System -Inventory $Session.Inventory `
            -InventoryProvider $workflowInventoryProvider -SystemInfoProvider $workflowSystemInfoProvider -CheckpointPath $checkpointPath -ExecutionMode NonAdminOnly `
            -ProgressCallback $terminalProgressCallback -ProcessInvoker $ProcessInvoker -SourceResolver $SourceResolver -FeatureVerifier $FeatureVerifier
    }
    else {
        $execution = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $Session.Catalog -SystemInfo $Session.System -Inventory $Session.Inventory `
            -InventoryProvider $workflowInventoryProvider -SystemInfoProvider $workflowSystemInfoProvider -CheckpointPath $checkpointPath `
            -ProgressCallback $terminalProgressCallback -ProcessInvoker $ProcessInvoker -SourceResolver $SourceResolver -FeatureVerifier $FeatureVerifier
    }
    $resultChoice = Show-FreshWinTerminalExecutionResult -ExecutionResult $execution -InputProvider $InputProvider -OutputWriter $OutputWriter
    if ($resultChoice.Action -eq 'Retry') {
        return Invoke-FreshWinTerminalPlanWorkflow -Session $Session -PackageIds $PackageIds -InputProvider $InputProvider `
            -OutputWriter $OutputWriter -InventoryProvider $InventoryProvider -SystemInfoProvider $SystemInfoProvider `
            -ProcessInvoker $ProcessInvoker -SourceResolver $SourceResolver -FeatureVerifier $FeatureVerifier `
            -EntryScriptPath $EntryScriptPath -DryRun:$DryRun
    }
    if (Test-FreshWinUiExecutionRequiresReboot -ExecutionResult $execution) {
        $resumeRegistration = Show-FreshWinTerminalExecutionRebootBoundary -ExecutionResult $execution `
            -CheckpointPath $checkpointPath -EntryScriptPath $EntryScriptPath -InputProvider $InputProvider -OutputWriter $OutputWriter
        return [pscustomobject]@{ Status='REBOOT_REQUIRED'; ExecutionStatus=$execution.Status; Plan=$plan; Result=$execution; CheckpointPath=$checkpointPath; ResumeRegistration=$resumeRegistration }
    }
    return [pscustomobject]@{ Status=$execution.Status; Plan=$plan; Result=$execution }
}

function Show-FreshWinTerminalPackageCenter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][string]$Center,
        [scriptblock]$InputProvider,
        [scriptblock]$OutputWriter,
        [scriptblock]$InventoryProvider,
        [string]$EntryScriptPath,
        [switch]$DryRun
    )
    $definition = Get-FreshWinTerminalCenterDefinition $Center
    $filter = if ($Center -eq 'updates') { 'UPDATES' } else { 'ALL' }
    $searchTerm = $null
    $notice = $null
    if ($Center -eq 'updates') {
        try { [void](Set-FreshWinTerminalInventoryPolicy -Session $Session -IncludeUpdates $true -InventoryProvider $InventoryProvider) }
        catch { $notice = Protect-FreshWinSensitiveText $_.Exception.Message }
    }
    while ($true) {
        $updateState = Get-FreshWinInventoryUpdateQueryState -Inventory $Session.Inventory
        $unknownUpdateView = $filter -eq 'UPDATES' -and -not [bool]$updateState.Known
        $rows = @()
        if (-not $unknownUpdateView) { $rows = @(Get-FreshWinTerminalPackageRows -Session $Session -Center $Center -Filter $filter -SearchTerm $searchTerm) }
        $status = @((Get-FreshWinTerminalString 'terminal.packageCenter.view' 'View: {0}' @($filter)))
        if ($unknownUpdateView) {
            $status += Get-FreshWinTerminalString 'terminal.packageCenter.updateStateUnknown' 'Community WinGet update state is unknown because that update inventory scan did not complete.'
            foreach ($updateError in @($updateState.Errors)) {
                $status += Get-FreshWinTerminalString 'terminal.packageCenter.updateProviderError' 'Update provider error: {0}' @($updateError)
            }
        }
        else { $status += Get-FreshWinTerminalString 'terminal.packageCenter.shown' 'Packages shown: {0}' @($rows.Count) }
        if ($Center -eq 'security') {
            try {
                $security = Get-FreshWinSecurityStatus
                $status += @(
                    (Get-FreshWinTerminalString 'terminal.packageCenter.protectionHealth' 'Protection health: {0}' @([string](Get-FreshWinPropertyValue $security 'OverallHealth' 'Review'))),
                    (Get-FreshWinTerminalString 'terminal.packageCenter.defenderFirewall' 'Microsoft Defender: {0} | Windows Firewall: {1}' @([string](Get-FreshWinPropertyValue $security 'DefenderHealth' 'Review'), [string](Get-FreshWinPropertyValue $security 'FirewallHealth' 'Review'))),
                    (Get-FreshWinTerminalString 'terminal.packageCenter.observedProtection' 'Observed antivirus products: {0} | firewall profiles: {1}' @(@((Get-FreshWinPropertyValue $security 'AntivirusProducts' @())).Count, @((Get-FreshWinPropertyValue $security 'FirewallProfiles' @())).Count))
                )
                foreach ($securityError in @((Get-FreshWinPropertyValue $security 'Errors' @()))) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$securityError)) { $status += Get-FreshWinTerminalString 'terminal.packageCenter.securityObservation' 'Security observation: {0}' @($securityError) }
                }
            }
            catch { $status += Get-FreshWinTerminalString 'terminal.packageCenter.securityUnknown' 'Security status is unknown: {0}' @((Protect-FreshWinSensitiveText $_.Exception.Message)) }
        }
        if ($notice) { $status += $notice }
        $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'),$definition.Title) -Title $definition.Title -Description $definition.Description `
            -Items $rows -Status $status `
            -ContextHelp @((Get-FreshWinTerminalString 'terminal.packageCenter.helpSelection' 'Select one or more numbers: 1,2,3,8 or mixed ranges such as 1,3-5,8.'), (Get-FreshWinTerminalString 'terminal.packageCenter.helpFilters' 'M shows missing/repair items; U updates; A all; R recommended; /text searches this center.')) `
            -Commands @((New-FreshWinTerminalCommand 'M' (Get-FreshWinTerminalString 'terminal.packageCenter.missing' 'Missing')), (New-FreshWinTerminalCommand 'U' (Get-FreshWinTerminalString 'terminal.packageCenter.updates' 'Updates')), (New-FreshWinTerminalCommand 'A' (Get-FreshWinTerminalString 'terminal.packageCenter.all' 'All')), (New-FreshWinTerminalCommand 'R' (Get-FreshWinTerminalString 'terminal.packageCenter.recommended' 'Recommended')), (New-FreshWinTerminalCommand '/text' (Get-FreshWinTerminalString 'ui.actions.search' 'Search')), (New-FreshWinTerminalCommand '?' (Get-FreshWinTerminalString 'terminal.common.help' 'Help')), (New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'ui.actions.back' 'Back'))) `
            -Prompt (Get-FreshWinTerminalString 'terminal.packageCenter.prompt' 'Select packages or enter a contextual command.')
        [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
        $raw = Read-FreshWinTerminalInput -Prompt 'select' -InputProvider $InputProvider
        if ($null -eq $raw) { return }
        $selection = ConvertFrom-FreshWinSelection -InputText ([string]$raw) -AvailableIds @($rows | ForEach-Object { [int]$_.Key }) `
            -AllowedCommands @('SELECT','MISSING','UPDATES','ALL','RECOMMENDED','SEARCH','HELP','BACK')
        if (-not $selection.Valid) { $notice = $selection.ErrorMessage; continue }
        $notice = $null
        switch ($selection.Command) {
            'BACK' { return }
            'HELP' { $notice = Get-FreshWinTerminalString 'terminal.packageCenter.planHelp' 'Selections are planned first. Type YES only after reviewing the generated actions.' }
            'MISSING' { $filter = 'MISSING'; $searchTerm = $null }
            'UPDATES' {
                $filter = 'UPDATES'
                $searchTerm = $null
                [void](Set-FreshWinTerminalInventoryPolicy -Session $Session -IncludeUpdates $true -InventoryProvider $InventoryProvider)
            }
            'ALL' { $filter = 'ALL'; $searchTerm = $null }
            'RECOMMENDED' { $filter = 'RECOMMENDED'; $searchTerm = $null }
            'SEARCH' { $filter = 'SEARCH'; $searchTerm = $selection.SearchTerm }
            'SELECT' {
                $packageIds = @($selection.Values | ForEach-Object { [string]$rows[$_ - 1].Value.Package.id })
                try {
                    [void](Invoke-FreshWinTerminalPlanWorkflow -Session $Session -PackageIds $packageIds -InputProvider $InputProvider -OutputWriter $OutputWriter -InventoryProvider $InventoryProvider -EntryScriptPath $EntryScriptPath -DryRun:$DryRun)
                }
                catch { $notice = Protect-FreshWinSensitiveText $_.Exception.Message }
            }
        }
    }
}

function Show-FreshWinTerminalQuickSetup {
    [CmdletBinding()]
    param([object]$Session, [scriptblock]$InputProvider, [scriptblock]$OutputWriter, [scriptblock]$InventoryProvider, [string]$EntryScriptPath, [switch]$DryRun)
    $preferred = @('essential','work','gaming','developer','full-recommended')
    $profiles = @($preferred | ForEach-Object { Get-FreshWinProfile -Profiles $Session.Profiles -Id $_ } | Where-Object { $null -ne $_ })
    $notice = $null
    while ($true) {
        $items = @(); $index = 0
        foreach ($profile in $profiles) {
            $index++
            $profileName = Get-FreshWinString -Key ([string]$profile.nameKey) -Default ([string]$profile.name)
            $description = Get-FreshWinString -Key ([string]$profile.descriptionKey) -Default ([string]$profile.notes)
            $items += New-FreshWinTerminalItem -Key ([string]$index) -Label $profileName -Badge '[SET]' -Detail (Get-FreshWinTerminalString 'terminal.quick.profileDetail' '{0} packages | {1}' @(@($profile.NormalizedPackageIds).Count, $description)) -Value $profile
        }
        try { $windowsUpdate = Get-FreshWinWindowsUpdateState -IncludeDetails } catch { $windowsUpdate = [pscustomobject]@{ Status='Unknown'; PendingCount=$null; RestartPending=$null } }
        try { $driverSummary = Get-FreshWinDriverSummary } catch { $driverSummary = [pscustomobject]@{ Status='Unknown'; Required=$null; Recommended=$null } }
        $runtimeMissing = 0; $runtimeUnknown = 0
        foreach ($runtimePackage in @(Get-FreshWinTerminalCenterPackages -Catalog $Session.Catalog -Center windows-runtimes)) {
            $runtimeDetection = Get-FreshWinPackageDetection -Package $runtimePackage -Inventory $Session.Inventory
            if ($runtimeDetection.State -in @('NotInstalled','Broken')) { $runtimeMissing++ }
            elseif ($runtimeDetection.State -eq 'Unknown') { $runtimeUnknown++ }
        }
        $status = @(
            (Get-FreshWinTerminalString 'terminal.quick.statusPlanner' 'Profiles are expanded by the recommendation engine and then sent to the shared planner.'),
            (Get-FreshWinTerminalString 'terminal.quick.statusUpdate' 'Windows Update: {0} | pending: {1} | restart: {2}' @($windowsUpdate.Status, $windowsUpdate.PendingCount, $windowsUpdate.RestartPending)),
            (Get-FreshWinTerminalString 'terminal.quick.statusDrivers' 'Driver attention: required {0} | review {1}' @($driverSummary.Required, $driverSummary.Recommended)),
            (Get-FreshWinTerminalString 'terminal.quick.statusRuntimes' 'Windows features and essential runtimes: {0} missing/repair | {1} unknown' @($runtimeMissing, $runtimeUnknown))
        )
        if ($notice) { $status += $notice }
        $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.home.entries.quick.label' 'Quick Setup')) -Title (Get-FreshWinTerminalString 'terminal.home.entries.quick.label' 'Quick Setup') `
            -Description (Get-FreshWinTerminalString 'terminal.quick.description' 'Choose one or more curated setup profiles. Existing, incompatible, manual, and unknown items remain visible in the plan.') `
            -Items $items -Status $status -ContextHelp @((Get-FreshWinTerminalString 'terminal.quick.helpSelection' 'Mixed selections and ranges are supported.'), (Get-FreshWinTerminalString 'terminal.quick.helpReview' 'Quick Setup never bypasses plan review or confirmation.'), (Get-FreshWinTerminalString 'terminal.quick.helpSystem' 'Windows Update, driver, and unsupported system actions remain review/manual; no separate updater is invented here.')) `
            -Commands @((New-FreshWinTerminalCommand '1-5' (Get-FreshWinTerminalString 'terminal.quick.selectProfiles' 'Select profiles')), (New-FreshWinTerminalCommand '?' (Get-FreshWinTerminalString 'terminal.common.help' 'Help')), (New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'ui.actions.back' 'Back'))) -Prompt (Get-FreshWinTerminalString 'terminal.quick.prompt' 'Select setup profiles.')
        [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
        $raw = Read-FreshWinTerminalInput -Prompt 'profile' -InputProvider $InputProvider
        if ($null -eq $raw) { return }
        $selection = ConvertFrom-FreshWinSelection -InputText ([string]$raw) -AvailableIds @(1..$profiles.Count) -CommandMap @{'?'='HELP';'0'='BACK'} -AllowedCommands @('SELECT','HELP','BACK')
        if (-not $selection.Valid) { $notice = $selection.ErrorMessage; continue }
        if ($selection.Command -eq 'BACK') { return }
        if ($selection.Command -eq 'HELP') { $notice = Get-FreshWinTerminalString 'terminal.quick.plannerHelp' 'The shared planner expands dependencies and reports conflicts before execution.'; continue }
        $packageIds = New-Object System.Collections.Generic.List[string]
        foreach ($selectedIndex in $selection.Values) {
            $profile = $profiles[$selectedIndex - 1]
            $recommendations = @(Get-FreshWinRecommendations -Catalog $Session.Catalog -SystemInfo $Session.System -Inventory $Session.Inventory -ProfileId ([string]$profile.id) -Profiles $Session.Profiles)
            foreach ($recommendation in $recommendations) {
                if (-not $packageIds.Contains([string]$recommendation.PackageId)) { $packageIds.Add([string]$recommendation.PackageId) }
            }
        }
        if ($packageIds.Count -eq 0) { $notice = Get-FreshWinTerminalString 'terminal.quick.empty' 'The selected profiles contain no catalog packages.'; continue }
        try { [void](Invoke-FreshWinTerminalPlanWorkflow -Session $Session -PackageIds $packageIds.ToArray() -InputProvider $InputProvider -OutputWriter $OutputWriter -InventoryProvider $InventoryProvider -EntryScriptPath $EntryScriptPath -DryRun:$DryRun) }
        catch { $notice = Protect-FreshWinSensitiveText $_.Exception.Message }
    }
}

function Show-FreshWinTerminalNetworkRescuePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Plan,
        [scriptblock]$InputProvider,
        [scriptblock]$OutputWriter,
        [AllowNull()][scriptblock]$StateProvider,
        [AllowNull()][scriptblock]$PlanProvider,
        [AllowNull()][scriptblock]$OfflineDiagnosticsProvider,
        [AllowNull()][scriptblock]$RetryProvider
    )
    $currentState = $State
    $currentPlan = $Plan
    $currentFolder = $null
    $notice = $null
    $offline = if ($null -ne $OfflineDiagnosticsProvider) { & $OfflineDiagnosticsProvider }
        else { Invoke-FreshWinCliOptionalOperation -Component OfflineNetworkDiagnostics -CommandNames @('Get-FreshWinOfflineNetworkDiagnostics') }

    while ($true) {
        $items = @($currentPlan.Items | ForEach-Object {
            New-FreshWinTerminalItem -Key ([string]$_.Order) -Label ([string]$_.Action) -Badge ("[$($_.Risk)]") -Detail ([string]$_.Description) -Value $_
        })
        $status = @(
            (Get-FreshWinTerminalString 'terminal.network.state' 'Rescue state: {0} | plan: {1}' @([string](Get-FreshWinPropertyValue $currentState 'RescueState' 'Unknown'), [string](Get-FreshWinPropertyValue $currentPlan 'Status' 'Unknown'))),
            (Get-FreshWinTerminalString 'terminal.network.counts' 'Adapters: {0} | problem devices: {1} | local matches: {2}' @(@((Get-FreshWinPropertyValue $currentState 'Adapters' @())).Count, @((Get-FreshWinPropertyValue $currentState 'ProblemDevices' @())).Count, @((Get-FreshWinPropertyValue $currentState 'LocalDrivers' @())).Count)),
            (Get-FreshWinTerminalString 'terminal.network.offlineStatus' 'Offline diagnostics: {0}' @([string](Get-FreshWinPropertyValue $offline 'Status' 'Unknown')))
        )
        if (-not [string]::IsNullOrWhiteSpace([string]$currentFolder)) {
            $status += Get-FreshWinTerminalString 'terminal.network.localFolder' 'Local/USB driver folder: {0}' @($currentFolder)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$notice)) { $status += $notice }
        $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.home.entries.drivers.label' 'Drivers & Hardware'), (Get-FreshWinTerminalString 'terminal.network.title' 'Network Rescue')) -Title (Get-FreshWinTerminalString 'terminal.network.planTitle' 'Network Rescue Plan') `
            -Description (Get-FreshWinTerminalString 'terminal.network.description' 'This plan is read-only guidance. It does not download a driver, install an INF, change an adapter, or claim connectivity.') `
            -Items $items -Status $status -ContextHelp @(
                (Get-FreshWinTerminalString 'terminal.network.helpInf' 'Local INF matches remain review-only until identity and signature are independently validated.'),
                (Get-FreshWinTerminalString 'terminal.network.helpOfficial' 'Acquire missing drivers only from the PC/OEM or adapter manufacturer.'),
                (Get-FreshWinTerminalString 'terminal.network.helpFolder' 'F scans a bounded absolute local folder, including a directly attached USB drive; network shares and reparse points are refused.'),
                (Get-FreshWinTerminalString 'terminal.network.helpRetry' 'R runs at most three read-only connectivity probes and never changes an adapter.')) `
            -Commands @(
                (New-FreshWinTerminalCommand 'F' (Get-FreshWinTerminalString 'terminal.network.scanFolder' 'Scan local/USB driver folder')),
                (New-FreshWinTerminalCommand 'R' (Get-FreshWinTerminalString 'terminal.network.retry' 'Retry read-only network probe')),
                (New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.return' 'Return'))) `
            -Prompt (Get-FreshWinTerminalString 'terminal.network.prompt' 'Enter F, R, or 0.')
        [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
        $raw = Read-FreshWinTerminalInput -Prompt 'network-rescue' -InputProvider $InputProvider
        if ($null -eq $raw) { return }
        $selection = ConvertFrom-FreshWinSelection -InputText ([string]$raw) -CommandMap @{'F'='FOLDER';'R'='RETRY';'0'='BACK'} -AllowedCommands @('FOLDER','RETRY','BACK')
        if (-not $selection.Valid) { $notice = $selection.ErrorMessage; continue }
        if ($selection.Command -eq 'BACK') { return }

        if ($selection.Command -eq 'FOLDER') {
            $requestedFolder = Read-FreshWinTerminalInput -Prompt (Get-FreshWinTerminalString 'terminal.network.folderPrompt' 'Absolute local/USB driver folder') -InputProvider $InputProvider
            try {
                $currentFolder = Resolve-FreshWinCliNetworkDriverFolder -Path ([string]$requestedFolder)
                if ([string]::IsNullOrWhiteSpace([string]$currentFolder)) { throw (Get-FreshWinTerminalString 'terminal.network.folderRequired' 'A local driver folder is required.') }
            }
            catch { $notice = Protect-FreshWinSensitiveText $_.Exception.Message; continue }
        }

        $bundleParameters = @{ LocalDriverFolder=$currentFolder; Retry=($selection.Command -eq 'RETRY') }
        if ($null -ne $StateProvider) { $bundleParameters.StateProvider = $StateProvider }
        if ($null -ne $PlanProvider) { $bundleParameters.PlanProvider = $PlanProvider }
        if ($null -ne $OfflineDiagnosticsProvider) { $bundleParameters.OfflineDiagnosticsProvider = $OfflineDiagnosticsProvider }
        if ($null -ne $RetryProvider) { $bundleParameters.RetryProvider = $RetryProvider }
        try {
            $bundle = Get-FreshWinCliNetworkRescueData @bundleParameters
            $nextState = Get-FreshWinPropertyValue $bundle 'State' $bundle
            $nextStatus = [string](Get-FreshWinPropertyValue $nextState 'Status' '')
            if ($nextStatus -in @('Unavailable','Unsupported','Error')) {
                $notice = [string](Get-FreshWinPropertyValue $nextState 'Reason' $nextStatus)
                continue
            }
            $currentState = $nextState
            $currentPlan = Get-FreshWinPropertyValue $bundle 'Plan' $currentPlan
            $offline = Get-FreshWinPropertyValue $bundle 'OfflineDiagnostics' $offline
            if ($selection.Command -eq 'RETRY') {
                $retryResult = Get-FreshWinPropertyValue $bundle 'Retry' $null
                $notice = Get-FreshWinTerminalString 'terminal.network.retryComplete' 'Retry status: {0} | probes: {1}' @([string](Get-FreshWinPropertyValue $retryResult 'Status' 'Unknown'), @((Get-FreshWinPropertyValue $retryResult 'Attempts' @())).Count)
            }
            else {
                $notice = Get-FreshWinTerminalString 'terminal.network.scanComplete' 'Local folder scan complete; review-only INF matches: {0}.' @(@((Get-FreshWinPropertyValue $currentState 'LocalDrivers' @())).Count)
            }
        }
        catch { $notice = Protect-FreshWinSensitiveText $_.Exception.Message }
    }
}

function Show-FreshWinTerminalDduPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Hardware,
        [scriptblock]$InputProvider,
        [scriptblock]$OutputWriter
    )
    $parameters = @{ GPUs=@($Hardware.GPUs); Manufacturer=[string]$Hardware.Manufacturer; Model=[string]$Hardware.Model }
    $plan = Invoke-FreshWinCliOptionalOperation -Component DduRecoveryPlan -CommandNames @('New-FreshWinDduRecoveryPlan') -Parameters $parameters
    $gpuItems = @(); $index = 0
    foreach ($gpu in @((Get-FreshWinPropertyValue $plan 'DetectedGPUs' @()))) {
        $index++
        $gpuItems += New-FreshWinTerminalItem -Key ("GPU$index") -Label ([string]$gpu.Name) -Badge '[GPU]' -Detail (Get-FreshWinTerminalString 'terminal.ddu.gpuDetail' '{0} | driver {1} | {2}' @($gpu.Vendor, $gpu.DriverVersion, $gpu.Status)) -Value $gpu
    }
    $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.home.entries.drivers.label' 'Drivers & Hardware'), 'DDU') -Title (Get-FreshWinTerminalString 'terminal.ddu.title' 'ADVANCED: DDU Recovery Plan') `
        -Description (Get-FreshWinTerminalString 'terminal.ddu.description' 'DDU is an external advanced repair workflow, not a routine update. FreshWin never downloads, stores, or executes a cleanup binary or arguments.') `
        -Items $gpuItems -Status @((Get-FreshWinTerminalString 'terminal.ddu.state' 'State: {0}' @([string](Get-FreshWinPropertyValue $plan 'State' 'Unknown'))), [string](Get-FreshWinPropertyValue $plan 'Warning' (Get-FreshWinTerminalString 'terminal.ddu.defaultWarning' 'Advanced risk acknowledgement is required.'))) `
        -ContextHelp @((Get-FreshWinTerminalString 'terminal.ddu.helpPrepare' 'Prepare a verified official replacement driver and an external safety checkpoint before manual cleanup.'), (Get-FreshWinTerminalString 'terminal.ddu.helpAcknowledge' 'Acknowledgement advances only the in-memory plan state; it does not run DDU.')) `
        -Commands @((New-FreshWinTerminalCommand 'ACKNOWLEDGE' (Get-FreshWinTerminalString 'terminal.ddu.acknowledge' 'Acknowledge advanced risk for plan only')), (New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'ui.actions.cancel' 'Cancel'))) -Prompt (Get-FreshWinTerminalString 'terminal.ddu.prompt' 'Type ACKNOWLEDGE exactly to advance the plan, or 0.')
    [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
    $confirmation = Read-FreshWinTerminalInput -Prompt 'ddu-risk' -InputProvider $InputProvider
    if ($confirmation -cne 'ACKNOWLEDGE') { return }

    $parameters['AcknowledgeAdvancedRisk'] = $true
    $advancedPlan = Invoke-FreshWinCliOptionalOperation -Component DduRecoveryPlan -CommandNames @('New-FreshWinDduRecoveryPlan') -Parameters $parameters
    $resultPage = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.home.entries.drivers.label' 'Drivers & Hardware'), 'DDU', (Get-FreshWinTerminalString 'terminal.ddu.planBreadcrumb' 'Plan')) -Title (Get-FreshWinTerminalString 'terminal.ddu.acknowledgedTitle' 'DDU Plan Acknowledged') `
        -Description (Get-FreshWinTerminalString 'terminal.ddu.acknowledgedDescription' 'The guarded recovery state machine is ready for replacement-driver preparation. Cleanup remains completely manual and outside FreshWin.') `
        -Status @(
            (Get-FreshWinTerminalString 'terminal.ddu.state' 'State: {0}' @([string](Get-FreshWinPropertyValue $advancedPlan 'State' 'Unknown'))),
            (Get-FreshWinTerminalString 'terminal.ddu.automatic' 'Automatic cleanup: {0} | automatic download: {1} | automatic execution: {2}' @([bool](Get-FreshWinPropertyValue $advancedPlan 'AutomaticCleanup' $false), [bool](Get-FreshWinPropertyValue $advancedPlan 'AutomaticDownload' $false), [bool](Get-FreshWinPropertyValue $advancedPlan 'AutomaticExecution' $false)))
        ) -ContextHelp @(
            (Get-FreshWinTerminalString 'terminal.ddu.helpApi' 'Use the exported operation API only to record explicit manual evidence and validated state transitions.'),
            (Get-FreshWinTerminalString 'terminal.ddu.helpCheckpoint' 'The ddu-plan CLI --output option stores only a validated non-executing plan checkpoint; it never registers startup execution or reboots Windows.')) `
        -Commands @((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.return' 'Return'))) -Prompt (Get-FreshWinTerminalString 'terminal.common.enterZeroReturn' 'Enter 0 to return.')
    [void](Write-FreshWinTerminalPage -Page $resultPage -OutputWriter $OutputWriter)
    [void](Read-FreshWinTerminalInput -Prompt 'ddu-return' -InputProvider $InputProvider)
}

function Show-FreshWinTerminalDriversHardware {
    [CmdletBinding()]
    param([scriptblock]$InputProvider, [scriptblock]$OutputWriter)
    $notice = $null
    while ($true) {
        $hardware = Get-FreshWinHardwareInfo
        $drivers = @(Get-FreshWinDriverInventory)
        $summary = Get-FreshWinDriverSummary -Drivers $drivers
        try { $gpuRecommendations = @(Get-FreshWinGpuDriverRecommendation -GPUs @($hardware.GPUs) -Manufacturer ([string]$hardware.Manufacturer) -Model ([string]$hardware.Model) -DriverInventory $drivers) }
        catch { $gpuRecommendations = @() }
        $networkState = Invoke-FreshWinCliOptionalOperation -Component NetworkRescueState -CommandNames @('Get-FreshWinNetworkRescueState')
        $networkPlan = Invoke-FreshWinCliOptionalOperation -Component NetworkRescuePlan -CommandNames @('New-FreshWinNetworkRescuePlan') -Parameters @{ State=$networkState }

        $items = @(); $index = 0
        foreach ($recommendation in $gpuRecommendations) {
            $index++
            $officialUri = if (-not [string]::IsNullOrWhiteSpace([string]$recommendation.OemSupport.OfficialSupportUri) -and $recommendation.Priority -eq 'Required') { [string]$recommendation.OemSupport.OfficialSupportUri } else { [string]$recommendation.OfficialVendorUri }
            $items += New-FreshWinTerminalItem -Key ("GPU$index") -Label ([string]$recommendation.GPU) -Badge ("[$($recommendation.Priority)]") -Detail (Get-FreshWinTerminalString 'terminal.drivers.officialSource' '{0} Official manual source: {1}' @($recommendation.Reason, $officialUri)) -Value $recommendation
        }
        foreach ($driver in @($drivers | Where-Object Health -ne 'Healthy')) {
            $index++
            $items += New-FreshWinTerminalItem -Key ("DRV$index") -Label ([string]$driver.Name) -Badge ([string]$driver.Badge) -Detail ("$($driver.Category) | $($driver.Health) | $($driver.Reason)") -Value $driver
        }
        $status = @(
            (Get-FreshWinTerminalString 'terminal.drivers.hardware' 'Hardware: {0} {1}' @($hardware.Manufacturer, $hardware.Model)),
            (Get-FreshWinTerminalString 'terminal.drivers.memoryGpu' 'Memory: {0} GB | GPUs: {1}' @($hardware.MemoryGB, @($hardware.GPUs).Count)),
            (Get-FreshWinTerminalString 'terminal.drivers.scan' 'Driver scan: {0} | required: {1} | review: {2}' @($summary.Status, $summary.Required, $summary.Recommended)),
            (Get-FreshWinTerminalString 'terminal.drivers.network' 'Network rescue: {0} | plan: {1}' @([string](Get-FreshWinPropertyValue $networkState 'RescueState' (Get-FreshWinPropertyValue $networkState 'Status' 'Unknown')), [string](Get-FreshWinPropertyValue $networkPlan 'Status' 'Unknown')))
        )
        if ($notice) { $status += $notice }
        $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.home.entries.drivers.label' 'Drivers & Hardware')) -Title (Get-FreshWinTerminalString 'terminal.home.entries.drivers.label' 'Drivers & Hardware') `
            -Description (Get-FreshWinTerminalString 'terminal.drivers.description' 'Device health is query-only. GPU recommendations point only to official OEM or GPU-vendor workflows; FreshWin does not silently replace drivers.') `
            -Items $items -Status $status -ContextHelp @((Get-FreshWinTerminalString 'terminal.drivers.helpNetwork' 'N opens the non-executing network rescue plan.'), (Get-FreshWinTerminalString 'terminal.drivers.helpDdu' 'D opens an explicit ADVANCED DDU plan-only workflow.'), (Get-FreshWinTerminalString 'terminal.drivers.helpRefresh' 'R repeats read-only hardware, driver, and network observations.')) `
            -Commands @((New-FreshWinTerminalCommand 'N' (Get-FreshWinTerminalString 'terminal.drivers.networkPlan' 'Network rescue plan')), (New-FreshWinTerminalCommand 'D' (Get-FreshWinTerminalString 'terminal.drivers.dduPlan' 'ADVANCED DDU plan only')), (New-FreshWinTerminalCommand 'R' (Get-FreshWinTerminalString 'terminal.common.refresh' 'Refresh')), (New-FreshWinTerminalCommand '?' (Get-FreshWinTerminalString 'terminal.common.help' 'Help')), (New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'ui.actions.back' 'Back'))) -Prompt (Get-FreshWinTerminalString 'terminal.common.contextPrompt' 'Enter a contextual command.')
        [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
        $raw = Read-FreshWinTerminalInput -Prompt 'drivers' -InputProvider $InputProvider
        if ($null -eq $raw) { return }
        $selection = ConvertFrom-FreshWinSelection -InputText ([string]$raw) -CommandMap @{'N'='NETWORK';'D'='DDU';'R'='REFRESH';'?'='HELP';'0'='BACK'} -AllowedCommands @('NETWORK','DDU','REFRESH','HELP','BACK')
        if (-not $selection.Valid) { $notice = $selection.ErrorMessage; continue }
        switch ($selection.Command) {
            'BACK' { return }
            'HELP' { $notice = Get-FreshWinTerminalString 'terminal.drivers.helpManual' 'Driver replacement remains manual unless a trusted catalog package can be independently detected and verified.' }
            'NETWORK' { Show-FreshWinTerminalNetworkRescuePlan -State $networkState -Plan $networkPlan -InputProvider $InputProvider -OutputWriter $OutputWriter }
            'DDU' { Show-FreshWinTerminalDduPlan -Hardware $hardware -InputProvider $InputProvider -OutputWriter $OutputWriter }
            default { $notice = Get-FreshWinTerminalString 'terminal.drivers.refreshed' 'Hardware, drivers, GPU guidance, and network rescue state refreshed.' }
        }
    }
}

function Show-FreshWinTerminalDiagnostics {
    [CmdletBinding()]
    param([object]$Session, [scriptblock]$InputProvider, [scriptblock]$OutputWriter, [switch]$DryRun)
    $notice = $null
    while ($true) {
        try {
            $diagnostics = Get-FreshWinDiagnostics
            $health = Get-FreshWinHealthSummary -Diagnostics $diagnostics
            $items = @(); $index = 0
            foreach ($component in @($health.Components)) {
                $index++
                $items += New-FreshWinTerminalItem -Key ([string]$index) -Label ([string]$component.Component) -Badge ("[$($component.Health)]") -Detail ([string]$component.Reason) -Value $component
            }
            $status = @(
                (Get-FreshWinTerminalString 'terminal.diagnostics.health' 'Overall health: {0} | attention: {1} | review: {2} | unsupported: {3}' @($health.OverallHealth, $health.AttentionCount, $health.ReviewCount, $health.UnsupportedCount)),
                (Get-FreshWinTerminalString 'terminal.diagnostics.collection' 'Collection status: {0} | live Windows evidence: {1}' @($diagnostics.Status, $diagnostics.IsLive)),
                (Get-FreshWinTerminalString 'terminal.diagnostics.readOnly' 'All diagnostics on this page are read-only. Unknown is not converted to pass or failure.')
            )
            foreach ($diagnosticError in @($diagnostics.Errors)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$diagnosticError)) { $status += Get-FreshWinTerminalString 'terminal.diagnostics.collectionError' 'Collection error: {0}' @($diagnosticError) }
            }
        }
        catch {
            $diagnostics = $null
            $health = $null
            $items = @()
            $status = @(
                (Get-FreshWinTerminalString 'terminal.diagnostics.failed' 'Diagnostics collection failed: {0}' @((Protect-FreshWinSensitiveText $_.Exception.Message))),
                (Get-FreshWinTerminalString 'terminal.diagnostics.noConclusion' 'No health conclusion was inferred from the failure.')
            )
        }
        if ($notice) { $status += $notice }
        $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.home.entries.diagnostics.label' 'Diagnostics & Repair')) -Title (Get-FreshWinTerminalString 'terminal.home.entries.diagnostics.label' 'Diagnostics & Repair') `
            -Description (Get-FreshWinTerminalString 'terminal.diagnostics.description' 'Review the composed system, hardware, network, security, driver, update, activation, and readiness observations.') `
            -Items $items -Status $status -ContextHelp @((Get-FreshWinTerminalString 'terminal.diagnostics.helpRefresh' 'R refreshes independent observations.'), (Get-FreshWinTerminalString 'terminal.diagnostics.helpExport' 'E creates a new privacy-redacted diagnostics bundle after confirmation.'), (Get-FreshWinTerminalString 'terminal.diagnostics.helpRepair' 'Use package centers to plan repairs for catalog packages reported as broken.')) `
            -Commands @((New-FreshWinTerminalCommand 'R' (Get-FreshWinTerminalString 'terminal.common.refresh' 'Refresh')), (New-FreshWinTerminalCommand 'E' (Get-FreshWinTerminalString 'terminal.diagnostics.export' 'Export redacted bundle')), (New-FreshWinTerminalCommand '?' (Get-FreshWinTerminalString 'terminal.common.help' 'Help')), (New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'ui.actions.back' 'Back'))) -Prompt (Get-FreshWinTerminalString 'terminal.common.contextPrompt' 'Enter a contextual command.')
        [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
        $raw = Read-FreshWinTerminalInput -Prompt 'diagnostics' -InputProvider $InputProvider
        if ($null -eq $raw) { return }
        $selection = ConvertFrom-FreshWinSelection -InputText ([string]$raw) -CommandMap @{'R'='REFRESH';'E'='EXPORT';'?'='HELP';'0'='BACK'} -AllowedCommands @('REFRESH','EXPORT','HELP','BACK')
        if (-not $selection.Valid) { $notice = $selection.ErrorMessage; continue }
        if ($selection.Command -eq 'BACK') { return }
        if ($selection.Command -eq 'HELP') { $notice = Get-FreshWinTerminalString 'terminal.diagnostics.safetyHelp' 'FreshWin never bypasses activation, Secure Boot, TPM, Windows eligibility, or security controls.' }
        elseif ($selection.Command -eq 'EXPORT') {
            if ($null -eq $diagnostics) { $notice = Get-FreshWinTerminalString 'terminal.diagnostics.noReport' 'No diagnostic report is available to export.'; continue }
            $defaultDestination = Get-FreshWinRetainedArtifactDirectory -Category Exports
            $destinationPrompt = (Get-FreshWinTerminalString 'terminal.diagnostics.outputPrompt' 'Absolute diagnostics output directory') + " [$defaultDestination]"
            $destination = Read-FreshWinTerminalInput -Prompt $destinationPrompt -InputProvider $InputProvider
            if ([string]::IsNullOrWhiteSpace([string]$destination)) { $destination = $defaultDestination }
            if (-not [System.IO.Path]::IsPathRooted([string]$destination) -or [string]$destination -match '[\x00\r\n]') {
                $notice = Get-FreshWinTerminalString 'terminal.diagnostics.absoluteRequired' 'The diagnostics output directory must be an absolute path.'; continue
            }
            if (-not $DryRun) {
                $confirmation = Read-FreshWinTerminalInput -Prompt (Get-FreshWinTerminalString 'terminal.diagnostics.confirmPrompt' 'Create a new redacted diagnostics bundle? Type YES') -InputProvider $InputProvider
                if ($confirmation -cne 'YES') { $notice = Get-FreshWinTerminalString 'terminal.diagnostics.cancelled' 'Diagnostics export cancelled.'; continue }
            }
            try {
                $export = Invoke-FreshWinCliOptionalOperation -Component DiagnosticsExport -CommandNames @('Export-FreshWinDiagnostics') -Parameters @{ OutputRoot=[System.IO.Path]::GetFullPath([string]$destination); Diagnostics=$diagnostics; Confirm=$false; WhatIf=[bool]$DryRun }
                $notice = if ($export.Status -eq 'Completed') { Get-FreshWinTerminalString 'terminal.diagnostics.exported' 'Redacted diagnostics exported to {0}.' @($export.OutputPath) } elseif ($export.Status -eq 'Preview') { Get-FreshWinTerminalString 'terminal.diagnostics.preview' 'Diagnostics export preview completed; no files were written.' } else { Get-FreshWinTerminalString 'terminal.diagnostics.exportStatus' 'Diagnostics export status: {0}.' @($export.Status) }
            }
            catch { $notice = Protect-FreshWinSensitiveText $_.Exception.Message }
        }
        else { $notice = Get-FreshWinTerminalString 'terminal.diagnostics.refreshed' 'Diagnostics refreshed.' }
    }
}

function Show-FreshWinTerminalBackup {
    [CmdletBinding()]
    param([object]$Session, [scriptblock]$InputProvider, [scriptblock]$OutputWriter, [scriptblock]$InventoryProvider, [string]$EntryScriptPath, [switch]$DryRun)
    $notice = $null
    while ($true) {
        $installedIds = @($Session.Catalog.Packages | Where-Object {
            (Get-FreshWinPackageDetection -Package $_ -Inventory $Session.Inventory).State -in @('Installed','UpdateAvailable','Broken')
        } | ForEach-Object { [string]$_.id })
        $driverBackupAvailable = $null -ne (Get-Command -Name New-FreshWinDriverBackup -CommandType Function -ErrorAction SilentlyContinue)
        $preResetAvailable = $null -ne (Get-Command -Name New-FreshWinPreResetPlan -CommandType Function -ErrorAction SilentlyContinue)
        $items = @(
            (New-FreshWinTerminalItem '1' (Get-FreshWinTerminalString 'terminal.backup.exportProfile' 'Export installed application profile') '[SAFE]' (Get-FreshWinTerminalString 'terminal.backup.profileCount' '{0} catalog applications can be recorded in a portable JSON profile.' @($installedIds.Count))),
            (New-FreshWinTerminalItem '2' (Get-FreshWinTerminalString 'terminal.backup.drivers' 'Back up third-party drivers') $(if ($driverBackupAvailable) { '[ADMIN]' } else { '[N/A]' }) $(if ($driverBackupAvailable) { Get-FreshWinTerminalString 'terminal.backup.driverDetail' 'On live Windows, exports with bounded PnPUtil into protected ProgramData storage and reports the actual path.' } else { Get-FreshWinTerminalString 'terminal.backup.driverUnavailable' 'The driver-backup operation is not loaded in this build.' })),
            (New-FreshWinTerminalItem '3' (Get-FreshWinTerminalString 'terminal.backup.checklist' 'Before-reset checklist') $(if ($preResetAvailable) { '[CHECK]' } else { '[INFO]' }) $(if ($preResetAvailable) { Get-FreshWinTerminalString 'terminal.backup.checklistDetail' 'Collect read-only readiness observations and build a non-executing reset checklist.' } else { Get-FreshWinTerminalString 'terminal.backup.checklistManual' 'Review personal-file backup, recovery keys, application inventory, and restore media manually.' })),
            (New-FreshWinTerminalItem '4' (Get-FreshWinTerminalString 'terminal.backup.restoreProfile' 'Restore portable application profile') '[PLAN]' (Get-FreshWinTerminalString 'terminal.backup.restoreDetail' 'Strictly validate a FreshWin profile, then review its packages through the shared planner.'))
        )
        $status = @((Get-FreshWinTerminalString 'terminal.backup.privacy' 'FreshWin does not inspect credential stores, browser profiles, SSH keys, or unrelated personal files.'))
        if ($notice) { $status += $notice }
        $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.home.entries.backup.label' 'Backup / Before Reset')) -Title (Get-FreshWinTerminalString 'terminal.home.entries.backup.label' 'Backup / Before Reset') `
            -Description (Get-FreshWinTerminalString 'terminal.backup.description' 'Record restorable FreshWin package choices and review what must be protected before resetting Windows.') `
            -Items $items -Status $status -ContextHelp @((Get-FreshWinTerminalString 'terminal.backup.helpProfile' 'Option 1 writes only a declarative FreshWin package profile.'), (Get-FreshWinTerminalString 'terminal.backup.helpDrivers' 'The requested path is audited only on live Windows; output is redirected below protected ProgramData and is not copied back.'), (Get-FreshWinTerminalString 'terminal.backup.helpReset' 'The checklist never starts or schedules a Windows reset.')) `
            -Commands @((New-FreshWinTerminalCommand '1' (Get-FreshWinTerminalString 'terminal.backup.exportProfileShort' 'Export app profile')), (New-FreshWinTerminalCommand '2' (Get-FreshWinTerminalString 'terminal.backup.driversShort' 'Back up drivers')), (New-FreshWinTerminalCommand '3' (Get-FreshWinTerminalString 'terminal.backup.checklistShort' 'Build reset checklist')), (New-FreshWinTerminalCommand '4' (Get-FreshWinTerminalString 'terminal.backup.restoreProfileShort' 'Restore app profile')), (New-FreshWinTerminalCommand '?' (Get-FreshWinTerminalString 'terminal.common.help' 'Help')), (New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'ui.actions.back' 'Back'))) -Prompt (Get-FreshWinTerminalString 'terminal.backup.prompt' 'Choose an available backup action.')
        [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
        $raw = Read-FreshWinTerminalInput -Prompt 'backup' -InputProvider $InputProvider
        if ($null -eq $raw) { return }
        if ([string]$raw -eq '0') { return }
        if ([string]$raw -eq '?') { $notice = Get-FreshWinTerminalString 'terminal.backup.helpPrivacy' 'FreshWin artifacts contain inventory and package choices, never application data, credentials, or recovery secrets.'; continue }

        if ([string]$raw -eq '1') {
            if ($installedIds.Count -eq 0) { $notice = Get-FreshWinTerminalString 'terminal.backup.noApps' 'No installed catalog applications were detected; no empty profile was written.'; continue }
            $defaultPath = Get-FreshWinDefaultArtifactPath -Category Backups -FileName ('FreshWin-Profile-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.json')
            $profilePrompt = (Get-FreshWinTerminalString 'terminal.backup.profilePathPrompt' 'New absolute .json output path') + " [$defaultPath]"
            $path = Read-FreshWinTerminalInput -Prompt $profilePrompt -InputProvider $InputProvider
            if ([string]::IsNullOrWhiteSpace([string]$path)) { $path = $defaultPath }
            try {
                $safePath = Resolve-FreshWinCliNewOutputPath -Path ([string]$path) -AllowedExtensions @('.json') -AllowMissingParent
                if ($DryRun) { $notice = Get-FreshWinTerminalString 'terminal.backup.profilePreview' 'Profile export preview: {0} package IDs would be written to {1}; no file was created.' @($installedIds.Count, $safePath) }
                else {
                    $export = Export-FreshWinProfile -Path $safePath -PackageIds $installedIds -Name (Get-FreshWinTerminalString 'terminal.backup.exportName' 'FreshWin pre-reset applications')
                    $notice = Get-FreshWinTerminalString 'terminal.backup.profileExported' 'Exported {0} package IDs to {1}.' @($export.PackageCount, $export.Path)
                }
            }
            catch { $notice = Protect-FreshWinSensitiveText $_.Exception.Message }
            continue
        }

        if ([string]$raw -eq '2') {
            if (-not $driverBackupAvailable) { $notice = Get-FreshWinTerminalString 'terminal.backup.driverUnavailableShort' 'The driver-backup operation is unavailable.'; continue }
            $defaultDestination = Get-FreshWinRetainedArtifactDirectory -Category Drivers
            $driverPrompt = (Get-FreshWinTerminalString 'terminal.backup.driverPathPrompt' 'Absolute requested path for the audit record (live output uses protected ProgramData)') + " [$defaultDestination]"
            $destination = Read-FreshWinTerminalInput -Prompt $driverPrompt -InputProvider $InputProvider
            if ([string]::IsNullOrWhiteSpace([string]$destination)) { $destination = $defaultDestination }
            if (-not [System.IO.Path]::IsPathRooted([string]$destination) -or [string]$destination -match '[\x00\r\n]') {
                $notice = Get-FreshWinTerminalString 'terminal.backup.driverAbsolute' 'The requested audit path must be absolute.'; continue
            }
            if (-not $DryRun -and -not (Test-FreshWinAdministrator)) { $notice = Get-FreshWinTerminalString 'terminal.backup.driverAdmin' 'Driver backup requires an administrator PowerShell session.'; continue }
            if (-not $DryRun) {
                $confirmation = Read-FreshWinTerminalInput -Prompt (Get-FreshWinTerminalString 'terminal.backup.driverConfirm' 'Export drivers into protected FreshWin ProgramData storage and report the actual path? Type YES') -InputProvider $InputProvider
                if ($confirmation -cne 'YES') { $notice = Get-FreshWinTerminalString 'terminal.backup.driverCancelled' 'Driver backup cancelled.'; continue }
            }
            try {
                $backup = Invoke-FreshWinCliOptionalOperation -Component DriverBackup -CommandNames @('New-FreshWinDriverBackup') -Parameters @{ OutputRoot=[System.IO.Path]::GetFullPath([string]$destination); Confirm=$false; WhatIf=[bool]$DryRun }
                $notice = if ($backup.Status -in @('Completed','FixtureVerified')) { Get-FreshWinTerminalString 'terminal.backup.driverCompleted' 'Driver backup completed at {0}.' @($backup.BackupPath) } elseif ($backup.Status -eq 'Preview') { Get-FreshWinTerminalString 'terminal.backup.driverPreview' 'Driver backup preview completed; no files were written.' } else { Get-FreshWinTerminalString 'terminal.backup.driverStatus' 'Driver backup status: {0}. {1}' @($backup.Status, [string](Get-FreshWinPropertyValue $backup 'Reason' '')) }
            }
            catch { $notice = Protect-FreshWinSensitiveText $_.Exception.Message }
            continue
        }

        if ([string]$raw -eq '3') {
            if (-not $preResetAvailable) { $notice = Get-FreshWinTerminalString 'terminal.backup.checklistUnavailable' 'The before-reset checklist operation is unavailable.'; continue }
            try {
                $resetPlan = Invoke-FreshWinCliOptionalOperation -Component PreResetPlan -CommandNames @('New-FreshWinPreResetPlan')
                $validationCommand = Get-Command -Name Test-FreshWinPreResetPlan -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
                $validation = if ($null -ne $validationCommand) { & $validationCommand -Plan $resetPlan } else { $null }
                $notice = if ($null -ne $validation) { Get-FreshWinTerminalString 'terminal.backup.checklistResult' 'Before-reset checklist: {0}; {1} required confirmations remain.' @($resetPlan.Status, $validation.BlockerCount) } else { Get-FreshWinTerminalString 'terminal.backup.checklistStatus' 'Before-reset checklist status: {0}.' @($resetPlan.Status) }
            }
            catch { $notice = Protect-FreshWinSensitiveText $_.Exception.Message }
            continue
        }

        if ([string]$raw -eq '4') {
            $profilePath = Read-FreshWinTerminalInput -Prompt (Get-FreshWinTerminalString 'terminal.backup.restorePathPrompt' 'Absolute portable profile .json path') -InputProvider $InputProvider
            try {
                $portableProfile = Import-FreshWinUserProfile -Path ([string]$profilePath) -Catalog $Session.Catalog
                $profileIncludesUpdates = [string]$portableProfile.updatePolicy -eq 'include-updates'
                [void](Set-FreshWinTerminalInventoryPolicy -Session $Session -IncludeUpdates $profileIncludesUpdates -InventoryProvider $InventoryProvider)
                [void](Invoke-FreshWinTerminalPlanWorkflow -Session $Session -PackageIds @($portableProfile.NormalizedPackageIds) -InputProvider $InputProvider -OutputWriter $OutputWriter -InventoryProvider $InventoryProvider -EntryScriptPath $EntryScriptPath -DryRun:$DryRun)
            }
            catch { $notice = Protect-FreshWinSensitiveText $_.Exception.Message }
            continue
        }

        $notice = Get-FreshWinTerminalString 'terminal.backup.invalidChoice' 'Choose 1, 2, 3, 4, ?, or 0.'
    }
}

function Write-FreshWinTerminalAssistantResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Intent,
        [AllowNull()][object[]]$Items = @(),
        [AllowNull()][string[]]$Status = @(),
        [scriptblock]$OutputWriter,
        [string]$Description
    )
    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = Get-FreshWinTerminalString 'terminal.assistant.intentDescription' 'The request was parsed as a read-only or navigation intent. No system change was made.'
    }
    $assistantTitle = Get-FreshWinTerminalString 'terminal.home.entries.assistant.label' 'Assistant'
    $statusLines = @(
        (Get-FreshWinTerminalString 'terminal.assistant.action' 'Action: {0}' @([string]$Intent.action)),
        (Get-FreshWinTerminalString 'terminal.assistant.targets' 'Targets: {0}' @(@($Intent.targets) -join ', '))
    )
    $statusLines += @($Status | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $page = New-FreshWinTerminalPage -Breadcrumb @(
        (Get-FreshWinTerminalString 'terminal.common.home' 'Home'),
        $assistantTitle,
        (Get-FreshWinTerminalString 'terminal.assistant.intentBreadcrumb' 'Intent')
    ) -Title ([string]$Intent.intent) -Description $Description -Items @($Items) -Status $statusLines `
        -ContextHelp @((Get-FreshWinTerminalString 'terminal.assistant.intentHelp' 'Use the matching FreshWin center to continue.')) `
        -Commands @((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.return' 'Return'))) `
        -Prompt (Get-FreshWinTerminalString 'terminal.common.returnHome' 'Return to Home.')
    [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
    return $page
}

function Invoke-FreshWinTerminalAssistantReadOnlyDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][object]$Intent,
        [scriptblock]$InputProvider,
        [scriptblock]$OutputWriter,
        [scriptblock]$InventoryProvider,
        [scriptblock]$DriverInventoryProvider,
        [scriptblock]$DiagnosticsProvider,
        [scriptblock]$WindowsUpdateProvider,
        [string]$EntryScriptPath,
        [switch]$DryRun
    )
    $action = [string]$Intent.action
    $readOnlyActions = @(
        'search_package', 'scan_drivers', 'get_hardware', 'get_missing', 'get_status',
        'run_diagnostics', 'list_installed_packages', 'list_drivers', 'list_updates',
        'open_section', 'show_help'
    )
    if ($action -notin $readOnlyActions) {
        return [pscustomobject]@{ Dispatched=$false; Action=$action; Result=$null }
    }

    $items = New-Object System.Collections.Generic.List[object]
    $status = New-Object System.Collections.Generic.List[string]
    $result = $null
    $index = 0

    switch ($action) {
        'get_status' {
            $result = Get-FreshWinTerminalHomePage -Session $Session
            foreach ($line in @($result.Status)) { $status.Add([string]$line) }
        }
        'get_hardware' {
            $result = $Session.System
            $osName = [string](Get-FreshWinPropertyValue -InputObject $result -Name 'OSName' -Default (Get-FreshWinPropertyValue -InputObject $result -Name 'OSFamily' -Default 'Unknown'))
            $build = [string](Get-FreshWinPropertyValue -InputObject $result -Name 'BuildNumber' -Default 'Unknown')
            $architecture = [string](Get-FreshWinPropertyValue -InputObject $result -Name 'Architecture' -Default 'Unknown')
            $cpu = [string](Get-FreshWinPropertyValue -InputObject $result -Name 'CPU' -Default 'Unknown')
            $memory = Get-FreshWinPropertyValue -InputObject $result -Name 'MemoryGB' -Default $null
            $gpus = @((Get-FreshWinPropertyValue -InputObject $result -Name 'GPUs' -Default @()))
            $status.Add((Get-FreshWinTerminalString 'terminal.home.status.system' '{0} | build {1} | {2}' @($osName, $build, $architecture)))
            $status.Add((Get-FreshWinTerminalString 'terminal.drivers.hardware' 'Hardware: {0} {1}' @(
                [string](Get-FreshWinPropertyValue -InputObject $result -Name 'Manufacturer' -Default 'Unknown'),
                [string](Get-FreshWinPropertyValue -InputObject $result -Name 'Model' -Default 'Unknown')
            )))
            $status.Add((Get-FreshWinTerminalString 'terminal.home.status.hardware' '{0} | {1} GB RAM | {2}' @($cpu, $memory, $(if ($gpus.Count -gt 0) { @($gpus | ForEach-Object { [string](Get-FreshWinPropertyValue -InputObject $_ -Name 'Name' -Default 'Unknown') }) -join ', ' } else { Get-FreshWinTerminalString 'terminal.home.status.unknownGpu' 'Unknown GPU' }))))
            foreach ($gpu in $gpus) {
                $index++
                $items.Add((New-FreshWinTerminalItem -Key ([string]$index) `
                    -Label ([string](Get-FreshWinPropertyValue -InputObject $gpu -Name 'Name' -Default 'Unknown GPU')) `
                    -Badge '[GPU]' -Detail ('Vendor: {0} | driver: {1}' -f `
                        [string](Get-FreshWinPropertyValue -InputObject $gpu -Name 'Vendor' -Default 'Unknown'),
                        [string](Get-FreshWinPropertyValue -InputObject $gpu -Name 'DriverVersion' -Default 'Unknown')) -Value $gpu))
            }
        }
        'search_package' {
            $query = [string](Get-FreshWinPropertyValue -InputObject $Intent.parameters -Name 'query' -Default '')
            $result = @(Find-FreshWinPackage -Catalog $Session.Catalog -Query $query)
            foreach ($package in $result) {
                $index++
                $source = Get-FreshWinPropertyValue -InputObject $package -Name 'source' -Default ([pscustomobject]@{})
                $description = Get-FreshWinString -Key ([string]$package.descriptionKey) -Default ([string]$package.name)
                $items.Add((New-FreshWinTerminalItem -Key ([string]$index) -Label ([string]$package.name) -Badge '[CAT]' `
                    -Detail ('{0} | {1}/{2} | source: {3} | {4}' -f [string]$package.id, [string]$package.category, [string]$package.subcategory, [string](Get-FreshWinPropertyValue -InputObject $source -Name 'type' -Default 'unknown'), $description) -Value $package))
            }
            $status.Add((Get-FreshWinTerminalString 'terminal.packageCenter.shown' 'Packages shown: {0}' @($result.Count)))
        }
        { $_ -in @('scan_drivers','list_drivers') } {
            $result = if ($null -ne $DriverInventoryProvider) { @(& $DriverInventoryProvider) } else { @(Get-FreshWinDriverInventory) }
            $summary = Get-FreshWinDriverSummary -Drivers @($result)
            $status.Add((Get-FreshWinTerminalString 'terminal.drivers.scan' 'Driver scan: {0} | required: {1} | review: {2}' @($summary.Status, $summary.Required, $summary.Recommended)))
            foreach ($driver in @($result)) {
                if ([string](Get-FreshWinPropertyValue -InputObject $driver -Name 'Component' -Default '') -eq 'DriverScannerDiagnostic') { continue }
                $index++
                $health = [string](Get-FreshWinPropertyValue -InputObject $driver -Name 'Health' -Default 'Unknown')
                $items.Add((New-FreshWinTerminalItem -Key ([string]$index) `
                    -Label ([string](Get-FreshWinPropertyValue -InputObject $driver -Name 'Name' -Default 'Unknown device')) `
                    -Badge ("[$health]") -Detail ('{0} | priority: {1} | {2}' -f `
                        [string](Get-FreshWinPropertyValue -InputObject $driver -Name 'Category' -Default 'Other'),
                        [string](Get-FreshWinPropertyValue -InputObject $driver -Name 'Priority' -Default 'Unknown'),
                        [string](Get-FreshWinPropertyValue -InputObject $driver -Name 'Reason' -Default 'No additional observation.')) -Value $driver))
            }
        }
        'run_diagnostics' {
            $result = if ($null -ne $DiagnosticsProvider) { & $DiagnosticsProvider } else { Get-FreshWinDiagnostics }
            if ($null -eq $result) { throw 'The diagnostics provider returned no result.' }
            $health = Get-FreshWinHealthSummary -Diagnostics $result
            $status.Add((Get-FreshWinTerminalString 'terminal.diagnostics.health' 'Overall health: {0} | attention: {1} | review: {2} | unsupported: {3}' @($health.OverallHealth, $health.AttentionCount, $health.ReviewCount, $health.UnsupportedCount)))
            $status.Add((Get-FreshWinTerminalString 'terminal.diagnostics.collection' 'Collection status: {0} | live Windows evidence: {1}' @(
                [string](Get-FreshWinPropertyValue -InputObject $result -Name 'Status' -Default 'Unknown'),
                [bool](Get-FreshWinPropertyValue -InputObject $result -Name 'IsLive' -Default $false)
            )))
            foreach ($component in @($health.Components)) {
                $index++
                $items.Add((New-FreshWinTerminalItem -Key ([string]$index) -Label ([string]$component.Component) `
                    -Badge ("[$($component.Health)]") -Detail ([string]$component.Reason) -Value $component))
            }
        }
        'list_installed_packages' {
            $result = @((Get-FreshWinPropertyValue -InputObject $Session.Inventory -Name 'Items' -Default @()))
            foreach ($application in $result) {
                $index++
                $updateAvailable = [bool](Get-FreshWinPropertyValue -InputObject $application -Name 'UpdateAvailable' -Default $false)
                $items.Add((New-FreshWinTerminalItem -Key ([string]$index) `
                    -Label ([string](Get-FreshWinPropertyValue -InputObject $application -Name 'DisplayName' -Default (Get-FreshWinPropertyValue -InputObject $application -Name 'WingetId' -Default 'Unknown application'))) `
                    -Badge $(if ($updateAvailable) { '[UP]' } else { '[OK]' }) `
                    -Detail ('{0} | version: {1}{2}' -f `
                        [string](Get-FreshWinPropertyValue -InputObject $application -Name 'WingetId' -Default 'unknown'),
                        [string](Get-FreshWinPropertyValue -InputObject $application -Name 'Version' -Default 'unknown'),
                        $(if ($updateAvailable) { ' | update available' } else { '' })) -Value $application))
            }
            $status.Add((Get-FreshWinTerminalString 'terminal.home.status.inventory' 'Observed applications: {0} | updates: {1}' @(
                $result.Count,
                @($result | Where-Object { [bool](Get-FreshWinPropertyValue -InputObject $_ -Name 'UpdateAvailable' -Default $false) }).Count
            )))
        }
        'list_updates' {
            $result = if ($null -ne $WindowsUpdateProvider) { & $WindowsUpdateProvider } else { Get-FreshWinWindowsUpdateState -IncludeDetails }
            if ($null -eq $result) { throw 'The Windows Update provider returned no result.' }
            $status.Add((Get-FreshWinTerminalString 'terminal.quick.statusUpdate' 'Windows Update: {0} | pending: {1} | restart: {2}' @(
                [string](Get-FreshWinPropertyValue -InputObject $result -Name 'Status' -Default 'Unknown'),
                (Get-FreshWinPropertyValue -InputObject $result -Name 'PendingCount' -Default $null),
                (Get-FreshWinPropertyValue -InputObject $result -Name 'RestartPending' -Default $null)
            )))
            foreach ($update in @((Get-FreshWinPropertyValue -InputObject $result -Name 'Updates' -Default @()))) {
                $index++
                $items.Add((New-FreshWinTerminalItem -Key ([string]$index) `
                    -Label ([string](Get-FreshWinPropertyValue -InputObject $update -Name 'Title' -Default 'Untitled update')) `
                    -Badge $(if ([bool](Get-FreshWinPropertyValue -InputObject $update -Name 'IsDriver' -Default $false)) { '[DRV]' } else { '[WIN]' }) `
                    -Detail ('KB: {0} | reboot: {1}' -f `
                        (@((Get-FreshWinPropertyValue -InputObject $update -Name 'KBArticleIds' -Default @())) -join ', '),
                        [bool](Get-FreshWinPropertyValue -InputObject $update -Name 'RebootRequired' -Default $false)) -Value $update))
            }
        }
        'get_missing' {
            $profile = Get-FreshWinProfile -Profiles $Session.Profiles -Id essential
            if ($null -eq $profile) { throw "Recommendation profile 'essential' was not found." }
            $recommendations = @(Get-FreshWinRecommendations -Catalog $Session.Catalog -SystemInfo $Session.System -Inventory $Session.Inventory -ProfileId essential -Profiles $Session.Profiles)
            $result = @(Get-FreshWinMissingRecommendations -Recommendations $recommendations -IncludeUpdates:$Session.IncludeUpdates)
            foreach ($recommendation in $result) {
                $index++
                $package = $recommendation.Package
                $detection = $recommendation.Detection
                $items.Add((New-FreshWinTerminalItem -Key ([string]$index) -Label ([string]$package.name) `
                    -Badge ([string](Get-FreshWinPropertyValue -InputObject $detection -Name 'Badge' -Default '[MISS]')) `
                    -Detail ([string]$recommendation.Reason) -Value $recommendation))
            }
            $status.Add((Get-FreshWinTerminalString 'terminal.packageCenter.shown' 'Packages shown: {0}' @($result.Count)))
        }
        'open_section' {
            $section = [string](Get-FreshWinPropertyValue -InputObject $Intent.parameters -Name 'section' -Default $(if (@($Intent.targets).Count -gt 0) { [string]$Intent.targets[0] } else { '' }))
            if ($section -notin @('gaming','developer')) { throw "Assistant section '$section' is not supported." }
            Show-FreshWinTerminalPackageCenter -Session $Session -Center $section -InputProvider $InputProvider -OutputWriter $OutputWriter -InventoryProvider $InventoryProvider -EntryScriptPath $EntryScriptPath -DryRun:$DryRun
            return [pscustomobject]@{ Dispatched=$true; Action=$action; Result=$section }
        }
        'show_help' {
            $result = @(
                'status', 'system info', 'hardware', 'search <text>', 'apps', 'updates',
                'drivers', 'scan drivers', 'doctor', 'missing', 'gaming', 'developer',
                'install <package IDs>', 'update [package IDs]', '<profile> setup'
            )
            foreach ($example in $result) {
                $index++
                $items.Add((New-FreshWinTerminalItem -Key ([string]$index) -Label $example -Badge '[INTENT]' -Value $example))
            }
        }
    }

    [void](Write-FreshWinTerminalAssistantResult -Intent $Intent -Items $items.ToArray() -Status $status.ToArray() -OutputWriter $OutputWriter)
    return [pscustomobject]@{ Dispatched=$true; Action=$action; Result=$result }
}

function Show-FreshWinTerminalAssistant {
    [CmdletBinding()]
    param(
        [object]$Session,
        [scriptblock]$InputProvider,
        [scriptblock]$OutputWriter,
        [scriptblock]$InventoryProvider,
        [scriptblock]$DriverInventoryProvider,
        [scriptblock]$DiagnosticsProvider,
        [scriptblock]$WindowsUpdateProvider,
        [string]$EntryScriptPath,
        [switch]$DryRun
    )
    $assistantTitle = Get-FreshWinTerminalString 'terminal.home.entries.assistant.label' 'Assistant'
    $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'),$assistantTitle) -Title $assistantTitle `
        -Description (Get-FreshWinTerminalString 'terminal.assistant.description' 'The assistant may return only an allowlisted FreshWin intent. It cannot supply executables, scripts, or native arguments.') `
        -Status @((Get-FreshWinTerminalString 'terminal.assistant.mutation' 'Mutating intents are routed back through the same planner and exact YES confirmation.')) `
        -ContextHelp @((Get-FreshWinTerminalString 'terminal.assistant.examples' 'Examples: install git and vscode; update; search browser; status.'), (Get-FreshWinTerminalString 'terminal.assistant.helpReturn' 'Enter 0 to return without parsing.')) `
        -Commands @((New-FreshWinTerminalCommand 'text' (Get-FreshWinTerminalString 'terminal.assistant.parse' 'Parse intent')), (New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'ui.actions.back' 'Back'))) -Prompt (Get-FreshWinTerminalString 'terminal.assistant.prompt' 'Enter one assistant request.')
    [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
    $raw = Read-FreshWinTerminalInput -Prompt 'assistant' -InputProvider $InputProvider
    if ($null -eq $raw -or [string]$raw -eq '0') { return }
    try {
        $intent = Invoke-FreshWinAssistantProvider -InputText ([string]$raw)
        if (-not [bool]$intent.isValid) { return }
        if ($intent.action -in @('queue_install','queue_update','recommend_profile')) {
            $packageIds = @($intent.targets)
            if ($intent.action -eq 'queue_update') {
                [void](Set-FreshWinTerminalInventoryPolicy -Session $Session -IncludeUpdates $true -InventoryProvider $InventoryProvider)
                $updateState = Get-FreshWinInventoryUpdateQueryState -Inventory $Session.Inventory
                if (-not $updateState.Known) {
                    $unknownMessage = Get-FreshWinTerminalString 'terminal.assistant.updateStateUnknown' 'Community WinGet update state is unknown because that update inventory scan did not complete.'
                    $unknownStatus = @($unknownMessage)
                    foreach ($updateError in @($updateState.Errors)) {
                        $unknownStatus += Get-FreshWinTerminalString 'terminal.assistant.updateProviderError' 'Update provider error: {0}' @($updateError)
                    }
                    [void](Write-FreshWinTerminalAssistantResult -Intent $intent -Description $unknownMessage -Status $unknownStatus -OutputWriter $OutputWriter)
                    return [pscustomobject]@{ Dispatched=$false; Status='UpdateStateUnknown'; UpdateState=$updateState }
                }
                $unscannedTargets = @(Get-FreshWinUnscannedUpdateTargets -Catalog $Session.Catalog -PackageIds $packageIds -UpdateSourcesScanned $updateState.UpdateSourcesScanned)
                if ($unscannedTargets.Count -gt 0) {
                    $manualMessage = Get-FreshWinTerminalString 'terminal.assistant.unscannedUpdateSource' 'The requested package source is outside the community WinGet update scan and remains unknown/manual: {0}' @($unscannedTargets -join ', ')
                    [void](Write-FreshWinTerminalAssistantResult -Intent $intent -Description $manualMessage -Status @($manualMessage) -OutputWriter $OutputWriter)
                    return [pscustomobject]@{ Dispatched=$false; Status='UpdateStateUnknown'; ManualReviewTargets=$unscannedTargets; UpdateState=$updateState }
                }
            }
            if ($intent.action -eq 'queue_update' -and $packageIds.Count -eq 0) {
                $updateRows = @(Get-FreshWinTerminalPackageRows -Session $Session -Center updates -Filter UPDATES)
                $packageIds = @($updateRows | ForEach-Object { [string]$_.Value.Package.id })
            }
            elseif ($intent.action -eq 'recommend_profile') {
                $profileId = [string](Get-FreshWinPropertyValue -InputObject $intent.parameters -Name 'profile' -Default $(if ($packageIds.Count -gt 0) { [string]$packageIds[0] } else { 'essential' }))
                if ($profileId -eq 'full') { $profileId = 'full-recommended' }
                $profile = Get-FreshWinProfile -Profiles $Session.Profiles -Id $profileId
                if ($null -eq $profile) { throw "Recommendation profile '$profileId' was not found." }
                $recommendations = @(Get-FreshWinRecommendations -Catalog $Session.Catalog -SystemInfo $Session.System -Inventory $Session.Inventory -ProfileId $profileId -Profiles $Session.Profiles)
                $packageIds = @($recommendations | ForEach-Object { [string]$_.PackageId } | Select-Object -Unique)
            }
            if ($packageIds.Count -gt 0) { [void](Invoke-FreshWinTerminalPlanWorkflow -Session $Session -PackageIds $packageIds -InputProvider $InputProvider -OutputWriter $OutputWriter -InventoryProvider $InventoryProvider -EntryScriptPath $EntryScriptPath -DryRun:$DryRun) }
            elseif ($intent.action -eq 'queue_update') {
                $nothingMessage = Get-FreshWinTerminalString 'terminal.assistant.noApplicationUpdates' 'No community WinGet package updates were observed in the completed update scan; Store updates were not queried.'
                [void](Write-FreshWinTerminalAssistantResult -Intent $intent -Description $nothingMessage -Status @($nothingMessage) -OutputWriter $OutputWriter)
            }
            return
        }
        if ($intent.action -eq 'backup_drivers') {
            $backupGuidance = Get-FreshWinTerminalString 'terminal.backup.helpDrivers' 'Driver backup requires an explicit destination and exact YES confirmation outside dry-run mode.'
            [void](Write-FreshWinTerminalAssistantResult -Intent $intent -Status @($backupGuidance) `
                -Description $backupGuidance -OutputWriter $OutputWriter)
            return
        }
        $dispatch = Invoke-FreshWinTerminalAssistantReadOnlyDispatch -Session $Session -Intent $intent `
            -InputProvider $InputProvider -OutputWriter $OutputWriter -InventoryProvider $InventoryProvider `
            -DriverInventoryProvider $DriverInventoryProvider -DiagnosticsProvider $DiagnosticsProvider `
            -WindowsUpdateProvider $WindowsUpdateProvider -EntryScriptPath $EntryScriptPath -DryRun:$DryRun
        if (-not [bool]$dispatch.Dispatched) {
            [void](Write-FreshWinTerminalAssistantResult -Intent $intent -OutputWriter $OutputWriter)
        }
    }
    catch {
        $errorPage = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'),$assistantTitle) -Title (Get-FreshWinTerminalString 'terminal.assistant.rejected' 'Assistant Request Rejected') `
            -Description (Protect-FreshWinSensitiveText $_.Exception.Message) -ContextHelp @((Get-FreshWinTerminalString 'terminal.assistant.rejectedHelp' 'Only constrained FreshWin intents are accepted.')) `
            -Commands @((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.return' 'Return'))) -Prompt (Get-FreshWinTerminalString 'terminal.common.returnHome' 'Return to Home.')
        [void](Write-FreshWinTerminalPage -Page $errorPage -OutputWriter $OutputWriter)
    }
}

function Show-FreshWinTerminalLanguage {
    [CmdletBinding()]
    param(
        [scriptblock]$InputProvider,
        [scriptblock]$OutputWriter,
        [scriptblock]$LocaleSaver,
        [scriptblock]$CompactModeSaver,
        [switch]$AllowCompactToggle
    )
    $locales = @(
        [pscustomobject]@{ Id=1; Locale='en-US'; Name='English (United States)' },
        [pscustomobject]@{ Id=2; Locale='vi-VN'; Name=('Ti' + [char]0x1EBF + 'ng Vi' + [char]0x1EC7 + 't') },
        [pscustomobject]@{ Id=3; Locale='zh-CN'; Name=(@([char]0x7B80,[char]0x4F53,[char]0x4E2D,[char]0x6587) -join '') },
        [pscustomobject]@{ Id=4; Locale='ja-JP'; Name=(@([char]0x65E5,[char]0x672C,[char]0x8A9E) -join '') }
    )
    $languageTitle = Get-FreshWinTerminalString 'terminal.home.entries.language.label' 'Language'
    $items = @($locales | ForEach-Object { New-FreshWinTerminalItem -Key ([string]$_.Id) -Label $_.Name -Badge $_.Locale -Detail (Get-FreshWinTerminalString 'terminal.language.itemDetail' 'Use this locale for catalog descriptions and localized UI strings.') -Value $_ })
    $commands = @((New-FreshWinTerminalCommand '1-4' (Get-FreshWinTerminalString 'terminal.language.select' 'Select locale')))
    $status = @()
    if ($AllowCompactToggle) {
        $compactLabel = if ([bool]$script:FreshWinTerminalCompactMode) { Get-FreshWinTerminalString 'terminal.language.compactOn' 'On' } else { Get-FreshWinTerminalString 'terminal.language.compactOff' 'Off' }
        $status += Get-FreshWinTerminalString 'terminal.language.compactStatus' 'Compact presentation: {0}' @($compactLabel)
        $commands += New-FreshWinTerminalCommand 'C' (Get-FreshWinTerminalString 'terminal.language.compactToggle' 'Toggle and save compact presentation')
    }
    $commands += New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'ui.actions.back' 'Back')
    $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'),$languageTitle) -Title $languageTitle -Description (Get-FreshWinTerminalString 'terminal.language.description' 'Choose a supported locale. The setting is saved in the normal FreshWin configuration.') `
        -Items $items -Status $status -ContextHelp @((Get-FreshWinTerminalString 'terminal.language.fallback' 'English remains the fallback if a localized string is unavailable.')) `
        -Commands $commands -Prompt (Get-FreshWinTerminalString 'terminal.language.prompt' 'Choose a language or display preference.')
    [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
    $raw = Read-FreshWinTerminalInput -Prompt 'language' -InputProvider $InputProvider
    if ($null -eq $raw -or [string]$raw -eq '0') { return $null }
    if ($AllowCompactToggle -and ([string]$raw).Trim().ToUpperInvariant() -eq 'C') {
        $newMode = -not [bool]$script:FreshWinTerminalCompactMode
        if ($null -ne $CompactModeSaver) { [void](& $CompactModeSaver $newMode) }
        else { [void](Set-FreshWinConfigCompactMode -CompactMode $newMode) }
        $script:FreshWinTerminalCompactMode = $newMode
        $savedLabel = if ($newMode) { Get-FreshWinTerminalString 'terminal.language.compactOn' 'On' } else { Get-FreshWinTerminalString 'terminal.language.compactOff' 'Off' }
        $savedPage = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'),$languageTitle) -Title $languageTitle `
            -Description (Get-FreshWinTerminalString 'terminal.language.compactSaved' 'Compact presentation was saved: {0}.' @($savedLabel)) `
            -Commands @((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'ui.actions.back' 'Back'))) -Prompt (Get-FreshWinTerminalString 'terminal.common.returnHome' 'Return to Home.')
        [void](Write-FreshWinTerminalPage -Page $savedPage -OutputWriter $OutputWriter)
        return $null
    }
    $selection = ConvertFrom-FreshWinSelection -InputText ([string]$raw) -AvailableIds @(1,2,3,4) -CommandMap @{'0'='BACK'} -AllowedCommands @('SELECT','BACK') -MaximumSelectionCount 1
    if (-not $selection.Valid -or $selection.Values.Count -ne 1) { return $null }
    $locale = [string]$locales[$selection.Values[0] - 1].Locale
    [void](Set-FreshWinLocale -Locale $locale)
    if ($null -ne $LocaleSaver) { [void](& $LocaleSaver $locale) }
    else { [void](Set-FreshWinConfigLocale -Locale $locale) }
    return $locale
}

function Show-FreshWinTerminalUpdateFreshWin {
    [CmdletBinding()]
    param(
        [scriptblock]$OutputWriter,
        [scriptblock]$UpdateStatusProvider,
        [scriptblock]$InputProvider,
        [scriptblock]$UpdateInstaller
    )
    $updateTitle = Get-FreshWinTerminalString 'terminal.home.entries.update.label' 'Update FreshWin'
    try {
        $updateStatus = if ($null -ne $UpdateStatusProvider) { & $UpdateStatusProvider } else { Get-FreshWinUpdateStatus }
    }
    catch {
        $updateStatus = [pscustomobject]@{
            Status='Unavailable'; UpdateAvailable=$false; CurrentVersion=(Get-FreshWinVersion); AvailableVersion=$null
            MutationPerformed=$false; Reason=(Protect-FreshWinSensitiveText $_.Exception.Message)
        }
    }
    $statusLines = @(
        (Get-FreshWinTerminalString 'terminal.update.version' 'Installed version: {0}' @([string](Get-FreshWinPropertyValue $updateStatus 'CurrentVersion' (Get-FreshWinVersion)))),
        (Get-FreshWinTerminalString 'terminal.update.status' 'Update check status: {0}' @([string](Get-FreshWinPropertyValue $updateStatus 'Status' 'Unavailable')))
    )
    $availableVersion = [string](Get-FreshWinPropertyValue $updateStatus 'AvailableVersion' '')
    if (-not [string]::IsNullOrWhiteSpace($availableVersion)) {
        $statusLines += Get-FreshWinTerminalString 'terminal.update.availableVersion' 'Available version: {0}' @($availableVersion)
    }
    $reason = [string](Get-FreshWinPropertyValue $updateStatus 'Reason' '')
    if (-not [string]::IsNullOrWhiteSpace($reason)) {
        $statusLines += Get-FreshWinTerminalString 'terminal.update.reason' 'Details: {0}' @((Protect-FreshWinSensitiveText $reason))
    }
    $updateAvailable = [bool](Get-FreshWinPropertyValue $updateStatus 'UpdateAvailable' $false)
    $statusLines += if ($updateAvailable) { 'Review the version above. Installation requires an explicit INSTALL confirmation.' } else { Get-FreshWinTerminalString 'terminal.update.noAction' 'No download or update command was executed.' }
    $commands = New-Object Collections.Generic.List[object]
    if ($updateAvailable) { $commands.Add((New-FreshWinTerminalCommand 'I' 'Install reviewed update')) }
    $commands.Add((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.return' 'Return')))
    $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'),$updateTitle) -Title $updateTitle `
        -Description (Get-FreshWinTerminalString 'terminal.update.description' 'Check configured, allowlisted update metadata. FreshWin does not automatically download, apply, or execute an update.') `
        -Status $statusLines `
        -ContextHelp @((Get-FreshWinTerminalString 'terminal.update.helpValidate' 'Validate a new checkout before using it.'), (Get-FreshWinTerminalString 'terminal.update.helpNoPipe' 'Do not pipe remote scripts directly into PowerShell.')) `
        -Commands $commands.ToArray() -Prompt (Get-FreshWinTerminalString 'terminal.common.returnHome' 'Return to Home.')
    [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
    if ($null -eq $InputProvider -or -not $updateAvailable) { return }
    $choice = Read-FreshWinTerminalInput -Prompt 'update' -InputProvider $InputProvider
    if ([string]$choice -ine 'I') { return }
    $confirmation = Read-FreshWinTerminalInput -Prompt 'Type INSTALL to continue' -InputProvider $InputProvider
    if ([string]$confirmation -cne 'INSTALL') { return }
    try {
        $result = if ($null -ne $UpdateInstaller) { & $UpdateInstaller $updateStatus } else { Invoke-FreshWinCoreUpdate -UpdateStatus $updateStatus -Confirm:$false }
        $resultPage = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'),$updateTitle) -Title 'FreshWin update result' `
            -Description 'The protected installer completed the reviewed update.' -Status @("Status: $([string]$result.Status)", "Version: $([string]$result.Version)", "Verified: $([bool]$result.Verified)") `
            -Commands @((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.return' 'Return'))) -Prompt (Get-FreshWinTerminalString 'terminal.common.returnHome' 'Return to Home.')
    }
    catch {
        $resultPage = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'),$updateTitle) -Title 'FreshWin update failed' `
            -Description (Protect-FreshWinSensitiveText $_.Exception.Message) -Status @('The previous protected installation was retained or restored by the installer.') `
            -Commands @((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.return' 'Return'))) -Prompt (Get-FreshWinTerminalString 'terminal.common.returnHome' 'Return to Home.')
    }
    [void](Write-FreshWinTerminalPage -Page $resultPage -OutputWriter $OutputWriter)
    [void](Read-FreshWinTerminalInput -Prompt 'update result' -InputProvider $InputProvider)
}

function Show-FreshWinTerminalAbout {
    [CmdletBinding()]
    param([scriptblock]$OutputWriter)
    $aboutTitle = Get-FreshWinTerminalString 'terminal.home.entries.about.label' 'About & Support'
    $page = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'),$aboutTitle) -Title $aboutTitle `
        -Description (Get-FreshWinTerminalString 'terminal.about.description' 'FreshWin — Windows Post-Install Toolkit. A safety-first Windows 10/11 inventory, recommendation, planning, execution, and verification assistant.') `
        -Status @((Get-FreshWinTerminalString 'terminal.about.version' 'Version: {0}' @((Get-FreshWinVersion))), (Get-FreshWinTerminalString 'terminal.about.developer' 'Developer: Mai Tuấn Dũng'), (Get-FreshWinTerminalString 'terminal.about.support' 'Support: maituandung004@gmail.com'), (Get-FreshWinTerminalString 'terminal.about.docs' 'Local documentation: README.md, CONTRIBUTING.md, and docs/.')) `
        -ContextHelp @((Get-FreshWinTerminalString 'terminal.about.helpCli' 'Run FreshWin help for the automation interface.'), (Get-FreshWinTerminalString 'terminal.about.helpValidate' 'Run FreshWin validate after changing catalogs, profiles, locales, or source.'), (Get-FreshWinTerminalString 'terminal.about.helpRedact' 'Redact diagnostics before sharing them with support.')) `
        -Commands @((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.return' 'Return'))) -Prompt (Get-FreshWinTerminalString 'terminal.common.returnHome' 'Return to Home.')
    [void](Write-FreshWinTerminalPage -Page $page -OutputWriter $OutputWriter)
}

function Start-FreshWinTerminalSession {
    [CmdletBinding()]
    param(
        [string]$Locale = 'en-US',
        [scriptblock]$InputProvider,
        [scriptblock]$OutputWriter,
        [scriptblock]$PlatformProvider,
        [scriptblock]$SessionProvider,
        [scriptblock]$ConfigurationProvider,
        [scriptblock]$LocaleSaver,
        [scriptblock]$CompactModeSaver,
        [switch]$LocaleExplicit,
        [switch]$Compact,
        [string]$EntryScriptPath,
        [switch]$DryRun
    )
    Initialize-FreshWinTerminalEncoding
    $script:FreshWinTerminalCompactMode = [bool]$Compact
    $fixtureMode = $null -ne $PlatformProvider -or $null -ne $SessionProvider
    $windowsAvailable = if ($null -ne $PlatformProvider) { [bool](& $PlatformProvider) } elseif ($null -ne $SessionProvider) { $true } else { Test-FreshWinWindows }
    $platformName = if ($fixtureMode -and $windowsAvailable) { 'FixtureWindows' } else { Get-FreshWinPlatformName }
    # A first-launch language page must not inherit a stale process-wide locale.
    # The selected/configured locale is initialized again after this page.
    [void](Initialize-FreshWinLocalization -Locale $Locale)
    $effectiveLocaleSaver = $LocaleSaver
    $effectiveCompactModeSaver = $CompactModeSaver
    if ($DryRun) { $effectiveLocaleSaver = { param($selectedLocale) return $selectedLocale } }
    elseif ($fixtureMode -and $null -eq $effectiveLocaleSaver) { $effectiveLocaleSaver = { param($selectedLocale) return $selectedLocale } }
    if ($DryRun) { $effectiveCompactModeSaver = { param($compactMode) return [pscustomobject]@{ Status='Preview'; CompactMode=[bool]$compactMode; MutationPerformed=$false } } }
    elseif ($fixtureMode -and $null -eq $effectiveCompactModeSaver) { $effectiveCompactModeSaver = { param($compactMode) return [pscustomobject]@{ Status='Fixture'; CompactMode=[bool]$compactMode; MutationPerformed=$false } } }
    if (-not $windowsAvailable) {
        $unsupported = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home')) -Title (Get-FreshWinTerminalString 'terminal.startup.unsupportedTitle' 'Interactive FreshWin is unavailable on this platform') `
            -Description (Get-FreshWinTerminalString 'terminal.startup.unsupportedDescription' 'The shared terminal setup experience requires Windows 10 or Windows 11. This host can still run validate, catalog, parser, and fixture-driven tests.') `
            -Status @((Get-FreshWinTerminalString 'terminal.startup.detectedPlatform' 'Detected platform: {0}' @($platformName)), (Get-FreshWinTerminalString 'terminal.startup.noSimulation' 'No Windows state or installer result was simulated.')) `
            -ContextHelp @((Get-FreshWinTerminalString 'terminal.startup.unsupportedHelp' 'Run FreshWin help for cross-platform read-only commands.')) `
            -Commands @((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.exit' 'Exit'))) -Prompt (Get-FreshWinTerminalString 'terminal.startup.ended' 'Interactive session ended.')
        [void](Write-FreshWinTerminalPage -Page $unsupported -OutputWriter $OutputWriter)
        return [pscustomobject]@{ Status='Unsupported'; Platform=$platformName; Locale=$Locale; IsFixture=$fixtureMode }
    }

    $configuration = $null
    if (-not $fixtureMode -or $null -ne $ConfigurationProvider) {
        try { $configuration = if ($null -ne $ConfigurationProvider) { & $ConfigurationProvider } else { Get-FreshWinConfig } }
        catch { $configuration = $null }
        $configuredLocale = [string](Get-FreshWinPropertyValue -InputObject $configuration -Name 'locale' -Default '')
        $languageSelected = [bool](Get-FreshWinPropertyValue -InputObject $configuration -Name 'languageSelected' -Default $false)
        $configuredUi = Get-FreshWinPropertyValue -InputObject $configuration -Name 'ui' -Default $null
        if ([bool](Get-FreshWinPropertyValue -InputObject $configuredUi -Name 'compactMode' -Default $false)) {
            $script:FreshWinTerminalCompactMode = $true
        }
        if (-not $LocaleExplicit -and (-not $languageSelected -or [string]::IsNullOrWhiteSpace($configuredLocale))) {
            try { $selectedLocale = Show-FreshWinTerminalLanguage -InputProvider $InputProvider -OutputWriter $OutputWriter -LocaleSaver $effectiveLocaleSaver }
            catch {
                $languageFailure = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home'), (Get-FreshWinTerminalString 'terminal.home.entries.language.label' 'Language')) -Title (Get-FreshWinTerminalString 'terminal.startup.languageSaveFailed' 'Language selection could not be saved') -Description (Protect-FreshWinSensitiveText $_.Exception.Message) `
                    -ContextHelp @((Get-FreshWinTerminalString 'terminal.startup.languageSaveHelp' 'Correct the FreshWin configuration-directory permissions and try again.')) -Commands @((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.exit' 'Exit'))) -Prompt (Get-FreshWinTerminalString 'terminal.startup.ended' 'Interactive session ended.')
                [void](Write-FreshWinTerminalPage -Page $languageFailure -OutputWriter $OutputWriter)
                return [pscustomobject]@{ Status='Failed'; Platform=$platformName; Locale=$null; IsFixture=$fixtureMode; DryRun=[bool]$DryRun }
            }
            if ([string]::IsNullOrWhiteSpace([string]$selectedLocale)) {
                return [pscustomobject]@{ Status='LanguageSelectionRequired'; Platform=$platformName; Locale=$null; IsFixture=$fixtureMode; DryRun=[bool]$DryRun }
            }
            $Locale = $selectedLocale
        }
        elseif (-not $LocaleExplicit) { $Locale = $configuredLocale }
    }

    [void](Initialize-FreshWinLocalization -Locale $Locale)
    try {
        if ($fixtureMode -and $null -eq $SessionProvider) { throw 'A Windows platform fixture requires an explicit session fixture.' }
        $session = if ($null -ne $SessionProvider) { & $SessionProvider } else { New-FreshWinTerminalSessionContext -IncludeUpdates:$false }
        if ($null -eq $session) { throw 'The terminal session provider returned no session.' }
        foreach ($requiredProperty in @('Catalog','System','Network','Inventory','Profiles','IncludeUpdates')) {
            if (-not (Test-FreshWinHasProperty -InputObject $session -Name $requiredProperty)) { throw "The terminal session is missing '$requiredProperty'." }
        }
        if ($fixtureMode) { $DryRun = $true }
    }
    catch {
        Write-FreshWinStartupFailureDiagnostic -ErrorRecord $_ -OutputWriter $OutputWriter
        $failure = New-FreshWinTerminalPage -Breadcrumb @((Get-FreshWinTerminalString 'terminal.common.home' 'Home')) -Title (Get-FreshWinTerminalString 'terminal.startup.failedTitle' 'FreshWin could not start') -Description (Protect-FreshWinSensitiveText $_.Exception.Message) `
            -ContextHelp @((Get-FreshWinTerminalString 'terminal.startup.failedHelp' 'Run FreshWin validate and correct reported project errors.')) -Commands @((New-FreshWinTerminalCommand '0' (Get-FreshWinTerminalString 'terminal.common.exit' 'Exit'))) -Prompt (Get-FreshWinTerminalString 'terminal.startup.ended' 'Interactive session ended.')
        [void](Write-FreshWinTerminalPage -Page $failure -OutputWriter $OutputWriter)
        return [pscustomobject]@{ Status='Failed'; Error=$_.Exception.Message; Locale=$Locale }
    }

    $notice = $null
    while ($true) {
        [void](Write-FreshWinTerminalPage -Page (Get-FreshWinTerminalHomePage -Notice $notice -Session $session) -OutputWriter $OutputWriter -Clear:($null -eq $OutputWriter))
        $notice = $null
        $raw = Read-FreshWinTerminalInput -Prompt 'home' -InputProvider $InputProvider
        if ($null -eq $raw) { break }
        $key = ([string]$raw).Trim().ToUpperInvariant()
        try {
            switch ($key) {
                '1' { Show-FreshWinTerminalQuickSetup -Session $session -InputProvider $InputProvider -OutputWriter $OutputWriter -EntryScriptPath $EntryScriptPath -DryRun:$DryRun }
                '2' { Show-FreshWinTerminalDriversHardware -InputProvider $InputProvider -OutputWriter $OutputWriter }
                '3' { Show-FreshWinTerminalPackageCenter -Session $session -Center applications -InputProvider $InputProvider -OutputWriter $OutputWriter -EntryScriptPath $EntryScriptPath -DryRun:$DryRun }
                '4' { Show-FreshWinTerminalPackageCenter -Session $session -Center gaming -InputProvider $InputProvider -OutputWriter $OutputWriter -EntryScriptPath $EntryScriptPath -DryRun:$DryRun }
                '5' { Show-FreshWinTerminalPackageCenter -Session $session -Center developer -InputProvider $InputProvider -OutputWriter $OutputWriter -EntryScriptPath $EntryScriptPath -DryRun:$DryRun }
                '6' { Show-FreshWinTerminalPackageCenter -Session $session -Center security -InputProvider $InputProvider -OutputWriter $OutputWriter -EntryScriptPath $EntryScriptPath -DryRun:$DryRun }
                '7' { Show-FreshWinTerminalPackageCenter -Session $session -Center windows-runtimes -InputProvider $InputProvider -OutputWriter $OutputWriter -EntryScriptPath $EntryScriptPath -DryRun:$DryRun }
                '8' { Show-FreshWinTerminalDiagnostics -Session $session -InputProvider $InputProvider -OutputWriter $OutputWriter -DryRun:$DryRun }
                '9' { Show-FreshWinTerminalBackup -Session $session -InputProvider $InputProvider -OutputWriter $OutputWriter -EntryScriptPath $EntryScriptPath -DryRun:$DryRun }
                'A' { Show-FreshWinTerminalAssistant -Session $session -InputProvider $InputProvider -OutputWriter $OutputWriter -EntryScriptPath $EntryScriptPath -DryRun:$DryRun }
                'L' { $selectedLocale = Show-FreshWinTerminalLanguage -InputProvider $InputProvider -OutputWriter $OutputWriter -LocaleSaver $effectiveLocaleSaver -CompactModeSaver $effectiveCompactModeSaver -AllowCompactToggle; if ($selectedLocale) { $Locale = $selectedLocale; $notice = Get-FreshWinTerminalString 'terminal.language.changed' 'Language changed to {0}.' @($Locale) } }
                'U' { Show-FreshWinTerminalUpdateFreshWin -OutputWriter $OutputWriter -InputProvider $InputProvider }
                'H' { Show-FreshWinTerminalAbout -OutputWriter $OutputWriter }
                '0' { return [pscustomobject]@{ Status='Exited'; Platform=$platformName; Locale=$Locale; IsFixture=$fixtureMode; DryRun=[bool]$DryRun } }
                default { $notice = Get-FreshWinTerminalString 'terminal.home.unknownKey' "Unknown home key '{0}'. Choose 1-9, A, L, U, H, or 0." @($key) }
            }
        }
        catch { $notice = Protect-FreshWinSensitiveText $_.Exception.Message }
    }
    return [pscustomobject]@{ Status='Exited'; Platform=$platformName; Locale=$Locale; IsFixture=$fixtureMode; DryRun=[bool]$DryRun }
}
