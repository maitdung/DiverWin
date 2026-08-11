# FreshWin

FreshWin is a safety-first PowerShell assistant for assessing a fresh Windows 10 or Windows 11 installation, selecting trusted applications, planning changes, and carrying out only the operations the user approved. Package data is declarative: catalog entries describe trusted package-manager identifiers, compatibility, detection, verification, restart impact, and risk. They do not contain arbitrary scripts.

FreshWin is designed for Windows. Its parser, catalog, localization, planning, security, and fixture-driven tests also run on macOS and Linux; those hosts do not prove that Windows APIs or installers work.

## Requirements

- Windows 10 or Windows 11 for live scanning, WinGet installation, optional features, elevation, and resume-after-reboot integration.
- PowerShell 7 is recommended. Windows PowerShell 5.1 is the declared minimum; its CI result remains pending until the Windows workflow runs.
- WinGet/App Installer 1.29 or newer for live WinGet inventory. Older redirected tables can truncate package identifiers, so update Microsoft App Installer before using live WinGet-backed inventory.
- An interactive administrator approval when a selected operation truly needs elevation. FreshWin does not bypass UAC.
- A protected installation below `%ProgramFiles%` for any elevated mutation. Read-only commands and `--dry-run` may run from a normal checkout, but FreshWin refuses to execute privileged project/catalog code from a user-writable directory.

No API key, cloud account, or credential is required for the deterministic assistant.

## Quick start

### Local Windows installation

Until FreshWin has an official release location and a clean-machine acceptance result, install only from a reviewed local checkout. From a normal, non-administrator PowerShell in the repository root, run:

```powershell
.\install.cmd
```

The installer validates the local project, requests UAC only for the installation phase, stages and validates the copied tree below `%ProgramFiles%`, registers only the protected shim directory `%ProgramFiles%\FreshWin\bin` once on the machine `PATH`, and verifies `Get-Command freshwin` in a new normal Windows PowerShell process. The core directory itself is not a PATH entry, so `FreshWin.ps1` cannot shadow the shim. It does not change any persistent execution-policy scope. Open a new PowerShell or Windows Terminal and launch from any directory with:

```powershell
freshwin
freshwin help
freshwin status
freshwin install vscode --dry-run
```

The installed `freshwin.cmd` launcher applies `ExecutionPolicy Bypass` only to its child Windows PowerShell process and only dispatches to the colocated protected `%ProgramFiles%\FreshWin\FreshWin.ps1`. FreshWin still performs its protected-source ACL validation before privileged work.

To uninstall from any directory, run:

```powershell
freshwin-uninstall
```

