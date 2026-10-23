# Change log

## 2026-10-23 — Public repository and v2.4.0 release documentation

User authorized publication to `qwe123ew/codex_Tunnel` and selected the MIT license.

- Add `README.md`, `docs/TROUBLESHOOTING.md`, fixture screenshots and `LICENSE`, covering executable download, first-run server setup, VS Code remote proxy configuration, build/test commands and compatibility limits.
- Keep the public repository's existing initial commit and import an audited current source snapshot. Exclude local development history, runtime state, saved servers, authentication files and build directories. Generalize the personal server alias previously mentioned in this change log.
- The public executable remains the already verified v2.4 binary; package it with the license, Chinese guides and checksums. A separate source bundle includes the public source snapshot and program for development/reference; ordinary users can download only the EXE.
- Pre-publication audit checked current tracked files, eight local commits/127 distinct file versions, embedded resources and previous archive entries. No high-confidence credential findings; the known personal alias was removed. This is a bounded inspection, not a security certification.
- GitHub repository visibility and authenticated write access were checked. Release assets are uploaded to a draft, downloaded and hash-checked before publication. No product code or local Codex/SSH/VS Code configuration changes are part of this documentation work.

Publication verified: https://github.com/qwe123ew/codex_Tunnel/releases/tag/v2.4.0 targets source commit `5a3b2cd0a04621fc6f204cd051990771f5e2e334`. All four assets (EXE, portable ZIP, source ZIP, SHA256SUMS.txt) were downloaded anonymously and matched local SHA-256 values. Public README, license and troubleshooting documents were fetched successfully. Public source compiled with the existing framework compiler, and the shipped EXE passed all 36 portable/resource checks against that source. The shipped EXE SHA-256 is `60b64987b3a8c3a0b2f819215db079d75513251aed35682b6e713c7ee55feb1d`.

## 2026-10-23 — One-click remote VS Code configuration and first-run guidance v2.4.0

User request: configure the selected server's VS Code proxy with one button, preserving local configuration; clicking Start on a new computer with no server entries should open a guided form and continue after saving.

Changes:
- `gui/GuiApp.cs`, `gui/ServerEditorWindow.cs`: compact one-click setup action, independent progress/result/cancel, guided empty-state forms with save-and-connect or save-and-configure continuation, and normal save-only Add Server. Existing unresolved SSH entries retain diagnostics. Configuration locks target/port selection while keeping Stop available for the existing tunnel. Success instructs reloading the remote VS Code window; port/server changes invalidate previous setup feedback.
- `gui/TunnelBackend.cs`, `Start-Tunnel.ps1`, `TunnelTools.ps1`, `SshImport.ps1`: separate job-owned SSH configuration action with selected native/manual authentication and jump route, no proxy probe or added forwarding, independent cancellation and five-minute timeout. Close/cancel cleans only owned children and snapshots. Fixed result messages require SSH exit zero and a valid remote success record; no raw settings or authentication output in GUI logs.
- `remote-vscode-config.sh`, `remote-vscode-config.js`: stream an editor using an existing compatible remote Node runtime, preferring VS Code's bundled runtime. Discover stable/Insiders, VSCODE_AGENT_FOLDER and active custom server/user-data paths using upstream VS Code directory semantics. Preserve JSONC comments, formatting, BOM, line endings, unrelated keys and trailing commas. Update all duplicate owned proxy keys consistently. Save original bytes in same-directory backups, stage/validate all targets, detect concurrent changes, atomically replace and attempt rollback on failure. Missing/malformed/linked/oversized/unsafe targets have fixed diagnostics. Repeating an identical setup is a no-op.
- `gui/Build-Gui.ps1`, `gui/app.manifest`, `tests/`: embed exactly nine public runtime files plus the existing icon; version 2.4.0.0. New editor, launcher and lifecycle regressions; existing fixture resources and standalone package checks updated.
- `gui/assets/vscode-setup-concept-v2.4.png`, `gui/design.md`, `read.md`, `VSCode-快速配置.md`, `plan.md`, `agnet.md`: imagegen design reference, precise gray-white/pale-blue layout, novice workflow, remote-only write scope, backup information and verification limits. Windows dependencies unchanged; no packages downloaded.

