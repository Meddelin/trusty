<p align="center">
  <img src="assets/icon.png" alt="Trusty" width="200">
</p>

# Trusty — VPN Client

[![Windows](https://img.shields.io/badge/platform-Windows-blue.svg)](https://www.microsoft.com/windows)
[![macOS](https://img.shields.io/badge/platform-macOS-black.svg)](https://www.apple.com/macos)
[![License](https://img.shields.io/badge/license-Apache--2.0-green.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.10.7+-02569B.svg?logo=flutter)](https://flutter.dev)
[![Release](https://img.shields.io/github/v/release/Meddelin/trusty?include_prereleases)](../../releases)

**Trusty** is a cross-platform GUI client for [TrustTunnel VPN](https://github.com/TrustTunnel/TrustTunnel).

> **Platforms:** Windows 10/11, macOS 11+
> **Status:** Community-developed GUI wrapper for TrustTunnel CLI — see [CHANGELOG.md](CHANGELOG.md) for what's new

## Features

- Material Design 3 interface with light/dark theme
- One-click VPN connection — connects as soon as the tunnel is up, disconnects instantly
- **Two connection modes** — full-system VPN through a TUN adapter, or a local SOCKS5 proxy on `127.0.0.1` (no virtual adapter / Wintun required)
- **Multiple servers** — keep a list of servers on the Servers tab and switch with one click (or from the Home screen switcher); per-server passwords and connection-filtering prefixes in the OS keystore
- **Server deployment to VPS** — automatic setup via SSH, with optional connection filtering (anti-probe TLS prefix); a deployed server is added to the list without touching existing ones
- **Ready-made routing lists** — one-click "sites blocked in Russia" preset ([itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains)) plus your own lists from a GitHub raw URL (auto-updating every 24h) or a local file
- Split tunneling (General/Selective modes)
  - Domains, IPs, CIDR ranges and applications
  - Bulk import — paste a whole list of domains/IPs/CIDR at once
  - Domain groups with automatic discovery of related resources
  - Domain suggestions harvested from live VPN logs
- Real-time VPN log monitoring
- System tray integration (Windows, macOS) — tray always reflects the current status
- Configurable close behavior — ask / minimize to tray / exit
- HTTP/2 and HTTP/3 protocols
- IPv6, custom DNS (DoH/DoT/DoQ), Anti-DPI, post-quantum key exchange, custom SNI
- Random password generation for VPN accounts

### Security

- VPN passwords and connection-filtering prefixes are stored in the OS keystore (Windows DPAPI / macOS Keychain), never in plain text
- SSH credentials for server deployment are used in-memory only and **never stored**
- SSH host-key pinning (trust-on-first-use) protects server deployment from MITM
- All values interpolated into configs are escaped; deployment inputs are validated before reaching the server shell
- The generated client config file is restricted to your user account and deleted after disconnect and on exit
- A prominent warning is shown if certificate verification is disabled

## Quick Start

### Windows

1. Download `Trusty-Windows-vX.X.X.zip` from [Releases](../../releases)
2. Extract to your preferred location
3. Run `Trusty.exe`
4. Add your server on the "Servers" tab or deploy your own via "Deploy"
5. Click "Connect"

The archive includes everything: GUI, CLI client (`trusttunnel_client.exe`), Wintun driver.

### macOS

1. Download `Trusty-macOS-vX.X.X.zip` from [Releases](../../releases)
2. Extract and move `.app` to `/Applications`
3. Place `client/` folder next to `.app`
4. First launch: Right-click → Open (the app is not code-signed, so Gatekeeper needs a one-time confirmation)
5. Add your server on the "Servers" tab
6. Click "Connect" — on **first connect only**, a macOS password dialog appears to grant VPN tunnel access (one-time setup, no terminal required)

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

1. Open the **Deploy** tab
2. Enter SSH credentials for your VPS (IP, username, password or key) — used for this session only, never saved
3. Specify a domain (must point to VPS via A record)
4. Set VPN username/password
5. (Optional) Enable **connection filtering** — Trusty generates a secret TLS prefix so the server answers only your client and ignores probes/scanners
6. Click **Install Server**

Trusty will automatically: connect via SSH → verify the host key (trust-on-first-use) → install TrustTunnel → upload configs → obtain TLS certificate via Let's Encrypt → start systemd service.

If TrustTunnel is already installed on the server, Trusty asks for confirmation before replacing it. If the server's SSH host key changed (e.g. you rebuilt the VPS), the deploy stops and offers **Trust new host key & retry**.

After installation, click "Apply Client Settings" — the new server is added to your server list and becomes active (existing servers are kept untouched), including the generated prefix, if enabled.

See [CONFIGURATION.md](CONFIGURATION.md#remote-server-deployment) for details.

## Connection Settings

**Servers** tab (per-server), **Settings** tab (app-level):

| Parameter | Description | Example |
|-----------|-------------|---------|
| Hostname | Server domain | `vpn.example.com` |
| IP Address | Server IP | `203.0.113.10` |
| Port | Port | `443` |
| Username | VPN login | `user1` |
| Password | VPN password (stored in the OS keystore) | `***` |
| DNS | DNS server(s), comma-separated | `8.8.8.8`, `tls://1.1.1.1`, `https://dns.adguard-dns.com/dns-query, 8.8.8.8` |
| Protocol | HTTP/2 or HTTP/3 | `http2` |
| Client random prefix | Optional — only if your server filters by it | `a1b2c3d4` |

Advanced options: IPv6, Anti-DPI, post-quantum key exchange, custom SNI, log level, certificate verification toggle, and the on-window-close behavior (ask / minimize / exit). See [CONFIGURATION.md](CONFIGURATION.md) for all of them.

## Connection Modes

Settings → Application lets you pick how the client listens for traffic (applies on the next connect; both modes share the same servers and settings):

- **VPN (TUN)** — the default. Routes **all system traffic** through a virtual network adapter (Wintun on Windows, utun on macOS). Requires administrator rights and, on Windows, `wintun.dll` next to the CLI.
- **Proxy (SOCKS5)** — the client runs a local SOCKS5 proxy on `127.0.0.1:<port>` (default 1080, loopback only) and creates **no network interface** — Wintun is not used in this mode. Point individual applications (or the system proxy settings) at the proxy; only that traffic goes through the tunnel. Split-tunnel rules apply to the proxied traffic. Useful when a virtual adapter can't be created at all.

> Note: on Windows the app currently still asks for administrator rights at startup even in SOCKS5 mode (the elevation is static in the exe manifest). Removing that requirement for SOCKS5-only use is planned separately.

## Split Tunneling

Two modes:
- **General** — all traffic through VPN, except exclusions
- **Selective** — only specified traffic through VPN

Supports: domains, IPs, CIDR, applications (`.exe` on Windows, `.app` on macOS).

Paste anything into the add field — a full URL, domain, IP or CIDR — it's normalized and validated automatically (`https://VK.com/feed` → `vk.com`, garbage is rejected). Apps are picked from the installed-apps list, or added manually by process name for anything the scan misses. Everything stays editable while connected; changes apply on the next connect.

Add entries one by one with **+**, or use the **paste-list** button to import a whole block at once (one entry per line, e.g.):

```
92.255.112.0/20
alfa.bank
vk.com
```

Domain groups with auto-discovery: when adding a single domain, Trusty finds related resources (CDN, API) and offers to group them. While the VPN is running, Trusty also watches the logs and suggests domains you might want to add.

## Platform Details

| | Windows | macOS |
|---|---|---|
| CLI | `trusttunnel_client.exe` | `trusttunnel_client` |
| TUN driver | Wintun (`wintun.dll`) — TUN mode only | Built-in utun — TUN mode only |
| Tray icon | `.ico` | `.png` |
| App discovery | Installed Apps (registry) + Microsoft Store, with app icons; running processes in search | `/Applications`, `/System/Applications`; running processes in search |
| Code signing | Not required | None (Right-click → Open once) |

## Troubleshooting

### "Trusty client not found"
- Make sure the CLI binary is in `client/` next to the application
- Windows: `client/trusttunnel_client.exe`
- macOS: `client/trusttunnel_client`

### Wintun Errors (Windows)
- Close other VPN clients (AmneziaVPN, WireGuard, etc.)
- Wintun driver can only be used by one application at a time
- Reconnecting right after a disconnect is handled automatically — Trusty waits for the driver to release before launching
- Applies to TUN mode only — SOCKS5 mode does not use Wintun (switch in Settings → Connection mode if the adapter can't be created on your system)

### "SSH host key changed — possible MITM" (Server tab)
- If you rebuilt/reinstalled the VPS, press **Trust new host key & retry**
- If you didn't touch the server, stop and investigate — see [CONFIGURATION.md](CONFIGURATION.md#troubleshooting-server-deployment)

### macOS: Gatekeeper Blocks Launch
- Right-click on `.app` → Open → Open
- Or: System Settings → Privacy & Security → Allow

### macOS: Password Dialog on First Connect
- On the first VPN connection, a macOS password dialog appears — this is expected
- Trusty sets the `setuid` bit on the CLI binary (one-time) so it can open the TUN device
- After confirming, subsequent connections work without any dialogs
- If the dialog was cancelled: just click Connect again

### Windows: UDP Socket Errors (WSAENOBUFS / 10055)
If you see `Failed to bind socket for UDP traffic (10055)` in logs, Windows has run out of socket buffer space. Fix with PowerShell (run as Administrator):
```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name MaxUserPort -Value 65534 -Type DWord
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name TcpTimedWaitDelay -Value 30 -Type DWord
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters' -Name DefaultSendWindow -Value 65536 -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters' -Name DefaultReceiveWindow -Value 65536 -Type DWord -Force
```
Then **restart Windows**.

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
