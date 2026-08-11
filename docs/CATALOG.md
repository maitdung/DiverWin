# Catalog contribution guide

Each file in `catalog/apps` describes one package. The filename must be `<id>.json`, and `descriptionKey` must be `packages.<id>.description`.

## Start with the schema

`catalog/package.schema.json` is canonical for field shape and enum values. Do not copy a nearby manifest without validating it; runtime importer, schema, tests, and documentation must agree on install and restart representation.

Required areas include identity/publisher, official HTTPS website, source, Windows/architecture compatibility, version policy, detection, dependencies, install policy, verification, restart impact, risk, license, recommendation metadata, and tags.

## Source policy

- Prefer an exact WinGet package identifier when the manifest is maintained and points to the expected publisher.
- Use the Microsoft Store source only with its exact product identifier.
- Use Windows-feature sources only for feature names present in FreshWin's source-code allowlist.
- Use manual/official guidance when editions, regions, licenses, security enrollment, third-party mirrors, or interactive choices prevent safe unattended installation.
- Never add a direct download-and-run command, PowerShell snippet, shell fragment, executable path, arguments, token, or credential.

`officialWebsite` and manual URLs must use HTTPS. Record why a workflow is manual. A community package-manager record should not be described as vendor-signed unless that claim was actually verified.

## Compatibility and dependencies

Compatibility values describe hard applicability or an observable prerequisite. Unknown observations should normally produce review/warning rather than a fabricated pass. If a prerequisite can be installed by another catalog record, add a dependency and make sure planning can satisfy it without declaring the dependent package permanently incompatible.

Every dependency ID must exist, and the full graph must be acyclic. Conflict groups identify choices that should not be auto-selected together, such as antivirus products or alternative runtime channels.

`compatibility.providesFeatures` is reserved for a small runtime-validated capability vocabulary. It lets a reviewed dependency provision an otherwise missing prerequisite without converting an unrelated compatibility block into an executable action. The execution engine still rechecks the actual system capability after the dependency; a declaration is never itself proof that the capability is available.

## Detection and verification

Use independent, stable signals:

- exact WinGet IDs;
- specific uninstall-registry display names;
- safe known paths rooted in approved Windows environment variables;
- Windows features, AppX packages, services, or device state when the runtime supports them.

Avoid broad display-name prefixes that collide with unrelated products. `verification.methods` and `minimumMatches` must reflect what the runtime actually evaluates. Manual workflows must not claim automatic verification.

## Localization

Add a natural package description to every supported locale. All locale files must have exact key parity with `en-US`, and formatting placeholders such as `{0}` must match exactly. Do not use machine translation without human review for security, licensing, restart, or elevation language.

## Validation

Run:

```powershell
pwsh -NoProfile -File ./FreshWin.ps1 validate
pwsh -NoProfile -File ./tests/Run-Tests.ps1
```

Before proposing a record, also verify the current package-manager ID and official URL on a safe network-connected system. Put the verification date and evidence in the review description rather than embedding volatile claims in executable fields.

## Microsoft runtime records

The following runtime identities were rechecked on 2026-08-11 against Microsoft's documentation and the Microsoft-owned WinGet community manifest repository:

| FreshWin ID | Exact WinGet ID | Scope and evidence |
|---|---|---|
| `dotnet-runtime` | `Microsoft.DotNet.Runtime.10` | Base .NET 10 runtime only. Microsoft lists the ID in its [Windows installation guidance](https://learn.microsoft.com/dotnet/core/install/windows), and the current manifests are under [Microsoft/DotNet/Runtime/10](https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/DotNet/Runtime/10). |
| `edge-webview2-runtime` | `Microsoft.EdgeWebView2Runtime` | Evergreen WebView2 runtime. The installer choices are described on the [official WebView2 page](https://developer.microsoft.com/microsoft-edge/webview2/), and the exact ID is present in [Microsoft/EdgeWebView2Runtime](https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/EdgeWebView2Runtime). |
| `directx-legacy-runtime` | `Microsoft.DirectX` | Optional legacy D3DX, XAudio 2.7, XInput 1.3, XACT, and related libraries. Microsoft's [download page](https://www.microsoft.com/en-us/download/details.aspx?id=35) explicitly says this package does not replace the DirectX runtime maintained by Windows; the package identity is in [Microsoft/DirectX](https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/DirectX). |

These records still fail closed when live inventory cannot independently verify installation. In particular, Microsoft's preferred WebView2 presence check uses an EdgeUpdate registry value that the current declarative detection schema does not model. FreshWin therefore requires exact WinGet correlation for that record; a Windows live test must confirm behavior on machines where WebView2 is an inbox or hidden system component.

## Developer profiles

Built-in developer profiles are data-only selections and use the same planner, detection, confirmation, and verification pipeline as direct package choices. Every profile defaults to `missing-only`; users must explicitly request updates.

| Profile ID | Focus | Packages |
|---|---|---:|
| `web-developer` | Browsers, Git, VS Code, Node.js LTS, and API testing | 9 |
| `full-stack` | Web, API, database, .NET/Python, WSL, and containers | 16 |
| `dotnet-developer` | .NET LTS SDK and native prerequisites | 9 |
| `python-developer` | Python, Git LFS, editor, and native x64 prerequisite | 7 |
| `devops` | WSL, containers, Terraform, Kubernetes, and Helm | 10 |
| `ai-developer` | Python, Git LFS, WSL, and containers | 9 |

The `.NET developer` profile deliberately retains Visual Studio as an interactive plan item rather than pretending its workload selection can be completed unattended. Cloud-vendor CLIs, AI models, and GPU drivers remain explicit opt-ins instead of being installed by a broad profile.
