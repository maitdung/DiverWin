Set-StrictMode -Version Latest

function Write-FreshWinCliData {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Data,
        [switch]$Json,
        [string[]]$Property
    )

    if ($Json) {
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $Data -Depth 30))
        return
    }
    if ($null -eq $Data) { return }
    $rendered = if ($Property -and $Property.Count -gt 0) {
        $Data | Format-Table -Property $Property -AutoSize | Out-String -Width 180
    } else {
        $Data | Format-List | Out-String -Width 180
    }
    Write-Host $rendered.TrimEnd()
}

function Write-FreshWinCliError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Command,
        [int]$ExitCode = 1,
        [switch]$Json
    )

    $safeMessage = Protect-FreshWinSensitiveText -Text $Message
    if ($Json) {
        [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject ([pscustomobject]@{
            ok = $false; command = $Command; exitCode = $ExitCode; error = $safeMessage
        })))
    } else {
        Write-Host $safeMessage -ForegroundColor Red
    }
}

function Write-FreshWinCliExecutionQueue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    $items = @($Plan.Items)
    Write-Host ("Executing {0} package{1}" -f $items.Count, $(if ($items.Count -eq 1) { '' } else { 's' }))
    $queuePosition = 0
    foreach ($item in $items) {
        $queuePosition++
        $name = [string](Get-FreshWinPropertyValue -InputObject $item.Package -Name 'name' -Default $item.PackageId)
        Write-Host ("[{0}/{1}] {2}  Waiting" -f $queuePosition, $items.Count, $name)
    }
}

