# Safety and trust model

FreshWin is allowed to automate setup only when the requested target, source, arguments, privilege, and verification method are known in advance.

## Trust tiers

1. Windows components use a small source-code allowlist and built-in Windows tools.
2. WinGet and Microsoft Store entries use validated package identifiers and typed arguments.
3. Official/manual entries provide HTTPS guidance but are not automatically downloaded or executed.
4. Arbitrary commands, scripts, shell fragments, and manifest-provided executable paths are forbidden.

An HTTPS URL proves transport protection, not publisher identity. A manual URL therefore remains guidance until a human follows the vendor workflow.

## Execution rules

- Arguments are arrays until the native process boundary. NUL characters and unsafe executable extensions are rejected.
- Package manifests cannot contain `command`, `commandLine`, `script`, `powershell`, `shell`, `arguments`, or `executable` fields at any depth.
- Automatic WinGet operations resolve only the exact Microsoft Desktop App Installer package family, require a valid Microsoft Authenticode signature, bind the declared source with `--source`, and use finite process timeouts. Silent and interactive policy is explicit; unattended mode refuses any workflow that requires interaction.

- FreshWin application, module, catalog, and executable trust remains rooted below protected `%ProgramFiles%\FreshWin`. FreshWin-retained user artifacts resolve the current user's Downloads known folder and use `FreshWin\Installers`, `Drivers`, `Exports`, or `Backups`; those directories are never executable or core trust roots and are created only when an approved write occurs. WinGet continues to own its normal download and cache locations.
- The local `install.cmd` bootstrap validates the checkout before requesting UAC, copies into a new inherited-ACL staging directory below Program Files, verifies file hashes and project validation there, and only then installs the protected tree. Only `%ProgramFiles%\FreshWin\bin` is registered on `PATH`; the core script directory is not. `freshwin.cmd` uses process-scoped `-ExecutionPolicy Bypass` solely for the protected parent entrypoint; FreshWin never changes persistent execution-policy settings. Machine `PATH` registration is exact, idempotent, and removed by `freshwin-uninstall`.
- Elevation happens only for the already-created checkpoint/plan and always through Windows' visible administrator approval. Elevated mutation additionally requires the complete FreshWin source/catalog tree to be below Program Files, non-reparse, administrator-owned, and not writable by the current user, Users, Authenticated Users, or Everyone.
- A process exit is recorded separately from post-install detection. Restart exit codes are handled explicitly, not as generic failures. WinGet's “restart before install” result remains a failed package action with a distinct retry-after-reboot flag; it creates recovery guidance but never claims the package was installed.
- Windows optional-feature state `EnablePending` is never reported as installed. It creates a reboot boundary and remains pending until a post-reboot scan observes every declared feature as `Enabled`.
- Retry applies only to recognized transient failures and is bounded.
- `--dry-run` never starts the process provider, writes an execution checkpoint/log/output artifact, persists a language choice, or reports installed-state verification.

## Catalog integrity

CI validates JSON syntax and schema, unique IDs, ID/filename alignment, dependency existence and cycles, HTTPS URLs, safe known-path variables, forbidden executable fields, locale keys, and profile references. Package-manager identifiers and official URLs should also receive periodic network-backed review; that research is not a substitute for local structural validation.

Catalog updates are trusted code changes. Review their diff like source code. Do not fetch and execute a remote catalog without signature/version policy and explicit update design.

## FreshWin self-update staging

The Update FreshWin terminal page validates only an explicitly configured HTTPS metadata endpoint and does not download, apply, or execute an update. The exported staging API requires validated allowlisted metadata, an explicit new `.zip` destination, a maximum 100 MB archive, and an exact SHA-256 match. It writes a bounded JSON identity sidecar containing the channel, version, publication time, package URI, hash, and length. An existing archive is reused only when that complete identity, sidecar length, current file length, and a freshly computed archive hash all match; an absent, altered, extended, reparse-point, or mismatched sidecar fails closed. Staging and reuse never imply installation, and no automatic apply path exists.

## Assistant boundary

The deterministic assistant parses a small command grammar locally. Optional providers may classify text, but their output is untrusted until validated against the action allowlist, target-ID grammar, target-count limit, and recursive forbidden-property policy. Mutating intents require confirmation and still travel through the normal planner.

Do not put credentials, tokens, license keys, or personal data in assistant text.

## Logging and state

Logs redact common secret keys, bearer tokens, URL credentials, AWS-style access keys, JWT-like values, and private-key blocks. Structured data is recursively protected and depth-limited. Redaction is defense in depth, not permission to ingest secrets.

