# Changelog

## [0.4.0] - 2026-08-26

### Added
- **Multiple servers, as a list** — Trusty now keeps a list of servers on a dedicated **Servers** tab: one card per server, one click switches the active server, the pencil opens an inline editor (with a discard-unsaved-changes guard), **Add server** opens a dialog that commits nothing until confirmed, and Delete lives inside the editor. Servers can have display names. The Home screen additionally shows a quick switcher above the Connect button when more than one server is saved. Switching replaces only the connection fields (host, credentials, protocol tweaks); app-wide settings — DNS, log level, VPN mode, split-tunneling lists — are preserved (DNS and log level are truly app-global keys now, with one-time migration). The existing single config is migrated into the list automatically. The **Settings** tab holds only application options (log level, close behavior); **shared network settings** (DNS — identical for every server) sit at the bottom of the Servers tab. The server-deployment tab is now called **Deploy**.
- **Test connection** — the Add-server dialog and the inline editor have a button that checks reachability (TCP connect + TLS handshake with the hostname as SNI) and reports the result. Catches wrong IP/port, firewall, no TLS listener, and certificate mismatches before you save (it does not verify VPN credentials — that needs a full connect).
- **Custom routing lists** — the one-click "sites blocked in Russia" preset (the maintained [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains) lists: blocked domains + Telegram/Discord subnets, ~1200 entries) is now one entry of a general mechanism: add your own lists from a raw URL (GitHub etc.) or a local file, with a validation preview ("Found N valid entries"). URL lists **auto-update at connect time** when older than 24 hours (bounded by an 8-second budget; falls back to the cached copy offline, re-downloads if the cache file vanished). Each list can apply in Selective mode (route via VPN), General mode (bypass VPN) or both; the user's own domain list stays separate.
- **Geosite / GeoIP presets** — the add-list dialog opens on a curated preset picker instead of demanding a raw URL: v2fly community domain categories ([domain-list-community](https://github.com/v2fly/domain-list-community) — YouTube, Discord, Meta (Facebook/Instagram), Telegram, Twitter/X, Netflix, OpenAI, Google) and per-country IP ranges ([v2fly/geoip](https://github.com/v2fly/geoip) — Russia, Ukraine, USA, Netherlands, Germany). Geosite files are parsed natively — `full:` entries, `include:` chains (with cycle and depth protection), `@attribute` tails; `regexp:`/`keyword:` rules that can't be expressed as exclusions are skipped. The cache always stores the flat parsed list, so auto-update and connect-time merging work unchanged; manual URL/file lists stay available. When the merged exclusions exceed a soft limit of 20 000, the app warns (log line + toast) that connection setup may slow down — but never blocks the connect.
- **Multiple DNS upstreams, with presets** — the DNS field accepts several upstreams separated by commas (e.g. a DoH resolver plus a plain-IP fallback); all of them are written to `dns_upstreams`. A preset menu next to the field (AdGuard Default / Family / Non-filtering, Cloudflare, Google) appends the chosen DoH upstream to the list — no duplicates, nothing you typed is overwritten.
- **Deploy without overwriting** — "Apply Client Settings" after a VPS deployment adds the deployed server as a new list entry (or updates the entry with the same domain) and makes it active. Other saved servers are never touched.
- **Real error state on Home** — a failed connect now shows a persistent error card with the specific reason ("run as administrator", "Wintun busy") instead of a vanishing toast with a raw exception; connecting to an unconfigured placeholder is refused with a hint. The Home screen always shows the active server and a live connection timer.
- **Logs got levels** — filter chips (All / Errors / Warnings) with counts, level-based coloring that also understands raw CLI `ERROR/WARN` lines, an error-count badge in the footer, and an honest "assuming connected" log line when the readiness timeout fires.
- **Deploy hardening** — the failed step is now marked red in the checklist (instead of greying everything), non-secret form fields survive restarts, the generated connection-filtering prefix is persisted and shown with a copy button (a "Last deployment" card restores it after a restart), installs can be **cancelled**, the success summary reflects the actually deployed values, and the log panel scrolls itself instead of yanking the page.
- **SOCKS5 connection mode** (requested in [#12](https://github.com/Meddelin/trusty/issues/12)) — Settings → Application has a connection-mode switch: **VPN (TUN)** (the default: full-system tunnel through a virtual adapter — Wintun on Windows) or **Proxy (SOCKS5)**, where the client runs a local SOCKS5 proxy on `127.0.0.1:<port>` (port configurable, loopback only) and creates **no network interface — `wintun.dll` is not used at all**. In SOCKS5 mode the app skips every piece of adapter handling (release waits, "Wintun busy" retries, "run as administrator" hints) and on macOS launches the client without sudo/privilege setup. The Home screen shows the proxy address while connected. Split-tunnel rules still apply to connections that go through the proxy, but only apps pointed at the proxy are tunneled at all — the Split Tunnel screen shows a banner saying exactly that. Known limitation: on Windows the app itself still requests administrator rights at startup even in SOCKS5 mode (the elevation is baked into the exe manifest); making it on-demand is separate future work.
- The **Post-Quantum Key Exchange** toggle now explains what it does and why it should stay enabled.

### Security
- **Client random prefix in the OS keystore** — the connection-filtering prefix is an access token, and it used to sit as plaintext JSON in `SharedPreferences`. It now lives in the keystore (one key per server, plus the deploy result's generated prefix), like the password; existing plaintext values are migrated automatically.
- **Config file cleanup** — the generated `trusttunnel_client.toml` (which contains the VPN password in plaintext) is deleted after disconnect and on app exit instead of lingering on disk; it is rewritten on every connect anyway.

### Changed
- **Instant close** — quitting no longer awaits the native window teardown before exiting; the app closes immediately instead of stalling for seconds (and can no longer hang if that teardown never completes). A repeated close click no longer stacks dialogs.
- **Unified messages** — one themed `InfoBanner` (info/warning/error, correct dark-mode contrast, optional persistent dismiss) replaced seven hand-rolled banners; one snackbar helper with fixed conventions (success 3s / warning 4s / error 6s with an automatic Copy action) replaced ~20 ad-hoc toasts. The first-run Home card and the update banner are dismissible for good.
- **Visual refresh** — custom desaturated steel-blue theme with semantic status tokens (correct in dark mode; red reserved for errors), flat tonal cards with hairline outlines, tonal navigation rail, floating snackbars, an animated status hero (breathing ring while connected, rotating icon while connecting), a calm tonal Disconnect button, and content constrained to a 640px column on desktop.

### Changed — Split Tunnel rework
- **Adding entries is instant** — a new entry lands in the list immediately; the related-domains discovery is now an optional "Find related" snackbar action instead of a blocking dialog on every add.
- **Input normalization & validation** — the add field accepts whatever you paste: a full URL (`https://VK.com:443/feed` → `vk.com`), a bare domain (including unicode like `кино.рф`), `*.wildcard`, IPv4/IPv6 (with or without port/brackets) or CIDR. Invalid entries are rejected with a message; a typo like `10.0.0.0/99` is an error instead of being silently truncated. The same validation applies to bulk import (with a "N invalid skipped" summary) and to adding into a group.
- **Editable while connected** — the Split Tunnel screen is no longer locked while the VPN is up; changes are saved immediately and apply on the next connect (the banner says so).
- **Apps tab** — selected apps are sorted to the top; apps the scanner didn't find are no longer invisible (they show at the top as "added by process name" entries); the search field doubles as manual add — type a process name and press **+** (bare names get `.exe` appended on Windows). Useful for portable apps and games the scan misses.
- **App list mirrors Settings → Apps, with real icons** — Windows discovery now reads the registry Uninstall hives (the same set as Installed Apps) plus Microsoft Store packages (`Get-AppxPackage` + manifest parsing), instead of blindly scanning the filesystem for every exe. Each entry shows the application's actual icon (extracted in one PowerShell batch, cached); process names are resolved from `DisplayIcon`/install locations. macOS scans `/System/Applications` too (Music, Safari). **Running processes** are still available — as search results only, so the default list stays clean. App search is space-insensitive ("apple music" matches `AppleMusic.exe`).
- **Compact mode switcher** — the two large mode cards are now a segmented button with a one-line description, freeing vertical space for the actual lists.
- Duplicate checks now work across groups and the standalone list together, case-insensitively; the group "rename" button is labeled Rename instead of Save.

### Performance
- **Bulk paste import is linear now** — importing a pasted domain list de-duplicated each line with a `List.contains` scan (quadratic: already noticeable around a thousand lines, minutes at tens of thousands); de-duplication now goes through a `Set`, extracted as a testable `importExclusionList` helper.
- **Domains tab builds its rows lazily** — the domain list is a `ListView.builder` instead of eagerly constructing a widget for every entry on each rebuild.
- Saving or writing the config no longer stringifies the entire domain list into the debug log (counts are logged instead) — with merged routing lists that built megabyte-sized log strings on every connect.
- **Large-list perf tests** — a new suite (`test/perf/large_lists_perf_test.dart`) proves 50 000-entry workloads stay fast and correct: TOML generation, pasted-list import, geosite/geoip parsing, routing-list merging with de-duplication, JSON round-trips of stored structures, and `.lst` cache loading — each asserts both the result and a generous wall-time bound, offline and deterministic.

### Fixed
- Saving connection settings no longer resets the VPN mode and split-tunneling lists (the Settings form previously rebuilt the config from scratch).

## [0.3.4] - 2026-07-18

### Security
- **TOML injection** — escape quotes/newlines/backslashes in all interpolated values (passwords, usernames, hostnames, domains, DNS, exclusions, SNI) in both the client config and the generated server configs, so a crafted value can't inject extra config keys.
- **Command injection** — validate `domain`/`email` (hostname/email shape + reject shell metacharacters) before they're used in root SSH commands during server deployment.
- **SSH MITM** — trust-on-first-use host-key verification for server deployment: the fingerprint is stored on first connect and a later mismatch aborts the deploy. A "Trust new host key & retry" button recovers when the change is expected (e.g. a rebuilt VPS).
- **macOS sudoers injection** — reject binary paths/usernames containing shell metacharacters or whitespace before writing the NOPASSWD sudoers rule, plus quote-escaping as defense in depth. The rule is now validated by `visudo` in a staging file (`trusty.tmp`, ignored by sudo) and only moved into place when valid, so a bad rule can never break sudo.
- **Credential storage** — the VPN password is now kept in the OS keystore (Windows DPAPI / macOS Keychain) instead of plaintext `SharedPreferences`; existing plaintext is migrated, and the generated config file is `chmod 600` (non-Windows). A keystore read failure degrades to an empty password instead of resetting the whole saved configuration.
- **TLS** — domain discovery no longer accepts invalid certificates; a warning is shown when "skip certificate verification" is enabled.

### Performance
- **Instant disconnect** — the client process is terminated immediately and the UI flips back to "Connect" right away; the Wintun adapter-release wait (Windows) is deferred and paid lazily at the start of the next connect, where it has usually already elapsed.
- **Faster connect** — the app watches the client output for a tunnel-up marker instead of sleeping a fixed 2 s, so the status turns "Connected" as soon as the tunnel is actually up (5 s fallback if no marker appears).
- **Snappier app exit** — quitting no longer blocks on the adapter-release wait.
- **Split Tunnel** — the installed-apps list loads lazily on first open of the Apps tab and the filesystem scan runs off the UI thread; log-based domain suggestions are debounced (500 ms batches) with a cached domain set instead of a per-line rescan.
- **Logs screen** — static header chrome no longer rebuilds on every incoming log line.

### Added
- **Close-window behavior** — the close dialog has a "Remember my choice" checkbox, and a new "On window close" setting (ask / minimize / exit) in Settings → Advanced lets you change the remembered choice later.
- **Tray sync** — the tray menu and tooltip now follow VPN status changes regardless of where they originate (Home screen button, tray, process exit).

### Changed
- **macOS is out of alpha** — alpha wording removed from the workflow, docs and release notes; macOS releases are stable from now on.

### Fixed
- A stale process-exit handler could clear the active connection state (and the new process reference) during a fast disconnect→reconnect.
- Cancelling while the adapter-release wait was pending no longer launches the client afterwards.

## [0.3.3] - 2026-07-17

### Added
- **Update notifications**: Trusty now checks GitHub Releases for a newer version on startup and once a day while running in the tray. When an update is available, the Home screen shows a dismissible banner with the new version number and a **Download** button that opens the release page in the browser.
- App version is read from the binary metadata (`package_info_plus`), so the update check always compares against the real built version — no manually maintained version constant.
- Network or GitHub API failures (offline, rate limit) are silent: the banner simply doesn't appear, and the check retries within a day.

### Changed
- macOS release workflow no longer marks releases as pre-release: both platform workflows publish into the same release, and a pre-release flag could hide it from `/releases/latest` — the endpoint the update check relies on.
- Release notes templates in CI updated for 0.3.3.

### Fixed
- All static-analysis warnings (unused import, dead code, deprecated `withOpacity`, `print` in production code, redundant string interpolation braces).
- Removed the stock template widget test that could never pass in this app.

## [0.3.2] - 2026-06-21

### Fixed
- **Connection filtering (client random prefix) now works.** The client config wrote the TLS client random under the wrong key — `client_random_prefix` instead of `client_random` — so the bundled client silently ignored it and could not connect to servers that filter by the prefix (handshakes were rejected: "Failed to ping location" / "Number of connection attempts exceeded", or "QUIC connection closed due to transport error"). The client config now uses the correct `client_random` key, and the auto-generated server prefix uses the required `prefix/mask` form. Servers without filtering were unaffected.

## [0.3.1] - 2026-06-20

### Added
- **Client random prefix** field in Settings — lets you connect to servers that filter connections by a TLS client random prefix.
- **Connection filtering** option when deploying a server — generates the prefix, configures the server to allow only your client, and auto-fills it into your client settings.
- **Bulk import** for split tunneling — paste a whole list of domains/IPs/CIDR at once instead of adding them one by one.

### Changed
- Server install now asks for confirmation before stopping and replacing an existing TrustTunnel installation.

### Fixed
- Windows: window close/minimize/maximize buttons could be invisible on the light theme.
- Connection failing to start when the application path contained non-ASCII characters (e.g. Cyrillic).

## [0.3.0] - 2026-05-27

### Added
- **Server Auto-Deployment**: Completely revamped Server Setup UI with automatic SSH configuration, robust installation of the latest TrustTunnel server, and auto-SSL certificate acquisition.
- **Dynamic Port Selection**: Setup wizard automatically detects busy ports (e.g., if 443 is used by Nginx, it tries 8443, then 4433) and configures the VPN to use a free port.
- **Auto-Update Existing Servers**: The install wizard safely detects and updates existing TrustTunnel server installations.
- **Multi-Protocol Support on Server**: Automatically configures the server `vpn.toml` to support HTTP/1 (WebSocket), HTTP/2, and QUIC, ensuring compatibility with the client's default HTTP/2 upstream protocol.
- **Reactive Configuration Application**: The "Apply to client" button now pushes configurations directly to the Settings screen in real-time, eliminating the need to restart or switch tabs blindly.

### Changed
- Tab navigation now preserves the form state across screens using `IndexedStack`.
- Server Installation defaults SSH key path directly to `~/.ssh/id_rsa` or `id_ed25519` for convenience.

### Fixed
- Let's Encrypt (Certbot) failures when port 80 is occupied, by dynamically falling back to Nginx/Apache plugin validation.
- Missing `listen_protocols` block in the generated `vpn.toml` that previously caused the TrustTunnel server endpoint to panic on start.
- Port auto-scanner skipping logic on existing servers, ensuring robust port availability on reinstall.