Verification:
- Remote JSONC/runtime suite: 36 cases, 35 passed and one file-symlink case skipped because Windows denies unprivileged file symlink creation. Actual directory junction and hardlink refusal cases passed; streamed shell used real Node against an isolated home fixture. No real server login or writes.
- Configuration action lifecycle: 32 checks passed, including independent active tunnel, cancellation, timeout, nonzero exit rejection, source snapshot and child/descendant cleanup. Actual Start-Tunnel launcher: 69 checks passed across synthetic native/manual SSH, no inherited/additional forwards, no proxy probing, success/no-op/errors and cleanup.
- Existing regressions: 35 native SSH, 15 native launcher, 45 profile/tunnel, 55 catalog, 107 GUI API, 52 backend lifecycle (including real heartbeat expiry), and 19 status assertions passed.
- Final C#5/.NET Framework build succeeded with warnings as errors: 445,440 bytes, version 2.4.0.0. The copied-only final EXE passed 36 resource/portable checks and 111 API checks. All 64 WPF control-state checks passed. Actual final default/minimum/onboarding/empty/configuring/configured previews were rendered; layout review remains separate from real SSH authentication.
- Local Codex config.toml, global SSH config and local VS Code settings.json SHA-256 fingerprints matched their pre-change values. Independent review found and repaired custom VS Code directory semantics, cancellation/timeout feedback and stale configuration-success feedback after port/server changes; no remaining blocking finding.
- Publish an allowlisted 54-file source/EXE archive with byte-for-byte source verification and SHA-256 sidecars; desktop copies contain no saved server data, credentials or runtime state.

Boundary: automated tests exercise Windows processes, WPF and isolated settings fixtures. They do not prove a new computer's password/MFA login, server policy or Codex account/model access. Custom remote installations require an identifiable running VS Code Server or VSCODE_AGENT_FOLDER; unknown targets are not guessed. Only the explicit setup action changes remote VS Code Machine proxy settings; ordinary tunnel startup and all local Codex/VS Code/SSH configuration remain unchanged. Same-account remote windows share these settings. Cancellation after remote commit may leave completed changes; rerunning verifies/completes safely.

## 2026-10-23 — Native SSH compatibility and VS Code setup v2.3.0

Problem: a second computer could list SSH aliases but showed blank endpoint fields even though VS Code connected successfully. The GUI used the strict manual-profile importer, which rejects otherwise valid native authentication options, multiple keys, ProxyCommand and nested jumps. Its error wrapper hid every cause behind one generic message. The exact configuration on that computer was not supplied; this change removes the identified compatibility restrictions generally instead of embedding personal host data.

Changes:
- `SshImport.ps1`: new native alias listing and bounded `ssh -G` preview, honoring an explicit VS Code SSH executable or trying installed local candidates. Capture a complete local Include graph, preserve Host/Match/authentication/routing semantics, and rewrite Includes into private snapshots. Strip inherited forwards, remote/local session commands, TTY/fork/control settings; add one controlled reverse forward. Match exec remains blocked before evaluation. Legacy strict import remains available for console/manual profiles.
- `gui/ServerCatalog.cs`, `gui/TunnelBackend.cs`: detect `remote.SSH.path` as well as configFile, prioritize VS Code's explicit clients, retain source/client identity, and carry native alias/config/client references through prepare/start. Track both preview and connection snapshot directories; dispose child jobs before nonrecursive allowlisted cleanup, including forced cancellation.
- `gui/Gui-Api.ps1`, `Start-Tunnel.ps1`: separate native display metadata from manual endpoint validation, reevaluate native references before start, preserve domain usernames and authentication settings, use the user home as native SSH working directory, and keep passwords in the authentication window. Fixed diagnostic categories never return raw stderr or config command values.
- `gui/GuiApp.cs`, `gui/app.manifest`: version 2.3.0.0, show selected native client in logs, clear obsolete parse-failure state after successful selection, and add a VS Code setup guide with a Copy Remote Settings JSON action using the selected remote port.
- `read.md`, `VSCode-快速配置.md`, `gui/design.md`, `plan.md`, `agnet.md`: explain automatic per-computer discovery, supported boundaries and novice remote extension setup. No additional runtime dependencies or resource files.

