# Changelog

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
