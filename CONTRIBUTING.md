# Contributing to FreshWin

Keep changes small, reviewable, and aligned with FreshWin's central promise: no hidden execution and no invented success.

## Before changing code

1. Read [Architecture](docs/ARCHITECTURE.md) and [Safety](docs/SAFETY.md).
2. Identify whether the change affects observation, policy, planning, execution, or verification.
3. Preserve fixture/provider seams around Windows-only APIs.
4. Do not add credentials, real machine inventory, private logs, generated installer binaries, or copied vendor content.

## Development rules

- Define each function once and load files in the module's explicit dependency order.
- Keep manifests declarative. Never place commands, scripts, executables, or argument lists in catalog JSON.
- Use typed process arguments and the shared safe runner for native processes.
- Treat unknown, missing, process-success, verified, and skipped as different states.
- Add an English localization key first, then maintain exact parity and placeholders in all supported locales.
- Use atomic state/config helpers and uniquely named temporary directories in tests.
- Do not weaken a Windows guard to make a macOS test pass.

## Catalog changes

Follow [Catalog contribution](docs/CATALOG.md). Verify identifiers and official URLs using current authoritative sources, document the verification date in the review, and run schema/semantic tests. New dependencies must exist and must not create cycles. New conflict groups need planning tests.

## Tests

Run the dependency-free suite before handing off:

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1
```

On Windows, also run the opt-in live query suite when safe:

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1 -IncludeWindowsIntegration
```

State exactly which host and suites ran. Do not claim Windows integration from fixture tests. See [Testing](docs/TESTING.md).

## Review checklist

- Source parses and module imports in a clean process.
- New public commands are explicit in the module manifest and CLI help.
- Catalog schema, runtime validator, and consumers agree.
- Locale and profile validation passes.
- Dry-run and manual/interactive boundaries have regression tests.
- Logs/checkpoints contain no newly introduced secret or executable fields.
- Windows-only limitations and untested paths are documented.

