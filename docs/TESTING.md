# Testing

FreshWin uses a dependency-free PowerShell harness so structural and safety checks run even when Pester and PSScriptAnalyzer are unavailable.

## Run the safe default suite

```powershell
pwsh -NoLogo -NoProfile -File ./tests/Run-Tests.ps1
```

The loader dot-sources every source file in a fixed dependency order. Tests cover parsing, duplicate function definitions, module metadata, CLI parsing, configuration/state I/O in uniquely named temporary directories, catalog schema and semantics, dependency cycles, locale parity/placeholders, built-in and portable profiles, terminal localization references, fixture scanners, compatibility/detection/planning, first-action inventory refresh, dependency refresh, reboot boundaries and same-boot resume refusal, mocked execution and verification, native argument quoting, path rules, JSONL history bounds and legacy-record redaction, assistant intent safety, queue validation, checkpoint minimization/integrity, driver-backup integrity, bounded local INF discovery, Security Center health policy, diagnostic export hashes, pre-reset secret omission, and DDU state transitions.

No default test installs software, enables a Windows feature, requests elevation, writes RunOnce, changes production state, or touches files outside its isolated temporary directory.

Filter by test-name regex while developing:

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1 -NamePattern 'Catalog|Localization'
```

## Windows-live integration

Live tests are query-only and require both a Windows host and an explicit switch:

```powershell
pwsh -NoLogo -NoProfile -File ./tests/Run-Tests.ps1 -IncludeWindowsIntegration
```

They query platform/admin state, CIM hardware/system data, network adapters, activation state, Windows Update, PnP drivers, Security Center, Microsoft Defender, firewall profiles, BitLocker status metadata, offline network diagnostics, a read-only system executable, and WinGet version/resolution when WinGet really exists. Live WinGet inventory requires a trusted WinGet/App Installer client version 1.29 or newer; update Microsoft App Installer before this check if needed. They also create a redacted diagnostics bundle only in the harness-owned temporary directory and validate that DDU remains a non-executing plan. If a prerequisite is missing, the test is skipped with the real reason. It must never be reported as passed.

These tests still do not prove installation, UAC elevation, Program Files ACL/source-trust behavior, ProgramData checkpoint ACLs, alternate-credential SID handoff, RunOnce/HKCU ownership, reboot/resume, Windows Sandbox, or vendor UI behavior. Those require a disposable Windows VM and a separately approved end-to-end protocol. Do not run destructive catalog tests on a developer workstation or shared CI runner.

Launcher and installer policy tests cover process-scoped execution-policy behavior, exact argument forwarding, Unicode/space paths, idempotent PATH value transforms, uninstall PATH removal, the standard inherited Program Files ACL descriptor, and pre-import failure diagnostics. The opt-in Windows-live suite only reads an already installed `%ProgramFiles%\FreshWin` tree and invokes read-only launcher commands; it does not install or uninstall FreshWin. Real UAC installation, PATH propagation into a newly opened terminal, and uninstall cleanup must be rerun manually on the Windows validation machine.

Live integration intentionally does not run PnPUtil driver export, INF installation, adapter mutation, security-setting changes, DDU cleanup, a reboot, replacement-driver installation, or Windows reset. Those are materially different tests and require an explicitly disposable Windows VM, separately approved artifacts, and post-snapshot recovery.

## Mocking strategy

Scanners accept provided CIM-like objects. Installer and execution functions accept process, inventory, feature-verifier, and progress callbacks. Tests exercise real transformation/policy code with those seams; a mock may replace the external boundary but may not replace the behavior being asserted.

Examples:

- A mocked process can capture the exact typed WinGet arguments and return a process exit record.
- Verification then receives a separate inventory provider and must observe the expected installed signal.
- A dry run supplies a process callback that fails the test if invoked.
- Windows Update, activation, hardware, network, and PnP record conversion use representative fixture objects on macOS.
- Network rescue fixtures create real bounded INF files in a harness-owned temporary directory and exercise hardware-ID matching; they do not prove Windows accepts the INF.
- Security fixtures provide raw product, Defender, and firewall records; they prove the health policy but not that Security Center returned those records.
- DDU fixtures exercise every guarded transition and may report `FixtureCompleted`; that is a state-machine result, never evidence that DDU or a Windows driver ran.

## Evidence labels

| Evidence | Meaning | What it does not mean |
| --- | --- | --- |
| `FixtureObserved`, `FixtureVerified`, `FixturePlan`, or `FixtureCompleted` with `IsLive = false` | Portable transformation, validation, redaction, or state policy ran against explicit providers/files. | A Windows API, driver, reboot, cleanup tool, or reset succeeded. |
| `LiveObserved` with `IsLive = true` | The opt-in suite queried the current Windows runner through the real read-only boundary. | A mutating recovery workflow works end to end. |
| `SKIP` | The host, switch, command, or prerequisite was absent. | Pass, failure, or inferred compatibility. |

## CI

FreshWin supports Windows 10 and Windows 11 only. The required GitHub Actions workflow runs on `windows-latest` under PowerShell 7 and the inbox Windows PowerShell 5.1 host. Windows additionally opts into query-only live tests in a separate job. The release workflow has its own required Windows CI prerequisite and cannot publish until both Windows PowerShell hosts pass. Workflow permissions are read-only for tests, checkout credentials are not persisted, and test jobs request no repository secrets.

A local pass is not a substitute for the required `windows-latest` result. Windows-live behavior is claimed only from an actual opt-in Windows run.

CI success means the declared tests passed on those runners. It does not authorize claims about untested Windows editions, ARM64, enterprise policy, vendor installers, driver export/install, DDU cleanup, reset, reboot continuity, or interactive UAC.

## Adding a regression test

Add a file named `tests/<area>.Tests.ps1` and register cases with `Add-FreshWinTest`. Use assertion helpers from `TestHarness.ps1`. Create temporary directories only with `New-FreshWinTestDirectory` and remove them in `finally`. A Windows-dependent test must declare `-Platform Windows` or `-Platform WindowsLive`; live tests must also remain non-mutating.
