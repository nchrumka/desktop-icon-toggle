# Build a script-only zip for GitHub Releases. Does not include .exe.
param(
    [string]$Version = '1.5.0',
    [switch]$GitHubRelease
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$name = "DesktopIconToggle-$Version"
$dist = Join-Path $root 'dist'
$stage = Join-Path $env:TEMP $name
$zipPath = Join-Path $dist "$name.zip"

$files = @(
    'Install.bat',
    'Install.ps1',
    'Uninstall.bat',
    'Uninstall.ps1',
    'DesktopIconTray.ps1',
    'DesktopIconManager.ps1',
    'Run-Hidden.vbs',
    'App.ico',
    'App-Hidden.ico',
    'README.md',
    'USER-MANUAL.md'
)

foreach ($f in $files) {
    $p = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $p)) {
        throw "Missing $f (needed in the release zip)."
    }
}

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
New-Item -ItemType Directory -Path $dist -Force | Out-Null
foreach ($f in $files) {
    Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $stage $f) -Force
}

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item -LiteralPath $stage -Recurse -Force

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$hashFile = Join-Path $dist "$name.zip.sha256"
"$hash  $name.zip" | Set-Content -Path $hashFile -Encoding ASCII

Write-Host "Zip: $zipPath"
Write-Host "SHA256: $hash"
Write-Host "Hash file: $hashFile"

if (-not $GitHubRelease) { return }

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Write-Warning "GitHub CLI (gh) was not found. Zip is ready; create the release from the GitHub website or install gh and re-run with -GitHubRelease."
    return
}

$notes = @"
Script-only install (no exe). Extract the zip and run Install.bat.

SHA-256: $hash

- Customize can keep selected files on the wallpaper
- Hide/restore on OneDrive desktops
- Uninstall finishes after the process exits
"@

& gh release create "v$Version" $zipPath --title $Version --notes $notes --repo nchrumka/desktop-icon-toggle
if ($LASTEXITCODE -ne 0) { throw "gh release create failed: $LASTEXITCODE" }
Write-Host "Published https://github.com/nchrumka/desktop-icon-toggle/releases/tag/v$Version"