Resume state stores package IDs and outcomes. On resume, FreshWin rebuilds the plan from the current local catalog and current machine state. It must not trust persisted executable paths or argument arrays.

Every checkpoint path is absolute and local; UNC, device, and mapped-network paths are rejected. Hash-bound UAC handoff prevents checkpoint byte changes between approval and use. The original invoking Windows SID is carried across the helper boundary, so privileged execution state below `%ProgramData%\FreshWin\state` grants Administrators/SYSTEM full control and only read/execute access to that invoking user—even when a different administrator credential approves UAC. Explicit RunOnce registration is performed back in the invoking user's process/HKCU, never in an alternate administrator's hive. A confirmed reboot-requiring installer is a queue boundary: later work remains pending for explicit resume instead of running against pre-reboot state. Its checkpoint records `Win32_OperatingSystem.LastBootUpTime`; an immediate same-boot resume is rejected, and unavailable boot evidence fails closed instead of retrying a reboot prerequisite.

The WSL 2 catalog flow follows Microsoft's feature prerequisites: FreshWin enables the allowlisted Windows Subsystem for Linux and Virtual Machine Platform features through DISM, stops for a required reboot when Windows reports a pending transition, and only then resumes the separately sourced WSL package and dependent application plan. A present `wsl.exe` launcher alone is not installation evidence.

Software inventory is fail-closed. A localized or changed WinGet table that cannot be parsed, a registry enumeration failure, or an unavailable provider yields `Unknown`; it never becomes negative proof that an application is absent. Execution refreshes inventory before the first installer and after each installer verification so software added during review is skipped instead of reinstalled.

## Risk and user choice

`SAFE`, `SYSTEM`, and `ADVANCED` describe increasing impact. System and advanced operations need conspicuous review. Antivirus conflict groups, runtime-channel conflicts, driver cleanup, Windows features, and restart-impacting changes must not be silently bundled.

FreshWin never bypasses activation, Windows 11 eligibility, Secure Boot, TPM, vendor licenses, or security software enrollment.

## Recovery and diagnostics operations

Driver backup resolves `pnputil.exe` only from the OS-reported `[Environment]::SystemDirectory`, using the native `Sysnative` view when a 32-bit process runs on 64-bit Windows, and invokes it with the typed `/export-driver`, `*`, and destination argument array. For a live export, the caller-supplied path is validated and retained only as `RequestedOutputRoot`; privileged output is redirected to a new protected child below `%ProgramData%\FreshWin\DriverBackups`. The result reports the actual `OutputRoot` and `BackupPath`, and FreshWin does not copy the export into the requested directory. A reported zero exit code is insufficient: at least one INF must exist, and the backup inventory must validate every manifested SHA-256 digest before restore planning. Restore output is a review plan and never installs the INF automatically.

Network rescue scans local INF files with file-count and size limits, skips reparse points, and matches hardware IDs conservatively. Its plans may describe a device rescan, official OEM acquisition, or administrator driver review, but they do not execute those actions or download a package. Retry probes are bounded and observation-only.

Security status queries Security Center, Microsoft Defender, and Windows Firewall without changing settings. The raw Security Center `productState` value is retained but deliberately not decoded as a health verdict because its bit layout is not a documented FreshWin contract. `Healthy` requires explicit Defender real-time protection and explicitly enabled firewall profiles; unknown facts remain `Review`.

Diagnostic exports recursively redact secrets, product-key fragments, serial/UUID fields, user/domain fields, MAC and IP addresses, and common user-home path segments. Every export uses a new contained directory and includes hashes for the diagnostics and health-summary payloads. The health summary reports evidence states rather than inventing a numeric score.

Pre-reset APIs query only allowlisted BitLocker status fields and protector types. They never request or retain a recovery password, recovery key, or key material. A complete checklist means “ready for manual reset review”; `ResetExecutionAllowed`, `AutomaticExecution`, and `ResetCommand` remain disabled or null.

The DDU workflow is an advanced state machine, not a DDU runner. FreshWin stores no cleanup executable or cleanup arguments and never downloads or launches DDU. It requires explicit risk acknowledgement, an official replacement-driver strategy, a safety checkpoint, manual cleanup confirmation, reboot/resume evidence, manual replacement installation, and observed post-install GPU health. A provider-driven fixture may reach `FixtureCompleted`, but only a live Windows observation can support a live completion claim.

## Reporting a security issue

Do not include credentials, private logs, license keys, or sensitive inventory in a public report. Describe the affected version, command, catalog record, expected boundary, and a minimal redacted reproduction. Until a private security contact is published by the project owner, avoid sharing exploit details publicly.
