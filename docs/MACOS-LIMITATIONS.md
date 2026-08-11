# macOS limitations

The macOS test host can establish substantial confidence in FreshWin's data and policy logic, but it cannot execute or validate Windows operating-system integrations.

## What macOS can test

- PowerShell parsing and deterministic module loading.
- JSON schema and semantic catalog validation.
- Dependency ordering, conflicts, recommendations, and plan state transitions.
- Localization file/key/placeholder parity.
- Configuration, logging, redaction, state envelopes, and checkpoints in isolated temporary paths.
- Argument escaping and rejection rules.
- Assistant parsing and untrusted-provider output validation.
- Hardware, system, network, activation, update, software, and driver transformation using supplied fixture objects.
- Installer/execution behavior through callbacks, including proof that dry run did not call the process boundary.
- Driver-backup manifest generation, real file hashing/tamper detection, and the rule that a provider must create at least one INF before a fixture can be verified.
- Bounded local INF parsing, network rescue classification/retry policy, Defender/firewall health policy, and offline-diagnostics redaction through explicit providers.
- Redacted diagnostics export and manifest hashing in harness-owned temporary directories.
- Pre-reset checklist gating and proof that supplied BitLocker recovery-secret fields are discarded.
- DDU risk, replacement, reboot/resume, manual-install, and verification state transitions without launching any cleanup or installer.
- Explicit unsupported results from live scanners on a non-Windows platform.

## What macOS cannot prove

- CIM/WMI classes and Windows-only PowerShell cmdlets return the expected live shape.
- Registry, COM Windows Update, AppX, optional-feature, TPM, Secure Boot, PnP, and activation providers behave correctly.
- WinGet and Microsoft Store identifiers resolve or install successfully.
- Windows native argument parsing, installer exit codes, Program Files/ProgramData ACL enforcement, elevation/UAC, RunOnce, reboot, and resume work end to end.
- Vendor installers are silent, correctly signed, license-compliant, or compatible with enterprise policy.
- Windows Defender/antivirus, device drivers, Windows Sandbox, WSL, ARM64, or specific Windows builds behave as expected.
- PnPUtil exports the installed driver store, Windows accepts a planned INF, or an Authenticode result matches an explicit signature-provider fixture.
- Security Center, Defender, Firewall, BitLocker, adapter, route, or DNS cmdlets return the same shapes used by fixtures.
- A DDU cleanup, reboot/resume, replacement-driver installation, or Windows reset succeeds.
- The complete safe suite parses and behaves correctly under Windows PowerShell 5.1. CI now includes that host, but its first result is pending until the workflow runs on Windows.

The test runner labels Windows-live checks `SKIP` on macOS with a reason. Fixture statuses include `FixtureObserved`, `FixtureVerified`, `FixturePlan`, and `FixtureCompleted`, always with `IsLive = false`; none may be presented as a Windows pass.

## Required Windows follow-up

Run the opt-in read-only suite on supported Windows versions. For mutation/elevation/reboot scenarios, use a disposable VM snapshot with no credentials or personal data, record the exact Windows/PowerShell/WinGet versions, review the plan first, and report actual failures. Never change a failed or skipped check to success merely to complete a release checklist.
