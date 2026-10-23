# Portable Codex SSH proxy tunnel implementation plan

Date: 2026-10-22

Goal: a portable Windows folder that discovers and verifies a local HTTP proxy, establishes an SSH reverse tunnel to a user-selected Linux server, and checks the real remote HTTPS route without changing local Codex configuration.

Architecture: Windows PowerShell 5.1 and the existing Windows OpenSSH/curl tools. A first-run wizard saves non-secret server/user/jump-host choices inside this folder. Each launch generates an isolated temporary SSH configuration; the SSH process stays in the visible launcher console for password/MFA prompts. An in-memory POSIX shell monitor runs remote curl checks through the forwarded loopback port and keeps the connection alive. No server configuration or package installation is automatic.

Alternatives considered: reuse a named global SSH alias (less portable and can inherit unwanted forwards); start a hidden service (harder password handling and ownership); use an isolated foreground SSH session (selected).

## Files and work

- [x] `ProxyTools.ps1`, `tests/test_proxy.ps1`: discover loopback HTTP candidates from Windows proxy settings, process environment, listening proxy processes and common listening ports; test actual target TLS/HTTP, reject CONNECT-only/403/TLS failures, retain timeouts and certificate validation.
- [x] `remote-monitor.sh`, `tests/test_remote_monitor.py`: check remote curl exists, test the configured proxy against OpenAI, distinguish initial failure/recovery, periodically check, print honest status, terminate on SSH disconnect. No files written on the remote host. Added read-only listener-address verification when ss is available.
- [x] `TunnelTools.ps1`, `Start-Tunnel.ps1`, `Start.cmd`, `Configure.cmd`, `Check.cmd`, `settings.example.json`: generic server/user/SSH port and optional multiple jumps; strict input validation; save only non-secret package settings; isolated SSH config with forwarding only on target; normal SSH host-key verification; visible credential prompts; clear port conflict diagnostics.
- [x] `tests/test_tunnel.ps1`, `tests/test_launcher.py`: malicious/invalid inputs rejected, custom usernames/hosts/ports/jumps survive generation, forwarding not inherited by jump hosts, PS5 native argv and Chinese paths with spaces, diagnostic mode and protected configuration hashes.
- [x] `read.md`, `change.md`, `agnet.md`: Chinese operational guide, local/remote isolation boundaries, no automatic dependency installs, remote VS Code JSON instructions, multi-computer port ownership, test evidence and limitations.
- [x] Run tests on Windows PowerShell 5.1; real local proxy check; use existing authenticated SSH dynamic forwarding for a bounded remote-route check where available (do not stop an existing tunnel or prompt for passwords in tools). A brand-new password login on another computer remains an interactive user check.
- [x] Review, local commit, create portable ZIP without runtime state, personal server details, credentials, logs or Git metadata; verify archive content and run the extracted diagnostic launcher.

Constraints: no edits to local `.codex`, global environment, registry, global SSH config or remote VS Code settings; no copying auth caches; no disabling TLS verification; no killing unrelated SSH processes; do not claim Codex login/model inference from an unauthenticated network probe.

Scope update (2026-10-23, v2.4): the user explicitly requested a one-click action to configure remote VS Code proxy settings. That action may update only the selected remote account's VS Code Machine settings with backups; the normal tunnel launch still does not write remote configuration. Local VS Code, Codex, SSH and proxy settings remain protected.

## 2026-10-23 — Select servers from local SSH configuration

- [x] Add an SSH alias selector, custom config path, typed alias, manual fallback and read-only query help.
- [x] Resolve supported effective connection settings with bounded OpenSSH -G after Include/Match-exec preflight; retain isolated runtime SSH config.
- [x] Exercise real PowerShell 5.1 setup and module fixtures, review supported/unsupported behavior, verify local config hashes.
- [x] Update guide/change record, create a local commit and rebuild/test the portable ZIP without personal settings.

## 2026-10-23 — Single executable package

