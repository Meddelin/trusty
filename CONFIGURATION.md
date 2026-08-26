# Trusty — Configuration Guide

Detailed guide for configuring Trusty VPN.

## Table of Contents

- [Remote Server Deployment](#remote-server-deployment)
- [Server Configuration](#server-configuration)
- [Authentication](#authentication)
- [Connection Filtering](#connection-filtering)
- [Network Settings](#network-settings)
- [Advanced Settings](#advanced-settings)
- [Split Tunneling](#split-tunneling)
- [DNS Configuration](#dns-configuration)
- [Configuration File Format](#configuration-file-format)

## Remote Server Deployment

The GUI can install and configure a Trusty server on a remote VPS automatically via SSH.

### Prerequisites

Before deploying:
1. **A VPS** with Linux (Ubuntu/Debian recommended), x86_64 or aarch64
2. **Root SSH access** to the VPS (password or SSH key)
3. **A domain name** with an A-record pointing to the VPS IP address
4. **Port 443** open on the VPS firewall (for VPN traffic)
5. **Port 80** temporarily open (for Let's Encrypt certificate verification)

### Deployment Steps

Navigate to the **Server** tab and fill in:

**SSH Connection:**
- **VPS IP** - Your server's IP address
- **SSH Port** - Default is 22
- **Username** - Default is `root`
- **Authentication** - Password or SSH private key file path

**Domain & Certificate:**
- **Domain** - Must already point to the VPS IP (e.g., `vpn.example.com`)
- **Email** - For Let's Encrypt certificate registration
- **Port** - Server listen port (default 443)

**VPN Account:**
- **Username** - Login for VPN connection
- **Password** - Use the dice button to generate a secure random password

**Security (optional):**
- **Enable connection filtering** - Generates a random TLS `client_random_prefix`, configures the server to allow only clients that send it and deny everyone else (probes, scanners). The prefix is carried over to your client settings by **Apply Client Settings**. See [Connection Filtering](#connection-filtering).

Click **Install Server** to start the automated deployment. The process:

1. Connects via SSH
2. Checks system architecture and existing installations — if TrustTunnel is already installed, **you are asked to confirm** before it is stopped and replaced
3. Downloads and installs Trusty endpoint
4. Generates and uploads configuration files (vpn.toml, credentials.toml, hosts.toml, and rules.toml if filtering is enabled)
5. Installs certbot and obtains a Let's Encrypt TLS certificate
6. Sets up and starts a systemd service
7. Verifies the service is running

After successful installation, click **Apply Client Settings** — the deployed server is added to your server list (or the entry with the same domain is updated) and becomes the active one. Existing servers in the list are never overwritten.

### Server Configuration Files

The installer creates these files on the server:

**`/opt/trusttunnel/vpn.toml`** - Main endpoint config:
```toml
listen_address = "0.0.0.0:443"
credentials_file = "/opt/trusttunnel/credentials.toml"
```

**`/opt/trusttunnel/credentials.toml`** - VPN user accounts:
```toml
[[client]]
username = "your-username"
password = "your-password"
```

**`/opt/trusttunnel/hosts.toml`** - TLS certificate paths:
```toml
[[main_hosts]]
hostname = "vpn.example.com"
cert_chain_path = "/etc/letsencrypt/live/vpn.example.com/fullchain.pem"
private_key_path = "/etc/letsencrypt/live/vpn.example.com/privkey.pem"
```

**`/opt/trusttunnel/rules.toml`** *(only when connection filtering is enabled)* - referenced from `vpn.toml` via `rules_file`. Rules are evaluated in order; the default is allow, so the trailing deny blocks everyone who doesn't send the prefix:
```toml
[[rule]]
client_random_prefix = "a1b2c3d4"
action = "allow"

[[rule]]
action = "deny"
```

### Troubleshooting Server Deployment

**SSH connection fails:**
- Verify the IP address and port are correct
- Check that SSH is enabled on the server
- Try connecting manually: `ssh root@your-vps-ip`
- If using a key, ensure it's in OpenSSH format (not PuTTY .ppk)

**"SSH host key changed — possible MITM":**
- Trusty pins the server's SSH host key on first connect (trust-on-first-use) and refuses to continue if it later changes
- If you rebuilt or reinstalled the VPS, the new key is expected — press **Trust new host key & retry**
- If you did NOT change the server, do not continue: someone may be intercepting the connection

**Certificate fails ("DNS problem"):**
- Ensure the domain's A-record points to the VPS IP
- DNS propagation may take up to 24 hours
- Verify port 80 is open: `curl http://your-domain.com`

**Service fails to start:**
- Check logs: `journalctl -u trusttunnel -n 50`
- Ensure port 443 is not used by another service (nginx, apache)
- Verify certificate files exist in `/etc/letsencrypt/live/`

For advanced server configuration, see the [TrustTunnel Server Documentation](https://github.com/TrustTunnel/TrustTunnel/blob/master/CONFIGURATION.md).

## Server Configuration

### Multiple Servers

Trusty keeps a list of servers on the dedicated **Servers** tab: one card per server. Clicking a card makes that server active (one click — no dropdowns); the pencil opens an inline editor with all connection fields; **Add server** opens a dialog; Delete lives inside the editor. The Home screen additionally shows a quick switcher above the Connect button when more than one server is saved. **Shared network settings** (DNS) sit at the bottom of the Servers tab — they apply to every server. App-level options (log level, close behavior) live on the separate **Settings** tab.

- **Switching** replaces only the connection fields (hostname, IP, port, credentials, protocol tweaks like Anti-DPI/SNI/prefix). App-wide settings — DNS, log level, VPN mode and all split-tunneling lists — stay as they are.
- **Adding** opens a dialog — nothing is saved until you confirm real values.
- **Deleting** removes the entry and its stored password (the last remaining server can't be deleted).
- Each server's password and client random prefix are stored separately in the OS keystore.
- **Apply Client Settings** after a server deployment adds the deployed server as a new entry (or updates the entry with the same domain) and makes it active — it never overwrites your other servers.

### Hostname

The server's domain name used for TLS session establishment.

**Examples:**
- `vpn.example.com`
- `server.yourdomain.net`
- `trusttunnel.company.org`

**Note:** This must match the certificate's Common Name (CN) or Subject Alternative Name (SAN) unless certificate verification is disabled.

### IP Address

The server's IP address. Can be IPv4 or IPv6.

**IPv4 Examples:**
- `203.0.113.10`
- `192.0.2.50`

**IPv6 Examples:**
- `2001:db8::1`
- `fd00::1`

**Note:** The GUI automatically formats IPv6 addresses for the configuration.

### Port

The server port number. Default is `443` (HTTPS).

**Common ports:**
- `443` - Standard HTTPS (recommended)
- `8443` - Alternative HTTPS
- `80` - HTTP (not recommended for production)

### IPv6 Support

Enable if your server supports IPv6 traffic routing.

**When to enable:**
- Your server has an IPv6 address configured
- You need to access IPv6-only resources
- Your ISP provides IPv6 connectivity

**When to disable:**
- Server doesn't support IPv6
- You only need IPv4 connectivity
- Experiencing routing issues with IPv6

## Authentication

### Username

Your VPN account username provided by your server administrator.

**Format considerations:**
- Case-sensitive
- Usually alphanumeric
- May include special characters depending on server configuration

### Password

Your VPN account password.

**Security best practices:**
- Use a strong, unique password
- Trusty stores the password in the OS keystore (Windows DPAPI / macOS Keychain), never in plain text; the generated client config file is restricted to your user account and deleted after disconnect and on exit
- Don't share passwords or commit them to version control
- Consider using a password manager to generate strong passwords

## Connection Filtering

Some servers only answer clients that send a known **TLS client random prefix** and silently drop everyone else. This hides the server from probes and scanners. If your server uses this, you must send the matching prefix or you won't be able to connect.

### Client random prefix

**Servers → edit a server → Advanced → Client random prefix.** A hex string (format: `prefix` or `prefix/mask`).

- Leave it **empty** unless your server requires it.
- The value must match an `allow` rule in the server's `rules.toml`.
- If you deployed the server from Trusty with **connection filtering** enabled, the prefix is generated for you and filled in automatically by **Apply Client Settings** — you don't need to type anything.
- For a manually configured server, copy the exact prefix from the server's `rules.toml`.

It is not a secret that protects your traffic (TLS already does that) — it's an access/obfuscation token. Anyone who knows it can pass the filter, so treat it like a shared access code. Trusty stores it in the OS keystore, like the password.

## Network Settings

### DNS Server

DNS resolver(s) to use for domain name resolution through the VPN. You can specify **several upstreams separated by commas** — e.g. a DoH resolver with a plain-IP fallback:

```
https://dns.adguard-dns.com/dns-query, 8.8.8.8
```

The preset menu next to the field (AdGuard Default / Family / Non-filtering, Cloudflare, Google) **appends** the chosen DoH upstream to the list — it never replaces what you typed, and duplicates are skipped.

**Format options:**

1. **Plain DNS:**
   ```
   8.8.8.8
   1.1.1.1
   ```

2. **DNS over TCP:**
   ```
   tcp://8.8.8.8:53
   ```

3. **DNS over TLS (DoT):**
   ```
   tls://1.1.1.1
   tls://dns.google
   ```

4. **DNS over HTTPS (DoH):**
   ```
   https://dns.adguard.com/dns-query
   https://cloudflare-dns.com/dns-query
   ```

5. **DNS over QUIC:**
   ```
   quic://dns.adguard.com:8853
   ```

**Popular DNS Providers:**

| Provider | Plain DNS | DoT | DoH |
|----------|-----------|-----|-----|
| Google | 8.8.8.8 | tls://dns.google | https://dns.google/dns-query |
| Cloudflare | 1.1.1.1 | tls://1.1.1.1 | https://cloudflare-dns.com/dns-query |
| Quad9 | 9.9.9.9 | tls://dns.quad9.net | https://dns.quad9.net/dns-query |
| AdGuard | 94.140.14.14 | tls://dns.adguard.com | https://dns.adguard.com/dns-query |

### Protocol

The protocol used to communicate with the server.

**Options:**
- **HTTP/2** (default): Widely supported, stable
- **HTTP/3**: Newer protocol using QUIC, may provide better performance

**Recommendation:** Start with HTTP/2. Try HTTP/3 if you experience:
- High packet loss
- Need better performance over unreliable networks
- Server explicitly recommends it

## Advanced Settings

### Skip Certificate Verification

**Default:** Disabled (recommended)

When enabled, any server certificate is accepted without verification.

**When to enable:**
- Using a self-signed certificate for testing
- Internal server with custom CA
- Certificate has expired but you trust the server

**Security warning:** Only enable this if you fully trust the server. This disables protection against man-in-the-middle attacks.

### Anti-DPI

**Default:** Disabled

Enables anti-Deep Packet Inspection measures to bypass network restrictions.

**When to enable:**
- You're in a region with internet censorship
- ISP throttles or blocks VPN traffic
- Experiencing unexpected connection drops

**Note:** May slightly impact performance. Test with and without to see if needed.

### Post-Quantum Key Exchange

**Default:** Enabled

When enabled, a post-quantum group may be used for key exchange during the TLS handshake. Leave it on unless a server is incompatible with it.

### Custom SNI

**Default:** empty (uses the hostname)

Overrides the SNI value sent in the TLS handshake. Leave empty unless your server administrator told you to set a specific value.

### Log Level

Controls verbosity of client logs.

**Levels:**
- **error**: Only critical errors
- **warn**: Errors and warnings
- **info**: General information (recommended)
- **debug**: Detailed debugging information
- **trace**: Very detailed trace information

**Recommendation:**
- Use **info** for normal operation
- Use **debug** or **trace** when troubleshooting
- Use **error** or **warn** for production with minimal logs

### On Window Close

Controls what happens when you close the main window.

**Options:**
- **ask** (default): show a dialog each time (it has a "Remember my choice" checkbox)
- **minimize**: hide to the system tray, VPN keeps running
- **exit**: disconnect the VPN and quit the app

Applied immediately — this setting is not part of the server configuration and doesn't need Save.

## Split Tunneling

Split tunneling allows selective routing of traffic through the VPN.

### VPN Mode

**General Mode** (default):
- All traffic goes through VPN **except** specified exclusions
- Use this for maximum privacy
- Add exclusions for local services or services that block VPN IPs

**Selective Mode:**
- Only specified traffic goes through VPN
- All other traffic uses direct connection
- Use this to VPN only specific apps/sites while keeping others fast

### Ready-Made Routing Lists

The Split Tunnel screen has a **Routing lists** section — sets of domains/IPs/CIDRs merged into the exclusions at connect time, kept separate from your own entries:

- **Built-in list "Default"** (similar in spirit to [roscomvpn-routing](https://github.com/hydraponique/roscomvpn-routing)) — the maintained [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains) lists of sites blocked in Russia (`Russia/inside-raw.lst` + Telegram/Discord subnets, ~1200 entries).
- **Your own lists** via **Add list**: a raw URL (e.g. a GitHub raw link, several URLs allowed) or a local file — plain text, one domain/IP/CIDR per line, `#` comments allowed. The **Check** step shows "Found N valid entries (M skipped)" before anything is saved.

Behavior:
- **Auto-update**: URL lists older than 24 hours are refreshed automatically when you connect (with a hard 8-second budget so connect never hangs; offline falls back to the cached copy, and a vanished cache file forces a re-download). The refresh button updates a list manually at any time.
- Each list applies in **Selective mode** (entries are routed *through* the VPN), **General mode** (entries *bypass* the VPN) or both — set per list in its ⋮ menu.
- Entries are validated (invalid lines are skipped) with size caps (5 MB / 100 000 entries), cached under `client/routing_lists/<id>.lst`.
- A failed update marks the list with the error; the last good cache keeps working.

### Exclusions/Inclusions

Add domains, IP addresses, or applications to exclude (General mode) or include (Selective mode).

Add entries one at a time with **+**, or click the **paste-list** button to import many at once — paste a block with one entry per line (commas and spaces also work). Duplicates are ignored.

Input is normalized automatically: you can paste a full URL (`https://user@VK.com:443/feed` becomes `vk.com`), a bare domain, an IP, an IPv6 in brackets, or a CIDR range. Ports, paths and schemes are stripped; entries that are not a valid domain/IP/CIDR are rejected with a message instead of silently landing in the config (a typo like `10.0.0.0/99` is an error, not a truncated entry).

After adding a domain, a snackbar offers **Find related** — the optional discovery that scans the site and suggests its CDN/API domains as a group. It no longer blocks every add with a dialog.

The whole screen stays editable while the VPN is connected: changes are saved immediately and take effect the next time you connect.

**Domain Examples:**

```
netflix.com           # Matches netflix.com and www.netflix.com
*.local               # Matches all .local subdomains
*.company.internal    # Matches all subdomains of company.internal
```

**IP Address Examples:**

```
192.168.1.1           # Single IP
10.0.0.0/8            # Entire 10.x.x.x network
2001:db8::/32         # IPv6 CIDR range
2001:db8::1           # Single IPv6 ([2001:db8::1]:443 is accepted too — the port is stripped)
```

**Application Examples:**

The Apps tab lists installed applications with their icons and checkboxes (selected ones are shown first). On Windows the list mirrors **Settings → Apps → Installed apps** (registry Uninstall entries) plus **Microsoft Store apps** (Apple Music, WhatsApp, …); on macOS it scans `/Applications` and `/System/Applications`. **Running processes** appear in search results only — if an app isn't listed, start it, type its name (or press refresh first), then pick the entry labeled "running now" with the exact process name.

As a last resort, type a process name into the search field and press **+** — on Windows a bare name gets `.exe` appended automatically. Manually added names stay visible at the top of the list.

Windows:
```
chrome.exe            # Google Chrome browser
steam.exe             # Steam client
Discord.exe           # Discord app
```

macOS:
```
Google Chrome         # Process name from .app bundle
steam_osx             # Steam client
Discord               # Discord app
```

**Common Use Cases:**

1. **Exclude local network** (General mode):
   ```
   192.168.0.0/16
   10.0.0.0/8
   *.local
   ```

2. **Exclude streaming services** (General mode):
   ```
   netflix.com
   hulu.com
   disneyplus.com
   ```

3. **VPN only for work** (Selective mode):
   ```
   *.company.com
   vpn.company.net
   outlook.exe
   teams.exe
   ```

4. **Exclude P2P apps** (General mode):
   ```
   utorrent.exe
   qbittorrent.exe
   ```

## DNS Configuration

The DNS field is required. You can:

1. Use a plain DNS server IP: `8.8.8.8`
2. Use encrypted DNS (DoH/DoT/DoQ) with the full URL format as shown in [Network Settings](#network-settings)

**DNS Leak Protection:**
- The client automatically routes DNS queries through the VPN when configured
- Set `change_system_dns = true` in advanced config to update system DNS settings

## Configuration File Format

The GUI generates TOML configuration files for the Trusty client.

**Example configuration:**

```toml
loglevel = "info"
vpn_mode = "general"
killswitch_enabled = true
killswitch_allow_ports = []
post_quantum_group_enabled = true
exclusions = ["*.local", "192.168.0.0/16"]
dns_upstreams = ["8.8.8.8:53"]

[endpoint]
hostname = "vpn.example.com"
addresses = ["203.0.113.10:443"]
has_ipv6 = true
username = "your-username"
password = "your-password"
client_random = ""
skip_verification = false
certificate = ""
upstream_protocol = "http2"
anti_dpi = false
custom_sni = ""

[listener]
[listener.tun]
bound_if = ""
included_routes = ["0.0.0.0/0", "2000::/3"]
excluded_routes = ["0.0.0.0/8", "10.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3"]
mtu_size = 1280
change_system_dns = true
```

**File location:**
- Windows: `client/trusttunnel_client.toml` (next to exe)
- macOS: `client/trusttunnel_client.toml` (next to `.app` bundle)
- Generated automatically when clicking "Connect"
- Contains credentials (not committed to git)

## Security Best Practices

1. **Use strong authentication:**
   - Never use default passwords
   - Use unique passwords for VPN accounts
   - Enable certificate verification when possible

2. **Configure DNS securely:**
   - Use encrypted DNS (DoH/DoT) when available
   - Don't use untrusted DNS servers
   - Verify DNS isn't leaking outside the VPN

3. **Protect configuration files:**
   - Don't share config files with passwords
   - Don't commit configs to version control (the generated `trusttunnel_client.toml` contains your password)

4. **Split tunneling considerations:**
   - Understand what traffic bypasses the VPN
   - Don't exclude sensitive applications in General mode
   - Test your configuration to ensure it works as expected

5. **Log levels:**
   - Use minimal logging in production
   - Debug/trace logs may contain sensitive information
   - Clear logs regularly if they contain sensitive data

## Troubleshooting Configuration Issues

### Connection fails with "authentication failed"
- Verify username and password are correct
- Check for extra spaces in credentials
- Ensure server is configured to accept your account

### DNS not working
- Try different DNS servers
- Verify DNS format is correct
- Check if encrypted DNS is supported by your network
- Test with plain DNS first (8.8.8.8)

### Windows: "System DNS proxy request failed" spam in logs
These are INFO-level messages logged when the DNS proxy can't immediately forward queries during connection startup. They are normal and self-resolve within a few seconds once the tunnel is fully established. The GUI automatically collapses repeated lines into a single `(×N)` counter.

### Windows: UDP socket error (WSAENOBUFS / code 10055)
`Failed to bind socket for UDP traffic (10055)` means Windows ran out of ephemeral socket buffer space, usually after a previous VPN session. Fix (requires Administrator PowerShell, then **reboot**):
```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name MaxUserPort -Value 65534 -Type DWord
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name TcpTimedWaitDelay -Value 30 -Type DWord
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters' -Name DefaultSendWindow -Value 65536 -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters' -Name DefaultReceiveWindow -Value 65536 -Type DWord -Force
```

### Split tunneling not working
- Verify exclusion/inclusion format
- Check VPN mode is correct (General vs Selective)
- Test with simple rules first
- Review logs for routing errors

### Certificate errors
- Ensure hostname matches certificate CN/SAN
- Check if certificate is expired
- Verify server certificate is valid
- Consider enabling skip_verification temporarily for testing only

### Performance issues
- Try different protocols (HTTP/2 vs HTTP/3)
- Adjust MTU size if experiencing packet loss
- Disable anti-DPI if not needed
- Check server load and network conditions

## Getting Help

If you encounter configuration issues:

1. Check the [README Troubleshooting](README.md#troubleshooting) section
2. Review logs at the **Logs** tab
3. Test with minimal configuration first
4. Search [GitHub Issues](https://github.com/Meddelin/trusty/issues)
5. Create a new issue with:
   - Your configuration (remove passwords!)
   - Error messages from logs
   - Steps to reproduce

---

For more information about the TrustTunnel protocol, visit the [TrustTunnel GitHub repository](https://github.com/TrustTunnel/TrustTunnel).
