# download_deps.ps1
# Downloads TrustTunnel CLI and Wintun driver into client/ directory.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\download_deps.ps1 [-Force]

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$clientDir = Join-Path $PSScriptRoot "..\client"

# Ensure client directory exists
if (-not (Test-Path $clientDir)) {
    New-Item -ItemType Directory -Force -Path $clientDir | Out-Null
}

$exePath = Join-Path $clientDir "trusttunnel_client.exe"
$dllPath = Join-Path $clientDir "wintun.dll"

# ── Download TrustTunnel CLI ──

if ($Force -or -not (Test-Path $exePath)) {
    Write-Host "Downloading TrustTunnel CLI..." -ForegroundColor Cyan

    $apiUrl = "https://api.github.com/repos/TrustTunnel/TrustTunnelClient/releases/latest"
    $release = Invoke-RestMethod -Uri $apiUrl

    $asset = $release.assets |
        Where-Object { $_.name -like "*windows*x86_64*" -or $_.name -like "*windows*amd64*" } |
        Select-Object -First 1

    if (-not $asset) {
        Write-Error "Could not find Windows x64 asset in latest release"
        exit 1
    }

    Write-Host "  Version: $($release.tag_name)"
    Write-Host "  Asset:   $($asset.name)"

    $zipPath = Join-Path $env:TEMP "trusttunnel_cli.zip"
    $extractDir = Join-Path $env:TEMP "trusttunnel_cli_temp"

    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    $found = Get-ChildItem -Path $extractDir -Filter "trusttunnel_client.exe" -Recurse | Select-Object -First 1
    if (-not $found) {
        $found = Get-ChildItem -Path $extractDir -Filter "trusttunnel.exe" -Recurse | Select-Object -First 1
    }
    if (-not $found) {
        Write-Error "Could not find trusttunnel_client.exe in downloaded archive"
        exit 1
    }

    Copy-Item -Path $found.FullName -Destination $exePath -Force
    $size = (Get-Item $exePath).Length
    Write-Host "  Saved:   $exePath ($([math]::Round($size / 1MB, 1)) MB)" -ForegroundColor Green

    # Cleanup
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "TrustTunnel CLI already exists, skipping (use -Force to re-download)" -ForegroundColor Yellow
}

# ── Download Wintun ──

if ($Force -or -not (Test-Path $dllPath)) {
    Write-Host "Downloading Wintun driver..." -ForegroundColor Cyan

    $wintunUrl = "https://www.wintun.net/builds/wintun-0.14.1.zip"
    $zipPath = Join-Path $env:TEMP "wintun.zip"
    $extractDir = Join-Path $env:TEMP "wintun_temp"

    Invoke-WebRequest -Uri $wintunUrl -OutFile $zipPath
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    $found = Get-ChildItem -Path $extractDir -Filter "wintun.dll" -Recurse |
        Where-Object { $_.DirectoryName -like "*amd64*" } |
        Select-Object -First 1

    if (-not $found) {
        Write-Error "Could not find wintun.dll (amd64) in downloaded archive"
        exit 1
    }

    Copy-Item -Path $found.FullName -Destination $dllPath -Force
    $size = (Get-Item $dllPath).Length
    Write-Host "  Saved:   $dllPath ($([math]::Round($size / 1KB, 1)) KB)" -ForegroundColor Green

    # Cleanup
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Wintun DLL already exists, skipping (use -Force to re-download)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Dependencies ready in $clientDir" -ForegroundColor Green
