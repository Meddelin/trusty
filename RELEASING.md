# Trusty — Release Instructions

## Automatic Releases

When a `v*` tag is pushed, two workflows are triggered automatically:

| Workflow | File | Platform | Release Type |
|----------|------|----------|-------------|
| Build and Release Windows | `release.yml` | Windows x64 | stable |
| Build and Release macOS | `release-macos.yml` | macOS universal | alpha (prerelease) |

## Creating a Release

### 1. Update Version

```yaml
# pubspec.yaml
version: 0.1.0+1
```

### 2. Commit and Push

```bash
git add pubspec.yaml
git commit -m "Bump version to 0.1.0"
git push origin main
```

### 3. Create Tag

```bash
git tag -a v0.1.0 -m "v0.1.0: description"
git push origin v0.1.0
```

### 4. Done

- GitHub Actions builds both platforms (3-5 minutes)
- Releases appear on [Releases](../../releases)
- Windows: `Trusty-Windows-v0.1.0.zip` (stable)
- macOS: `Trusty-macOS-v0.1.0.zip` (prerelease)

## What Happens During Build

### Windows (`release.yml`)

1. Checkout → Flutter setup → `flutter pub get`
2. `flutter build windows --release`
3. Download CLI (`*windows*x86_64*`) from TrustTunnelClient releases
4. Download Wintun 0.14.1 (amd64) from wintun.net
5. Build ZIP with exe, CLI, wintun.dll, README.txt
6. Publish GitHub Release (stable)

### macOS (`release-macos.yml`)

1. Checkout → Flutter setup → `flutter pub get`
2. `flutter build macos --release`
3. Download CLI (`*macos*universal*`) from TrustTunnelClient releases
4. Build ZIP with .app, client/, README.txt
5. Publish GitHub Release (prerelease)

## Versioning

[Semantic Versioning](https://semver.org/):

- `MAJOR.MINOR.PATCH` — `0.1.0`
- MAJOR — incompatible changes
- MINOR — new features
- PATCH — bug fixes

Examples:
```
v0.1.0 — first release
v1.0.0 — stable release
```

## Pre-release Checklist

- [ ] Version updated in `pubspec.yaml`
- [ ] `flutter analyze` has no errors
- [ ] Windows build compiles locally
- [ ] README and documentation are up to date
- [ ] No hardcoded secrets in code

## Rolling Back a Release

```bash
# Delete tag
git tag -d v0.1.0
git push origin :refs/tags/v0.1.0
```

Then delete the release on GitHub → Releases → Delete release.

## Manual Build

If CI/CD is unavailable:

```bash
flutter clean && flutter pub get

# Windows
flutter build windows --release
# Copy build/windows/x64/runner/Release/ + client/

# macOS
flutter build macos --release
# Copy build/macos/Build/Products/Release/*.app + client/
```

See [BUILDING.md](BUILDING.md) for details.
