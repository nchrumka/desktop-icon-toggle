param(
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'

$installDir   = "$env:LOCALAPPDATA\DesktopIconToggle"
$cliPath      = Join-Path $installDir 'DesktopIconManager.ps1'
$snapshotPath = Join-Path $installDir 'snapshot.json'
$startupDir   = [Environment]::GetFolderPath('Startup')
$startupLink  = Join-Path $startupDir 'Desktop Icon Toggle.lnk'

Write-Host "Uninstalling Desktop Icon Toggle..." -ForegroundColor Cyan

# Safety net: if icons are currently hidden/customized, restore the true original
# BEFORE removing anything, so nobody ends up with icons missing permanently.
if ((Test-Path $snapshotPath) -and (Test-Path $cliPath)) {
    Write-Host "Your desktop has been customized - restoring your original icons first..." -ForegroundColor Yellow
    & powershell -ExecutionPolicy RemoteSigned -File $cliPath -Restore -Silent
}

# Stop the running tray icon so it doesn't linger after its files are gone.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*DesktopIconTray.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

schtasks.exe /Delete /TN 'DesktopIconToggleHelper' /F 2>$null | Out-Null

if (Test-Path $startupLink) { Remove-Item $startupLink -Force }
$programsDir = [Environment]::GetFolderPath('Programs')
$desktopDir  = [Environment]::GetFolderPath('Desktop')
@(
    (Join-Path $programsDir 'Desktop Icon Toggle.lnk'),
    (Join-Path $programsDir 'Restore Desktop Icons.lnk'),
    (Join-Path $desktopDir 'Restore Desktop Icons.lnk')
) | ForEach-Object { if (Test-Path $_) { Remove-Item $_ -Force } }
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DesktopIconToggle' -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue }

if (-not $Silent) {
    Write-Host ""
    Write-Host "Desktop Icon Toggle has been completely removed." -ForegroundColor Green
    Write-Host ""
    Read-Host "Press Enter to close this window"
}
