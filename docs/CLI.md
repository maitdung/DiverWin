# CLI reference

After local installation with `.\install.cmd`, the stable Windows command is `freshwin`. The protected entrypoint remains `%ProgramFiles%\FreshWin\FreshWin.ps1`, but users do not need to invoke it directly or bypass policy manually. The launcher forwards the original command arguments to that entrypoint. Use `freshwin help` on the installed version as the final authority for exact options.

## Read-only commands

`help [command]` prints usage, safety classification, platform requirements, and examples.

`validate` validates module metadata, source parsing, catalog schema/semantics, dependency graph, profiles, and localization parity. It performs no network calls or Windows mutations.

`catalog` lists available packages with IDs, categories, source type, risk level, install policy, and compatibility metadata.

`search <text>` searches catalog ID, name, publisher, tags, category, and subcategory. Search text is limited to 128 characters and control characters are rejected.

`status` gathers supported machine state. On non-Windows hosts it reports explicit unsupported components instead of simulating Windows. Live WinGet inventory requires a trusted WinGet/App Installer client version 1.29 or newer; update Microsoft App Installer if the client is older because redirected tables may truncate package identifiers.

`doctor` and `diagnostics` compose read-only system, hardware, network, security, driver, update, activation, and readiness observations. `apps`, `drivers`, and `updates` show focused inventories. `gaming`, `developer`, and `security` show their catalog-center state.

`history [count]` reads existing user-local JSONL logs and shows the newest records (50 by default, at most 500). It scans at most 31 daily files, ignores malformed records and files larger than 16 MB, rejects a reparse-point log directory, and applies the current secret-redaction policy again before rendering legacy records. The command never creates, modifies, or deletes a log. Use `--json` for the structured `TimestampUtc`, `Version`, `OsBuild` (when present), `Action`, `PackageId`, `Stage`, `Result`, `ExitCode`, and `ErrorSummary` fields.

`recommend [profile]` compares profile membership, compatibility, and installed state. The default policy recommends missing/broken software; updates require an explicit include-updates policy.

`compact-mode [status|on|off]` reads or explicitly persists `ui.compactMode` in the current user's normalized FreshWin configuration. `compact-mode on --dry-run` and `compact-mode off --dry-run` preview the requested value without creating or changing the configuration. In the terminal UI, open `L` (Language) and choose `C` to toggle the same preference. The `--compact` switch remains invocation-only and does not persist anything.

`plan <package-id...>` expands dependencies, detects conflicts, resolves source availability, and reports blocked/manual/elevation/restart items without executing them.

`network-rescue [absolute-local-folder] [--retry]` inspects adapter/problem-device state and bounded local/USB INF matches, then returns a non-executing plan; `--retry` performs at most three read-only probes and it does not write a rescue bundle. `ddu-plan [--output <new-checkpoint.json>]` creates advanced non-executing guidance and may save only a validated plan-state checkpoint. That checkpoint never registers startup execution or restarts Windows. Neither command downloads or installs a driver.

Application update views and the Assistant `update` intent report only the community `winget` source scanned by FreshWin. An empty result is shown only after `UpdatesScanned=true` with `UpdateSourcesScanned` containing `winget`; provider failures return `UpdateStateUnknown`. Microsoft Store and other unscanned-source update requests remain unknown/manual rather than being reported as current.

When execution status or its summary requires a reboot, CLI output switches to a reboot envelope containing the actual checkpoint path, an exact resume command, the underlying execution status/summary, and a structured RunOnce registration result. `--register-resume` remains explicit; the envelope does not turn `COMPLETED_WITH_ISSUES` into a successful exit status. The terminal renders the same checkpoint boundary before returning from direct-admin, elevated-helper, or post-helper execution.

## Potentially mutating commands

`install <package-id...>` creates and reviews a plan, then executes eligible items. Use `--dry-run` first in unattended workflows. Manual or interactive records remain manual; unknown installed state is blocked rather than treated as missing.

`resume <absolute-checkpoint-path>` validates the checkpoint envelope and IDs, reloads the current trusted catalog, re-scans current state, and creates a new executable plan. For a reboot-bound checkpoint, the current Windows boot-session timestamp must differ from the recorded one; running the resume command before restarting is refused. Resume does not trust persisted source/executable fields.

