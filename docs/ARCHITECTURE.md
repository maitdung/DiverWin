# Architecture

FreshWin separates observation, policy, planning, execution, and verification so a successful subprocess cannot be mistaken for a successful setup.

## Data flow

```text
trusted local catalog + profiles + locale files
                    |
Windows scanners -> compatibility -> detection -> recommendation/selection
                                             |
                                      immutable intent
                                             |
                                    dependency-first plan
                                             |
                          confirmation / elevation boundary
                                             |
                                    typed process execution
                                             |
                               independent state verification
                                             |
                              summary + redacted checkpoint/log
```

The command-line entrypoint is an adapter. Reusable behavior belongs in the module and source components; the entrypoint parses arguments, loads configuration/localization, dispatches a command, renders results, and maps outcomes to documented exit codes.

## Component boundaries

`src/Core` owns JSON I/O, configuration, state envelopes, logging/redaction, localization, safe native-process execution, and assistant intent validation.

`src/Scanner` gathers platform, system, hardware, network, activation, Windows Update, and software observations. FreshWin supports Windows 10 and Windows 11 only, and live Windows APIs are guarded. Most scanners accept provided objects so transformations can be tested without mutating the Windows host.

`src/Drivers` classifies PnP state and produces official OEM/GPU guidance. Driver recommendations do not imply automatic third-party downloads.

`src/Operations` composes guarded scanners into review-oriented Windows workflows. It owns contained output paths and integrity hashing, driver export/backup validation, local network-driver discovery, Security Center observations, redacted diagnostic bundles, pre-reset checklists, and the DDU recovery state machine. Provider seams exercise transformation and policy code on any host, but provider results always remain non-live. Operations that could install a driver, clean a display driver, restart Windows, or start a reset are represented as manual plan states rather than executable callbacks.

`src/Packages` imports catalog records, evaluates compatibility, detects installed state, resolves an allowlisted source strategy, installs through typed arguments, and verifies the resulting state.

`src/Recommendation` combines profiles and manifest metadata. Conflict groups and dependencies must be resolved before execution.

`src/Execution` creates stable dependency-first plans, reports progress, checkpoints resumable data, identifies elevation requirements, and executes plan items. It refreshes installed state at execution start, re-resolves every source from the trusted catalog, refreshes again during post-install verification, and stops at a confirmed reboot boundary. A resume rebuilds executable/source information from the current trusted catalog; persisted executable paths are not trusted.

`src/UI` parses command-line and menu selection input. Rendering should consume localized strings rather than embed policy.

## State model

A package may be compatible, blocked, not applicable, installed, not installed, broken, updateable, or unknown. Unknown is not equivalent to missing.

A plan item has a requested action (`INSTALL`, `UPDATE`, `REPAIR`, `SKIP`, `MANUAL`, or `BLOCKED`) and a separate execution state. Dry-run validation, process success, verification success, unknown verification, elevation required, and reboot required remain distinct.

Windows optional features have an additional observed transition: `EnablePending` is reboot evidence, not successful verification. FreshWin checkpoints the item as pending, stops the queue, and requires the resumed scan to observe `Enabled` before the feature can satisfy a dependency. This is used by the WSL 2 platform-feature dependency so container packages are reviewed in one dependency closure without being run before Windows has actually activated WSL.

Checkpoints contain identifiers and outcomes, not trusted executable paths or raw manifest commands. State filenames are restricted, JSON is enveloped with a schema version, and writes use a temporary file before replacement. When an outcome requires reboot, the checkpoint also records the OS-observed boot-session timestamp; restore fails closed until a different boot session is observed. UAC handoff binds exact bytes with SHA-256; privileged checkpoints live in an ACL-protected ProgramData directory, and RunOnce registration is explicit and removable.

FreshWin distinguishes application state evidence by availability. Unparseable package-manager output or failed registry enumeration produces `Unknown`, never `NotInstalled`. `SKIP` and manual items remain non-success states in execution summaries, and dependency satisfaction is recomputed from current evidence rather than stale plan metadata.

## Dependency direction

The module must load source files in an explicit order beginning with shared core helpers and platform guards. A function name should be defined once. Internal helpers should remain private, while `FreshWin.psd1` lists the supported exported commands explicitly.

Catalog validation has one canonical contract: `catalog/package.schema.json` plus semantic checks for uniqueness, dependency existence/cycles, localization keys, source safety, and catalog-wide conflicts. Runtime import and CI must agree with it.

## Extension points

- New package data belongs in `catalog/apps`, not in executable source code.
- New recommendation bundles belong in `profiles`.
- New languages begin from the complete canonical `en-US` key set.
- Assistant providers return only the constrained FreshWin intent schema. Provider output cannot supply executables, arguments, scripts, or shell commands.
- Windows-specific integrations should expose fixture/provider parameters so their policy logic remains cross-platform testable.
- A provider fixture validates FreshWin policy, not the Windows API behind the seam. Results must retain `IsLive = false` and a fixture-specific status.

See [Operations and recovery workflows](OPERATIONS.md) for state machines, data boundaries, and the live-validation matrix.
