# Trusty — Configuration Guide

Detailed guide for configuring Trusty VPN.

## Table of Contents

- [Where Settings Live](#where-settings-live)
- [Remote Server Deployment](#remote-server-deployment)
- [Server Configuration](#server-configuration)
- [Authentication](#authentication)
- [Connection Filtering](#connection-filtering)
- [Network Settings](#network-settings)
- [Advanced Settings](#advanced-settings)
- [App Settings](#app-settings)
- [Split Tunneling](#split-tunneling)
- [DNS Configuration](#dns-configuration)
- [Configuration File Format](#configuration-file-format)

## Where Settings Live

Trusty has five tabs: **Home**, **Servers**, **Split Tunnel**, **Logs**, **Deploy**. There is no separate settings screen: each app-wide control sits next to what it governs.

| Setting | Where to find it |
|---------|------------------|
| Hostname, IP, port, username, password, protocol, filtering prefix, custom SNI, and the four Advanced switches | **Servers**, the pencil on a server card |
| DNS upstreams | **Servers**, the **App settings** column |
| Connection mode and SOCKS5 port | **Servers**, the **App settings** column |
| VPN mode, exclusions, apps, routing lists | **Split Tunnel** |
| Client log level | **Logs**, in the filter row |
| What the window's close button does | The navigation rail footer, behind the sliders icon |
| VPS deployment | **Deploy** |

The fields inside a server card need **Save**. Everything app-wide is written as you change it; only the close behavior takes effect at once, the rest applies the next time you connect.

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

Navigate to the **Deploy** tab and fill in:

**SSH Connection:**
- **VPS IP** - Your server's IP address
- **SSH Port** - Default is 22
- **Username** - Default is `root`
- **Authentication** - Password or SSH private key file path

**Domain and Certificate:**
- **Domain** - Must already point to the VPS IP (e.g., `vpn.example.com`). Nothing checks this for you; the certificate step is where a wrong A-record shows up.
- **Email (Let's Encrypt)** - For certificate registration
- **Port** - Server listen port (default 443). If it is already taken, the installer moves to the next free one.

**VPN Account:**
- **VPN Username** - Login for VPN connection
- **VPN Password** - Use the dice button to generate a random password

One account is set up. Changing it later means running Deploy again.

**Security (optional):**
- **Connection filtering** - Generates a random TLS `client_random_prefix` and writes a `rules.toml` that allows only handshakes carrying it, denying everything else. Probes and scanners get no useful answer; the port is still open and still speaks TLS. The marker is server-wide, not per device: any client configured with it is answered. **Add to my servers** fills it into the server entry it creates. See [Connection Filtering](#connection-filtering).

Click **Install Server** to start the automated deployment. The process:

1. Connects via SSH
2. Checks the system architecture and looks for an existing installation. If TrustTunnel is already there, **you are asked to confirm** before it is stopped and replaced
3. Downloads and installs Trusty endpoint
4. Generates and uploads configuration files (vpn.toml, credentials.toml, hosts.toml, and rules.toml if filtering is enabled)
5. Installs certbot and obtains a Let's Encrypt TLS certificate, unless one for this domain is already there, in which case it is left alone. Renewal afterwards is the server's job, not Trusty's.
6. Sets up and starts a systemd service
7. Checks that the service started

The SSH address, user and secret are used for this deployment only and are never saved. Cancelling stops the installation; anything already changed on the VPS stays changed. Trusty installs the server and does not manage it afterwards, so starting, stopping and removing it happen on the VPS.

After a successful installation, click **Add to my servers**. The deployed server joins your server list (or the entry with the same domain is updated) and becomes the active one, and your other servers are left alone. It does not connect you; press Connect on the Home screen.

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

**"SSH host key changed: possible MITM":**
- Trusty remembers the server's SSH fingerprint on the first connect and refuses to continue if it later changes
- If you rebuilt or reinstalled the VPS, the new key is expected, so press **Trust new host key & retry**
- If you did not change the server, stop and check. Someone may be intercepting the connection

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

Trusty keeps a list of servers on the **Servers** tab, one card per server. Clicking a card makes that server active. The pencil on the card opens an inline editor with every connection field, **Add server** at the top opens a dialog, and Delete lives inside the editor. The Home screen shows a quick switcher above the Connect button when more than one server is saved; with a single server it names that one instead. The **App settings** column on the right holds what all servers share: connection mode, SOCKS5 port and DNS upstreams.

- **Switching** replaces only the connection fields (hostname, IP, port, credentials, protocol, filtering prefix, custom SNI, and the Advanced switches). The shared settings stay as they are: DNS, connection mode, log level, VPN mode and every split-tunneling list.
- **Adding** opens a dialog, so nothing is saved until you confirm real values.
- **Deleting** removes the entry and its stored password. You always keep at least one entry: deleting the last server resets it to a blank one rather than leaving the list empty.
- Each server's password and client random prefix are stored separately in the OS keystore.
- **Add to my servers** after a deployment adds the deployed server as a new entry (or updates the entry with the same domain) and makes it active. It never overwrites your other servers.
- Server fields are locked while a connection is active. Disconnect to edit them.

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

A switch in the editor's **Advanced** expander. It says whether IPv6 traffic may be routed through this endpoint, and it is written to the config as `has_ipv6`.

**Enable it when:**
- Your server has an IPv6 address configured
- You need to reach IPv6-only resources through the tunnel

**Disable it when:**
- The server has no IPv6 address
- IPv6 routing through this endpoint misbehaves

Turning it off does not send IPv6 traffic around the tunnel; it tells the client this endpoint is not a route for IPv6.

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
- Trusty keeps the password in the OS keystore (Windows DPAPI / macOS Keychain), never in a settings file. The generated client config does hold it in plain text; on macOS that file is written with `chmod 600`, and on both platforms it is deleted when you disconnect and when the app exits
- Don't share passwords or commit them to version control
- Consider using a password manager to generate strong passwords

## Connection Filtering

Some servers only answer connections that carry a known **TLS client random prefix** and silently drop everyone else, so probes and scanners get no useful answer. The port stays open and still speaks TLS. If your server works this way, you must send the matching prefix or you won't be able to connect.

### Filtering prefix

**Servers → the pencil on a server card → Filtering prefix (optional).** A hex string, either `prefix` or `prefix/mask`. Anything else is rejected when you save.

- Leave it **empty** unless your server requires it.
- The value must match an `allow` rule in the server's `rules.toml`.
- If you deployed the server from Trusty with **Connection filtering** on, the prefix is generated for you and filled in by **Add to my servers**, so there is nothing to type.
- For a manually configured server, copy the exact prefix from the server's `rules.toml`.

It does not protect your traffic; TLS does that. It decides who the server answers, and it is server-wide: anyone who knows it passes the filter, so treat it like a shared access code. Trusty keeps it in the OS keystore, like the password.

**Test against a filtering server.** The **Test** button in the server editor opens a TCP connection and a TLS handshake, and it cannot send the prefix. A filtering server ignores that unmarked handshake by design, so the result says the server was reached and ignored an unmarked handshake rather than reporting a failure. Your client does send the prefix when you connect.

## Network Settings

### DNS Upstreams

**Servers → App settings → DNS upstreams.** One field, shared by every server. It holds the resolvers used for domain names that go through the tunnel, and you can give **several upstreams separated by commas**, such as a DoH resolver with a plain-IP fallback:

```
https://dns.adguard-dns.com/dns-query, 8.8.8.8
```

The preset menu next to the label (AdGuard Default / Family / Non-filtering, Cloudflare, Google) **appends** the chosen DoH upstream to the list. It never replaces what you typed, and a duplicate is refused with a message. Whatever the field holds is written into the config verbatim, and a change applies the next time you connect.

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

The protocol used to communicate with the server, chosen per server in the editor next to the filtering prefix.

**Options:**
- **HTTP/2** (default): Widely supported, stable
- **HTTP/3**: Newer protocol using QUIC, may provide better performance

**Recommendation:** Start with HTTP/2. Try HTTP/3 if you experience:
- High packet loss
- Need better performance over unreliable networks
- Server explicitly recommends it

## Advanced Settings

Four switches sit behind the **Advanced** expander in the server editor: IPv6, skip certificate verification, anti-DPI and post-quantum key exchange. They belong to one server and need **Save**. Custom SNI and the filtering prefix are full-width fields in the same editor, above the expander.

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

### Written for You, With No Control

Some values in the generated config look like settings and are not. They are written at fixed values, and nothing in the interface changes them:

| Key | Value | Note |
|-----|-------|------|
| `killswitch_enabled` | `true` | Always on. Requests that should go through the endpoint are not sent directly when the tunnel is down. |
| `killswitch_allow_ports` | `[]` | No local port is exempted. |
| `mtu_size` | `1280` | TUN configs only. |
| `bound_if` | `""` | The client picks the interface. |
| `included_routes` / `excluded_routes` | fixed lists | The whole address space through the tunnel, private and link-local ranges kept off it. |
| `change_system_dns` | `true` | TUN configs only. See [DNS Configuration](#dns-configuration). |
| `certificate` | `""` | The system certificate store is used. |

## App Settings

These are shared by every server. They are saved as soon as you change them.

### Log Level

**Logs tab**, in the filter row above the console. It sets the verbosity the client itself writes, so it governs the very lines that screen shows. A change applies the next time you connect.

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

The sliders icon at the bottom of the navigation rail, under the app icon and above the GitHub and Telegram links. It controls what happens when you close the main window.

**Options:**
- **ask** (default): show a dialog on each close (it has a "Remember my choice" checkbox)
- **minimize**: hide to the system tray, the VPN keeps running
- **exit**: disconnect the VPN and quit the app

This is the one setting that takes effect at once. It is not part of the server configuration and needs no Save.

### Connection Mode

**Servers → App settings → Connection mode**, with the SOCKS5 port field below it in proxy mode. Shared by all servers, applied on the next connect, and locked while a connection is active.

**Modes:**
- **VPN (TUN)** (default): routes system traffic through a virtual network adapter, Wintun on Windows (which needs elevated privileges and `wintun.dll`) or utun on macOS. Addresses on your local network stay off the tunnel.
- **Proxy (SOCKS5)**: the client listens on `127.0.0.1:<port>` (default 1080, loopback only, any port from 1 to 65535) as a SOCKS5 proxy and creates no network interface, so Wintun is never touched. Only the applications you point at the proxy, directly or through the system proxy settings, go through the tunnel, and the split-tunnel rules apply to the traffic that reaches it. Use this mode when a virtual adapter cannot be created on your system.

On Windows the app still asks for administrator rights when it starts, in both modes; the elevation is baked into the executable manifest. On macOS, only TUN mode asks for your password, once.

## Split Tunneling

Split tunneling routes some traffic through the VPN and some around it. One list of entries, read two ways depending on the mode. In proxy mode it governs the traffic that reaches the proxy, not everything on the machine.

### VPN Mode

**General Mode** (default):
- Everything goes through the VPN **except** your list
- Use it for maximum privacy
- Add entries for local services, or for services that block VPN addresses

**Selective Mode:**
- Only your list goes through the VPN
- Everything else connects directly
- Use it to tunnel a few sites or apps and leave the rest alone

### Ready-Made Routing Lists

The Split Tunnel screen has a **Routing lists** column: ready-made sets of domains, IP addresses and CIDR ranges, merged with your own rules when you connect and kept separate from the entries you typed.

**A fresh install has no lists.** The column starts empty and you pick what you want. **Add list** offers three sources:

- **Preset** - the catalogue. The first entry is **Sites blocked in Russia**, the maintained [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains) set (`Russia/inside-raw.lst` plus the Telegram and Discord subnets). After it come v2fly community domain categories (YouTube, Discord, Meta, Telegram, Twitter / X, Netflix, OpenAI, Google) and per-country IP ranges (Russia, Ukraine, United States, Netherlands, Germany). Domain rules from a v2fly category are imported; regexp and keyword rules are skipped.
- **From URL** - a raw text URL, several allowed, one domain/IP/CIDR per line with `#` comments.
- **From file** - a local file in the same format.

The **Check** step shows "Found N valid entries (M skipped)" before anything is saved.

Upgrading from a version that used the old built-in preset keeps it as a list named **Default**, with its enabled state and cached copy intact.

Behavior:
- **Refresh**: when you connect, URL lists older than 24 hours are downloaded again, with a hard 8-second budget so connect never hangs. Offline, Trusty uses the last downloaded copy of each list, and a missing cache file forces a re-download. The refresh button updates a list at any time; a file-backed list only changes when you press it.
- Each list applies in **Selective mode** (its entries are routed *through* the VPN), **General mode** (its entries *bypass* the VPN) or both, set per list in its ⋮ menu.
- Any list can be deleted from that same menu, including one carried over from an older install. The catalogue can add it back.
- Entries are validated, invalid lines are skipped, and caps apply (5 MB, 100 000 entries). Copies are cached under `client/routing_lists/<id>.lst`.
- A failed update marks the list; the last downloaded copy stays in use. During a connect the failure is silent and shows only on the tile.

### Exclusions/Inclusions

Add domains, IP addresses, or applications to exclude (General mode) or include (Selective mode).

Add entries one at a time with **+**, or use the **paste-list** button to import many at once from a block with one entry per line (commas and spaces work too). Duplicates are ignored.

Input is normalized automatically: you can paste a full URL (`https://user@VK.com:443/feed` becomes `vk.com`), a bare domain, an IP, an IPv6 in brackets, or a CIDR range. Ports, paths and schemes are stripped, and anything that is not a valid domain, IP or CIDR is rejected with a message rather than landing in the config. A typo like `10.0.0.0/99` is an error, not a truncated entry.

After you add a domain, a snackbar offers **Find related**, an optional scan of the site that suggests its CDN and API domains as a group. Ignore it and nothing happens.

The screen stays editable while the VPN is connected. Changes are saved right away and apply the next time you connect.

**Domain Examples:**

```
netflix.com           # A domain
*.local               # A wildcard
*.company.internal    # A wildcard under your own domain
```

Trusty passes these to the client as written and makes no promise about subdomains, so write the wildcard yourself when you want them covered.

**IP Address Examples:**

```
192.168.1.1           # Single IP
10.0.0.0/8            # Entire 10.x.x.x network
2001:db8::/32         # IPv6 CIDR range
2001:db8::1           # Single IPv6 ([2001:db8::1]:443 works too, the port is stripped)
```

**Application Examples:**

The Apps tab lists installed applications with checkboxes, the selected ones first. On Windows the list mirrors Windows' own **Settings → Apps → Installed apps** (registry Uninstall entries) plus **Microsoft Store apps** (Apple Music, WhatsApp, and so on), each with its real icon. On macOS it scans `/Applications`, `/System/Applications` and `~/Applications`, one level deep and without icons. **Running processes** appear in search results only: if an app is missing, start it, type its name (press refresh first if needed), then pick the entry labeled "running now" with the exact process name.

Trusty matches apps by process name.

As a last resort, type a process name into the search field and press **+**. On Windows a bare name gets `.exe` appended for you. Names added this way stay at the top of the list.

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

The DNS field is required and takes at least one upstream. You can:

1. Use a plain DNS server IP: `8.8.8.8`
2. Use encrypted DNS (DoH/DoT/DoQ) with the full URL format as shown in [Network Settings](#network-settings)

**DNS leak protection:**
- The client intercepts plain DNS queries that pass through the endpoint and sends them to your upstreams instead.
- `change_system_dns = true` is written into every TUN config, so **VPN (TUN)** mode may change the system resolver while connected. There is no switch for it. **Proxy (SOCKS5)** mode writes no TUN table at all and leaves system DNS alone.

## Configuration File Format

The GUI writes one TOML file for the Trusty client each time you connect. Values come straight from the fields described above, escaped for TOML; the keys listed under [Written for You](#written-for-you-with-no-control) are constants. The real file carries the client's own comments above each key, trimmed here.

**Example configuration:**

```toml
loglevel = "info"
vpn_mode = "general"
killswitch_enabled = true
killswitch_allow_ports = []
post_quantum_group_enabled = true
exclusions = ["*.local", "192.168.0.0/16"]
dns_upstreams = ["8.8.8.8"]

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

In SOCKS5 [connection mode](#connection-mode) the `[listener.tun]` table is replaced by a SOCKS listener (the CLI accepts exactly one listener table):

```toml
[listener]
[listener.socks]
address = "127.0.0.1:1080"
```

`exclusions` holds your own domains, IPs and process names with the entries of every enabled routing list merged in. The lists are merged only here, at connect time, and stay separate on the Split Tunnel screen.

**File location:**
- Windows: `client/trusttunnel_client.toml`, in the `client` folder beside `Trusty.exe`
- macOS: `client/trusttunnel_client.toml`, beside the `.app` bundle
- Written each time you press Connect, deleted when you disconnect and when the app exits
- Contains your password in plain text, so keep it out of version control

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

The **Test** button in the server editor will not catch this. It checks that the host is reachable and speaks TLS; your username and password are checked only when you connect.

### "Trusty client not found"
The client lives in a `client` folder next to the Trusty executable, and that is the path the message names. Trusty looks there rather than in whatever folder it happened to be started from, so a shortcut with an odd working directory is not the cause. Put `trusttunnel_client.exe` (Windows) or `trusttunnel_client` (macOS) in that folder.

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
- Try the other protocol (HTTP/2 vs HTTP/3)
- Turn anti-DPI off if your network does not need it
- Switch off routing lists you are not using; a very large merged set makes connecting slow
- Check server load and network conditions

Trusty measures no speed, latency or data volume, so judge these by how the connection behaves.

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
