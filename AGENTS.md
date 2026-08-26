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
│   └── domain_group.dart          # DomainGroup + DomainGroupsData models
├── services/
│   ├── config_service.dart        # Persistence (SharedPreferences) + server list + routing preset + TOML file I/O
│   ├── vpn_service.dart           # Process management, connection state, logs
│   ├── server_setup_service.dart  # Remote VPS deployment via SSH (dartssh2)
│   └── domain_discovery_service.dart  # HTTP fetch + HTML parse for related domains
└── screens/
    ├── home_screen.dart           # Connect/disconnect, status display
    ├── servers_screen.dart        # Server list (one-click switch, inline editor) + shared DNS
    ├── settings_screen.dart       # App-level settings (log level, close action)
    ├── server_setup_screen.dart   # Remote server deployment form + progress
    ├── split_tunnel_screen.dart   # Domain groups, app discovery, log suggestions
    └── logs_screen.dart           # Real-time log viewer
```

### UI Conventions
- Theme: `lib/theme/app_theme.dart` — one builder for both brightnesses (steel-blue seed, flat tonal cards) + `ThemeExtension<StatusColors>`; status colors ONLY via `VpnStatusExtension.colorOf(context)`, red is reserved for errors.
- Messages: inline strips use `widgets/info_banner.dart` (severity + optional persistent dismissKey); toasts use `utils/app_snackbar.dart` (`showAppSnackBar` — fixed durations, auto-Copy on errors, never queues). Do not hand-roll colored Containers or raw ScaffoldMessenger calls.
- Log severity: `utils/log_level.dart` parses both emoji markers and raw CLI ` ERROR / WARN ` tokens; the Logs screen filters/colors by it.
- Desktop layout: screen content is constrained to a 640px column.

### State Management
- **Provider** + `ChangeNotifierProvider`
- `VpnService` — reactive connection state + logs
- `ServerSetupService` — SSH deployment state + logs
- `ConfigService` — plain service injected via `Provider`

### Server List & Persistence Keys
Multiple servers are stored in SharedPreferences; `server_config` remains the single "active config" contract all screens read/write:
- `server_config` — active config JSON (its `id` links it to the list entry)
- `server_list` — array of all server entries (passwords never stored here)
- `active_server_id` — id of the active entry
- Passwords: OS keystore, one `vpn_password_<id>` key per server (legacy `vpn_password` kept as a read fallback / downgrade safety)
- `routing_lists` (JSON array of `RoutingList`) + `client/routing_lists/<id>.lst` caches — ready-made routing lists (built-in blocked-in-Russia preset + user URL/file lists), merged into exclusions at TOML-write time per each list's `appliesTo` mode; URL lists auto-refresh at connect when older than 24h (8s budget). Legacy `routing_preset_*` keys migrate automatically.
- `app_dns`, `app_log_level` — app-global settings (seeded from the active config once; server entries may carry stale copies that are ignored)
- `deploy_form_config`, `deploy_last_result` — non-secret VPS-deploy form defaults and the persisted outcome of the last successful deploy (incl. generated client_random_prefix)
- `banner_dismissed_*`, `update_dismissed_version` — persistent dismissals of InfoBanners / the update banner

`saveConfig()` upserts the active entry by id and makes it active; `switchServer()` swaps only connection fields, preserving app-wide settings (DNS, log level, VPN mode, split tunneling). The one-time migration wraps a legacy single config into the list on first access.

### Connection Flow
1. User clicks Connect → `HomeScreen._handleButtonPress()`
2. `ConfigService.loadConfig()` → SharedPreferences
3. **macOS only:** `VpnService._ensureMacOSPrivileges(exePath)` — checks setuid bit via `stat -f %Sp`; if missing, calls `osascript` to show macOS password dialog and runs `chmod u+s` (one-time per install)
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
| Client dir | `Directory.current.path/client/` | Navigate up from `.app` bundle |
| TUN driver | Wintun (wintun.dll, 5s release wait) | Native utun + setuid via osascript (one-time) |
| Tray icon | `.ico` via `Platform.resolvedExecutable` path | `.png` via `.app/Contents/Frameworks/...` |
| App discovery | Registry Uninstall hives (= Settings → Apps) + Store apps via `Get-AppxPackage`/AppxManifest; icons via `ExtractAssociatedIcon` batch into temp cache; running processes via `tasklist` (search-only) | `/Applications` + `/System/Applications` → `.app` bundles, running processes via `ps` |

Key platform checks in code:
- `config_service.dart`: `getClientDirectory()`, `getTrustTunnelExecutable()`
- `vpn_service.dart`: `_ensureMacOSPrivileges()` + `_hasMacOSSetuid()` (macOS); Wintun waits in `connect()`, `disconnect()`, `shutdown()` (Windows, 4 places)
- `split_tunnel_screen.dart`: `_getInstalledAppsWindows()` / `_getInstalledAppsMacOS()`
- `main.dart`: tray icon path
- `home_screen.dart`: help text (exe name)
- `server_setup_screen.dart`: SSH key path hint

## File Locations at Runtime

| File | Windows | macOS |
|------|---------|-------|
| CLI binary | `./client/trusttunnel_client.exe` | `../client/trusttunnel_client` (relative to .app) |
| TUN driver | `./client/wintun.dll` | Not needed |
| Config | `./client/trusttunnel_client.toml` | `../client/trusttunnel_client.toml` |
| Tray icon | `./data/flutter_assets/assets/tray_icon.ico` | Inside `.app` bundle (`.png`) |

## CI/CD

Two GitHub Actions workflows triggered on `v*` tags:

- `.github/workflows/release.yml` — Windows (stable release)
- `.github/workflows/release-macos.yml` — macOS (stable release)

Both download the **latest** CLI from [TrustTunnelClient releases](https://github.com/TrustTunnel/TrustTunnelClient/releases) at build time.

### Release Process
1. Update version in `pubspec.yaml`
2. `git commit && git tag vX.Y.Z && git push origin vX.Y.Z`
3. Both workflows run automatically

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
| path | ^1.9.1 | Path manipulation |
| tray_manager | ^0.2.3 | System tray (Windows, macOS) |
| window_manager | ^0.4.2 | Window control |
| dartssh2 | ^2.9.0 | SSH/SFTP for server deployment |
| ffi | ^2.1.0 | Win32 `GetShortPathNameW` (ASCII paths for the CLI) |
| cupertino_icons | ^1.0.8 | Icons |

## Known Issues & TODOs

- [ ] macOS: no code signing (Gatekeeper bypass required on first launch)
- [ ] No auto-download CLI at runtime
- [ ] Routing preset updates are manual (refresh button); no scheduled auto-update
- [ ] Limited tests (model/parser unit tests; no widget/integration coverage)
- [ ] SOCKS5 listener not in GUI (TUN only)
- [ ] No auto-reconnect
- [ ] Deep-link import (`tt://?` format, `--deeplink` flag) not implemented

## Upstream

- TrustTunnel Client: https://github.com/TrustTunnel/TrustTunnelClient (latest tested: v1.0.49)
- TrustTunnel Server: https://github.com/TrustTunnel/TrustTunnel
- License: Apache 2.0
- Platforms: Windows, Linux, macOS (universal)
- Wintun: https://www.wintun.net/ (Windows only)
