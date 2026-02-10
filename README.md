<p align="center">
  <img src="assets/icon.png" alt="Trusty" width="200">
</p>

# Trusty — VPN Client

[![Windows](https://img.shields.io/badge/platform-Windows-blue.svg)](https://www.microsoft.com/windows)
[![macOS](https://img.shields.io/badge/platform-macOS_(alpha)-lightgrey.svg)](https://www.apple.com/macos)
[![License](https://img.shields.io/badge/license-Apache--2.0-green.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.10.7+-02569B.svg?logo=flutter)](https://flutter.dev)
[![Release](https://img.shields.io/github/v/release/Meddelin/trusty?include_prereleases)](../../releases)

**Trusty** is a cross-platform GUI client for [TrustTunnel VPN](https://github.com/TrustTunnel/TrustTunnel).

> **Platforms:** Windows 10/11, macOS 11+ (alpha)  
> **Status:** Community-developed GUI wrapper for TrustTunnel CLI

## Features

- Material Design 3 interface with light/dark theme
- One-click VPN connection
- **Server deployment to VPS** — automatic setup via SSH
- Split tunneling (General/Selective modes)
- Domain groups with automatic discovery of related resources
- Real-time VPN log monitoring
- System tray integration (Windows, macOS)
- HTTP/2 and HTTP/3 protocols
- IPv6, custom DNS (DoH/DoT/DoQ)
- Random password generation for VPN accounts

## Quick Start

### Windows

1. Download `Trusty-Windows-vX.X.X.zip` from [Releases](../../releases)
2. Extract to your preferred location
3. Run `Trusty.exe`
4. Configure server in "Settings" or deploy your own via "Server"
5. Click "Connect"

The archive includes everything: GUI, CLI client (`trusttunnel_client.exe`), Wintun driver.

### macOS (Alpha)

1. Download `Trusty-macOS-vX.X.X.zip` from [Releases](../../releases)
2. Extract and move `.app` to `/Applications`
3. Place `client/` folder next to `.app`
4. First launch: Right-click → Open (Gatekeeper bypass)
5. Configure and connect

> macOS version is in alpha — no code signing, possible TUN limitations.

### Building from Source

```bash
git clone https://github.com/Meddelin/trusty.git
cd trusty
flutter pub get
flutter build windows --release   # Windows
flutter build macos --release     # macOS
```

See [BUILDING.md](BUILDING.md) for details.

## Server Deployment

Trusty can automatically deploy a TrustTunnel server on a VPS:

1. Open the **Server** tab
2. Enter SSH credentials for your VPS (IP, username, password or key)
3. Specify a domain (must point to VPS via A record)
4. Set VPN username/password
5. Click **Install Server**

Trusty will automatically: connect via SSH → install TrustTunnel → upload configs → obtain TLS certificate via Let's Encrypt → start systemd service.

After installation, click "Apply Client Settings" to auto-fill connection settings.

See [CONFIGURATION.md](CONFIGURATION.md#remote-server-deployment) for details.

## Connection Settings

**Settings** tab:

| Parameter | Description | Example |
|-----------|-------------|---------|
| Hostname | Server domain | `vpn.example.com` |
| IP Address | Server IP | `203.0.113.10` |
| Port | Port | `443` |
| Username | VPN login | `user1` |
| Password | VPN password | `***` |
| DNS | DNS server | `8.8.8.8`, `tls://1.1.1.1` |
| Protocol | HTTP/2 or HTTP/3 | `http2` |

See [CONFIGURATION.md](CONFIGURATION.md) for details.

## Split Tunneling

Two modes:
- **General** — all traffic through VPN, except exclusions
- **Selective** — only specified traffic through VPN

Supports: domains, IPs, CIDR, applications (`.exe` on Windows, `.app` on macOS).

Domain groups with auto-discovery: when adding a domain, Trusty finds related resources (CDN, API) and offers to group them.

## Project Structure

```
trusty/
├── lib/
│   ├── main.dart                    # Entry point, window, tray, navigation
│   ├── models/                      # Data models
│   │   ├── server_config.dart       # VPN client config + TOML
│   │   ├── server_setup_config.dart # Server deployment config
│   │   ├── setup_step.dart          # Server setup steps
│   │   ├── domain_group.dart        # Domain groups
│   │   └── vpn_status.dart          # VPN statuses
│   ├── services/                    # Business logic
│   │   ├── vpn_service.dart         # VPN process management
│   │   ├── config_service.dart      # Configuration and files
│   │   ├── server_setup_service.dart # SSH server deployment
│   │   └── domain_discovery_service.dart # Domain discovery
│   └── screens/                     # UI screens
│       ├── home_screen.dart         # Home (connection)
│       ├── settings_screen.dart     # Server settings
│       ├── split_tunnel_screen.dart # Split tunneling
│       ├── server_setup_screen.dart # Server deployment
│       └── logs_screen.dart         # Log viewer
├── assets/
│   ├── icon.png                    # App icon (1024x1024)
│   ├── tray_icon.ico               # Tray icon (Windows)
│   └── tray_icon.png               # Tray icon (macOS)
├── windows/                        # Windows platform
├── macos/                          # macOS platform
├── .github/workflows/
│   ├── release.yml                 # CI/CD Windows
│   └── release-macos.yml           # CI/CD macOS (alpha)
└── client/                         # CLI binaries (runtime)
```

## Platform Details

| | Windows | macOS (alpha) |
|---|---|---|
| CLI | `trusttunnel_client.exe` | `trusttunnel_client` |
| TUN driver | Wintun (`wintun.dll`) | Built-in utun |
| Tray icon | `.ico` | `.png` |
| App discovery | Program Files, AppData | `/Applications` |
| Code signing | Not required | None (Right-click → Open) |

## Troubleshooting

### "Trusty client not found"
- Make sure the CLI binary is in `client/` next to the application
- Windows: `client/trusttunnel_client.exe`
- macOS: `client/trusttunnel_client`

### Wintun Errors (Windows)
- Close other VPN clients (AmneziaVPN, WireGuard, etc.)
- Wintun driver can only be used by one application at a time
- Wait 5 seconds after disconnecting before reconnecting

### macOS: Gatekeeper Blocks Launch
- Right-click on `.app` → Open → Open
- Or: System Settings → Privacy & Security → Allow

### Connection Not Establishing
1. Check server hostname, IP and port
2. Check username and password
3. Try switching protocol (HTTP/2 ↔ HTTP/3)
4. Review logs in the "Logs" tab

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Included components:
- [TrustTunnel Client CLI](https://github.com/TrustTunnel/TrustTunnelClient) — Apache 2.0
- See [NOTICE](NOTICE) for full license information

## Links

- [TrustTunnel Protocol](https://github.com/TrustTunnel/TrustTunnel) — core protocol and server
- [TrustTunnel Client](https://github.com/TrustTunnel/TrustTunnelClient) — CLI client
- [Issues](../../issues) — report a problem

---

Made with Flutter