`assistant <text>` returns or dispatches an allowlisted intent. Examples include `assistant "install git and vscode"`, `assistant "search terminal"`, and `assistant "status"`. Installation/update/profile intents require confirmation and use the same planner as direct commands.

`profile <id>` expands a curated profile through the same recommendation, planning, confirmation, execution, and verification engine as `install`.

`restore-profile <absolute-local-profile.json>` strictly validates a portable profile exported by FreshWin, rejects unknown/duplicate package IDs and schema extensions, then sends its choices through that same engine.

`backup-drivers [absolute-local-directory]` uses the guarded PnPUtil export workflow after confirmation. The requested path defaults to the current user's Downloads known folder under `FreshWin\Drivers` and may be overridden. On a live Windows export, that path is retained as `RequestedOutputRoot` for the audit record; it is not a privileged write destination. FreshWin redirects the export to a new protected child below `%ProgramData%\FreshWin\DriverBackups`, reports the actual `OutputRoot` and `BackupPath`, and does not copy the result into the requested directory. Provider-backed test fixtures may use their isolated caller-supplied root and do not represent the live ACL behavior. `export-diagnostics [absolute-local-file.json]` defaults to `Downloads\FreshWin\Exports`, permits an explicit override, writes a new privacy-redacted report, and refuses overwrite. Both commands support `--dry-run`.

## Common options

- `--dry-run`: validate and report; do not mutate.
- `--verbose`: include diagnostic detail. Secret redaction still applies.
- `--compact`: reduce presentation for this invocation without changing semantics or persisted configuration.
- `--include-updates`: include explicitly observed catalog updates in policy.
- `--json`: emit structured JSON, including structured error output.
- `--yes`, `-y`: confirm an already reviewed operation without another prompt.
- `--output <absolute-local-path>`: write a new supported artifact; never overwrite.
- `--locale <en-US|vi-VN|zh-CN|ja-JP>`: override locale for this invocation.
- `--resume <absolute-path>`: internal-compatible resume form accepted by the argument parser.
- `--checkpoint-hash <sha256>`: bind resume input to exact checkpoint bytes.
- `--register-resume`: explicitly create a visible one-time RunOnce entry only when reboot remains required.
- `--elevated-helper`: internal only. It is invalid without a validated resume checkpoint.

Package IDs use lower-case letters, numbers, periods, underscores, and hyphens. Multiple IDs may be passed as separate values or a comma-separated selection. Checkpoint and output paths are local absolute filesystem paths; UNC, device, mapped-network, reparse-point, and overwrite targets are rejected where the operation writes or resumes state.

Read-only commands and dry runs may execute from a normal checkout. Any process that already has administrator rights, and every automatic UAC handoff, requires FreshWin to be installed below `%ProgramFiles%` with a protected, non-reparse ACL tree. This prevents elevated execution of a project or catalog that an unprivileged process can rewrite.

## Local install and uninstall

There is no official online FreshWin release URL yet. From a reviewed local checkout, run `.\install.cmd` in a normal PowerShell. The installer requests UAC only while copying and verifying `%ProgramFiles%\FreshWin` and registering only `%ProgramFiles%\FreshWin\bin` on the machine `PATH`. The directory containing `FreshWin.ps1` is deliberately not registered. The installer does not set a user or machine execution policy. Open a new terminal after installation.

Run `freshwin-uninstall` to remove the installed core and its exact machine `PATH` entry. User-local configuration, logs, and retained `Downloads\FreshWin` exports/backups are preserved. Do not use or publish an unverified `irm | iex` bootstrap.

## Automation contract

Automation should rely on structured output when the command offers it, not parse colored presentation text. Treat nonzero exit status, `BLOCKED`, `MANUAL`, `ELEVATION_REQUIRED`, `UNKNOWN_VERIFICATION`, and `COMPLETED_WITH_ISSUES` as distinct outcomes.

Do not assume a Windows-live operation was tested merely because `validate` passed on macOS. See [Testing](TESTING.md).