function Write-FreshWinCliProgressEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Event)

    if ([string]$Event.Stage -eq 'COMPLETE') {
        Write-Host ("[{0}/{1}] {2}  {3}: {4}" -f $Event.Position, $Event.Total, $Event.Name, $Event.Status, $Event.Detail)
        return
    }
    $exitText = if ($null -ne $Event.ExitCode) { " Exit code: $($Event.ExitCode)." } else { '' }
    Write-Host ("[{0}/{1}] {2}  [{3}/6] {4} [{5}] {6}{7}" -f `
        $Event.Position, $Event.Total, $Event.Name, $Event.StageNumber, $Event.StageLabel, $Event.Status, $Event.Detail, $exitText)
}

function Get-FreshWinCliHelp {
    [CmdletBinding()]
    param(
        [switch]$Compact,
        [AllowNull()][string]$Command
    )

    $usage = 'Usage: pwsh ./FreshWin.ps1 <command> [values] [options]'
    if (-not [string]::IsNullOrWhiteSpace($Command)) {
        $requestedCommand = $Command.Trim().ToLowerInvariant()
        $aliases = @{
            '?'             = 'help'
            '--help'        = 'help'
            '-h'            = 'help'
            '--version'     = 'version'
            '-v'            = 'version'
            'list'          = 'catalog'
            'diagnostics'   = 'doctor'
        }
        if ($aliases.ContainsKey($requestedCommand)) { $requestedCommand = $aliases[$requestedCommand] }

        $commandHelp = @{
            'interactive' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 [--dry-run] [--locale <locale>]'
                Safety = 'Interactive review surface; system changes still require an explicit reviewed workflow and confirmation.'
                Platform = 'The terminal UI is supported on Windows 10/11. Non-Windows launches report Unsupported without simulating Windows.'
                Description = 'Open the localized terminal UI and navigate all FreshWin centers through the shared planner.'
                Examples = @('pwsh ./FreshWin.ps1 --dry-run', 'pwsh ./FreshWin.ps1 --locale vi-VN')
            }
            'validate' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 validate [--json]'
                Safety = 'Read-only; performs no network calls or Windows mutation.'
                Platform = 'Portable on Windows, macOS, and Linux with PowerShell 7; Windows PowerShell 5.1 is also supported on Windows.'
                Description = 'Validate module metadata, source parsing, manifests, dependencies, profiles, and locale parity.'
                Examples = @('pwsh ./FreshWin.ps1 validate', 'pwsh ./FreshWin.ps1 validate --json')
            }
            'catalog' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 catalog [--compact] [--json]'
                Safety = 'Read-only.'
                Platform = 'Portable; reads only the bundled trusted catalog.'
                Description = 'List catalog IDs and their category, source, risk, installation policy, and localized description.'
                Examples = @('pwsh ./FreshWin.ps1 catalog --compact', 'pwsh ./FreshWin.ps1 list --json')
            }
            'search' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 search <text> [--json]'
                Safety = 'Read-only. Search text is limited to 128 characters and must not contain control characters.'
                Platform = 'Portable; searches only bundled catalog metadata.'
                Description = 'Search IDs, names, publishers, tags, categories, and subcategories using literal case-insensitive text.'
                Examples = @('pwsh ./FreshWin.ps1 search browser', 'pwsh ./FreshWin.ps1 search "developer tools" --json')
            }
            'status' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 status [--include-updates] [--json]'
                Safety = 'Read-only system observation.'
                Platform = 'Windows provides live observations; other hosts return explicit Unsupported component states.'
                Description = 'Compose current system, hardware, network, software, update, driver, activation, security, and readiness status.'
                Examples = @('pwsh ./FreshWin.ps1 status', 'pwsh ./FreshWin.ps1 status --json')
            }
            'history' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 history [count] [--compact] [--json]'
                Safety = 'Read-only. It does not create, modify, or delete logs; legacy records are redacted again before display.'
                Platform = 'Portable; reads existing FreshWin user-local JSONL logs. Count defaults to 50 and is limited to 500.'
                Description = 'Show recent structured execution and process history from a bounded set of daily log files.'
                Examples = @('pwsh ./FreshWin.ps1 history', 'pwsh ./FreshWin.ps1 history 100 --json')
            }
            'doctor' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 doctor [--include-updates] [--json]'
                Safety = 'Read-only diagnostics; it does not repair or change the host.'
                Platform = 'Windows provides live observations; other hosts report unsupported Windows components.'
                Description = 'Aggregate diagnostic and health observations. The diagnostics alias has identical behavior.'
                Examples = @('pwsh ./FreshWin.ps1 doctor', 'pwsh ./FreshWin.ps1 diagnostics --json')
            }
            'apps' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 apps [--include-updates] [--json]'
                Safety = 'Read-only inventory.'
                Platform = 'Live inventory requires Windows and trusted scanner providers.'
                Description = 'Show detected installed applications and, when explicitly requested, observed package updates.'
                Examples = @('pwsh ./FreshWin.ps1 apps', 'pwsh ./FreshWin.ps1 apps --include-updates --json')
            }
            'drivers' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 drivers [--json]'
                Safety = 'Read-only device and driver inventory.'
                Platform = 'Live inventory requires Windows.'
                Description = 'Show driver health, category, version, priority, and missing/problem-device evidence.'
                Examples = @('pwsh ./FreshWin.ps1 drivers', 'pwsh ./FreshWin.ps1 drivers --json')
            }
            'updates' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 updates [--json]'
                Safety = 'Read-only Windows Update query; it does not install updates.'
                Platform = 'Live update state requires Windows.'
                Description = 'Show Windows Update service and pending-update observations.'
                Examples = @('pwsh ./FreshWin.ps1 updates', 'pwsh ./FreshWin.ps1 updates --json')
            }
            'gaming' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 gaming [--include-updates] [--json]'
                Safety = 'Read-only catalog-center view.'
                Platform = 'Accurate installed/update state requires Windows live inventory.'
                Description = 'Show Gaming Center packages with compatibility, source, risk, and detected state.'
                Examples = @('pwsh ./FreshWin.ps1 gaming', 'pwsh ./FreshWin.ps1 gaming --include-updates --json')
            }
            'developer' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 developer [--include-updates] [--json]'
                Safety = 'Read-only catalog-center view.'
                Platform = 'Accurate installed/update state requires Windows live inventory.'
                Description = 'Show Developer Center packages with compatibility, source, risk, and detected state.'
                Examples = @('pwsh ./FreshWin.ps1 developer', 'pwsh ./FreshWin.ps1 developer --json')
            }
            'security' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 security [--include-updates] [--json]'
                Safety = 'Read-only. FreshWin does not disable or weaken Windows security controls.'
                Platform = 'Live Defender, firewall, and Security Center observations require Windows.'
                Description = 'Show security application catalog state together with available Windows protection observations.'
                Examples = @('pwsh ./FreshWin.ps1 security', 'pwsh ./FreshWin.ps1 security --json')
            }
            'recommend' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 recommend [profile-id] [--include-updates] [--json]'
                Safety = 'Read-only recommendation; it does not queue or install packages.'
                Platform = 'Live compatibility and installed-state decisions require Windows.'
                Description = 'Compare a curated profile with current compatibility and observed package state. The default profile is essential.'
                Examples = @('pwsh ./FreshWin.ps1 recommend', 'pwsh ./FreshWin.ps1 recommend gaming --json')
            }
            'profile' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 profile <profile-id> [--dry-run] [--include-updates] [--yes]'
                Safety = 'Potentially mutating; uses the shared planner, shows the plan, and requires confirmation unless --yes is supplied.'
                Platform = 'Live planning and execution are Windows-only. Use --dry-run before an approved real run.'
                Description = 'Expand a curated profile and process it through normal dependency, detection, planning, execution, and verification.'
                Examples = @('pwsh ./FreshWin.ps1 profile essential --dry-run', 'pwsh ./FreshWin.ps1 profile gaming --yes')
            }
            'restore-profile' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 restore-profile <absolute-local-profile.json> [--dry-run] [--yes]'
                Safety = 'Potentially mutating; strictly validates the portable profile before using the shared planner.'
                Platform = 'Live planning and execution are Windows-only. The profile path must be absolute and local.'
                Description = 'Restore package choices and update policy from a FreshWin portable profile without trusting executable fields.'
                Examples = @('pwsh ./FreshWin.ps1 restore-profile C:\FreshWin\profiles\work.json --dry-run')
            }
            'plan' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 plan <package-id...> [--include-updates] [--output <new-file.json>] [--json]'
                Safety = 'Does not change Windows. Without --dry-run, --output may write one new plan artifact and never overwrites.'
                Platform = 'Planning from live installed state is Windows-only.'
                Description = 'Build a dependency-first plan with compatibility, detection, source, elevation, restart, manual, and blocked states.'
                Examples = @('pwsh ./FreshWin.ps1 plan git vscode', 'pwsh ./FreshWin.ps1 plan 7zip --json')
            }
            'install' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 install <package-id...> [--dry-run] [--include-updates] [--yes] [--register-resume]'
                Safety = 'Mutating on a real run; a reviewed plan and explicit confirmation are required. Manual items are never auto-executed.'
                Platform = 'Windows-only. Administrator-required items use a controlled, checkpoint-bound UAC handoff.'
                Description = 'Install eligible catalog packages through the shared queue, then refresh inventory and verify observed state.'
                Examples = @('pwsh ./FreshWin.ps1 install git vscode --dry-run', 'pwsh ./FreshWin.ps1 install 7zip --yes')
            }
            'backup-drivers' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 backup-drivers [absolute-requested-path] [--dry-run] [--yes]'
                Safety = 'On live Windows, the requested path is retained for audit only; output is written below protected %ProgramData%\FreshWin\DriverBackups and the actual path is reported. No copy is made to the requested path.'
                Platform = 'Windows-only and requires an administrator session for a real export.'
                Description = 'Export installed third-party drivers with the guarded PnPUtil workflow into a protected live-output directory.'
                Examples = @('pwsh ./FreshWin.ps1 backup-drivers D:\FreshWin-DriverBackup --dry-run')
            }
            'network-rescue' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 network-rescue [absolute-local-driver-folder] [--retry] [--json]'
                Safety = 'Read-only query and plan; it does not download or install drivers and writes no rescue bundle.'
                Platform = 'Live adapter and problem-device observations require Windows.'
                Description = 'Inspect network state and, when supplied, bounded local/USB INF matches, then return non-executing recovery guidance. --retry repeats at most three read-only probes.'
                Examples = @('pwsh ./FreshWin.ps1 network-rescue --retry', 'pwsh ./FreshWin.ps1 network-rescue D:\OfflineDrivers --retry --json')
            }
            'export-diagnostics' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 export-diagnostics [absolute-local-file.json] [--dry-run] [--json]'
                Safety = 'Writes one new privacy-redacted JSON report and refuses overwrite; --dry-run writes nothing.'
                Platform = 'Portable, with explicit Unsupported fields where Windows observations are unavailable.'
                Description = 'Collect diagnostics, redact sensitive values, and export the resulting report.'
                Examples = @('pwsh ./FreshWin.ps1 export-diagnostics C:\FreshWin\report.json --dry-run')
            }
            'ddu-plan' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 ddu-plan [--yes] [--output <new-checkpoint.json>] [--dry-run] [--json]'
                Safety = 'Advanced non-executing guidance only. FreshWin does not run DDU or perform driver cleanup. A checkpoint stores only validated plan state and never registers startup execution.'
                Platform = 'Useful live GPU evidence requires Windows; unsupported hosts remain explicit.'
                Description = 'Build guarded DDU recovery guidance. --yes acknowledges advanced risk but does not authorize execution; --output writes one new resumable plan checkpoint.'
                Examples = @('pwsh ./FreshWin.ps1 ddu-plan', 'pwsh ./FreshWin.ps1 ddu-plan --yes --output C:\FreshWin\ddu-checkpoint.json')
            }
            'resume' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 resume <absolute-checkpoint.json> [--checkpoint-hash <sha256>] [--dry-run] [--yes]'
                Safety = 'Potentially mutating after strict checkpoint and optional SHA-256 validation; current catalog and live state rebuild the plan.'
                Platform = 'Windows-only. RunOnce registration occurs only with explicit --register-resume.'
                Description = 'Continue eligible queue work from a validated checkpoint without trusting persisted executable or native-argument data.'
                Examples = @('pwsh ./FreshWin.ps1 resume C:\ProgramData\FreshWin\state\execution-checkpoint.json --dry-run')
            }
            'assistant' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 assistant <text> [--dry-run] [--yes] [--json]'
                Safety = 'Deterministic allowlisted intent parsing; mutating intents still use normal planning and confirmation.'
                Platform = 'Read-only intents degrade explicitly off Windows; installation and update execution are Windows-only.'
                Description = 'Dispatch supported local intents such as search, status, diagnostics, install, update, and profile recommendations.'
                Examples = @('pwsh ./FreshWin.ps1 assistant "search terminal"', 'pwsh ./FreshWin.ps1 assistant "install git and vscode" --dry-run')
            }
            'version' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 version [--json]'
                Safety = 'Read-only.'
                Platform = 'Portable.'
                Description = 'Show the FreshWin name and module version.'
                Examples = @('pwsh ./FreshWin.ps1 version', 'pwsh ./FreshWin.ps1 --version --json')
            }
            'update' = [pscustomobject]@{
                Usage = 'freshwin update [--yes] [--dry-run] [--json]'
                Safety = 'Checks protected release metadata first. Download and atomic installation require a second invocation with explicit --yes.'
                Platform = 'Windows-only for installation; the status check is read-only.'
                Description = 'Review the official FreshWin release status, then explicitly download, verify, stage, and invoke the protected rollback-capable installer.'
                Examples = @('freshwin update', 'freshwin update --yes', 'freshwin update --yes --dry-run --json')
            }
            'compact-mode' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 compact-mode [status|on|off] [--dry-run] [--json]'
                Safety = 'Status is read-only. On/off changes only ui.compactMode in the current user FreshWin configuration; --dry-run writes nothing.'
                Platform = 'Portable.'
                Description = 'Inspect or explicitly persist the terminal compact-presentation preference. The --compact switch remains invocation-only.'
                Examples = @('pwsh ./FreshWin.ps1 compact-mode status', 'pwsh ./FreshWin.ps1 compact-mode on --dry-run', 'pwsh ./FreshWin.ps1 compact-mode off')
            }
            'help' = [pscustomobject]@{
                Usage = 'pwsh ./FreshWin.ps1 help [command] [--compact]'
                Safety = 'Read-only.'
                Platform = 'Portable.'
                Description = 'Show generic help or detailed usage, safety, platform requirements, and examples for one supported command.'
                Examples = @('pwsh ./FreshWin.ps1 help', 'pwsh ./FreshWin.ps1 help install')
            }
        }

        if (-not $commandHelp.ContainsKey($requestedCommand)) {
            throw "Unknown help target '$Command'. Run FreshWin help to list supported commands."
        }
        $detail = $commandHelp[$requestedCommand]
        if ($Compact) {
            return @(
                "FreshWin command: $requestedCommand",
                "Usage: $($detail.Usage)",
                "Safety: $($detail.Safety)",
                "Platform: $($detail.Platform)",
                "Example: $(@($detail.Examples)[0])"
            ) -join [Environment]::NewLine
        }
        $exampleLines = @($detail.Examples | ForEach-Object { "  $_" })
        return (@(
            "FreshWin command: $requestedCommand", '',
            "Usage: $($detail.Usage)", '',
            "Purpose: $($detail.Description)",
            "Safety: $($detail.Safety)",
            "Platform: $($detail.Platform)", '',
            'Examples:'
        ) + $exampleLines) -join [Environment]::NewLine
    }

    if ($Compact) {
        return @(
            'FreshWin - Windows Post-Install Toolkit.',
            'Safe Windows inventory, planning, execution, and verification.',
            $usage,
            'Commands: validate catalog search status history doctor apps drivers updates update gaming developer security diagnostics',
            '          recommend profile restore-profile plan install resume backup-drivers network-rescue export-diagnostics ddu-plan assistant version help',
            'Options: --dry-run --yes --json --register-resume (RunOnce is never registered implicitly).',
            'Use help <command> for command-specific usage, safety, platform requirements, and examples.'
        ) -join [Environment]::NewLine
    }

    $localizedStatus = Get-FreshWinString -Key 'cli.commands.status' -Default 'Show the current scan and execution status.'
    $localizedDoctor = Get-FreshWinString -Key 'cli.commands.doctor' -Default 'Run diagnostics without changing the system.'
    $localizedRecommend = Get-FreshWinString -Key 'cli.commands.recommend' -Default 'Build a package plan from a curated profile.'
    $localizedInstall = Get-FreshWinString -Key 'cli.commands.install' -Default 'Queue one or more catalog packages for installation.'
    return @(
        'FreshWin - Windows Post-Install Toolkit.',
        'FreshWin safely inventories and prepares Windows 10/11 software and driver work.', '', $usage, '',
        'Commands:',
        '  validate                         Validate catalog, profiles, and localization',
        '  catalog                          List the trusted package catalog',
        '  search <text>                    Search the trusted package catalog',
        ('  status                            {0}' -f $localizedStatus),
        '  history [count]                  Show recent redacted JSONL execution history (maximum 500)',
        ('  doctor | diagnostics              {0}' -f $localizedDoctor),
        '  apps | drivers | updates          Show read-only inventory',
        '  update                           Review or explicitly install a verified FreshWin release',
        '  gaming | developer | security     Show catalog center state',
        ('  recommend [profile]                {0}' -f $localizedRecommend),
        '  profile <id>                     Review and apply a curated profile through the shared planner',
        '  restore-profile <path.json>      Validate and apply a portable profile through the shared planner',
        '  plan <package...>                Build a non-mutating dependency-first installation plan',
        ('  install <package...>               {0}' -f $localizedInstall),
        '  backup-drivers [requested-path]  Export drivers to protected ProgramData output; report actual path',
        '  network-rescue [folder]          Inspect local/USB INF matches and optionally retry read-only probes',
        '  export-diagnostics [path.json]   Write a privacy-redacted diagnostic report',
        '  ddu-plan                         Show advanced, non-executing DDU guidance',
        '  resume --resume <path>           Resume from a hash-validated checkpoint',
        '  assistant <command>              Dispatch an allowlisted intent through normal FreshWin interfaces',
        '  compact-mode [status|on|off]     Inspect or persist compact terminal presentation',
        '  version                          Show the FreshWin version',
        '  help [command]                   Show generic or command-specific help', '',
        'Options:',
        '  --dry-run                        Validate or preview without changing Windows',
        '  --include-updates                Include detected package updates',
        '  --retry                          Repeat at most three read-only network rescue probes',
        '  --profile <id>                   Select a recommendation profile',
        '  --output <path>                  Write a plan or command artifact to a safe path',
        '  --locale <locale>                en-US, vi-VN, zh-CN, or ja-JP',
        '  --json                           Emit command data as JSON',
        '  --yes, -y                        Confirm a previously reviewed operation',
        '  --register-resume                Explicitly register RunOnce when a completed queue requires reboot',
        '  --checkpoint-hash <sha256>       Verify a resume checkpoint (normally generated by FreshWin)',
        '  --compact                        Use compact help or tabular output',
        '  --verbose                        Enable detailed terminal logging', '',
        'FreshWin never executes manifest-provided commands. Manual and interactive vendor workflows remain manual.',
        'Unknown detection or verification is never converted to success.'
    ) -join [Environment]::NewLine
}

function Get-FreshWinCliCatalog {
    [CmdletBinding()]
    param()

    $catalog = Import-FreshWinPackageCatalog
    if (-not $catalog.IsValid) {
        throw "The package catalog is invalid: $(@($catalog.Errors.Error) -join ' ')"
    }
    return $catalog
}

function Get-FreshWinCliSystemContext {
    [CmdletBinding()]
    param([switch]$IncludeUpdates)

    $network = Get-FreshWinNetworkState
    $system = if (Test-FreshWinWindows) { Get-FreshWinSystemInfo -NetworkState $network } else { Get-FreshWinSystemInfo }
    $inventory = Get-FreshWinSoftwareInventorySnapshot -IncludeUpdates:$IncludeUpdates
    return [pscustomobject]@{
        Network   = $network
        System    = $system
        Inventory = $inventory
    }
}

function Get-FreshWinCliDiagnostics {
    [CmdletBinding()]
    param([switch]$IncludeUpdates)

    $operation = Get-Command -Name Get-FreshWinDiagnostics -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $operation) {
        $diagnostics = & $operation
        $healthCommand = Get-Command -Name Get-FreshWinHealthSummary -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
        $health = if ($null -ne $healthCommand) { & $healthCommand -Diagnostics $diagnostics } else { $null }
        $softwareInventory = Get-FreshWinSoftwareInventorySnapshot -IncludeUpdates:$IncludeUpdates
        return [pscustomobject][ordered]@{
            SchemaVersion = 'FreshWin.CliDiagnostics/1'
            GeneratedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Platform = Get-FreshWinPlatformName
            Diagnostics = $diagnostics
            HealthSummary = $health
            SoftwareInventory = $softwareInventory
            IncludePackageUpdates = [bool]$IncludeUpdates
            MutationPerformed = $false
        }
    }

    $context = Get-FreshWinCliSystemContext -IncludeUpdates:$IncludeUpdates
    $hardware = Get-FreshWinHardwareInfo
    $activation = Get-FreshWinActivationStatus
    $updates = Get-FreshWinWindowsUpdateState -IncludeDetails
    $drivers = Get-FreshWinDriverSummary
    $readiness = if (Test-FreshWinWindows) {
        Get-FreshWinWindows11Readiness -SystemInfo $context.System -HardwareInfo $hardware
    } else { Get-FreshWinWindows11Readiness }
    return [pscustomobject][ordered]@{
        GeneratedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Platform = Get-FreshWinPlatformName
        System = $context.System
        Hardware = $hardware
        Network = $context.Network
        Activation = $activation
        WindowsUpdate = $updates
        Drivers = $drivers
        Windows11Readiness = $readiness
        SoftwareInventory = $context.Inventory
        InstalledApplicationCount = $(if ($context.Inventory.Available) { @($context.Inventory.Items).Count } else { $null })
        SoftwareInventoryStatus = [string]$context.Inventory.Status
        MutationPerformed = $false
    }
}

function Get-FreshWinCliCenterData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('gaming','developer','security','applications','windows-runtimes','updates')][string]$Center,
        [switch]$IncludeUpdates,
        [AllowNull()][object]$Catalog,
        [AllowNull()][object]$Context
    )

    if ($null -eq $Catalog) { $Catalog = Get-FreshWinCliCatalog }
    if ($null -eq $Context) { $Context = Get-FreshWinCliSystemContext -IncludeUpdates:$IncludeUpdates }
    $packages = @(Get-FreshWinTerminalCenterPackages -Catalog $Catalog -Center $Center)
    return @($packages | ForEach-Object {
        $package = $_
        $compatibility = Get-FreshWinPackageCompatibility -Package $package -SystemInfo $Context.System
        $detection = Get-FreshWinPackageDetection -Package $package -Inventory $Context.Inventory -Compatibility $compatibility
        [pscustomobject][ordered]@{
            PackageId = [string]$package.id
            Name = [string]$package.name
            Category = [string]$package.category
            Subcategory = [string]$package.subcategory
            State = [string]$detection.State
            Badge = [string]$detection.Badge
            Compatibility = [string]$compatibility.Status
            Source = [string]$package.source.type
            RiskLevel = [string]$package.riskLevel
        }
    })
}

function Get-FreshWinInventoryUpdateQueryState {
    [CmdletBinding()]
    param([AllowNull()][object]$Inventory)

    $available = [bool](Get-FreshWinPropertyValue -InputObject $Inventory -Name 'Available' -Default $false)
    $updatesScanned = [bool](Get-FreshWinPropertyValue -InputObject $Inventory -Name 'UpdatesScanned' -Default $false)
    $updateSourcesScanned = @((Get-FreshWinPropertyValue -InputObject $Inventory -Name 'UpdateSourcesScanned' -Default @()) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    $errors = @((Get-FreshWinPropertyValue -InputObject $Inventory -Name 'Errors' -Default @()) | ForEach-Object {
        if ($null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_)) { Protect-FreshWinSensitiveText ([string]$_) }
    })
    return [pscustomobject][ordered]@{
        Known          = ($available -and $updatesScanned -and $updateSourcesScanned -contains 'winget')
        Available      = $available
        UpdatesScanned = $updatesScanned
        UpdateSourcesScanned = $updateSourcesScanned
        InventoryStatus = [string](Get-FreshWinPropertyValue -InputObject $Inventory -Name 'Status' -Default 'Unknown')
        Errors         = $errors
    }
}

function Get-FreshWinUnscannedUpdateTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [AllowNull()][string[]]$PackageIds,
        [AllowNull()][string[]]$UpdateSourcesScanned
    )

    $scanned = @($UpdateSourcesScanned | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    $requested = @($PackageIds | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
    return @($Catalog.Packages | Where-Object {
        ([string]$_.id).ToLowerInvariant() -in $requested -and
        ([string](Get-FreshWinPropertyValue (Get-FreshWinPropertyValue $_ 'source' ([pscustomobject]@{})) 'type' '')).ToLowerInvariant() -notin $scanned
    } | ForEach-Object { [string]$_.id })
}

function Resolve-FreshWinCliNewOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$AllowedExtensions,
        [switch]$AllowMissingParent
    )

    if (-not (Test-FreshWinLocalAbsolutePath -Path $Path)) {
        throw 'The output path must be an absolute local path.'
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($AllowedExtensions -notcontains [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()) {
        throw "The output path must use one of these extensions: $($AllowedExtensions -join ', ')."
    }
    if ([System.IO.File]::Exists($fullPath) -or [System.IO.Directory]::Exists($fullPath)) {
        throw "Refusing to overwrite existing output '$fullPath'."
    }
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw 'The output parent directory does not exist.'
    }
    $parentExists = [System.IO.Directory]::Exists($parent)
    if (-not $parentExists -and -not $AllowMissingParent) {
        throw 'The output parent directory does not exist.'
    }
    $existingAncestor = $parent
    while (-not [System.IO.Directory]::Exists($existingAncestor)) {
        $nextAncestor = [System.IO.Path]::GetDirectoryName($existingAncestor)
        if ([string]::IsNullOrWhiteSpace($nextAncestor) -or $nextAncestor -eq $existingAncestor) {
            throw 'The output parent directory ancestry could not be validated.'
        }
        $existingAncestor = $nextAncestor
    }
    $attributes = [System.IO.File]::GetAttributes($existingAncestor)
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The output parent directory must not be a reparse point.' }
    if (Test-FreshWinWindows) {
        $root = [System.IO.Path]::GetPathRoot($parent)
        $ancestor = Get-Item -LiteralPath $existingAncestor -Force -ErrorAction Stop
        while ($null -ne $ancestor) {
            if (($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "The output path cannot traverse reparse point '$($ancestor.FullName)'."
            }
            if ([string]::Equals($ancestor.FullName.TrimEnd([char]'\', [char]'/'), $root.TrimEnd([char]'\', [char]'/'), [StringComparison]::OrdinalIgnoreCase)) { break }
            $ancestor = $ancestor.Parent
        }
    }
    return $fullPath
}

function Invoke-FreshWinCliOptionalOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string[]]$CommandNames,
        [hashtable]$Parameters = @{}
    )

    $operation = $null
    foreach ($name in $CommandNames) {
        $operation = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $operation) { break }
    }
    if ($null -eq $operation) {
        return [pscustomobject][ordered]@{
            Component = $Component
            Status = 'Unavailable'
            Succeeded = $false
            IsSupported = $false
            MutationPerformed = $false
            Reason = "$Component is not available in this FreshWin build."
        }
    }
    $supportedParameters = @{}
    foreach ($key in $Parameters.Keys) {
        if ($operation.Parameters.ContainsKey([string]$key)) { $supportedParameters[[string]$key] = $Parameters[$key] }
    }
    return & $operation @supportedParameters
}

function Resolve-FreshWinCliNetworkDriverFolder {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-FreshWinLocalAbsolutePath -Path $Path)) {
        throw 'The local driver folder must be an absolute local path.'
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.Directory]::Exists($fullPath)) { throw 'The local driver folder does not exist.' }
    if (([System.IO.File]::GetAttributes($fullPath) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The local driver folder must not be a reparse point.'
    }
    return $fullPath
}

function Get-FreshWinCliNetworkRescueData {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$LocalDriverFolder,
        [switch]$Retry,
        [AllowNull()][scriptblock]$StateProvider,
        [AllowNull()][scriptblock]$PlanProvider,
        [AllowNull()][scriptblock]$OfflineDiagnosticsProvider,
        [AllowNull()][scriptblock]$RetryProvider
    )

    $state = if ($null -ne $StateProvider) { & $StateProvider $LocalDriverFolder }
        else { Invoke-FreshWinCliOptionalOperation -Component NetworkRescueState -CommandNames @('Get-FreshWinNetworkRescueState') -Parameters @{ LocalDriverFolder=$LocalDriverFolder } }
    $stateStatus = [string](Get-FreshWinPropertyValue $state 'Status' '')
    if ($stateStatus -in @('Unavailable','Unsupported','Error')) { return $state }

    $plan = if ($null -ne $PlanProvider) { & $PlanProvider $state }
        else { Invoke-FreshWinCliOptionalOperation -Component NetworkRescuePlan -CommandNames @('New-FreshWinNetworkRescuePlan') -Parameters @{ State=$state } }
    $offline = if ($null -ne $OfflineDiagnosticsProvider) { & $OfflineDiagnosticsProvider }
        else { Invoke-FreshWinCliOptionalOperation -Component OfflineNetworkDiagnostics -CommandNames @('Get-FreshWinOfflineNetworkDiagnostics') }
    $retryResult = $null
    if ($Retry) {
        $retryResult = if ($null -ne $RetryProvider) { & $RetryProvider }
            else { Invoke-FreshWinCliOptionalOperation -Component NetworkRescueRetry -CommandNames @('Invoke-FreshWinNetworkRescueRetry') -Parameters @{ MaximumAttempts=3; DelayMilliseconds=0 } }
    }
    return [pscustomobject][ordered]@{
        State              = $state
        Plan               = $plan
        OfflineDiagnostics = $offline
        Retry              = $retryResult
        MutationPerformed  = $false
    }
}

function Save-FreshWinCliDduCheckpointArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$DryRun
    )

    $outputPath = Resolve-FreshWinCliNewOutputPath -Path $Path -AllowedExtensions @('.json')
    $validation = Test-FreshWinDduRecoveryPlan -Plan $Plan
    if (-not $validation.Valid) { throw "The DDU plan cannot be checkpointed: $($validation.Errors -join '; ')" }
    if ($DryRun) {
        return [pscustomobject][ordered]@{ Status='Preview'; Path=$outputPath; MutationPerformed=$false }
    }
    $savedPath = Save-FreshWinDduRecoveryCheckpoint -Plan $Plan -Path $outputPath -Confirm:$false
    return [pscustomobject][ordered]@{ Status='Saved'; Path=$savedPath; MutationPerformed=$true }
}

function Test-FreshWinUiExecutionRequiresReboot {
    [CmdletBinding()]
    param([AllowNull()][object]$ExecutionResult)

    if ($null -eq $ExecutionResult) { return $false }
    if ([string](Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Status' -Default '') -eq 'REBOOT_REQUIRED') { return $true }
    $summary = Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Summary' -Default $null
    return [bool](Get-FreshWinPropertyValue -InputObject $summary -Name 'RebootRequired' -Default $false)
}

function Get-FreshWinResumeCommandText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EntryScriptPath,
        [Parameter(Mandatory = $true)][string]$CheckpointPath
    )

    $hostExecutable = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    return '{0} -NoLogo -NoProfile -File "{1}" resume "{2}"' -f $hostExecutable, $EntryScriptPath, $CheckpointPath
}

function New-FreshWinCliRebootEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$ExecutionResult,
        [Parameter(Mandatory = $true)][string]$CheckpointPath,
        [Parameter(Mandatory = $true)][string]$EntryScriptPath,
        [switch]$RegisterResume,
        [AllowNull()][object]$ExistingRegistration,
        [AllowNull()][object]$Elevation,
        [AllowNull()][scriptblock]$ResumeRegistrar
    )

    if (-not (Test-FreshWinUiExecutionRequiresReboot -ExecutionResult $ExecutionResult)) {
        throw 'A reboot envelope requires explicit reboot evidence from execution status or summary.'
    }
    if ([string]::IsNullOrWhiteSpace($CheckpointPath)) { throw 'A checkpoint path is required for reboot guidance.' }
    if ([string]::IsNullOrWhiteSpace($EntryScriptPath)) { throw 'The entry script path is required for reboot guidance.' }

    $registration = [pscustomobject][ordered]@{ Requested=[bool]$RegisterResume; Registered=$false; Status=$(if ($RegisterResume) { 'Pending' } else { 'NotRequested' }); Error=$null }
    if ($RegisterResume) {
        try {
            $registeredResult = if ($null -ne $ExistingRegistration) { $ExistingRegistration }
                elseif ($null -ne $ResumeRegistrar) { & $ResumeRegistrar $EntryScriptPath $CheckpointPath }
                else { Register-FreshWinResume -EntryScriptPath $EntryScriptPath -CheckpointPath $CheckpointPath -Confirm:$false }
            $registration.Registered = [bool](Get-FreshWinPropertyValue -InputObject $registeredResult -Name 'Registered' -Default $false)
            $registration.Status = if ($registration.Registered) { 'Registered' } else { 'NotRegistered' }
        }
        catch {
            $registration.Status = 'Failed'
            $registration.Error = Protect-FreshWinSensitiveText $_.Exception.Message
        }
    }

    return [pscustomobject][ordered]@{
        Status             = 'REBOOT_REQUIRED'
        ExecutionStatus    = [string](Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Status' -Default 'Unknown')
        PlanId             = [string](Get-FreshWinPropertyValue -InputObject (Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Plan' -Default $null) -Name 'Id' -Default (Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'PlanId' -Default ''))
        CheckpointPath      = $CheckpointPath
        ResumeCommand       = Get-FreshWinResumeCommandText -EntryScriptPath $EntryScriptPath -CheckpointPath $CheckpointPath
        ResumeRegistration  = $registration
        Summary             = Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Summary' -Default $null
        Execution           = $ExecutionResult
        Elevation           = $Elevation
    }
}

function Test-FreshWinElevatedHelperExecutionResult {
    [CmdletBinding()]
    param([AllowNull()][object]$ExecutionResult)

    if ($null -eq $ExecutionResult) { return $false }
    $status = [string](Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Status' -Default '')
    if ($status -in @('COMPLETED', 'DRY_RUN_COMPLETE', 'REBOOT_REQUIRED', 'INCOMPLETE')) { return $true }
    if ($status -ne 'COMPLETED_WITH_ISSUES') { return $false }

    $plan = Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Plan' -Default $null
    if ($null -eq $plan) { return $false }
    $failedAdminAttempts = @((Get-FreshWinPropertyValue -InputObject $plan -Name 'Items' -Default @()) | Where-Object {
        $requiresAdmin = [bool](Get-FreshWinPropertyValue -InputObject $_ -Name 'RequiresAdmin' -Default $false)
        $action = [string](Get-FreshWinPropertyValue -InputObject $_ -Name 'Action' -Default '')
        $state = [string](Get-FreshWinPropertyValue -InputObject $_ -Name 'State' -Default '')
        $result = Get-FreshWinPropertyValue -InputObject $_ -Name 'Result' -Default $null
        $stage = [string](Get-FreshWinPropertyValue -InputObject $result -Name 'Stage' -Default '')
        $requiresAdmin -and $action -in @('INSTALL', 'UPDATE', 'REPAIR') -and
            $stage -ne 'PrivilegePartition' -and
            $state -in @('FAILED', 'BLOCKED', 'ELEVATION_REQUIRED', 'UNKNOWN_VERIFICATION')
    })
    return $failedAdminAttempts.Count -eq 0
}

function Invoke-FreshWinCliPackageWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$PackageIds,
        [Parameter(Mandatory = $true)][object]$Parsed,
        [string]$EntryScriptPath,
        [switch]$PlanOnly,
        [AllowNull()][object]$Catalog,
        [AllowNull()][object]$Context
    )

    if (-not (Test-FreshWinWindows)) { throw 'Installation planning from live state is supported only on Windows. Use validate and mocked tests on this host.' }
    if ($PackageIds.Count -eq 0) { throw "$Command requires at least one package ID." }
    if ($null -eq $Catalog) { $Catalog = Get-FreshWinCliCatalog }
    if ($null -eq $Context) { $Context = Get-FreshWinCliSystemContext -IncludeUpdates:$Parsed.IncludeUpdates }
    $updatePolicy = if ($Parsed.IncludeUpdates) { 'include-updates' } else { 'missing-only' }
    $plan = New-FreshWinInstallPlan -PackageIds $PackageIds -Catalog $Catalog -SystemInfo $Context.System -Inventory $Context.Inventory -UpdatePolicy $updatePolicy -DryRun:$Parsed.DryRun
    if (-not [string]::IsNullOrWhiteSpace([string]$Parsed.OutputPath)) {
        $outputPath = Resolve-FreshWinCliNewOutputPath -Path ([string]$Parsed.OutputPath) -AllowedExtensions @('.json')
        if (-not $Parsed.DryRun) { [void](Save-FreshWinInstallPlan -Plan $plan -Path $outputPath) }
    }
    $planView = @($plan.Items | Select-Object PackageId, Action, Reason, SafetyLevel, RequiresAdmin, RestartImpact)
    if ($PlanOnly -or -not $Parsed.Json) {
        Write-FreshWinCliData -Data $planView -Json:$Parsed.Json -Property @('PackageId', 'Action', 'SafetyLevel', 'RequiresAdmin', 'RestartImpact', 'Reason')
    }
    if ($PlanOnly) { return [pscustomobject]@{ ExitCode=0; Command=$Command; Data=$plan; Error=$null } }

    if ($Parsed.Json -and -not $Parsed.Yes -and -not $Parsed.DryRun) {
        $confirmationData = [pscustomobject]@{ Status='ConfirmationRequired'; Plan=$plan; Message='Review the plan and repeat the command with --yes to authorize execution.' }
        Write-FreshWinCliData -Data $confirmationData -Json
        return [pscustomobject]@{ ExitCode=3; Command=$Command; Data=$confirmationData; Error='Explicit --yes is required for a mutating JSON command.' }
    }
    if (-not $Parsed.Yes -and -not $Parsed.DryRun) {
        $confirmation = Read-FreshWinInput -Prompt 'Execute this reviewed plan? Type YES' -AllowEmpty
        if ($confirmation -cne 'YES') {
            if ($Parsed.Json) { Write-FreshWinCliData -Data ([pscustomobject]@{ Status='Cancelled'; Plan=$plan }) -Json }
            return [pscustomobject]@{ ExitCode=3; Command=$Command; Data=$plan; Error='Installation cancelled.' }
        }
    }
    $contextIsAdmin = [bool](Get-FreshWinPropertyValue -InputObject $Context.System -Name 'Admin' -Default (Get-FreshWinPropertyValue -InputObject $Context.System -Name 'IsAdministrator' -Default $false))
    if (-not $Parsed.Json) { Write-FreshWinCliExecutionQueue -Plan $plan }
    $cliProgressCallback = {
        param($progressEvent)
        if (-not $Parsed.Json) { Write-FreshWinCliProgressEvent -Event $progressEvent }
    }
    $checkpointPath = if ($Parsed.DryRun) { $null }
        elseif ($contextIsAdmin) { Get-FreshWinProtectedCheckpointPath }
        else { Get-FreshWinDefaultCheckpointPath }
    $elevation = Get-FreshWinPlanElevationRequirement -Plan $plan
    if ($elevation.Required -and -not $Context.System.Admin -and -not $Parsed.DryRun) {
        if ([string]::IsNullOrWhiteSpace($EntryScriptPath)) { throw 'The entry script path is required to request controlled elevation.' }
        $elevationParameters = @{ Plan=$plan; EntryScriptPath=$EntryScriptPath; CheckpointPath=$checkpointPath; Wait=$true; Confirm=$false }
        [void](Get-Command -Name Invoke-FreshWinElevatedResume -ErrorAction Stop)
        $elevated = Invoke-FreshWinElevatedResume @elevationParameters
        $elevatedProcessExit = Get-FreshWinPropertyValue -InputObject $elevated -Name 'ProcessExitCode'
        $childResult = Get-FreshWinPropertyValue -InputObject $elevated -Name 'ChildResult' -Default $null
        $childResultMatches = $null -ne $childResult -and [string](Get-FreshWinPropertyValue $childResult 'planId' '') -eq [string]$plan.Id
        $childStatus = [string](Get-FreshWinPropertyValue $childResult 'status' '')
        $elevatedExit = if ($elevated.Started -and $null -ne $elevatedProcessExit -and [int]$elevatedProcessExit -eq 0 -and
            $childResultMatches -and $childStatus -in @('Succeeded','RebootRequired')) { 0 } else { 1 }
        $protectedCheckpointPath = [string](Get-FreshWinPropertyValue -InputObject $elevated -Name 'ProtectedCheckpointPath' -Default '')
        $elevatedCheckpoint = $null
        if (-not [string]::IsNullOrWhiteSpace($protectedCheckpointPath)) {
            try { $elevatedCheckpoint = Get-FreshWinExecutionCheckpoint -Path $protectedCheckpointPath } catch { $elevatedCheckpoint = $null }
        }
        $checkpointMatches = $null -ne $elevatedCheckpoint -and [string]$elevatedCheckpoint.planId -eq [string]$plan.Id
        if ($checkpointMatches -and ([string]$elevatedCheckpoint.status -eq 'REBOOT_REQUIRED' -or
            (Test-FreshWinCheckpointRequiresReboot -Checkpoint $elevatedCheckpoint))) {
            $checkpointExecution = [pscustomobject]@{
                Status=[string]$elevatedCheckpoint.status
                PlanId=[string]$plan.Id
                Summary=[pscustomobject]@{ RebootRequired=$true }
            }
            $rebootData = New-FreshWinCliRebootEnvelope -ExecutionResult $checkpointExecution `
                -CheckpointPath $protectedCheckpointPath -EntryScriptPath $EntryScriptPath `
                -RegisterResume:$Parsed.RegisterResume -Elevation $elevated
            Write-FreshWinCliData -Data $rebootData -Json:$Parsed.Json
            $rebootExit = if ($elevatedExit -ne 0 -or ($Parsed.RegisterResume -and -not $rebootData.ResumeRegistration.Registered)) { 1 } else { 0 }
            return [pscustomobject]@{ ExitCode=$rebootExit; Command=$Command; Data=$rebootData; Error=$(if ($rebootExit) { 'Execution or requested resume registration completed with issues.' } else { $null }) }
        }
        if ($elevatedExit -ne 0) {
            $childResultError = [string](Get-FreshWinPropertyValue $elevated 'ChildResultError' '')
            $fallbackReason = if ($childResultError) { "The protected child result could not be read: $childResultError" }
                elseif ($null -eq $childResult) { 'The elevated child exited before it could publish a protected execution result.' }
                else { 'Elevated execution did not complete successfully.' }
            $failureExecution = New-FreshWinElevatedFailureExecutionResult -Plan $plan -ChildResult $childResult `
                -ChildExitCode $elevatedProcessExit -FallbackReason $fallbackReason
            $failureReport = New-FreshWinExecutionReport -ExecutionResult $failureExecution -IncludeDetails:$Parsed.VerboseOutput
            Write-FreshWinCliData -Data $failureReport -Json:$Parsed.Json
            return [pscustomobject]@{ ExitCode=1; Command=$Command; Data=$failureExecution; Report=$failureReport; Error=$fallbackReason }
        }
        if ([string]::IsNullOrWhiteSpace($protectedCheckpointPath)) { throw 'The elevated helper did not report its protected checkpoint path.' }
        if (-not $checkpointMatches) { throw 'The elevated helper checkpoint is missing or does not match the reviewed plan.' }

        # Rebuild exclusively from the trusted catalog and refreshed state.
        # Admin actions that completed in the helper reconcile to SKIP; only
        # ordinary-user actions may execute in this parent phase.
        $Context = Get-FreshWinCliSystemContext -IncludeUpdates:$Parsed.IncludeUpdates
        $plan = Restore-FreshWinPlanFromCheckpoint -Checkpoint $elevatedCheckpoint -Catalog $Catalog -SystemInfo $Context.System -Inventory $Context.Inventory
        $includeUpdates = [bool]$Parsed.IncludeUpdates
        $data = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $Catalog -SystemInfo $Context.System -Inventory $Context.Inventory `
            -InventoryProvider { Get-FreshWinSoftwareInventorySnapshot -Refresh -IncludeUpdates:$includeUpdates } `
            -SystemInfoProvider { Get-FreshWinSystemInfo } -CheckpointPath $checkpointPath -ExecutionMode NonAdminOnly `
            -ProgressCallback $cliProgressCallback
    }
    else {
        $includeUpdates = [bool]$Parsed.IncludeUpdates
        $data = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $Catalog -SystemInfo $Context.System -Inventory $Context.Inventory -InventoryProvider { Get-FreshWinSoftwareInventorySnapshot -Refresh -IncludeUpdates:$includeUpdates } -SystemInfoProvider { Get-FreshWinSystemInfo } -CheckpointPath $checkpointPath -ProgressCallback $cliProgressCallback
    }
    $exitCode = if ($data.Status -in @('COMPLETED','DRY_RUN_COMPLETE','REBOOT_REQUIRED')) { 0 } else { 1 }
    if (Test-FreshWinUiExecutionRequiresReboot -ExecutionResult $data) {
        $rebootData = New-FreshWinCliRebootEnvelope -ExecutionResult $data -CheckpointPath $checkpointPath `
            -EntryScriptPath $EntryScriptPath -RegisterResume:$Parsed.RegisterResume
        Write-FreshWinCliData -Data $rebootData -Json:$Parsed.Json
        $rebootExit = if ($exitCode -ne 0 -or ($Parsed.RegisterResume -and -not $rebootData.ResumeRegistration.Registered)) { 1 } else { 0 }
        return [pscustomobject]@{ ExitCode=$rebootExit; Command=$Command; Data=$rebootData; Error=$(if ($rebootExit) { 'Execution or requested resume registration completed with issues.' } else { $null }) }
    }
    $executionReport = New-FreshWinExecutionReport -ExecutionResult $data -Progress @($data.Progress) -IncludeDetails:$Parsed.VerboseOutput
    Write-FreshWinCliData -Data $executionReport -Json:$Parsed.Json
    return [pscustomobject]@{ ExitCode=$exitCode; Command=$Command; Data=$data; Report=$executionReport; Error=$(if ($exitCode) { 'Execution completed with one or more unresolved items.' } else { $null }) }
}

