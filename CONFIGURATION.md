# Trusty — Configuration Guide

Detailed guide for configuring Trusty VPN.

## Table of Contents

- [Remote Server Deployment](#remote-server-deployment)
- [Server Configuration](#server-configuration)
- [Authentication](#authentication)
- [Network Settings](#network-settings)
- [Advanced Settings](#advanced-settings)
- [Split Tunneling](#split-tunneling)
- [DNS Configuration](#dns-configuration)
- [Configuration File Format](#configuration-file-format)
- [Import/Export](#importexport)

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

Click **Install Server** to start the automated deployment. The process:

1. Connects via SSH
2. Checks system architecture and existing installations
3. Downloads and installs Trusty endpoint
4. Generates and uploads configuration files (vpn.toml, credentials.toml, hosts.toml)
5. Installs certbot and obtains a Let's Encrypt TLS certificate
6. Sets up and starts a systemd service
7. Verifies the service is running

After successful installation, click **Apply Client Settings** to automatically fill in the connection settings.

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

### Troubleshooting Server Deployment

**SSH connection fails:**
- Verify the IP address and port are correct
- Check that SSH is enabled on the server
- Try connecting manually: `ssh root@your-vps-ip`
- If using a key, ensure it's in OpenSSH format (not PuTTY .ppk)

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
- Store passwords securely (the GUI uses encrypted local storage)
- Don't share passwords or commit them to version control
- Consider using a password manager to generate strong passwords

## Network Settings

### DNS Server

DNS resolver to use for domain name resolution through the VPN.

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

### Fallback Protocol

Protocol to use if the primary protocol fails.

**Options:**
- **None** (default): Don't fallback
- **HTTP/2**: Fallback to HTTP/2
- **HTTP/3**: Fallback to HTTP/3

**Use cases:**
- Primary: HTTP/3, Fallback: HTTP/2 (try new protocol, fallback to stable)
- Primary: HTTP/2, Fallback: None (keep it simple)

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

### Exclusions/Inclusions

Add domains, IP addresses, or applications to exclude (General mode) or include (Selective mode).

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
[2001:db8::1]:443     # IPv6 with specific port
```

**Application Examples:**

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

The DNS field in settings is simplified. For advanced DNS configuration, you can:

1. Use a custom DNS server IP: `8.8.8.8`
2. Leave empty to use system DNS
3. For encrypted DNS (DoH/DoT), use the full URL format as shown in [Network Settings](#network-settings)

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
exclusions = ["*.local", "192.168.0.0/16"]
dns_upstreams = ["8.8.8.8:53"]

[endpoint]
hostname = "vpn.example.com"
addresses = ["203.0.113.10:443"]
has_ipv6 = true
username = "your-username"
password = "your-password"
skip_verification = false
upstream_protocol = "http2"
upstream_fallback_protocol = ""
anti_dpi = false

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

## Import/Export

### Export Configuration

To back up your settings or transfer to another computer:

1. Open **Settings** tab
2. Click **Export Configuration**
3. Choose a save location
4. Save as `.json` file

**Exported data includes:**
- Server hostname and IP
- Port and protocol settings
- Username (password is encrypted)
- DNS settings
- Split tunneling rules

### Import Configuration

To restore settings or use a shared configuration:

1. Open **Settings** tab
2. Click **Import Configuration**
3. Select the `.json` file
4. Review imported settings
5. Update password if needed
6. Click **Save Settings**

**Note:** Always verify imported configurations before connecting. Ensure the server details are correct.

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
   - Don't commit configs to version control
   - Use import/export for password-free transfers

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