Verification:
- Native framework C#5 build with warnings-as-errors succeeded: final executable 396,800 bytes, version 2.3.0.0.
- 35 real local SSH-G native assertions; 47 existing strict importer assertions. Covered authentication options, multiple/missing keys, domain usernames, relative keys, ProxyCommand without execution/disclosure, nested jumps, Include boundaries, Match rules, controlled forwarding and original-file preservation.
- 15 real Start-Tunnel integration assertions with a private synthetic SSH executable/proxy: native metadata and executable/alias selection, reverse-forward arguments, monitor stdin/status, working directory, snapshot cleanup and no source mutation. No external network or SSH login.
- 55 catalog assertions including VS Code client discovery and priority; 52 backend lifecycle assertions including child/descendant termination, heartbeat expiry and forced-cancellation cleanup of preview snapshots.
- 111 GUI API assertions, 102 diagnostic assertions across 25 requests, 49 UI state checks and 32 final standalone package assertions. Copied-only EXE loads the native embedded implementation and cleans preview snapshots.
- Read-only native discovery on this computer found three aliases, resolved address/user/port and actual client without warnings, and did not start a tunnel.
- Local Codex and SSH configuration fingerprints remain unchanged. Independent review found no remaining release-blocking issue after fixing client priority and preview ownership.
- Versioned EXE/source ZIP and desktop folder use explicit allowlists, copy/archive byte verification and SHA-256 sidecars; personal SSH files, AppData profiles and credentials are not included.

Boundary: not tested on the user's other computer or through a new password/MFA login, remote extension authentication or model request. Automatic discovery covers the default user SSH config and stable/Insiders default user settings; arbitrary portable/custom-data profiles and Match exec require additional support. Original custom ProxyCommand executes only when the user starts their configured SSH connection. VS Code remote settings remain an explicit user step and are not silently changed by this software.

## 2026-10-23 — Add and edit saved servers with local discovery v2.2.0

User request: add a server directly in the GUI on a new computer with no SSH configuration, save address/user/port/jump hosts in application-owned storage, and automatically read supported existing local server configurations.

Files and behavior:
- `gui/ServerEditorWindow.cs`, `gui/GuiApp.cs`: Add Server and saved-entry Edit actions, empty-state guidance, ordered zero-to-four jump hosts, optional per-endpoint key paths, inline validation, asynchronous saving with input preservation after failure, stable-ID selection after save, and source labels/path tooltips. Retains gray-white/pale-blue controls; new design reference in `gui/assets/add-server-concept-v2.2.png`.
- `gui/ServerCatalog.cs`, `gui/TunnelBackend.cs`: versioned `%LOCALAPPDATA%\CodexProxyTunnel\servers.json`, strict schema with no secret fields, stable IDs, atomic replacement and cross-process file locking. Corrupt files are preserved and cannot silently be overwritten. Missing key files can still be opened for editing; validation runs before save/start.
- Automatic catalog merges software-saved entries, the default user SSH config, and the custom config paths in stable/Insiders default VS Code user settings. Supports JSONC and guarded SSH Includes, deduplicates source paths, and isolates source failures. No scan of all terminal clients or network hosts.
- `gui/Gui-Api.ps1`: bounded profile-validation operation; existing runtime scripts and SSH authentication flow retained. Discovery rejects network/device config paths before filesystem probing; the editor does not synchronously probe typed key paths.
- `gui/Build-Gui.ps1`, `gui/app.manifest`: compile four C# sources, version 2.2.0.0, unchanged seven public runtime resources plus the existing icon. No new dependency downloads.
- `tests/test_server_catalog.ps1`, `tests/test_gui_backend.ps1`, `tests/test_gui_package.ps1`: isolated catalog and integration coverage; `read.md`, `gui/design.md`, `plan.md`, `agnet.md`: usage, design, ownership and verification records.