Goal: copy only CodexProxyTunnel.exe to another Windows computer and use the existing tunnel flow from a Chinese console menu. Preserve foreground SSH authentication and configuration isolation.

Architecture: compile a small C# console launcher with the already-installed .NET Framework compiler. Embed the five runtime scripts as assembly resources, extract only those known files into a unique temporary directory, and invoke Windows PowerShell with explicit arguments. Save connection choices separately at `%LOCALAPPDATA%\CodexProxyTunnel\settings.json`. Launch PowerShell suspended, attach it to a dedicated Windows Job Object, then resume it so closing the launcher terminates only its own process tree.

Alternatives: a PS2EXE dependency would add a download and require compatibility checks for dot-sourcing and SSH prompts; a Python bundle would add a Python runtime. Reuse the installed Windows/.NET runtime and existing tested scripts instead. This deliverable retains a console menu; no separate graphical interface is part of this packaging change.

- [x] `exe/Program.cs`, `exe/app.manifest`: embed/extract runtime resources, strict CLI options and correct Windows quoting, foreground inherited stdio, menu/EOF behavior, job-owned lifetime, narrow temporary cleanup, asInvoker privileges.
- [x] `exe/Build-Exe.ps1`: locate the existing framework compiler, compile without downloads, embed an explicit source allowlist, create `dist/CodexProxyTunnel.exe` with version metadata.
- [x] `tests/test_exe.py`: execute the real EXE alone from a Unicode/spaced folder; exercise help/menu/SSH selection/manual configuration and failure paths without login; validate output/config and protected global configuration hashes.
- [x] Run the build and tests, inspect embedded resources and executable metadata, perform a bounded real local proxy check, review lifecycle and cleanup, distinguish runtime tests from a real SSH password session.
- [x] Update `read.md`, `change.md`, and `agnet.md`; publish the EXE with checksum and a source bundle; make a local commit. No credentials or saved personal host settings in the executable.

## 2026-10-23 — Graphical desktop v2.0

Goal: a portable, attractive Chinese desktop GUI with SSH-host dropdown, start/stop buttons, local proxy results, remote status and logs. Preserve the console edition and local configuration isolation.

Architecture: native WPF on installed .NET Framework 4.8. Generate an imagegen design reference, then implement real controls with dark cards and mint actions. A C# backend extracts seven allowlisted public resources, invokes bounded hidden PowerShell JSON operations and owns a dedicated visible SSH-authentication console through Windows Job Objects. Local proxy evidence and remote HTTPS evidence remain independent; monitor heartbeats expire. No password fields or new third-party runtimes.

- [x] Generate the design reference and document palette, spacing, layout, typography and state semantics.
- [x] Implement async host selection/import, proxy check, start/stop, status cards, logs, help and port validation.
- [x] Add atomic monitor IPC, generation-safe status delivery, owned process cancellation, repeat-save compatibility and heartbeat expiry.
- [x] Complete GUI state/lifecycle/IPC regressions, render actual WPF previews at default/minimum sizes, and perform bounded local proxy verification.
- [x] Verify embedded resources and config isolation, package EXE/source ZIP, update evidence and commit.

## 2026-10-23 — Minimal gray-white and pale-blue refresh v2.1

User direction: make the interface simpler and improve button design; confirmed palette is gray-white plus pale blue. Apply the generated design reference using native WPF controls, keeping the tunnel backend unchanged.

- [x] Inspect current styles, record user color preference and generate a new imagegen reference.
- [x] Replace the dark palette, simplify header/layout details, and define primary/secondary/ghost buttons with native icons and interaction states.
- [x] Design the requested application icon with imagegen, export nine ICO sizes, and embed the icon in the EXE and window.
- [x] Render actual default, minimum, advanced and control-state previews; run existing relevant UI/package checks.
- [x] Record results, build a separate v2.1 EXE/source ZIP with checksums, verify protected configuration hashes and commit.

## 2026-10-23 — Saved servers and automatic discovery v2.2

