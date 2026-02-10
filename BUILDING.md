# Trusty — Building from Source

## Prerequisites

### Common

1. **Flutter SDK** (3.10.7+) — https://flutter.dev/docs/get-started/install
2. **Dart SDK** (3.10+) — included with Flutter
3. **Git** — https://git-scm.com/

### Windows

4. **Visual Studio 2022** with components:
   - Desktop development with C++
   - Windows 10 SDK (10.0.17763.0+)

### macOS

4. **Xcode** (14+) from App Store
5. **CocoaPods**: `sudo gem install cocoapods`

## Building

### Clone

```bash
git clone https://github.com/Meddelin/trusty.git
cd trusty
```

### Check Environment

```bash
flutter doctor -v
```

### Install Dependencies

```bash
flutter pub get
```

### Debug Build (development)

```bash
flutter run -d windows   # Windows
flutter run -d macos      # macOS
```

### Release Build

```bash
flutter build windows --release   # Windows
flutter build macos --release     # macOS
```

**Output:**
- Windows: `build/windows/x64/runner/Release/`
- macOS: `build/macos/Build/Products/Release/trusty.app`

## Getting the CLI Client

The GUI is a wrapper around the CLI. You need to download the CLI binary separately.

### Windows

```powershell
# PowerShell: download latest CLI
$repo = "TrustTunnel/TrustTunnelClient"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"
$release = Invoke-RestMethod -Uri $apiUrl
$asset = $release.assets | Where-Object { $_.name -like "*windows*x86_64*" } | Select-Object -First 1

Invoke-WebRequest -Uri $asset.browser_download_url -OutFile "cli.zip"
Expand-Archive -Path "cli.zip" -DestinationPath "cli_temp" -Force

$exe = Get-ChildItem -Path "cli_temp" -Filter "trusttunnel_client.exe" -Recurse | Select-Object -First 1
New-Item -ItemType Directory -Force -Path "client"
Copy-Item -Path $exe.FullName -Destination "client\trusttunnel_client.exe"
Remove-Item -Path "cli.zip", "cli_temp" -Recurse -Force
```

You also need **Wintun** for TUN mode:
```powershell
Invoke-WebRequest -Uri "https://www.wintun.net/builds/wintun-0.14.1.zip" -OutFile "wintun.zip"
Expand-Archive -Path "wintun.zip" -DestinationPath "wintun_temp" -Force
$dll = Get-ChildItem -Path "wintun_temp" -Filter "wintun.dll" -Recurse | Where-Object { $_.DirectoryName -like "*amd64*" } | Select-Object -First 1
Copy-Item -Path $dll.FullName -Destination "client\wintun.dll"
Remove-Item -Path "wintun.zip", "wintun_temp" -Recurse -Force
```

### macOS

```bash
# Bash: download latest CLI
API_URL="https://api.github.com/repos/TrustTunnel/TrustTunnelClient/releases/latest"
DOWNLOAD_URL=$(curl -fsSL "$API_URL" | grep -o '"browser_download_url": *"[^"]*macos[^"]*"' | head -1 | cut -d'"' -f4)

curl -fsSL "$DOWNLOAD_URL" -o cli.tar.gz
mkdir -p client
tar -xzf cli.tar.gz -C client/
chmod +x client/trusttunnel_client
rm cli.tar.gz
```

Wintun is **not needed** on macOS — the built-in utun is used.

## Directory Structure for Running

### Windows

```
Trusty/
├── Trusty.exe
├── flutter_windows.dll
├── *.dll
├── data/flutter_assets/assets/
│   └── tray_icon.ico
└── client/
    ├── trusttunnel_client.exe
    └── wintun.dll
```

### macOS

```
Trusty/
├── trusty.app
└── client/
    └── trusttunnel_client
```

## Quick Build (Windows)

Script for automatic dependency download and build:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1
```

## Clean Build

```bash
flutter clean
flutter pub get
flutter build windows --release
```

## Hot Reload (development)

When using `flutter run`:
- `r` — hot reload
- `R` — hot restart
- `q` — quit

## CI/CD

Automatic builds via GitHub Actions when a `v*` tag is pushed.
See [RELEASING.md](RELEASING.md).

---

More about Flutter Desktop: https://docs.flutter.dev/platform-integration/desktop