Validation:
- Native C#5 framework compilation with warnings as errors succeeded. Final executable is version 2.2.0.0, 359,424 bytes.
- Windows PowerShell 5.1: 44 catalog assertions passed, including two-process concurrent additions, locked-store retry/reload, save/restart/edit, no SSH configuration, malformed-store preservation, strict credential rejection, JSONC custom paths, Include provenance and network-path rejection.
- Existing GUI API integration: 94 checks passed. Existing process lifecycle, cancellation and real heartbeat expiry: 35 checks passed. The final UI self-test passed all 48 checks, including save-pending locks, validation, edit preservation and source labels.
- Final standalone-EXE package test: 30 checks passed, including copying only the EXE to a Unicode/spaced directory, extracting and hashing all embedded resources, decoding all nine icon sizes, saving/resolving a manual two-jump server with no SSH config, preserving the remote port, and cleaning owned temporary runtime files.
- Seven actual WPF previews rendered from the final executable. Default/minimum/source dropdown/empty/add-server/two-jump layouts were visually inspected; preview fixtures do not use real account or server data.
- Read-only discovery on this computer found three aliases from one default SSH source, including the expected existing server alias, with zero warnings. Application profile/store fingerprints were unchanged; no SSH tunnel was started.
- Local Codex and global SSH configuration SHA-256 values match the pre-change values. Independent source review has no remaining blocking findings.
- Separate versioned EXE and source/EXE ZIP use an explicit allowlist and byte-for-byte archive checks, with SHA-256 sidecars. Earlier v2.1 deliverables are retained; no personal settings, passwords, tokens or key contents are bundled.

Verification boundary: fixture persistence, native local SSH parsing, UI rendering and process lifecycle were tested. No new interactive server login, remote Codex authentication or model request was performed in this change. The normal SSH authentication window remains the place to enter passwords or MFA.

## 2026-10-23 — Minimal light interface and application icon v2.1.0

User direction: simplify the interface, replace the previous palette with gray-white plus pale blue, deliberately design the buttons, and add a software icon.

Changes:
- gui/GuiApp.cs: light surfaces, simplified header, restrained borders, compact primary/outlined/ghost buttons with vector icons, and matching dropdown/input/log/scroll styles. Hover, press, keyboard focus, disabled and busy states retain clear visual differences. Dynamic button captions preserve their icons. Application and help windows load the embedded application icon; the header uses the same identity.
- gui/assets/design-concept-v2.1.png and gui/design.md: imagegen concept plus concrete palette, typography, layout and control-state documentation.
- gui/assets/app-icon-source.png / app.ico / Build-Icon.ps1: imagegen chain-link mark on a pale-blue rounded tile, exported with transparency to nine ICO sizes from 16 to 256 px. No new dependencies downloaded.
- gui/Build-Gui.ps1 / app.manifest: v2.1.0 build with native Windows EXE icon and one managed branding resource; the seven tunnel runtime resources remain separate.
- tests/test_gui_package.ps1: extend artifact checks for the icon resource and native Windows decoding of all nine sizes. Backend/start-stop/network code remains unchanged; no new server login is part of this visual refresh.
- read.md / plan.md: updated usage names, visual design and release evidence. The new standalone filename is CodexTunnel-v2.1.exe, preserving the prior release.

Verification:
- Final Windows .NET build succeeds with warnings treated as errors: version 2.1.0.0, 318,464 bytes.
- The exact release passes 29 UI state checks and 25 portable artifact checks. Embedded files match current source hashes; all nine icon frames are present both in native EXE icon data and the managed branding resource.
- Six real WPF previews generated: default, minimum size, expanded advanced settings, dropdown, button states and connected fixture. Visual inspection found no overlapping controls. The minimum window keeps primary actions visible and scrolls logs/content when needed.
- Button preview uses fixture-only WPF input flags and real templates; it is distinct from manual pointer/keyboard acceptance. All preview hosts and statuses are synthetic.
- Release ZIP is checked against an explicit source/artifact allowlist and byte-for-byte inputs, with SHA-256 sidecars for both ZIP and standalone EXE. No saved personal host configuration, credentials, runtime logs or Git data are packaged.

Verification boundary: existing connection behavior was preserved; this turn performed no new real SSH authentication or model request. Protected local Codex and global SSH configuration hashes are checked separately before delivery.

## 2026-10-23 — Graphical Windows desktop v2.0.0

Purpose: select an existing SSH host and manage the proxy tunnel from a Chinese desktop window, with separate local proxy and remote verification results. Keep the existing console edition available and preserve local Codex/global SSH configuration.

