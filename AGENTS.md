# AGENTS.md — Trusty Project Guide

## Overview

**Trusty** is a cross-platform Flutter GUI client for [Trusty VPN](https://github.com/TrustTunnel/TrustTunnelClient) (Apache 2.0).
A wrapper around the CLI client: generates TOML configs and manages the process.

**Platforms:** Windows 10/11, macOS 11+ (both stable)

## Architecture

```
lib/
├── main.dart                      # Entry point, window/tray, navigation
├── models/
│   ├── server_config.dart         # VPN config model + TOML generation (toToml())
│   ├── server_setup_config.dart   # Remote server deployment config (SSH, domain, VPN creds)
│   ├── setup_step.dart            # Setup step enum with UI props
│   ├── vpn_status.dart            # Status enum with UI properties (color, icon, text)
│   ├── domain_group.dart          # DomainGroup + DomainGroupsData models
│   └── routing_list.dart          # RoutingList model (ready-made domain/IP sets)
├── services/
│   ├── config_service.dart        # Persistence (SharedPreferences) + server list + routing lists + TOML file I/O
│   ├── vpn_service.dart           # Process management, connection state, logs
│   ├── server_setup_service.dart  # Remote VPS deployment via SSH (dartssh2)
│   ├── domain_discovery_service.dart  # HTTP fetch + HTML parse for related domains
│   └── update_service.dart        # Running version, new-release check, repo link
├── screens/
│   ├── home_screen.dart           # Connect/disconnect, status display
│   ├── servers_screen.dart        # Server list (one-click switch, inline editor) + shared settings
│   ├── server_setup_screen.dart   # Remote server deployment form + progress ("Deploy")
│   ├── split_tunnel_screen.dart   # Domain groups, routing lists, app discovery, log suggestions
│   └── logs_screen.dart           # Real-time log viewer + log level
├── theme/app_theme.dart           # Both brightnesses, StatusColors, control geometry, pointer states
├── widgets/                       # AppSwitch, InfoBanner, GitHubMark, TelegramMark
└── utils/                         # log_level, exclusion_parser, routing_source_parser, connection_test, app_snackbar
```

There is no `settings_screen.dart`: the Settings tab was removed in 1.0.0 and its
three controls moved next to what they govern (see UI Conventions → Navigation).

### UI Conventions

Read `design-concepts/KIT.md` before you touch a screen: it holds the tokens, the
type scale, the control geometry and every component shape. `design-concepts/COPY.md`
is the authority on what a user-facing string may claim. Check it before writing one.

- Theme: `lib/theme/app_theme.dart` — one builder for both brightnesses (palette taken
  from the app icon: teal accent over near-black, flat cards with hairline borders) +
  `ThemeExtension<StatusColors>`. Both brightnesses follow the OS setting.
- Colors come from `Theme.of(context).colorScheme` or the `StatusColors` extension.
  Never write a `Color(0x…)` literal in a screen or a widget. Status colors ONLY via
  `VpnStatusExtension.colorOf(context)`, red is reserved for errors.
- Control geometry (heights, radii, borders, padding) is stated once in the theme.
  If a control comes out the wrong shape, fix the theme rather than the call site.
- No Material ripple anywhere: `splashFactory` is `NoSplash` app-wide. Hover and press
  are flat tints, focus is a ring (`focusRingSide`, `kFocusRingWidth`). Give a new
  control the same three states.
- Toggles use `AppSwitch` (`widgets/app_switch.dart`). Material's `Switch` is three
  times the size of every other control and its geometry is not reachable through
  `switchTheme`, so it is replaced rather than restyled.
- Type: Geologica for the interface, ChivoMono for values the user reads as data
  (hosts, addresses, ports, counts, log lines), with JetBrainsMono behind it for
  Cyrillic. All three are bundled in `assets/fonts/`. Headings are never mono, and
  there are no uppercase tracked labels.
- No emoji, in the interface or in log output.
- Navigation: five destinations in the rail, Home, Servers, Split Tunnel, Logs, Deploy.
  Do not add a Settings tab back. App-wide controls sit next to what they govern: log level on
  Logs, connection mode and SOCKS5 port with the shared DNS on Servers, window-close
  behaviour in the navigation rail footer (which also carries the GitHub and Telegram
  links and the running version).
- Messages: inline strips use `widgets/info_banner.dart` (severity + optional persistent dismissKey); toasts use `utils/app_snackbar.dart` (`showAppSnackBar` — fixed durations, auto-Copy on errors, never queues). Do not hand-roll colored Containers or raw ScaffoldMessenger calls.
- Log severity: `utils/log_level.dart` reads a real level token, either the app's own
  leading `ERROR`/`WARN`/`DEBUG` or the CLI's inline ` ERROR / WARN ` tag; the Logs
  screen filters and colors by it. Severity never travels as a glyph.
- Desktop layout: screens fill the window as flat cards, edge to edge, with no centred
  column. The window minimum is 850×650 and every screen has to survive it.
- Accessibility: an icon-only control needs a `tooltip` or a `Semantics` label, and text
  has to clear WCAG AA against whatever is actually behind it.

### State Management
- **Provider** + `ChangeNotifierProvider`
- `VpnService` — reactive connection state + logs
- `ServerSetupService` — SSH deployment state + logs
- `ConfigService` — plain service injected via `Provider`

### Server List & Persistence Keys
Multiple servers are stored in SharedPreferences; `server_config` remains the single "active config" contract all screens read/write:
- `server_config` — active config JSON (its `id` links it to the list entry)
- `server_list` — array of all server entries, per-server connection fields only (passwords and client random prefixes never stored here; app-global settings and the split-tunnel lists are not duplicated per entry either)
- `active_server_id` — id of the active entry
- Passwords: OS keystore, one `vpn_password_<id>` key per server (legacy `vpn_password` kept as a read fallback / downgrade safety)
- Client random prefixes: OS keystore, one `client_random_prefix_<id>` key per server (plaintext values in stored JSON migrate on first access; unlike the password, `''` is a real value and is written as-is)
- `routing_lists` (JSON array of `RoutingList`) + `client/routing_lists/<id>.lst` caches — ready-made routing lists (the blocked-in-Russia "Default" set + user/preset URL/file lists), merged into exclusions at TOML-write time per each list's `appliesTo` mode; a fresh install starts with none of them (the blocked-in-Russia set is the first entry of the add-list catalogue instead) and every list, built-in included, can be deleted. `_ensureRoutingLists()` carries the old single preset over only for an install that actually used it; URL lists auto-refresh at connect when older than 24h (8s budget). Sources may be `plain`, v2fly `geosite` or `geoip` (`format` field; absent = plain) — caches always hold the flat parsed entries, so only the download path (`utils/routing_source_parser.dart`, incl. geosite `include:` sub-fetches) is format-aware. Legacy `routing_preset_*` keys migrate automatically.
- `app_dns`, `app_log_level` — app-global settings (seeded from the active config once; server entries may carry stale copies that are ignored)
- `app_connection_mode` (`tun` | `socks5`; absent = tun), `app_socks_port` (default 1080) — app-global connection mode; same stale-copy rule. In `socks5` the TOML gets `[listener.socks]` (loopback only) instead of `[listener.tun]`, and `VpnService` skips all Wintun waits/hints and the macOS sudo path
- `deploy_form_config`, `deploy_last_result` — non-secret VPS-deploy form defaults and the persisted outcome of the last successful deploy (its generated client_random_prefix lives in the keystore under `deploy_last_prefix`)
- `banner_dismissed_*`, `update_dismissed_version` — persistent dismissals of InfoBanners / the update banner

`saveConfig()` upserts the active entry by id and makes it active; `switchServer()` swaps only connection fields, preserving app-wide settings (DNS, log level, VPN mode, split tunneling). The one-time migration wraps a legacy single config into the list on first access.

### Connection Flow
1. User clicks Connect → `HomeScreen._handleButtonPress()`
2. `ConfigService.loadConfig()` → SharedPreferences
3. **macOS + TUN mode only:** `VpnService._ensureMacOSPrivileges(exePath)` — checks setuid bit via `stat -f %Sp`; if missing, calls `osascript` to show macOS password dialog and runs `chmod u+s` (one-time per install). SOCKS5 mode needs no privileges and launches the binary directly (no sudo)
4. `ConfigService.writeConfigFile()` → TOML at `./client/trusttunnel_client.toml`
5. `VpnService.connect()` → spawns CLI with `--config` and `--loglevel`
6. stdout/stderr captured, parsed for log levels; consecutive similar lines collapsed via `_addLog()` deduplication
7. 2s stability check → Connected
8. Exit code != 0 → Error (Wintun check on Windows, TUN permission check on macOS)

### Log Deduplication
`_addLog()` in `vpn_service.dart` strips all digit sequences from the message to produce a pattern. Consecutive lines with the same pattern are collapsed in-place: `"System DNS proxy request id=14812 failed"` + 400 more → `"... request id=14812 failed (×401)"`. State resets on `clearLogs()` and on process exit.

### Server Deployment Flow (SSH)
1. User fills form → `ServerSetupService.installServer(config)`
2. Steps: SSH connect → check system → install → upload configs (SFTP) → certbot → systemd → verify
3. Each step updates `SetupStep` enum → UI rebuilds via `Consumer`
4. On success → "Apply to client" auto-fills settings

### Platform Abstraction

| Component | Windows | macOS |
|-----------|---------|-------|
| CLI binary | `trusttunnel_client.exe` | `trusttunnel_client` |
| Client dir | `client/` next to the executable (`resolveClientBaseDir()`; the launch CWD only in a dev run) | Navigate up from `.app` bundle |
| TUN driver | Wintun (wintun.dll, 5s release wait) | Native utun + setuid via osascript (one-time) |
| Tray icon | `.ico` via `Platform.resolvedExecutable` path | `.png` via `.app/Contents/Frameworks/...` |
| App discovery | Registry Uninstall hives (= Settings → Apps) + Store apps via `Get-AppxPackage`/AppxManifest; icons via `ExtractAssociatedIcon` batch into temp cache; running processes via `tasklist` (search-only) | `/Applications` + `/System/Applications` → `.app` bundles, running processes via `ps` |

Key platform checks in code:
- `config_service.dart`: `getClientDirectory()`, `getTrustTunnelExecutable()`
- `vpn_service.dart`: `_ensureMacOSPrivileges()` + `_hasMacOSSetuid()` (macOS); Wintun waits in `connect()`, `disconnect()`, `shutdown()` (Windows, 4 places) — all gated off in SOCKS5 mode (`classifyStartupFailure` keeps the wintun/admin error hints TUN-only)
- `split_tunnel_screen.dart`: `_getInstalledAppsWindows()` / `_getInstalledAppsMacOS()`
- `main.dart`: tray icon path
- `home_screen.dart`: help text (exe name)
- `server_setup_screen.dart`: SSH key path hint

## File Locations at Runtime

| File | Windows | macOS |
|------|---------|-------|
| CLI binary | `<exe dir>/client/trusttunnel_client.exe` | `../client/trusttunnel_client` (relative to .app) |
| TUN driver | `<exe dir>/client/wintun.dll` | Not needed |
| Config | `<exe dir>/client/trusttunnel_client.toml` | `../client/trusttunnel_client.toml` |
| Tray icon | `<exe dir>/data/flutter_assets/assets/tray_icon.ico` | Inside `.app` bundle (`.png`) |

## CI/CD

Two GitHub Actions workflows triggered on `v*` tags:

- `.github/workflows/release.yml` — Windows (stable release)
- `.github/workflows/release-macos.yml` — macOS (stable release)

Both download the **latest** CLI from [TrustTunnelClient releases](https://github.com/TrustTunnel/TrustTunnelClient/releases) at build time.

### Release Process
1. Update version in `pubspec.yaml` (currently `1.0.0+7`)
2. `git commit && git tag vX.Y.Z && git push origin vX.Y.Z`
3. Both workflows run automatically

## Tests

`flutter test` runs the whole suite. Keep it green before you commit.

- `test/ui/` drives the real screens against the real services; only the platform edges
  are faked (`test/ui/harness.dart`). A screen that overflows at the 850×650 window
  minimum, or a control that throws, fails here the way it would on a user's machine.
- `test/ui/a11y_test.dart` is the accessibility floor: WCAG AA text contrast, measured
  against the pixels actually behind each string, and an accessible name on every
  icon-only control. New UI has to pass it rather than be excluded from it.
- Everything else under `test/` is unit coverage for models, parsers, persistence,
  TOML generation and the connection state machine.

## Important Rules

### Security
- **NEVER** commit real credentials
- `.gitignore` blocks `*.toml` (except `.toml.example`), `*.exe`, `wintun.dll`
- SharedPreferences stores config locally

### UI Language
- All user-facing text is in **English**

### Platform Considerations
- **Windows:** Admin privileges for TUN; needs `wintun.dll`; the Wintun adapter takes ~5s to release after disconnect — handled automatically (the wait is deferred and paid lazily before the next connect); if `WSAENOBUFS (10055)` errors appear, apply registry fix (see README Troubleshooting)
- **macOS:** Sandbox disabled; native utun; no code signing (Right-click → Open on first launch); on first VPN connect, an osascript dialog asks for the Mac password once to set `chmod u+s` on the CLI binary — no terminal needed on subsequent runs

### Split Tunnel Domain Groups
- GUI-only grouping, TOML stays flat `exclusions = [...]`
- All user input goes through `normalizeExclusion()` / `classifyExclusion()` (`utils/exclusion_parser.dart`): URL → host, port/path stripping, domain/IP/CIDR validation (unicode domains supported); invalid input is rejected in the UI
- Auto-discovery: HTTP GET + HTML parse — opt-in via a "Find related" snackbar action after adding a domain (not a blocking dialog)
- Background log monitoring: `VpnService._logObservers` feed suggestions
- Groups flatten via `DomainGroupsData.flattenDomains()`
- The screen stays editable while connected; changes apply on next connect (config TOML is written at connect time)

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| provider | ^6.1.2 | State management |
| shared_preferences | ^2.3.3 | Local config storage |
| flutter_secure_storage | ^10.3.1 | Passwords and filtering prefixes in the OS keystore |
| path | ^1.9.1 | Path manipulation |
| file_selector | ^1.0.3 | Native open dialog for a routing list from a file |
| package_info_plus | ^10.2.1 | Running version, shown in the rail footer |
| tray_manager | ^0.2.3 | System tray (Windows, macOS) |
| window_manager | ^0.4.2 | Window control |
| dartssh2 | ^2.9.0 | SSH/SFTP for server deployment |
| ffi | ^2.1.0 | Win32 `GetShortPathNameW` (ASCII paths for the CLI) |
| cupertino_icons | ^1.0.8 | Icons |

## Known Issues & TODOs

- [ ] macOS: no code signing (Gatekeeper bypass required on first launch)
- [ ] No auto-download CLI at runtime
- [ ] Routing lists refresh at connect (24h staleness) or from the Update now button; no background scheduler
- [ ] No auto-reconnect
- [ ] SOCKS5 mode still requests admin at app startup on Windows (static `requireAdministrator` manifest; on-demand elevation would break CLI stdout capture)
- [ ] Deep-link import (`tt://?` format, `--deeplink` flag) not implemented

## Upstream

- TrustTunnel Client: https://github.com/TrustTunnel/TrustTunnelClient (latest tested: v1.0.49)
- TrustTunnel Server: https://github.com/TrustTunnel/TrustTunnel
- License: Apache 2.0
- Platforms: Windows, Linux, macOS (universal)
- Wintun: https://www.wintun.net/ (Windows only)