function Get-FreshWinCliProfileWorkflowData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProfileId,
        [switch]$IncludeUpdates
    )
    $catalog = Get-FreshWinCliCatalog
    $context = Get-FreshWinCliSystemContext -IncludeUpdates:$IncludeUpdates
    $profiles = Import-FreshWinProfiles -Catalog $catalog
    $profile = Get-FreshWinProfile -Profiles $profiles -Id $ProfileId
    if ($null -eq $profile) { throw "Recommendation profile '$ProfileId' was not found." }
    $recommendations = @(Get-FreshWinRecommendations -Catalog $catalog -SystemInfo $context.System -Inventory $context.Inventory -ProfileId $ProfileId -Profiles $profiles)
    return [pscustomobject]@{
        Catalog = $catalog
        Context = $context
        Profiles = $profiles
        Profile = $profile
        Recommendations = $recommendations
        PackageIds = @($recommendations | ForEach-Object { [string]$_.PackageId } | Select-Object -Unique)
    }
}

function Invoke-FreshWinCliAssistantDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Intent,
        [Parameter(Mandatory = $true)][object]$Parsed,
        [string]$EntryScriptPath,
        [AllowNull()][object]$Catalog,
        [AllowNull()][object]$Context
    )
    if (-not [bool]$Intent.isValid) {
        Write-FreshWinCliData -Data $Intent -Json:$Parsed.Json
        return [pscustomobject]@{ ExitCode=2; Command='assistant'; Data=$Intent; Error=[string]$Intent.error }
    }

    $action = [string]$Intent.action
    if ($action -eq 'queue_install') {
        $ids = @($Intent.targets | ForEach-Object { ([string]$_).ToLowerInvariant() })
        return Invoke-FreshWinCliPackageWorkflow -Command assistant -PackageIds $ids -Parsed $Parsed -EntryScriptPath $EntryScriptPath
    }
    if ($action -eq 'queue_update') {
        $Parsed.IncludeUpdates = $true
        if ($null -eq $Catalog) { $Catalog = Get-FreshWinCliCatalog }
        if ($null -eq $Context) { $Context = Get-FreshWinCliSystemContext -IncludeUpdates }
        $updateState = Get-FreshWinInventoryUpdateQueryState -Inventory $Context.Inventory
        if (-not $updateState.Known) {
            $data = [pscustomobject][ordered]@{
                Intent=$Intent
                Dispatched=$false
                Status='UpdateStateUnknown'
                UpdateState=$updateState
                Result=@()
            }
            Write-FreshWinCliData -Data $data -Json:$Parsed.Json
            return [pscustomobject]@{ ExitCode=1; Command='assistant'; Data=$data; Error='Community WinGet update state is unknown because that update inventory scan did not complete.' }
        }
        $ids = @($Intent.targets | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $unscannedTargets = @(Get-FreshWinUnscannedUpdateTargets -Catalog $Catalog -PackageIds $ids -UpdateSourcesScanned $updateState.UpdateSourcesScanned)
        if ($unscannedTargets.Count -gt 0) {
            $data = [pscustomobject][ordered]@{
                Intent=$Intent
                Dispatched=$false
                Status='UpdateStateUnknown'
                UpdateState=$updateState
                ManualReviewTargets=$unscannedTargets
                Reason='The requested package source is outside the community WinGet update scan and remains unknown/manual.'
                Result=@()
            }
            Write-FreshWinCliData -Data $data -Json:$Parsed.Json
            return [pscustomobject]@{ ExitCode=1; Command='assistant'; Data=$data; Error=[string]$data.Reason }
        }
        if ($ids.Count -eq 0) {
            $ids = @(Get-FreshWinCliCenterData -Center updates -IncludeUpdates -Catalog $Catalog -Context $Context | Where-Object State -eq 'UpdateAvailable' | ForEach-Object PackageId)
        }
        if ($ids.Count -eq 0) {
            $data = [pscustomobject]@{ Intent=$Intent; Dispatched=$true; Status='NothingToDo'; Scope='community-winget'; UpdateSourcesScanned=$updateState.UpdateSourcesScanned; Result=@() }
            Write-FreshWinCliData -Data $data -Json:$Parsed.Json
            return [pscustomobject]@{ ExitCode=0; Command='assistant'; Data=$data; Error=$null }
        }
        return Invoke-FreshWinCliPackageWorkflow -Command assistant -PackageIds $ids -Parsed $Parsed -EntryScriptPath $EntryScriptPath -Catalog $Catalog -Context $Context
    }
    if ($action -eq 'recommend_profile') {
        $profileId = [string](Get-FreshWinPropertyValue -InputObject $Intent.parameters -Name 'profile' -Default $(if (@($Intent.targets).Count) { [string]$Intent.targets[0] } else { 'essential' }))
        if ($profileId -eq 'full') { $profileId = 'full-recommended' }
        $profileData = Get-FreshWinCliProfileWorkflowData -ProfileId $profileId -IncludeUpdates:$Parsed.IncludeUpdates
        return Invoke-FreshWinCliPackageWorkflow -Command assistant -PackageIds $profileData.PackageIds -Parsed $Parsed -EntryScriptPath $EntryScriptPath -Catalog $profileData.Catalog -Context $profileData.Context
    }
    if ($action -eq 'backup_drivers') {
        $data = [pscustomobject]@{
            Intent=$Intent; Dispatched=$false; Status='DestinationRequired'
            Reason='Assistant driver backup requires an explicit destination. Use backup-drivers <absolute-folder> after reviewing it.'
        }
        Write-FreshWinCliData -Data $data -Json:$Parsed.Json
        return [pscustomobject]@{ ExitCode=3; Command='assistant'; Data=$data; Error=$data.Reason }
    }

    $result = switch ($action) {
        'search_package' {
            $query = [string](Get-FreshWinPropertyValue -InputObject $Intent.parameters -Name 'query' -Default '')
            @(Find-FreshWinPackage -Catalog (Get-FreshWinCliCatalog) -Query $query)
        }
        'scan_drivers' { @(Get-FreshWinDriverInventory) }
        'list_drivers' { @(Get-FreshWinDriverInventory) }
        'get_hardware' { Get-FreshWinHardwareInfo }
        'get_status' { Get-FreshWinCliDiagnostics -IncludeUpdates:$Parsed.IncludeUpdates }
        'run_diagnostics' { Get-FreshWinCliDiagnostics -IncludeUpdates:$Parsed.IncludeUpdates }
        'list_installed_packages' { Get-FreshWinSoftwareInventorySnapshot -IncludeUpdates:$Parsed.IncludeUpdates }
        'list_updates' { Get-FreshWinWindowsUpdateState -IncludeDetails }
        'get_missing' {
            $profileData = Get-FreshWinCliProfileWorkflowData -ProfileId essential -IncludeUpdates:$Parsed.IncludeUpdates
            @(Get-FreshWinMissingRecommendations -Recommendations $profileData.Recommendations -IncludeUpdates:$Parsed.IncludeUpdates)
        }
        'open_section' {
            $section = [string](Get-FreshWinPropertyValue -InputObject $Intent.parameters -Name 'section' -Default $(if (@($Intent.targets).Count) { [string]$Intent.targets[0] } else { '' }))
            if ($section -in @('gaming','developer')) { @(Get-FreshWinCliCenterData -Center $section -IncludeUpdates:$Parsed.IncludeUpdates) }
            else { [pscustomobject]@{ Section=$section; Status='UnsupportedSection' } }
        }
        'show_help' { Get-FreshWinCliHelp -Compact:$Parsed.Compact }
        default { [pscustomobject]@{ Status='NotDispatched'; Reason="No safe dispatcher is registered for action '$action'." } }
    }
    $data = [pscustomobject]@{ Intent=$Intent; Dispatched=$true; Status='Completed'; Result=$result }
    Write-FreshWinCliData -Data $data -Json:$Parsed.Json
    return [pscustomobject]@{ ExitCode=0; Command='assistant'; Data=$data; Error=$null }
}