Files and behavior:
- gui/GuiApp.cs / app.manifest: native WPF window, server dropdown, config-file chooser, resolved route, advanced ports, start/stop, independent proxy check, status cards, last successful remote verification time, logs and help. Async work and state guards keep the interface responsive; only verified remote evidence displays ready.
- gui/design.md / assets/design-concept-v2.png: imagegen design reference, implemented colors, typography, layout and status semantics. Actual previews render the WPF controls using synthetic example data.
- gui/TunnelBackend.cs / Gui-Api.ps1: seven embedded public resources, bounded JSON helpers, dedicated visible SSH-authentication console, kill-on-close Job Objects and per-run generations. Stop/close operate on owned processes. Stale health becomes unverified after the configured monitor interval plus 45 seconds, then recovers with new evidence.
- Start-Tunnel.ps1: optional GuiStatusPath and atomic snapshots of a fixed monitor protocol. SSH authentication input/stderr are never captured into GUI logs. Local and remote HTTP status remain independent.
- TunnelTools.ps1: use PowerShell's NullString for File.Replace backup paths; Windows PowerShell 5.1 otherwise converts a null argument to an invalid empty path when overwriting an existing profile. Repeated saves and status writes now work.
- gui/Build-Gui.ps1: build an ordinary-user WPF WinExe using the installed .NET Framework compiler, with no dependency download. Runtime configuration lives at the GUI-specific AppData profile path.
- tests/test_gui_api.ps1 / test_gui_backend.ps1 / test_gui_status.ps1 / test_gui_package.ps1: helper contracts, process lifecycle, IPC semantics, expiry, portable embedded-runtime checks and configuration isolation. Existing launcher/profile regressions retained.
- read.md / plan.md / agnet.md: GUI instructions, scope, ownership and release evidence.

Validation:
- Final native build succeeds with warnings as errors, version 2.0.0.0, 179,200 bytes. Seven embedded resources match current source byte-for-byte.
- Final EXE: 27 UI state checks and 21 portable package checks passed. Package test copies only the EXE into a Unicode/spaced path, loads its embedded runtime, resolves a synthetic host using native ssh -G, and verifies cleanup without starting a server connection.
- GUI API and compiled-backend helper tests: 94 assertions passed under Windows PowerShell 5.1. Existing profile tests: 45; monitor-to-GUI status tests: 19; actual PowerShell launcher integration tests: 12, all passed.
- Independent backend lifecycle tests: 35 assertions passed with actual owned child trees. Covered pending preparation cancellation and immediate restart, out-of-order/corrupt state, real 55-second heartbeat expiry and recovery, unexpected child exit, Stop/Dispose cleanup and preservation of an unrelated process. Fixtures use an internal hidden-console seam; all public production constructors retain visible authentication.
- Actual WPF previews at default and minimum window sizes were visually inspected. Controls and text fit; the minimum window scrolls its content. This is visual rendering evidence, separate from interactive server authentication.
- Read-only live backend verification listed local aliases, resolved a route with two jumps and automatically verified the current loopback HTTP proxy twice with target HTTP 401. IsRunning remained false and the GUI profile was not changed. Local Codex/global SSH SHA-256 hashes remained unchanged.
- Release packaging uses an explicit allowlist, verifies archived bytes against source, and includes no personal settings, credentials, Git metadata or runtime logs. The standalone EXE is byte-identical to the tested build; EXE and ZIP have SHA-256 sidecars. The previous console release remains available.

Verification boundary: a new real SSH password/MFA login and actual remote Codex account/model use were not performed in this GUI turn. HTTP 401 establishes unauthenticated HTTPS reachability only. The EXE has no commercial code signature. Runtime dependencies are Windows PowerShell 5.1, OpenSSH, curl and .NET Framework 4.8.

## 2026-10-23 — Single-file Windows EXE 1.2.0

Purpose: run the existing SSH proxy tunnel by copying and double-clicking one executable. The console menu keeps normal SSH authentication in the same window and offers start, configure, proxy check, SSH query help and host listing.

Files and behavior:
- exe/Program.cs: C# launcher with strict CLI parsing and Windows argument quoting; six explicit embedded runtime/document resources; unique per-action temporary extraction and fixed-name nonrecursive cleanup. Default profile is `%LOCALAPPDATA%\CodexProxyTunnel\settings.json`, with `--config` available for an explicit alternative.
- exe/app.manifest: asInvoker permissions, version 1.2.0.0; no administrator request.
- exe/Build-Exe.ps1: local .NET Framework compiler only, no package installation or network restore; outputs dist/CodexProxyTunnel.exe.
- Start-Tunnel.ps1: optional ExecutableHost switch changes launcher hints to EXE menu actions, preserving script-mode behavior.
- tests/test_exe.py: real executable tests, including standalone copying, Unicode/spaced and metacharacter paths, piped menu input, config import, explicit manual jumps, relative identity path compatibility, bounded error paths and owned-process shutdown.
- read.md / plan.md / agnet.md / .gitignore: EXE usage, configuration location, implementation and release boundaries; build artifacts are not stored in Git.