Uninstall requests UAC, removes only the protected application tree and its exact machine `PATH` entry, and preserves user configuration, logs, exports, backups, and downloaded artifacts. There is intentionally no runnable placeholder remote-install command. The production packaging, verification model, publishing steps, and clean-VM acceptance boundary are documented in [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

### Repository checkout

From the repository root, the following commands are read-only or dry-run safe:

```powershell
pwsh -NoProfile -File ./FreshWin.ps1 help
pwsh -NoProfile -File ./FreshWin.ps1 validate
pwsh -NoProfile -File ./FreshWin.ps1 status
pwsh -NoProfile -File ./FreshWin.ps1 recommend essential
pwsh -NoProfile -File ./FreshWin.ps1 install git,vscode --dry-run
```

On Windows, both supported hosts use the same entrypoint:

```powershell
powershell.exe -NoLogo -NoProfile -File .\FreshWin.ps1 help
pwsh.exe       -NoLogo -NoProfile -File .\FreshWin.ps1 help
```

For a real operation that may elevate, use the local installer above. It creates `%ProgramFiles%\FreshWin` with normal inherited Program Files ACLs; users should not manually weaken or replace those ACLs. FreshWin validates that tree before requesting or accepting elevated execution.

Run `help <command>` before relying on a command in unattended automation. A dry run validates catalog resolution and creates a plan but must not start installers, enable Windows features, alter the registry, or claim verification success.

## Command surface

| Command | Purpose | Mutation policy |
| --- | --- | --- |
| `help [command]` | Show command and safety guidance. | Never mutates. |
| `validate` | Validate module metadata, catalog, dependencies, profiles, and locale parity. | Never mutates. |
| `catalog` | List catalog packages and source/risk metadata. | Never mutates. |
| `search <text>` | Search IDs, names, publishers, tags, categories, and subcategories with bounded single-line text. | Never mutates. |
| `status`, `doctor`, `diagnostics` | Inspect Windows, hardware, network, activation, updates, software, drivers, security, and readiness. | Query-only. |
| `history [count]` | Show recent redacted execution/process records from existing JSONL logs. | Query-only; defaults to 50 and permits at most 500 records. |
| `apps`, `drivers`, `updates` | Show focused live inventory. | Query-only. |
| `gaming`, `developer`, `security` | Show catalog-center compatibility and detected state. | Query-only. |
| `recommend [profile]` | Compare a profile with compatibility and installed state. | Never mutates. |
| `profile <id>` | Build and optionally execute a curated profile through the shared planner. | Mutating; supports `--dry-run`. |
| `restore-profile <path.json>` | Strictly validate and apply a portable FreshWin profile through the shared planner. | Mutating; supports `--dry-run`. |
| `plan <package-id...>` | Resolve dependencies, compatibility, detection, source, elevation, and restart impact. | Never changes Windows; `--output` may write a new plan file. |
| `install <package-id...>` | Execute an approved plan, then verify observed state. | Mutating; supports `--dry-run`. |
| `resume <checkpoint>` | After a required reboot is observed, rebuild a plan from the current trusted catalog and continue eligible work. | Potentially mutating after validation; same-boot retry is refused. |
| `backup-drivers <absolute-local-directory>` | Export third-party drivers with PnPUtil and verify the resulting manifest. On live Windows, the supplied path is retained only as an audited request; privileged output is redirected to a protected `%ProgramData%\FreshWin\DriverBackups` child and the actual path is reported. Nothing is copied to the requested path. | Mutating; explicit confirmation and admin required. |
| `network-rescue [folder] [--retry]` | Inspect network state and bounded local/USB INF matches; optionally run at most three read-only probes. | Query/plan only. |
| `export-diagnostics <path.json>` | Write a privacy-redacted report to a new local file. | Writes only the requested artifact; supports `--dry-run`. |
| `ddu-plan [--output <new-checkpoint.json>]` | Build guarded advanced recovery guidance without running DDU; optionally save only the validated non-executing plan state. | Plan/checkpoint only. |
| `assistant <text>` | Convert constrained language into an allowlisted FreshWin intent. | Intent only; mutating intents require confirmation. |
| `compact-mode [status\|on\|off]` | Inspect or persist the current user's terminal compact-presentation preference. | User-local configuration only; `--dry-run` writes nothing. |

Common switches include `--dry-run`, `--include-updates`, `--json`, `--yes`, `--output`, `--locale`, `--verbose`, and `--compact`. `--compact` affects only that invocation; use `compact-mode on` or the Language page's `C` action to persist the preference. Resume paths must be absolute, local, and non-device paths. A reboot-bound checkpoint records the observed Windows boot session and cannot be resumed until that session changes. The elevated-helper switch is internal and requires a SHA-256-bound checkpoint. RunOnce registration happens only with explicit `--register-resume`.

See [CLI reference](docs/CLI.md) for command expectations and [Safety model](docs/SAFETY.md) before unattended use.

The module also exposes review-oriented operations for driver backup, network rescue, Security Center status, redacted diagnostics, pre-reset preparation, and advanced DDU recovery planning. These APIs deliberately distinguish provider fixtures from live Windows observations and do not make DDU cleanup or Windows reset executable. See [Operations guide](docs/OPERATIONS.md).

## What FreshWin will not do

- Execute command strings, scripts, or shell fragments from a package manifest.
- Download and run an unverified vendor executable just because a URL exists.
- Silently install a package whose workflow is marked manual or interactive.
- Guess that an installation succeeded. A completed process and verified installed state are separate outcomes.
- Bypass Windows 11 hardware requirements, product activation, UAC, antivirus choices, or vendor licensing.
- Treat a macOS fixture test as a successful Windows integration test.

## Data and privacy

By default, per-user configuration, logs, caches, and the reserved updates directory live below the current user's local application-data `FreshWin` directory. The exported staging API still requires an explicit `.zip` destination and never applies an update. Privileged execution checkpoints move to an ACL-protected `%ProgramData%\FreshWin\state` location; they are content-hash-bound and store no executable paths or native arguments. Temporary work uses the operating-system temporary directory. Logs are JSON Lines and redact common credential fields and token patterns, but users should still avoid passing secrets as package names, assistant text, or command-line arguments.

FreshWin has no reason to read browser profiles, credential stores, SSH keys, cloud credentials, or unrelated user files.

## Testing

The repository includes a dependency-free PowerShell harness:

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1
```

On Windows, live query-only integration tests are deliberately opt-in:

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1 -IncludeWindowsIntegration
```

The portable suite is also intended to run under Windows PowerShell 5.1:

```powershell
powershell.exe -NoLogo -NoProfile -File .\tests\Run-Tests.ps1
```

Skipped Windows tests are reported as skipped; they are never converted into passes. See [Testing](docs/TESTING.md) and [macOS limitations](docs/MACOS-LIMITATIONS.md).

## Project guides

- [Architecture](docs/ARCHITECTURE.md)
- [Safety and trust model](docs/SAFETY.md)
- [CLI reference](docs/CLI.md)
- [Operations and recovery workflows](docs/OPERATIONS.md)
- [Catalog contribution](docs/CATALOG.md)
- [Testing](docs/TESTING.md)
- [macOS limitations](docs/MACOS-LIMITATIONS.md)
- [Contributing](CONTRIBUTING.md)
#   D i v e r W i n  
 