function Start-FreshWinInteractive {
    [CmdletBinding()]
    param(
        [string]$Locale = 'en-US',
        [string]$EntryScriptPath,
        [switch]$LocaleExplicit,
        [switch]$Compact,
        [switch]$DryRun
    )

    return Start-FreshWinTerminalSession -Locale $Locale -LocaleExplicit:$LocaleExplicit -Compact:$Compact -EntryScriptPath $EntryScriptPath -DryRun:$DryRun
}

function Invoke-FreshWinCliCompactMode {
    [CmdletBinding()]
    param(
        [ValidateSet('status','on','off')][string]$Mode = 'status',
        [switch]$DryRun,
        [string]$ConfigPath
    )

    $config = Get-FreshWinConfig -Path $ConfigPath
    $previous = [bool]$config.ui.compactMode
    if ($Mode -eq 'status') {
        return [pscustomobject][ordered]@{
            Status='Current'; CompactMode=$previous; PreviousCompactMode=$previous
            MutationPerformed=$false; ConfigPath=$(if ($ConfigPath) { [IO.Path]::GetFullPath($ConfigPath) } else { (Get-FreshWinPaths).ConfigPath })
        }
    }

    $requested = $Mode -eq 'on'
    if ($DryRun) {
        return [pscustomobject][ordered]@{
            Status='Preview'; CompactMode=$requested; PreviousCompactMode=$previous
            MutationPerformed=$false; ConfigPath=$(if ($ConfigPath) { [IO.Path]::GetFullPath($ConfigPath) } else { (Get-FreshWinPaths).ConfigPath })
        }
    }
    $saved = Set-FreshWinConfigCompactMode -CompactMode $requested -Path $ConfigPath
    return [pscustomobject][ordered]@{
        Status=$(if ($previous -eq $requested) { 'Unchanged' } else { 'Saved' })
        CompactMode=[bool]$saved.ui.compactMode; PreviousCompactMode=$previous
        MutationPerformed=$true; ConfigPath=$(if ($ConfigPath) { [IO.Path]::GetFullPath($ConfigPath) } else { (Get-FreshWinPaths).ConfigPath })
    }
}

