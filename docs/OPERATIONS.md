# Operations and recovery workflows

FreshWin operations turn Windows observations into inspectable reports and manual recovery plans. They preserve three distinct claims:

- A portable fixture proves FreshWin transformation, safety, and state-machine logic.
- A live observation proves a read-only Windows provider returned data on that host.
- A mutating recovery outcome requires a separately approved disposable-Windows test and is not inferred by FreshWin's normal suite.

## Driver backup and restore planning

`New-FreshWinDriverBackup` exports installed third-party drivers with the trusted Windows PnPUtil binary into a new child directory. It writes `hardware-report.json`, `driver-profile.json`, and `backup-manifest.json`. Completion requires both process success and at least one real INF. Provider fixtures use `Status = FixtureVerified`, `IsLive = false`, and `WindowsExecutionVerified = false` even when the portable file checks pass.

For a live elevated export, `OutputRoot` is recorded as `RequestedOutputRoot` but is not used for privileged writes. FreshWin fails closed to `%ProgramData%\FreshWin\DriverBackups`, validates that its existing parent is not writable by an unprivileged identity, and creates the staging root and random backup child with inheritance disabled and explicit Full Control only for Administrators and SYSTEM. It revalidates the contained tree and rejects reparse points before and after PnPUtil and after writing the manifest. Only after every privileged write finishes does it grant the Windows identity performing the approved export inheritable Modify access. If PnPUtil times out, FreshWin cannot prove that descendant activity ended, so it withholds that access grant and leaves the incomplete staging directory protected. The result reports the actual `OutputRoot` and `BackupPath`, with `OutputRedirected = true`, `ProtectedStaging = true`, and `UserAccessGranted` describing the final access handoff. FreshWin does not copy the elevated result into the originally requested directory. Explicit provider fixtures retain their isolated caller-supplied output directory and never imply this live ACL behavior.

`Get-FreshWinDriverBackupInventory` accepts a backup only when the schema, contained relative paths, file presence, and SHA-256 digests validate. An unmanifested folder is review-only. `New-FreshWinDriverRestorePlan` exact-matches problem-device hardware IDs to the verified profile and emits typed PnPUtil arguments for review; `ExecutionAllowed` and each item's automatic-execution flag remain false.

Live driver export and restore are not part of the default or query-only Windows suite. Export writes potentially large data and restore changes PnP state, so both require a separately approved disposable Windows VM protocol.

## Network rescue

`Get-FreshWinNetworkRescueState` composes adapters, problem devices, hardware IDs, link state, and optional local INF matches into one of these states:

| State | Meaning |
| --- | --- |
| `Online` | Internet availability was explicitly observed. |
| `DriverMissing` | A network problem device reports Windows problem code 28. |
| `AdapterProblem` | A network device reports another problem. |
| `NoAdapter` | No physical non-Bluetooth network adapter was observed. |
| `LinkOnly` | A physical link exists but internet availability was not established. |
| `Offline` | Adapters exist and internet unavailability was explicitly observed. |
| `OfflineUnknown` | Evidence is incomplete. |

`Find-FreshWinLocalNetworkDriver` scans only local INF files, bounds file count and size, skips reparse points, hashes each match, and distinguishes exact hardware-ID matches from prefix matches that require review. It does not validate a Windows signature or install the file.

`New-FreshWinNetworkRescuePlan` describes diagnostics, an explicitly confirmed rescan, local-driver review, or manual official OEM acquisition. `Invoke-FreshWinNetworkRescueRetry` repeats read-only probes at most five times. `Get-FreshWinOfflineNetworkDiagnostics` queries IP, route, and DNS state and redacts network identifiers. None of these functions downloads or installs a driver.

## Security status

`Get-FreshWinSecurityStatus` queries three independent read-only sources:

- `root/SecurityCenter2` antivirus and firewall products;
- `Get-MpComputerStatus` for Microsoft Defender facts;
- `Get-NetFirewallProfile` for Windows Firewall profiles.

Raw Security Center `productState` values are labeled `NotInterpreted`. Overall health is `Healthy` only when Defender real-time protection is explicitly true and every observed firewall profile is explicitly enabled. Any explicit false is `Attention`; missing or ambiguous evidence is `Review`. Provider seams test this policy on non-Windows hosts without implying that Security Center was queried.

