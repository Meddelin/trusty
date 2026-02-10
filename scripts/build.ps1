# build.ps1
# Build TrustTunnel GUI with all dependencies.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\build.ps1 [-Debug] [-SkipDeps]

param(
    [switch]$Debug,
    [switch]$SkipDeps
)

$ErrorActionPreference = "Stop"
$projectRoot = Join-Path $PSScriptRoot ".."
Push-Location $projectRoot

try {
    # Step 1: Download dependencies
    if (-not $SkipDeps) {
        Write-Host "=== Downloading dependencies ===" -ForegroundColor Cyan
        & powershell -ExecutionPolicy Bypass -File scripts\download_deps.ps1
        if ($LASTEXITCODE -ne 0) { throw "Failed to download dependencies" }
        Write-Host ""
    }

    # Step 2: Get Flutter packages
    Write-Host "=== Getting Flutter packages ===" -ForegroundColor Cyan
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }
    Write-Host ""

    # Step 3: Build
    if ($Debug) {
        Write-Host "=== Building (debug) ===" -ForegroundColor Cyan
        flutter run -d windows
    } else {
        Write-Host "=== Building (release) ===" -ForegroundColor Cyan
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

        # Copy client/ into build output
        $buildDir = "build\windows\x64\runner\Release"
        $buildClientDir = Join-Path $buildDir "client"
        if (-not (Test-Path $buildClientDir)) {
            New-Item -ItemType Directory -Force -Path $buildClientDir | Out-Null
        }
        Copy-Item "client\trusttunnel_client.exe" -Destination $buildClientDir -Force
        Copy-Item "client\wintun.dll" -Destination $buildClientDir -Force
        Copy-Item "client\trusttunnel_client.toml.example" -Destination $buildClientDir -Force

        Write-Host ""
        Write-Host "=== Build complete ===" -ForegroundColor Green
        Write-Host "Output: $buildDir"
    }
} finally {
    Pop-Location
}