Process ownership: PowerShell starts suspended, is assigned to a dedicated kill-on-close Job Object, then resumes with inherited console handles. The launcher does not inspect passwords, redirect authentication into logs, kill unrelated processes, or modify local Codex/global SSH configuration. Relative file inputs retain the caller's working directory.

Validation (2026-10-23):
- Successful native framework compilation, version 1.2.0.0, 99,840 bytes; --help and --version run successfully.
- All 15 real-EXE integration tests passed in the final full run, including forced parent termination followed by verified exit of its waiting PowerShell child. Normal/failure exits clean extracted runtime files; forced termination may leave the fixed script files behind.
- All 12 original PowerShell launcher integration cases passed after the EXE-specific message changes.
- The actual EXE's --check --no-prompt selected the current Windows HTTP proxy and returned two target HTTPS HTTP 401 responses. This verifies the local unauthenticated proxy route, not a remote login or Codex account.
- All six embedded resources were hashed and matched current source byte-for-byte. Source SSH and local Codex config hashes remained unchanged. Static review found no unresolved blocking issues after preserving relative key-path behavior.
- A later redundant rebuild was prevented by an existing-file lock. Read-only Windows Restart Manager identified McAfee Framework Host as the holder. No security service was changed or stopped; the previously successful build was retained and tested, with its resources verified against final source.
- The published standalone EXE is byte-identical to the tested build; its --version and read-only --list-hosts both ran successfully. The 24-file source/EXE ZIP passed explicit-allowlist and byte-for-byte verification, with no personal settings or credentials. SHA-256 sidecars were generated for both deliverables.

Verification boundary: no new server password/MFA session or manual Ctrl+C acceptance test was performed during packaging. The console/Job design and automated child cleanup were verified separately. No commercial signing certificate was used.

## 2026-10-23 — Import servers from this computer's SSH configuration

Purpose: select an existing SSH alias instead of manually looking up server addresses, users, ports and jump hosts. All saved choices remain inside this package; local Codex and the original SSH configuration are unchanged.

Files and behavior:
- SshImport.ps1: enumerate literal Host aliases across Include files; resolve effective connection fields through bounded local OpenSSH -G; resolve each ProxyJump endpoint independently, with explicit user/port overrides and IPv6 support.
- Start-Tunnel.ps1: numbered server menu, custom SSH file selection, typed alias for wildcard rules, manual fallback, cancel, read-only -ListSshHosts and -ShowSshHelp. Existing saved profiles still launch directly. -ManualSetup retains the original wizard.
- Ssh-Help.cmd / read.md: copyable PowerShell queries and an explanation of alias, hostname, user, port and proxyjump; instructions for VS Code custom SSH config paths.
- TunnelTools.ps1: preserve the special IdentityFile none value when importing, avoiding a fallback to default key files.
- tests/test_ssh_import.ps1 / tests/test_launcher.py / tests/test_tunnel.ps1: import, integration and isolation coverage. Test fixtures contain synthetic hosts only.

Import boundaries:
- Import the selected per-user file and Includes; do not include system-wide SSH config. The generated runtime config still omits existing forwards and remote commands.
- Preflight the complete supported Include graph, including hidden files, before SSH evaluation. Reject Match exec, cyclic/oversized Include graphs and ambiguous structural syntax without executing config commands.
- Refuse ProxyCommand, nested per-hop ProxyJump and nondefault authentication/routing/host-key options that the saved profile cannot preserve. Show the unsupported setting name without exposing command values. The user can choose another config or review the manual lookup instructions.
- Read only key paths, never key contents. Preserve one existing key or explicit none; refuse ambiguous multiple keys, missing explicit keys and unsupported expansions. SSH itself performs normal authentication during a later interactive launch.

