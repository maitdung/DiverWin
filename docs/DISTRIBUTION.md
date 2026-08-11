# FreshWin distribution and clean-machine bootstrap

FreshWin's online installer is intentionally unpublished until an official GitHub repository and release URL are selected. Do not construct or execute an `irm | iex` command from a placeholder. The checked-in `bootstrap.ps1` fails closed while its official metadata token is unresolved; the release builder replaces that token only in the generated release asset.

## Authoritative version

`FreshWin.psd1` is the sole product-version source. Runtime `Get-FreshWinVersion`, `freshwin --version`, the release artifact name, embedded release manifest, release metadata, and protected install manifest all derive from its `ModuleVersion` value.

## Release artifact

`tools/New-FreshWinRelease.ps1` enumerates the same production payload used by the protected installer. It excludes tests, `.git`, `.github`, development logs, local configuration/state, checkpoints, and temporary files. ZIP entries are sorted and use a fixed timestamp so repeated builds from identical source bytes produce the same archive hash.

The versioned ZIP contains the required root scripts and module files, `bin/`, `src/`, `catalog/`, `profiles/`, `locales/`, `installer/`, and an embedded `release-manifest.json`. That manifest records the SHA-256 and byte length of every production payload file. The archive-level `.sha256` file covers the complete ZIP, including the embedded manifest.

## Publishing procedure

1. Run the complete portable suite under Windows PowerShell 5.1 and validate the project.
2. Set `ModuleVersion` in `FreshWin.psd1`, commit the reviewed source, and create the matching tag, for example `v0.1.0`.
3. Push the tag. `.github/workflows/release.yml` verifies the tag/version relationship, reruns the portable suite, builds the assets, and publishes the GitHub Release.
4. Confirm the release contains exactly these custom assets:
   - `FreshWin-<version>.zip`
   - `FreshWin-<version>.sha256`
   - `FreshWin-stable.release.json`
   - `bootstrap.ps1`
5. Independently download the assets, compare the ZIP against the `.sha256` file, inspect the metadata package URI/hash/version, and test the generated bootstrap in a clean Windows VM.
6. Only after that acceptance test, publish the official one-command URL using the release's stable `bootstrap.ps1` download endpoint. Until then, documentation must not present a runnable remote-install command.

For a manual reproducibility check before tagging, run the release builder twice with the same repository identifier and explicit publication timestamp in separate empty output directories, then compare the ZIP SHA-256 values.

## Verification model

The generated bootstrap is anchored by HTTPS delivery from the official GitHub Release. It downloads strict, bounded release metadata from the stable latest-release asset, permits only reviewed GitHub release/asset hosts, and verifies the versioned ZIP SHA-256 before extraction. Safe extraction rejects traversal, device-like paths, oversized payloads, and duplicate/unexpected files. It then verifies every extracted production file against the embedded manifest and confirms the module version before invoking `install.ps1`.

The existing installer stages and validates the source, requests UAC only for protected installation/PATH changes, performs the rollback-capable Program Files update, verifies installed hashes and ACLs, and confirms launcher resolution from a fresh non-elevated Windows PowerShell process. Bootstrap temporary files are removed in `finally` on success or failure.

## Update and uninstall

The protected install manifest retains the stable release-metadata endpoint. `freshwin update` is read-only and displays the current/available versions and review state. A second explicit `freshwin update --yes` downloads the versioned archive, verifies both archive and per-file hashes, stages it under the operating-system temporary directory, and invokes the same elevated atomic installer. It never silently auto-updates.

`freshwin-uninstall` requests UAC, removes `%ProgramFiles%\FreshWin` and only the exact `%ProgramFiles%\FreshWin\bin` machine PATH entry. User configuration, logs, downloads, exports, backups, and other retained artifacts remain untouched.

## Remaining acceptance boundary

Portable and same-host tests do not prove clean-machine installation. Before claiming the distribution works, run the generated bootstrap on a second Windows 10/11 machine or clean VM with Windows PowerShell 5.1, no repository checkout, no Git/GitHub CLI/PowerShell 7 assumption, a Unicode username, and a normal non-administrator shell. Verify `freshwin`, `freshwin help`, `freshwin status`, `freshwin doctor`, `freshwin install 7zip --dry-run`, `freshwin update`, and `freshwin-uninstall` from unrelated directories and fresh shells.
