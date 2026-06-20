# Changelog

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