## Diagnostics and health summary

`Get-FreshWinDiagnostics` independently collects system, hardware, network, security, driver, Windows Update, activation, readiness, and optional project-validation components. A failed component becomes an error observation without discarding successful components.

`Get-FreshWinHealthSummary` gives each component `Healthy`, `Attention`, `Review`, or `Unsupported` and applies attention-first precedence. `NumericalScore` is deliberately null because incomplete observations do not support a defensible score.

`Export-FreshWinDiagnostics` creates a unique contained directory containing:

- `diagnostics.json`, recursively privacy-redacted;
- `health-summary.json`, also redacted;
- `manifest.json`, with SHA-256 digests for both payloads.

The export never collects browser profiles, credentials, recovery keys, or unrelated user files. Redaction is defense in depth; do not intentionally supply secrets to a provider.

## Pre-reset preparation

`Get-FreshWinPreResetObservations` reads only BitLocker status, protector types, storage health/capacity, power observations, and pending-restart state. Recovery passwords, recovery keys, and key material are excluded even if a fixture supplies them.

`New-FreshWinPreResetPlan` creates a twelve-item checklist covering user-data backup, verified drivers, application inventory, hardware and diagnostics reports, browser/sync state, account/license access, externally stored BitLocker recovery access, recovery media, power, storage, and pending restart. `Set-FreshWinPreResetChecklistItem` records explicit user evidence, and `Test-FreshWinPreResetPlan` reports blockers.

`ReadyForManualResetReview` is not permission to reset automatically. Every plan has `ResetExecutionAllowed = false`, `AutomaticExecution = false`, and `ResetCommand = null`. FreshWin contains no reset runner.

## Advanced DDU recovery

DDU is represented only by `New-FreshWinDduRecoveryPlan` and guarded transitions in `Move-FreshWinDduRecoveryPlan`:

```text
GPU detection
  -> advanced-risk acknowledgement
  -> verified replacement prepared OR explicit official post-cleanup acquisition strategy
  -> external safety checkpoint
  -> ready for manual cleanup
  -> manual-cleanup confirmation
  -> reboot required
  -> resume-after-reboot checkpoint
  -> replacement acquisition when deferred
  -> manual replacement installation
  -> observed GPU/driver verification
  -> completed
```

Prepared artifacts require a local file, matching SHA-256 digest, recognized official HTTPS source, and valid signature evidence. On macOS, a signature provider can exercise the policy but yields fixture validation and never `WindowsSignatureVerified`.

Every DDU plan fixes `AutomaticCleanup`, `AutomaticDownload`, and `AutomaticExecution` to false, stores no cleanup executable or arguments, and rejects invalid transitions. A failed post-install observation stays in `VerificationRequired`. `Save-FreshWinDduRecoveryCheckpoint` persists only a validated plan; it never registers startup execution or restarts the host.

## Validation matrix

| Surface | Portable/default suite | Opt-in Windows-live suite | Not claimed |
| --- | --- | --- | --- |
| Driver backup | Provider creates real temporary INF; report/manifest/hash/tamper rules. | Not run because export writes driver-store data. | Live PnPUtil export or driver restore. |
| Network rescue | INF parser, state policy, bounded retry, redaction, no-auto-action plan. | Real adapter/problem-device and offline diagnostic queries. | Device rescan, driver install, or OEM download. |
| Security | Raw provider mapping and Defender/firewall health policy. | Real Security Center, Defender, and firewall queries. | Changing protection settings or proving third-party enrollment. |
| Diagnostics | Component isolation, privacy redaction, bundle hashes, summary precedence. | Real read-only component aggregation plus temporary redacted export. | Completeness across every Windows edition/policy. |
| Pre-reset | Secret omission, checklist blockers, immutable no-reset fields. | Real BitLocker metadata, storage, power, and restart queries. | Starting or completing Windows reset. |
| DDU | Full guarded state machine, artifact/hash/source policy, checkpoint validation. | Live GPU detection while cleanup remains disabled. | DDU download/execution, reboot, or replacement-driver installation. |

Run portable tests with `./tests/Run-Tests.ps1`. On Windows, opt into the query-only boundary with `./tests/Run-Tests.ps1 -IncludeWindowsIntegration`. A skipped live test remains skipped and never becomes fixture success.