function Invoke-FreshWinCli {
    [CmdletBinding()]
    param(
        [AllowNull()][string[]]$Arguments = @(),
        [string]$EntryScriptPath
    )

    $jsonRequested = @($Arguments | Where-Object { ([string]$_).ToLowerInvariant() -eq '--json' }).Count -gt 0
    $parsed = ConvertFrom-FreshWinCommandLine -Arguments $Arguments
    if (-not $parsed.Valid) {
        Write-FreshWinCliError -Message $parsed.Error -Command $parsed.Command -ExitCode 2 -Json:$jsonRequested
        return [pscustomobject]@{ ExitCode = 2; Command = $parsed.Command; Data = $null; Error = $parsed.Error }
    }

    $locale = if ($parsed.Locale) { $parsed.Locale } else {
        try {
            $configured = Get-FreshWinConfig
            if ($configured.locale) { [string]$configured.locale } else { 'en-US' }
        } catch { 'en-US' }
    }
    try { [void](Initialize-FreshWinLocalization -Locale $locale) } catch { }

    $command = ([string]$parsed.Command).ToLowerInvariant()
    if ($command -in @('--help', '-h', '/?')) { $command = 'help' }
    if ($command -in @('--version', '-v')) { $command = 'version' }
    $verboseMutationCommands = @('interactive','install','profile','restore-profile','resume','assistant','backup-drivers','export-diagnostics')
    if ($parsed.VerboseOutput -and -not $parsed.DryRun -and $command -in $verboseMutationCommands) {
        [void](Initialize-FreshWinLogger -VerboseTerminal)
    }

    # These values span the elevated helper's startup boundary. They are kept
    # outside the command switch so the failure path can publish the original
    # stage and exception without itself throwing.
    $elevatedHelperResultPath = $null
    $elevatedHelperProtectedReady = $false
    $elevatedHelperPlanId = ''
    $elevatedHelperPackageId = ''
    $elevatedHelperStage = 'ChildStartup'
    $elevatedHelperCheckpointPath = ''

    try {
        if ($parsed.Retry -and $command -ne 'network-rescue') {
            throw '--retry is supported only by network-rescue.'
        }
        switch ($command) {
            'interactive' {
                $data = Start-FreshWinInteractive -Locale $locale -LocaleExplicit:($null -ne $parsed.Locale) -Compact:$parsed.Compact -EntryScriptPath $EntryScriptPath -DryRun:$parsed.DryRun
                $exitCode = if ($data.Status -eq 'Failed') { 1 } elseif ($data.Status -eq 'LanguageSelectionRequired') { 3 } else { 0 }
                return [pscustomobject]@{ ExitCode = $exitCode; Command = $command; Data = $data; Error = $(if ($exitCode -eq 0) { $null } else { [string]$data.Status }) }
            }
            { $_ -in @('help', '?') } {
                if (@($parsed.Values).Count -gt 1) { throw 'help accepts at most one command name.' }
                $helpTarget = if (@($parsed.Values).Count -eq 1) { [string]$parsed.Values[0] } else { $null }
                [Console]::Out.WriteLine((Get-FreshWinCliHelp -Command $helpTarget -Compact:$parsed.Compact))
                return [pscustomobject]@{ ExitCode = 0; Command = 'help'; Data = $null; Error = $null }
            }
            'version' {
                $data = [pscustomobject]@{ Name = 'FreshWin'; Version = Get-FreshWinVersion }
                Write-FreshWinCliData -Data $data -Json:$parsed.Json
                return [pscustomobject]@{ ExitCode = 0; Command = $command; Data = $data; Error = $null }
            }
            'update' {
                if (@($parsed.Values).Count -gt 0) { throw 'update accepts no package names or positional values.' }
                $status = Get-FreshWinUpdateStatus
                if (-not $parsed.Yes) {
                    $data = [pscustomobject][ordered]@{
                        Status=[string]$status.Status; CurrentVersion=[string]$status.CurrentVersion
                        AvailableVersion=[string]$status.AvailableVersion; UpdateAvailable=[bool]$status.UpdateAvailable
                        Reason=[string]$status.Reason; MutationPerformed=$false
                        ReviewRequired=[bool]$status.UpdateAvailable
                        NextCommand=$(if ($status.UpdateAvailable) { 'freshwin update --yes' } else { $null })
                    }
                    Write-FreshWinCliData -Data $data -Json:$parsed.Json
                    return [pscustomobject]@{ ExitCode=0; Command=$command; Data=$data; Error=$null }
                }
                if (-not $status.UpdateAvailable) { throw "No reviewed FreshWin update is available. $($status.Reason)" }
                $data = if ($parsed.DryRun) { Invoke-FreshWinCoreUpdate -UpdateStatus $status -WhatIf } else { Invoke-FreshWinCoreUpdate -UpdateStatus $status -Confirm:$false }
                Write-FreshWinCliData -Data $data -Json:$parsed.Json
                return [pscustomobject]@{ ExitCode=0; Command=$command; Data=$data; Error=$null }
            }
            'compact-mode' {
                if (@($parsed.Values).Count -gt 1) { throw 'compact-mode accepts at most one value: status, on, or off.' }
                $mode = if (@($parsed.Values).Count -eq 1) { ([string]$parsed.Values[0]).ToLowerInvariant() } else { 'status' }
                if ($mode -notin @('status','on','off')) { throw 'compact-mode accepts only status, on, or off.' }
                $data = Invoke-FreshWinCliCompactMode -Mode $mode -DryRun:$parsed.DryRun
                Write-FreshWinCliData -Data $data -Json:$parsed.Json
                return [pscustomobject]@{ ExitCode=0; Command=$command; Data=$data; Error=$null }
            }
            'validate' {
                $data = Test-FreshWinProject
                Write-FreshWinCliData -Data $data -Json:$parsed.Json
                $exitCode = if ($data.IsValid) { 0 } else { 1 }
                return [pscustomobject]@{ ExitCode = $exitCode; Command = $command; Data = $data; Error = $null }
            }
            { $_ -in @('catalog', 'list') } {
                $catalog = Get-FreshWinCliCatalog
                $data = @($catalog.Packages | Select-Object id, name, category, subcategory, publisher,
                    @{N='source';E={$_.source.type}}, riskLevel, @{N='installMode';E={$_.install.mode}},
                    @{N='description';E={ Get-FreshWinString -Key ([string]$_.descriptionKey) -Default ([string]$_.name) }})
                $catalogColumns = if ($parsed.Compact) { @('id', 'name', 'source') } else { @('id', 'name', 'category', 'source', 'riskLevel', 'installMode') }
                Write-FreshWinCliData -Data $data -Json:$parsed.Json -Property $catalogColumns
                return [pscustomobject]@{ ExitCode = 0; Command = 'catalog'; Data = $data; Error = $null }
            }
            'search' {
                if (@($parsed.Values).Count -eq 0) { throw 'search requires text.' }
                $catalog = Get-FreshWinCliCatalog
                $data = @(Find-FreshWinPackage -Catalog $catalog -Query ($parsed.Values -join ' '))
                Write-FreshWinCliData -Data $data -Json:$parsed.Json -Property @('id', 'name', 'category', 'publisher')
                return [pscustomobject]@{ ExitCode = 0; Command = $command; Data = $data; Error = $null }
            }
            { $_ -in @('status', 'doctor', 'diagnostics') } {
                $data = Get-FreshWinCliDiagnostics -IncludeUpdates:$parsed.IncludeUpdates
                Write-FreshWinCliData -Data $data -Json:$parsed.Json
                return [pscustomobject]@{ ExitCode = 0; Command = $command; Data = $data; Error = $null }
            }
            'history' {
                if (@($parsed.Values).Count -gt 1) { throw 'history accepts at most one record count.' }
                $last = 50
                if (@($parsed.Values).Count -eq 1) {
                    $countText = [string]$parsed.Values[0]
                    if ($countText -notmatch '^\d{1,3}$') { throw 'history count must be an integer from 1 to 500.' }
                    $last = [int]$countText
                    if ($last -lt 1 -or $last -gt 500) { throw 'history count must be an integer from 1 to 500.' }
                }
                $records = @(Get-FreshWinLogHistory -Last $last)
                $data = [pscustomobject][ordered]@{
                    Status = if ($records.Count -gt 0) { 'Available' } else { 'Empty' }
                    Count = $records.Count
                    Records = $records
                    MutationPerformed = $false
                }
                if ($parsed.Json) { Write-FreshWinCliData -Data $data -Json }
                else {
                    Write-Host "FreshWin history: $($records.Count) record(s)"
                    $properties = if ($parsed.Compact) { @('TimestampUtc','Action','PackageId','Result') } else { @('TimestampUtc','Action','PackageId','Stage','Result','ExitCode','ErrorSummary') }
                    Write-FreshWinCliData -Data $records -Property $properties
                }
                return [pscustomobject]@{ ExitCode = 0; Command = $command; Data = $data; Error = $null }
            }
            'apps' {
                $data = Get-FreshWinSoftwareInventorySnapshot -IncludeUpdates:$parsed.IncludeUpdates
                if ($parsed.Json) { Write-FreshWinCliData -Data $data -Json }
                else {
                    Write-Host "Software inventory: $($data.Status) | available: $($data.Available) | items: $($data.ItemCount)"
                    Write-FreshWinCliData -Data @($data.Items) -Property @('DisplayName', 'Version', 'Source', 'UpdateAvailable', 'AvailableVersion')
                }
                return [pscustomobject]@{ ExitCode = 0; Command = $command; Data = $data; Error = $null }
            }
            'drivers' {
                $data = @(Get-FreshWinDriverInventory)
                Write-FreshWinCliData -Data $data -Json:$parsed.Json -Property @('Badge', 'Name', 'Category', 'DriverVersion', 'Priority', 'Health')
                return [pscustomobject]@{ ExitCode = 0; Command = $command; Data = $data; Error = $null }
            }
            'updates' {
                $data = Get-FreshWinWindowsUpdateState -IncludeDetails
                Write-FreshWinCliData -Data $data -Json:$parsed.Json
                return [pscustomobject]@{ ExitCode = 0; Command = $command; Data = $data; Error = $null }
            }
            { $_ -in @('gaming', 'developer') } {
                $data = @(Get-FreshWinCliCenterData -Center $command -IncludeUpdates:$parsed.IncludeUpdates)
                Write-FreshWinCliData -Data $data -Json:$parsed.Json -Property @('Badge','Name','State','Compatibility','Source','RiskLevel')
                return [pscustomobject]@{ ExitCode=0; Command=$command; Data=$data; Error=$null }
            }
            'security' {
                $packages = @(Get-FreshWinCliCenterData -Center security -IncludeUpdates:$parsed.IncludeUpdates)
                $status = Invoke-FreshWinCliOptionalOperation -Component SecurityStatus -CommandNames @('Get-FreshWinSecurityStatus')
                $data = [pscustomobject][ordered]@{
                    Status = $status
                    Packages = $packages
                    MutationPerformed = $false
                }
                Write-FreshWinCliData -Data $data -Json:$parsed.Json
                return [pscustomobject]@{ ExitCode=0; Command=$command; Data=$data; Error=$null }
            }
            'recommend' {
                $catalog = Get-FreshWinCliCatalog
                $context = Get-FreshWinCliSystemContext -IncludeUpdates:$parsed.IncludeUpdates
                $profiles = Import-FreshWinProfiles -Catalog $catalog
                $profileId = if ($parsed.Profile) { $parsed.Profile } elseif (@($parsed.Values).Count -gt 0) { [string]$parsed.Values[0] } else { 'essential' }
                $profile = Get-FreshWinProfile -Profiles $profiles -Id $profileId
                if ($null -eq $profile) { throw "Recommendation profile '$profileId' was not found." }
                $data = @(Get-FreshWinRecommendations -Catalog $catalog -SystemInfo $context.System -Inventory $context.Inventory -ProfileId $profileId -Profiles $profiles)
                Write-FreshWinCliData -Data $data -Json:$parsed.Json -Property @('PackageId', 'Selected', 'Reason')
                return [pscustomobject]@{ ExitCode = 0; Command = $command; Data = $data; Error = $null }
            }
            'profile' {
                if ($parsed.Profile -and @($parsed.Values).Count -gt 0) { throw 'Specify the profile ID either positionally or with --profile, not both.' }
                $profileId = if ($parsed.Profile) { [string]$parsed.Profile } elseif (@($parsed.Values).Count -eq 1) { ([string]$parsed.Values[0]).ToLowerInvariant() } else { '' }
                if ([string]::IsNullOrWhiteSpace($profileId)) { throw 'profile requires exactly one profile ID.' }
                $profileData = Get-FreshWinCliProfileWorkflowData -ProfileId $profileId -IncludeUpdates:$parsed.IncludeUpdates
                return Invoke-FreshWinCliPackageWorkflow -Command profile -PackageIds $profileData.PackageIds -Parsed $parsed -EntryScriptPath $EntryScriptPath -Catalog $profileData.Catalog -Context $profileData.Context
            }
            'restore-profile' {
                if ($parsed.Profile -or @($parsed.Values).Count -ne 1) {
                    throw 'restore-profile requires exactly one portable .json profile path.'
                }
                $catalog = Get-FreshWinCliCatalog
                $portableProfile = Import-FreshWinUserProfile -Path ([string]$parsed.Values[0]) -Catalog $catalog
                $profileIncludesUpdates = [string]$portableProfile.updatePolicy -eq 'include-updates'
                $parsed.IncludeUpdates = $profileIncludesUpdates
                $context = Get-FreshWinCliSystemContext -IncludeUpdates:$profileIncludesUpdates
                return Invoke-FreshWinCliPackageWorkflow -Command restore-profile -PackageIds @($portableProfile.NormalizedPackageIds) -Parsed $parsed -EntryScriptPath $EntryScriptPath -Catalog $catalog -Context $context
            }
            { $_ -in @('plan', 'install') } {
                $packageIds = @(ConvertTo-FreshWinPackageIdList -Tokens $parsed.Values)
                return Invoke-FreshWinCliPackageWorkflow -Command $command -PackageIds $packageIds -Parsed $parsed -EntryScriptPath $EntryScriptPath -PlanOnly:($command -eq 'plan')
            }
            'backup-drivers' {
                if (@($parsed.Values).Count -gt 1 -or ($parsed.OutputPath -and @($parsed.Values).Count -gt 0)) {
                    throw 'Specify exactly one driver backup destination, either positionally or with --output.'
                }
                $destination = if (@($parsed.Values).Count -eq 1) { [string]$parsed.Values[0] } elseif ($parsed.OutputPath) { [string]$parsed.OutputPath } else { Get-FreshWinRetainedArtifactDirectory -Category Drivers }
                if (-not [System.IO.Path]::IsPathRooted($destination) -or $destination -match '[\x00\r\n]') {
                    throw 'The driver backup destination must be an absolute directory.'
                }
                if ((Test-FreshWinWindows) -and -not (Test-FreshWinAdministrator) -and -not $parsed.DryRun) {
                    throw 'Driver backup requires an administrator PowerShell session.'
                }
                if (-not $parsed.Yes -and -not $parsed.DryRun) {
                    $confirmation = Read-FreshWinInput -Prompt 'Export installed drivers to a new contained folder? Type YES' -AllowEmpty
                    if ($confirmation -cne 'YES') { return [pscustomobject]@{ ExitCode=3; Command=$command; Data=$null; Error='Driver backup cancelled.' } }
                }
                $data = Invoke-FreshWinCliOptionalOperation -Component DriverBackup -CommandNames @('New-FreshWinDriverBackup') -Parameters @{ OutputRoot=$destination; Confirm=$false; WhatIf=[bool]$parsed.DryRun }
                Write-FreshWinCliData -Data $data -Json:$parsed.Json
                $exitCode = if ($data.Status -in @('Completed','FixtureVerified','Preview')) { 0 } else { 1 }
                return [pscustomobject]@{ ExitCode=$exitCode; Command=$command; Data=$data; Error=$(if ($exitCode) { [string](Get-FreshWinPropertyValue $data 'Reason' ($data.Errors -join ' ')) } else { $null }) }
            }
            'network-rescue' {
                if (@($parsed.Values).Count -gt 1) { throw 'network-rescue accepts at most one local driver folder.' }
                $folder = Resolve-FreshWinCliNetworkDriverFolder -Path $(if (@($parsed.Values).Count -eq 1) { [string]$parsed.Values[0] } else { $null })
                $data = Get-FreshWinCliNetworkRescueData -LocalDriverFolder $folder -Retry:$parsed.Retry
                $stateStatus = [string](Get-FreshWinPropertyValue $data 'Status' '')
                $stateUnavailable = $stateStatus -in @('Unavailable','Unsupported','Error')
                Write-FreshWinCliData -Data $data -Json:$parsed.Json
                return [pscustomobject]@{ ExitCode=$(if ($stateUnavailable) { 1 } else { 0 }); Command=$command; Data=$data; Error=$null }
            }
            'export-diagnostics' {
                if (@($parsed.Values).Count -gt 1 -or ($parsed.OutputPath -and @($parsed.Values).Count -gt 0)) {
                    throw 'Specify exactly one diagnostics output path, either positionally or with --output.'
                }
                $requestedPath = if (@($parsed.Values).Count -eq 1) { [string]$parsed.Values[0] } elseif ($parsed.OutputPath) { [string]$parsed.OutputPath } else {
                    Get-FreshWinDefaultArtifactPath -Category Exports -FileName ('FreshWin-Diagnostics-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.json')
                }
                $outputPath = Resolve-FreshWinCliNewOutputPath -Path $requestedPath -AllowedExtensions @('.json') -AllowMissingParent
                $report = Get-FreshWinCliDiagnostics -IncludeUpdates:$parsed.IncludeUpdates
                $safeReport = if ($null -ne (Get-Command Protect-FreshWinPrivacyData -ErrorAction SilentlyContinue)) { Protect-FreshWinPrivacyData -InputObject $report } else { Protect-FreshWinSensitiveData -InputObject $report }
                if ($parsed.DryRun) { $data = [pscustomobject]@{ Status='Preview'; Path=$outputPath; Report=$safeReport; MutationPerformed=$false } }
                else {
                    [void](Write-FreshWinJsonFile -Path $outputPath -Value $safeReport -Depth 30 -CreateNew)
                    $data = [pscustomobject]@{ Status='Exported'; Path=$outputPath; Report=$safeReport; MutationPerformed=$true }
                }
                Write-FreshWinCliData -Data $data -Json:$parsed.Json
                return [pscustomobject]@{ ExitCode=0; Command=$command; Data=$data; Error=$null }
            }
            'ddu-plan' {
                if (@($parsed.Values).Count -gt 0) { throw 'ddu-plan does not accept positional values.' }
                $dduCommand = Get-Command -Name New-FreshWinDduRecoveryPlan -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
                $plan = if ($null -ne $dduCommand) {
                    & $dduCommand -AcknowledgeAdvancedRisk:$parsed.Yes
                } else {
                    Get-FreshWinDduWorkflow -AcknowledgeAdvancedRisk:$parsed.Yes
                }
                $data = if (-not [string]::IsNullOrWhiteSpace([string]$parsed.OutputPath)) {
                    $checkpoint = Save-FreshWinCliDduCheckpointArtifact -Plan $plan -Path ([string]$parsed.OutputPath) -DryRun:$parsed.DryRun
                    [pscustomobject][ordered]@{ Plan=$plan; Checkpoint=$checkpoint; MutationPerformed=[bool]$checkpoint.MutationPerformed }
                } else { $plan }
                Write-FreshWinCliData -Data $data -Json:$parsed.Json
                return [pscustomobject]@{ ExitCode=0; Command=$command; Data=$data; Error=$null }
            }
            'resume' {
                if (-not (Test-FreshWinWindows)) { throw 'Execution resume is supported only on Windows.' }
                if (@($parsed.Values).Count -gt 1 -or ($parsed.ResumePath -and @($parsed.Values).Count -gt 0)) {
                    throw 'Specify exactly one resume checkpoint, either positionally or with --resume.'
                }
                $resumePath = [string]$parsed.ResumePath
                if ([string]::IsNullOrWhiteSpace($resumePath) -and @($parsed.Values).Count -eq 1) {
                    $resumePath = [string]$parsed.Values[0]
                }
                if (-not (Test-FreshWinLocalAbsolutePath -Path $resumePath)) { throw 'resume requires one absolute local checkpoint path.' }
                $resumePath = [System.IO.Path]::GetFullPath($resumePath)
                if ($parsed.ElevatedHelper -and -not (Test-FreshWinAdministrator)) { throw 'The elevated helper did not receive administrator rights.' }
                if ($parsed.ElevatedHelper) { $elevatedHelperStage = 'LoadCheckpoint' }
                $expectedHash = if (-not [string]::IsNullOrWhiteSpace([string]$parsed.CheckpointHash)) { [string]$parsed.CheckpointHash } else { $null }
                $checkpoint = Get-FreshWinExecutionCheckpoint -Path $resumePath -ExpectedSha256 $expectedHash
                if ($null -eq $checkpoint) { throw 'Execution checkpoint was not found.' }
                if ($parsed.ElevatedHelper) {
                    $elevatedHelperPlanId = [string]$checkpoint.planId
                    $elevatedHelperPackageId = [string](@($checkpoint.requestedPackageIds)[0])
                    $elevatedHelperStage = 'ProtectedState'
                    $elevatedHelperResultPath = Get-FreshWinProtectedExecutionResultPath -HandoffId ([string]$parsed.HandoffId)
                    $elevatedHelperCheckpointPath = Get-FreshWinProtectedCheckpointPath -ReaderSid ([string]$parsed.CallerSid)
                    $elevatedHelperProtectedReady = $true
                    [void](Save-FreshWinElevatedExecutionResult -HandoffId ([string]$parsed.HandoffId) -Result ([pscustomobject]@{
                        PlanId=$elevatedHelperPlanId; Status='Started'; Stage='LoadCatalog'; PackageId=$elevatedHelperPackageId
                        Reason='The elevated helper validated the reviewed checkpoint and initialized protected result state.'
                        ExceptionType=''; ExceptionMessage=''; ChildExitCode=$null; LogPath=''
                        CheckpointPath=$elevatedHelperCheckpointPath; Items=@(); Summary=$null
                    }))
                    $elevatedHelperStage = 'LoadCatalog'
                }
                $catalog = Get-FreshWinCliCatalog
                if ($parsed.ElevatedHelper) { $elevatedHelperStage = 'ScanCurrentState' }
                $context = Get-FreshWinCliSystemContext -IncludeUpdates:($checkpoint.updatePolicy -eq 'include-updates')
                if ($parsed.ElevatedHelper) { $elevatedHelperStage = 'RestorePlan' }
                $plan = Restore-FreshWinPlanFromCheckpoint -Checkpoint $checkpoint -Catalog $catalog -SystemInfo $context.System -Inventory $context.Inventory
                if ($parsed.DryRun) { $plan.DryRun = $true }
                $planView = @($plan.Items | Select-Object PackageId, Action, Reason, SafetyLevel, RequiresAdmin, RestartImpact)
                if (-not $parsed.Json) {
                    Write-FreshWinCliData -Data $planView -Property @('PackageId', 'Action', 'SafetyLevel', 'RequiresAdmin', 'RestartImpact', 'Reason')
                }
                if (-not $parsed.ElevatedHelper -and -not $parsed.Yes -and -not $parsed.DryRun -and -not [bool]$checkpoint.dryRun) {
                    if ($parsed.Json) {
                        $confirmationData = [pscustomobject]@{ Status='ConfirmationRequired'; Plan=$plan; Message='Review the rebuilt plan and repeat with --yes to authorize resume.' }
                        Write-FreshWinCliData -Data $confirmationData -Json
                        return [pscustomobject]@{ ExitCode=3; Command=$command; Data=$confirmationData; Error='Explicit --yes is required for a mutating JSON resume.' }
                    }
                    $confirmation = Read-FreshWinInput -Prompt 'Resume this rebuilt and reviewed plan? Type YES' -AllowEmpty
                    if ($confirmation -cne 'YES') {
                        if ($parsed.Json) { Write-FreshWinCliData -Data ([pscustomobject]@{ Status='Cancelled'; Plan=$plan }) -Json }
                        return [pscustomobject]@{ ExitCode = 3; Command = $command; Data = $plan; Error = 'Resume cancelled.' }
                    }
                }
                $resumeElevation = Get-FreshWinPlanElevationRequirement -Plan $plan
                $resumeExecutionMode = if ($parsed.ElevatedHelper) { 'AdminOnly' } else { 'All' }
                if (-not $parsed.ElevatedHelper -and $resumeElevation.Required -and -not [bool]$context.System.Admin -and -not [bool]$plan.DryRun) {
                    if ([string]::IsNullOrWhiteSpace($EntryScriptPath)) { throw 'The entry script path is required to request controlled elevation.' }
                    $elevationParameters = @{
                        Plan=$plan
                        EntryScriptPath=$EntryScriptPath
                        CheckpointPath=(Get-FreshWinDefaultCheckpointPath)
                        Wait=$true
                        Confirm=$false
                    }
                    [void](Get-Command -Name Invoke-FreshWinElevatedResume -ErrorAction Stop)
                    $elevated = Invoke-FreshWinElevatedResume @elevationParameters
                    $elevatedProcessExit = Get-FreshWinPropertyValue -InputObject $elevated -Name 'ProcessExitCode'
                    $childResult = Get-FreshWinPropertyValue -InputObject $elevated -Name 'ChildResult' -Default $null
                    $childResultMatches = $null -ne $childResult -and [string](Get-FreshWinPropertyValue $childResult 'planId' '') -eq [string]$plan.Id
                    $childStatus = [string](Get-FreshWinPropertyValue $childResult 'status' '')
                    $elevatedExit = if ($elevated.Started -and $null -ne $elevatedProcessExit -and [int]$elevatedProcessExit -eq 0 -and
                        $childResultMatches -and $childStatus -in @('Succeeded','RebootRequired')) { 0 } else { 1 }
                    $protectedCheckpointPath = [string](Get-FreshWinPropertyValue -InputObject $elevated -Name 'ProtectedCheckpointPath' -Default '')
                    $elevatedCheckpoint = $null
                    if (-not [string]::IsNullOrWhiteSpace($protectedCheckpointPath)) {
                        try { $elevatedCheckpoint = Get-FreshWinExecutionCheckpoint -Path $protectedCheckpointPath } catch { $elevatedCheckpoint = $null }
                    }
                    $checkpointMatches = $null -ne $elevatedCheckpoint -and [string]$elevatedCheckpoint.planId -eq [string]$plan.Id
                    if ($checkpointMatches -and ([string]$elevatedCheckpoint.status -eq 'REBOOT_REQUIRED' -or
                        (Test-FreshWinCheckpointRequiresReboot -Checkpoint $elevatedCheckpoint))) {
                        $checkpointExecution = [pscustomobject]@{
                            Status=[string]$elevatedCheckpoint.status
                            PlanId=[string]$plan.Id
                            Summary=[pscustomobject]@{ RebootRequired=$true }
                        }
                        $rebootData = New-FreshWinCliRebootEnvelope -ExecutionResult $checkpointExecution `
                            -CheckpointPath $protectedCheckpointPath -EntryScriptPath $EntryScriptPath `
                            -RegisterResume:$parsed.RegisterResume -Elevation $elevated
                        Write-FreshWinCliData -Data $rebootData -Json:$parsed.Json
                        $rebootExit = if ($elevatedExit -ne 0 -or ($parsed.RegisterResume -and -not $rebootData.ResumeRegistration.Registered)) { 1 } else { 0 }
                        return [pscustomobject]@{ ExitCode=$rebootExit; Command=$command; Data=$rebootData; Error=$(if ($rebootExit) { 'Execution or requested resume registration completed with issues.' } else { $null }) }
                    }
                    if ($elevatedExit -ne 0) {
                        $childResultError = [string](Get-FreshWinPropertyValue $elevated 'ChildResultError' '')
                        $fallbackReason = if ($childResultError) { "The protected child result could not be read: $childResultError" }
                            elseif ($null -eq $childResult) { 'The elevated child exited before it could publish a protected execution result.' }
                            else { 'Elevated resume did not complete successfully.' }
                        $failureExecution = New-FreshWinElevatedFailureExecutionResult -Plan $plan -ChildResult $childResult `
                            -ChildExitCode $elevatedProcessExit -FallbackReason $fallbackReason
                        $failureReport = New-FreshWinExecutionReport -ExecutionResult $failureExecution -IncludeDetails:$parsed.VerboseOutput
                        Write-FreshWinCliData -Data $failureReport -Json:$parsed.Json
                        return [pscustomobject]@{ ExitCode=1; Command=$command; Data=$failureExecution; Report=$failureReport; Error=$fallbackReason }
                    }
                    if (-not $checkpointMatches) { throw 'The elevated resume checkpoint is missing or does not match the reviewed plan.' }
                    $checkpoint = $elevatedCheckpoint
                    $context = Get-FreshWinCliSystemContext -IncludeUpdates:($checkpoint.updatePolicy -eq 'include-updates')
                    $plan = Restore-FreshWinPlanFromCheckpoint -Checkpoint $checkpoint -Catalog $catalog -SystemInfo $context.System -Inventory $context.Inventory
                    $resumeExecutionMode = 'NonAdminOnly'
                }
                # The hash-bound user checkpoint is read-only in the elevated helper.
                # Writing it with administrator rights would make its parent directory
                # a privileged junction/TOCTOU target.
                $resumeContextIsAdmin = [bool](Get-FreshWinPropertyValue -InputObject $context.System -Name 'Admin' -Default (Get-FreshWinPropertyValue -InputObject $context.System -Name 'IsAdministrator' -Default $false))
                $executionCheckpointPath = if ([bool]$plan.DryRun) { $null } elseif ($parsed.ElevatedHelper -or $resumeContextIsAdmin) {
                    if ($parsed.ElevatedHelper -and -not [string]::IsNullOrWhiteSpace($elevatedHelperCheckpointPath)) {
                        $elevatedHelperCheckpointPath
                    }
                    elseif ($null -ne (Get-Command -Name Get-FreshWinProtectedCheckpointPath -ErrorAction SilentlyContinue)) {
                        Get-FreshWinProtectedCheckpointPath -ReaderSid $(if ($parsed.ElevatedHelper) { [string]$parsed.CallerSid } else { $null })
                    }
                    else { throw 'The protected elevated checkpoint provider is unavailable.' }
                } else { Get-FreshWinDefaultCheckpointPath }
                $resumeIncludesUpdates = $checkpoint.updatePolicy -eq 'include-updates'
                if (-not $parsed.Json) { Write-FreshWinCliExecutionQueue -Plan $plan }
                $resumeProgressCallback = {
                    param($progressEvent)
                    if (-not $parsed.Json) { Write-FreshWinCliProgressEvent -Event $progressEvent }
                }
                if ($parsed.ElevatedHelper) { $elevatedHelperStage = 'PackageExecution' }
                $data = Invoke-FreshWinExecutionPlan -Plan $plan -Catalog $catalog -SystemInfo $context.System -Inventory $context.Inventory -InventoryProvider { Get-FreshWinSoftwareInventorySnapshot -Refresh -IncludeUpdates:$resumeIncludesUpdates } -SystemInfoProvider { Get-FreshWinSystemInfo } -CheckpointPath $executionCheckpointPath -ExecutionMode $resumeExecutionMode -ProgressCallback $resumeProgressCallback
                $resumeSucceeded = if ($parsed.ElevatedHelper) {
                    Test-FreshWinElevatedHelperExecutionResult -ExecutionResult $data
                } else { $data.Status -in @('COMPLETED', 'DRY_RUN_COMPLETE', 'REBOOT_REQUIRED') }
                if ($parsed.ElevatedHelper) {
                    $elevatedHelperStage = 'PublishResult'
                    $childReport = New-FreshWinExecutionReport -ExecutionResult $data -Progress @($data.Progress) -IncludeDetails:$false
                    $childProblem = @($childReport.Items | Where-Object { $_.Outcome -in @('Failed','Manual','Unknown verification') } | Select-Object -First 1)
                    $childStatus = if (Test-FreshWinUiExecutionRequiresReboot -ExecutionResult $data) { 'RebootRequired' }
                        elseif ($resumeSucceeded) { 'Succeeded' } else { 'CompletedWithIssues' }
                    $childStage = if ($childProblem.Count -eq 1 -and [string]$childProblem[0].FailedStage) { [string]$childProblem[0].FailedStage } else { 'Complete' }
                    $childReason = if ($childProblem.Count -eq 1) { [string]$childProblem[0].Reason } else { 'The elevated execution phase completed and published its protected result.' }
                    $childPackageId = if ($childProblem.Count -eq 1) { [string]$childProblem[0].PackageId } else { $elevatedHelperPackageId }
                    $childLogPath = ''
                    try {
                        $loggerVariable = Get-Variable -Name FreshWinLoggerContext -Scope Script -ErrorAction SilentlyContinue
                        if ($null -ne $loggerVariable -and $null -ne $loggerVariable.Value -and
                            [IO.Directory]::Exists([string]$loggerVariable.Value.LogDirectory)) {
                            $childLogPath = Get-FreshWinLogPath -Context $loggerVariable.Value
                        }
                    } catch { $childLogPath = '' }
                    [void](Save-FreshWinElevatedExecutionResult -HandoffId ([string]$parsed.HandoffId) -Result ([pscustomobject]@{
                        PlanId=$elevatedHelperPlanId; Status=$childStatus; Stage=$childStage; PackageId=$childPackageId
                        Reason=$childReason; ExceptionType=''; ExceptionMessage=''
                        ChildExitCode=$(if ($resumeSucceeded) { 0 } else { 1 }); LogPath=$childLogPath
                        CheckpointPath=$executionCheckpointPath; Items=@($childReport.Items); Summary=$childReport.Summary
                    }))
                }
                if (Test-FreshWinUiExecutionRequiresReboot -ExecutionResult $data) {
                    $rebootData = New-FreshWinCliRebootEnvelope -ExecutionResult $data -CheckpointPath $executionCheckpointPath `
                        -EntryScriptPath $EntryScriptPath -RegisterResume:$parsed.RegisterResume
                    Write-FreshWinCliData -Data $rebootData -Json:$parsed.Json
                    $rebootExit = if (-not $resumeSucceeded -or ($parsed.RegisterResume -and -not $rebootData.ResumeRegistration.Registered)) { 1 } else { 0 }
                    return [pscustomobject]@{ ExitCode=$rebootExit; Command=$command; Data=$rebootData; Error=$(if ($rebootExit) { 'Execution or requested resume registration completed with issues.' } else { $null }) }
                }
                $resumeReport = New-FreshWinExecutionReport -ExecutionResult $data -Progress @($data.Progress) -IncludeDetails:$parsed.VerboseOutput
                Write-FreshWinCliData -Data $resumeReport -Json:$parsed.Json
                return [pscustomobject]@{ ExitCode = $(if ($resumeSucceeded) { 0 } else { 1 }); Command = $command; Data = $data; Report=$resumeReport; Error = $null }
            }
            'assistant' {
                if (@($parsed.Values).Count -eq 0) { throw 'assistant requires a command to parse.' }
                $intent = Invoke-FreshWinAssistantProvider -InputText ($parsed.Values -join ' ')
                return Invoke-FreshWinCliAssistantDispatch -Intent $intent -Parsed $parsed -EntryScriptPath $EntryScriptPath
            }
            default { throw "Unknown command '$command'. Run FreshWin help." }
        }
    }
    catch {
        $caughtError = $_
        $message = Protect-FreshWinSensitiveText -Text $caughtError.Exception.Message
        if ($parsed.ElevatedHelper -and $elevatedHelperProtectedReady -and
            -not [string]::IsNullOrWhiteSpace($elevatedHelperPlanId)) {
            # Never let the diagnostic handoff replace or hide the original
            # failure. No user-writable fallback is used if protected state is
            # unavailable.
            try {
                $failureLogPath = ''
                $loggerVariable = Get-Variable -Name FreshWinLoggerContext -Scope Script -ErrorAction SilentlyContinue
                if ($null -ne $loggerVariable -and $null -ne $loggerVariable.Value -and
                    [IO.Directory]::Exists([string]$loggerVariable.Value.LogDirectory)) {
                    $failureLogPath = Get-FreshWinLogPath -Context $loggerVariable.Value
                }
                [void](Save-FreshWinElevatedExecutionResult -HandoffId ([string]$parsed.HandoffId) -Result ([pscustomobject]@{
                    PlanId=$elevatedHelperPlanId; Status='Failed'; Stage=$elevatedHelperStage; PackageId=$elevatedHelperPackageId
                    Reason=$message; ExceptionType=[string]$caughtError.Exception.GetType().FullName
                    ExceptionMessage=$message; ChildExitCode=1; LogPath=$failureLogPath
                    CheckpointPath=$elevatedHelperCheckpointPath; Items=@(); Summary=$null
                }))
            } catch { }
        }
        Write-FreshWinCliError -Message $message -Command $command -ExitCode 1 -Json:$parsed.Json
        return [pscustomobject]@{ ExitCode = 1; Command = $command; Data = $null; Error = $message }
    }
}