User request: add servers without a pre-existing SSH config, enter address/user/port/jump hosts, save in the application's own configuration, and automatically read available local server definitions.

Design: a light Add/Edit dialog using the current palette and reusable button styles; an app-owned versioned servers.json under LocalAppData; merged catalog of saved entries and supported local SSH aliases. Auto-discover default SSH config and VS Code / Code Insiders custom config paths using bounded JSONC parsing. Display source labels; keep actual SSH import guarded by the existing preflight. Missing/broken external configuration must not hide otherwise usable saved entries. Authentication remains in SSH.

- [x] Review current import/store boundaries and generate Add Server design reference.
- [x] Implement atomic application catalog with validation, source discovery, per-source warnings and concurrency protection.
- [x] Add server form, ordered jump rows, edit support, clear empty state and selection after save.
- [x] Verify fixture persistence, missing config, corruption, multi-hop, custom paths, concurrent writes and UI rendering/state behavior.
- [x] Build/package v2.2, verify protected configuration hashes, update evidence and commit.

## 2026-10-23 — Native SSH compatibility and novice setup v2.3

Observed: another computer lists six SSH aliases but cannot import the selected entry, although VS Code connects. The strict endpoint converter rejects working SSH authentication and routing options, and a generic error hides the cause. User requires per-computer automatic discovery and a VS Code setup guide, not hardcoded host data or manual config collection.

- [x] Trace list/import behavior, inspect VS Code client discovery and confirm error masking; reproduce diagnostic failure before repair.
- [x] Add native SSH preview and isolated configuration snapshots that preserve authentication/ProxyJump/ProxyCommand while removing inherited tunnel/session side effects.
- [x] Detect VS Code custom SSH executables, carry native references through the backend, and clean owned snapshots on normal stop or process cancellation.
- [x] Show useful diagnostics and include novice VS Code remote settings, installation and login guidance with the selected remote proxy port.
- [x] Run native fixtures, API, lifecycle, catalog, package and UI checks; publish a new desktop folder and record limits of testing on the other computer.

## 2026-10-23 — One-click remote VS Code setup and first-run guidance v2.4

Design: reuse the gray-white and pale-blue controls; add a compact remote VS Code action with independent progress, cancellation and result. Empty-server start opens a guided form, saves to the application store and continues the original action only after successful validation. Keep regular Add Server save-only. Imagegen reference: gui/assets/vscode-setup-concept-v2.4.png.

Remote action: a separate owned SSH authentication session uses the same selected server/client/jump settings without adding port forwarding or disturbing the active tunnel. Stream a dependency-free JSONC editor using the Node runtime already installed with VS Code Server. Locate the remote account's VS Code installation, preserve unrelated settings and comments, create an exact backup before changing existing data, and reject malformed or unsafe targets. The user completes normal SSH authentication if required; configuration success requires reloading the VS Code remote window.

- [x] Define UI flow and remote-only write boundary; generate reference and inspect current extension proxy handling.
- [x] Implement guarded JSONC patching, runtime discovery and fixed result protocol with fixtures.
- [x] Implement independent cancellable backend action, authentication and cleanup without proxy probing or forwarding.
- [x] Add guided first-run continuation and one-click UI with separate progress/result.
- [x] Verify settings preservation, idempotence, failure/cancellation, native/manual SSH, UI previews, packaged resources and protected local hashes.
- [x] Update guides, commit and publish v2.4 desktop folder without user data.

## 2026-10-23 — Public GitHub publication

User destination: `https://github.com/qwe123ew/codex_Tunnel`; user chose MIT. Preserve the destination's existing history while importing a clean current snapshot; do not upload unrelated local development history or user data.

- [x] Verify repository visibility/access and audit current source, binary, archive and relevant history.
- [x] Prepare MIT license, public quick start, troubleshooting, screenshots and sanitized records.
- [ ] Validate public checkout, commit/push source without force, and prepare EXE/portable/source assets with checksums.
- [ ] Upload and verify release assets, publish v2.4.0, and confirm public download URLs.