Validation (2026-10-23):
- Windows PowerShell 5.1: 47 SSH import checks passed with actual local ssh -G, including Include precedence, quoted paths, Unicode key paths, ordered jumps, overrides, IPv6, guarded unsupported options and rejection before Match exec can run.
- Windows PowerShell 5.1: 43 tunnel/profile checks and 18 proxy checks passed.
- Python development tests: all 12 real PowerShell launcher cases and 20 remote monitor cases passed. Total: 140 checks/tests.
- Read-only import of the user's existing server alias succeeded with two ordered jumps. Original LocalForward/ForwardAgent settings were not copied. Source SSH and local Codex config hashes were unchanged; no profile was saved and no server login was attempted by that check.
- Independent static review found and repaired hidden Include omission and explicit missing default-name key misclassification; final review had no remaining high-impact finding.
- The 19-file ZIP passed allowlist and byte-for-byte source verification. After extraction, its real Windows PowerShell 5.1 launcher selected a fixture alias, saved the correct host/user/custom port, and displayed lookup help. Protected configuration hashes remained unchanged. No personal settings, credentials, Git metadata or debug fixtures are included.

Verification boundary: import tests evaluate local SSH configuration; they do not prove a new computer can log in, that its server permits reverse forwarding, or that Codex is logged in. Those checks remain the normal interactive Start.cmd and plugin flow.

## 2026-10-22 — Portable Windows SSH proxy tunnel

Purpose: reuse the official Codex extension on remote Linux hosts through a Windows computer's existing local HTTP proxy, without changing local Codex configuration. Server address, username, SSH port and jump hosts are generic first-run settings; no personal destination is bundled.

Files:
- Start.cmd / Configure.cmd / Check.cmd: visible entry points.
- Start-Tunnel.ps1 / TunnelTools.ps1: wizard, isolated per-session SSH config, validation, foreground authentication and cleanup.
- ProxyTools.ps1: read-only discovery, bounded TLS/HTTP probing and independent probe watchdog.
- remote-monitor.sh: streamed POSIX monitor, explicit remote proxy probes, degradation/recovery reporting; no server files written.
- settings.example.json / read.md / plan.md / agnet.md / tests/: portable example, user guide and verification records.

Design decisions:
- Select a local proxy only after two target HTTPS responses; never count HTTP CONNECT alone.
- Preserve normal certificate and SSH host-key validation. Store no passwords or tokens.
- Keep failed target checks visible while retaining the SSH tunnel for possible recovery. A missing remote curl is explicitly unverified.
- Do not inherit arbitrary local SSH forwards, change shared remote settings, steal an occupied port or automatically replay password prompts.
- Reconfigure through the package's own settings.json when changing hosts. Optional private-key paths are validated for the current computer.

Validation (2026-10-22):
- Windows PowerShell 5.1: 42 profile/SSH-config assertions passed, including custom users/ports, multiple jumps, IPv6, unsafe input rejection and native OpenSSH `-G` parsing.
- Windows PowerShell 5.1: 18 proxy tests passed, including real IPv6-only listener discovery, native argv quoting, timeout cleanup, CONNECT-only failure, HTTP 403 and malformed output.
- Python development tests: 26 tests passed (6 real PowerShell launcher/wizard cases and 20 POSIX monitor cases). Covered Chinese paths with spaces, direct/two-jump profiles, no stored passwords, missing tools, failure/recovery, stdin EOF, hangup handling and unsafe listener rejection.
- Real CheckOnly run auto-selected the current local HTTP proxy and received two HTTP 401 responses. A separate read-only probe through the existing authenticated SSH route also returned target HTTP 401.
- The exact generated command and streamed monitor payload were executed through Windows PowerShell 5.1 into Git Bash against a real proxy: HTTP 401 and TUNNEL_READY; listener binding was explicitly unverified because that local test shell has no ss.
- Local Codex config.toml and global SSH config SHA-256 values were unchanged across the checks. No credential contents were read or copied.
- The ZIP was checked byte-for-byte against an explicit 16-file allowlist. It contains no real settings.json, credentials, runtime state, Git directory or bytecode cache. Its extracted launcher also passed a real CheckOnly run with two target HTTP 401 responses.

Review repairs: localhost proxy candidates now cover both IPv4 and IPv6; the server monitor checks actual listener addresses when ss is available and stops its own session if sshd forces a non-loopback bind.

Verification boundary: no new password/MFA SSH session was opened on an unspecified second computer or server. Existing-route tests do not substitute for that first interactive login. HTTP 401 proves unauthenticated target HTTPS access only, not Codex account login, all authentication hosts or model inference. Runtime automatic checks provide those network observations when the user first runs the package; actual plugin login/inference still require the normal UI flow.
