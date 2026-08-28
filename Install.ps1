trap {
    Write-Host ""
    Write-Host "INSTALL FAILED:" -ForegroundColor Red
    Write-Host "$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor Red
    try {
        $logPath = Join-Path $PSScriptRoot 'install-error.log'
        "$(Get-Date -Format 'u')  $($_.Exception.Message)  (line $($_.InvocationInfo.ScriptLineNumber))" |
            Out-File -FilePath $logPath -Append -Encoding UTF8
        Write-Host "(also logged to $logPath)" -ForegroundColor DarkYellow
    } catch {}
    Write-Host ""
    Read-Host "Press Enter to close this window"
    exit 1
}

$ErrorActionPreference = 'Stop'

$installDir  = "$env:LOCALAPPDATA\DesktopIconToggle"
$traySrc     = Join-Path $PSScriptRoot 'DesktopIconTray.ps1'
$trayDest    = Join-Path $installDir 'DesktopIconTray.ps1'
$cliSrc      = Join-Path $PSScriptRoot 'DesktopIconManager.ps1'
$cliDest     = Join-Path $installDir 'DesktopIconManager.ps1'
$icoSrc      = Join-Path $PSScriptRoot 'App.ico'
$icoDest     = Join-Path $installDir 'App.ico'
$vbsSrc      = Join-Path $PSScriptRoot 'Run-Hidden.vbs'
$vbsDest     = Join-Path $installDir 'Run-Hidden.vbs'
$startupDir  = [Environment]::GetFolderPath('Startup')
$startupLink = Join-Path $startupDir 'Desktop Icon Toggle.lnk'

Write-Host "Installing Desktop Icon Toggle..." -ForegroundColor Cyan
Write-Host "Source folder: $PSScriptRoot"

if (-not (Test-Path $traySrc)) {
    throw "DesktopIconTray.ps1 was not found next to Install.ps1 (looked in: $PSScriptRoot). Make sure you extracted the ENTIRE zip and are running Install.bat from inside that extracted folder, not from within the zip itself."
}
if (-not (Test-Path $cliSrc)) {
    throw "DesktopIconManager.ps1 was not found next to Install.ps1 (looked in: $PSScriptRoot)."
}

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -Path $traySrc -Destination $trayDest -Force
Copy-Item -Path $cliSrc  -Destination $cliDest  -Force
$uninstallSrc = Join-Path $PSScriptRoot 'Uninstall.ps1'
if (Test-Path $uninstallSrc) {
    Copy-Item -Path $uninstallSrc -Destination (Join-Path $installDir 'Uninstall.ps1') -Force
}
if (Test-Path $vbsSrc) {
    Copy-Item -Path $vbsSrc -Destination $vbsDest -Force
}
if (Test-Path $icoSrc) {
    Copy-Item -Path $icoSrc -Destination $icoDest -Force
}
$icoHiddenSrc = Join-Path $PSScriptRoot 'App-Hidden.ico'
$icoHiddenDest = Join-Path $installDir 'App-Hidden.ico'
if (Test-Path $icoHiddenSrc) {
    Copy-Item -Path $icoHiddenSrc -Destination $icoHiddenDest -Force
}

$exeDest = Join-Path $installDir 'DesktopIconToggle.exe'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$launcherSrc = Join-Path $PSScriptRoot 'Launcher.cs'
$builtExe = $false
if ((Test-Path $csc) -and (Test-Path $launcherSrc)) {
    $wf = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.Windows.Forms.dll'
    $manifest = Join-Path $PSScriptRoot 'app.manifest'
    $cscArgs = @('/nologo', '/target:winexe', '/optimize+', "/r:$wf", "/out:$exeDest", $launcherSrc)
    if (Test-Path $manifest) { $cscArgs = @('/nologo', '/target:winexe', '/optimize+', "/win32manifest:$manifest", "/r:$wf", "/out:$exeDest", $launcherSrc) }
    if ((Test-Path $icoDest) -and (Test-Path $manifest)) {
        $cscArgs = @('/nologo', '/target:winexe', '/optimize+', "/win32icon:$icoDest", "/win32manifest:$manifest", "/r:$wf", "/out:$exeDest", $launcherSrc)
    } elseif (Test-Path $icoDest) {
        $cscArgs = @('/nologo', '/target:winexe', '/optimize+', "/win32icon:$icoDest", "/r:$wf", "/out:$exeDest", $launcherSrc)
    }
    & $csc @cscArgs
    if ($LASTEXITCODE -eq 0 -and (Test-Path $exeDest)) {
        $builtExe = $true
        Write-Host "Built DesktopIconToggle.exe" -ForegroundColor DarkGreen
        try {
            $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
                Where-Object { $_.Subject -eq 'CN=Desktop Icon Toggle' } |
                Select-Object -First 1
            if (-not $cert) {
                $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Desktop Icon Toggle' -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(5)
            }
            $sig = Set-AuthenticodeSignature -FilePath $exeDest -Certificate $cert -ErrorAction Stop
            Write-Host "Signed exe: $($sig.Status)" -ForegroundColor DarkGreen
        } catch {
            Write-Host "(Could not sign the exe: $($_.Exception.Message))" -ForegroundColor DarkYellow
        }
    }
}

function Write-HiddenLauncher([string]$vbsPath, [string]$psCommand) {
    $escaped = $psCommand -replace '"', '""'
    @"
CreateObject("WScript.Shell").Run "$escaped", 0, False
"@ | Set-Content -Path $vbsPath -Encoding ASCII
}

$launchWindow = Join-Path $installDir 'Launch-Window.vbs'
$launchTray   = Join-Path $installDir 'Launch-Tray.vbs'
$launchReset  = Join-Path $installDir 'Launch-Reset.vbs'
Write-HiddenLauncher $launchWindow "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$trayDest`" -ShowUi"
Write-HiddenLauncher $launchTray   "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$trayDest`""
Write-HiddenLauncher $launchReset  "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$cliDest`" -Reset"

if (-not (Test-Path $trayDest)) {
    throw "Copy appeared to succeed but $trayDest still doesn't exist. Check antivirus/permissions on $installDir."
}
Write-Host "Copied files to $installDir" -ForegroundColor DarkGreen

try {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -like "*DesktopIconTray.ps1*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
} catch {
    Write-Host "(Could not check for a running instance - continuing anyway: $($_.Exception.Message))" -ForegroundColor DarkYellow
}

$wshShell = New-Object -ComObject WScript.Shell

function New-AppShortcut([string]$path, [string]$target, [string]$arguments, [string]$desc) {
    $sc = $wshShell.CreateShortcut($path)
    $sc.TargetPath = $target
    $sc.Arguments = $arguments
    $sc.WorkingDirectory = $installDir
    $sc.WindowStyle = 7
    $sc.Description = $desc
    if (Test-Path $icoDest) { $sc.IconLocation = "$icoDest,0" }
    elseif ($builtExe) { $sc.IconLocation = "$exeDest,0" }
    $sc.Save()
}

if ($builtExe) {
    New-AppShortcut $startupLink $exeDest '-Tray' 'Desktop Icon Toggle - runs in the notification area'
    $startTarget = $exeDest
    $startArgs = ''
    $restoreTarget = $exeDest
    $restoreArgs = '-Reset'
} else {
    New-AppShortcut $startupLink "$env:SystemRoot\System32\wscript.exe" "`"$launchTray`"" 'Desktop Icon Toggle - runs in the notification area'
    $startTarget = "$env:SystemRoot\System32\wscript.exe"
    $startArgs = "`"$launchWindow`""
    $restoreTarget = "$env:SystemRoot\System32\wscript.exe"
    $restoreArgs = "`"$launchReset`""
}
Write-Host "Created Startup shortcut: $startupLink" -ForegroundColor DarkGreen

$programsDir = [Environment]::GetFolderPath('Programs')
$desktopDir  = [Environment]::GetFolderPath('Desktop')
$startLink   = Join-Path $programsDir 'Desktop Icon Toggle.lnk'
$restoreStart = Join-Path $programsDir 'Restore Desktop Icons.lnk'
$restoreDesk  = Join-Path $desktopDir 'Restore Desktop Icons.lnk'

New-AppShortcut $startLink $startTarget $startArgs 'Open Desktop Icon Toggle'
New-AppShortcut $restoreDesk $restoreTarget $restoreArgs 'Show all desktop icons'
$oldRestoreStart = Join-Path $programsDir 'Restore Desktop Icons.lnk'
if (Test-Path $oldRestoreStart) { Remove-Item $oldRestoreStart -Force }
Write-Host "Created Start menu shortcut. Restore Desktop Icons remains on the desktop only." -ForegroundColor DarkGreen

$uninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DesktopIconToggle'
New-Item -Path $uninstKey -Force | Out-Null
Set-ItemProperty $uninstKey -Name DisplayName -Value 'Desktop Icon Toggle'
Set-ItemProperty $uninstKey -Name DisplayVersion -Value '1.4.1'
Set-ItemProperty $uninstKey -Name Publisher -Value 'Desktop Icon Toggle'
Set-ItemProperty $uninstKey -Name InstallLocation -Value $installDir
Set-ItemProperty $uninstKey -Name NoModify -Value 1 -Type DWord
Set-ItemProperty $uninstKey -Name NoRepair -Value 1 -Type DWord
if ($builtExe) {
    Set-ItemProperty $uninstKey -Name DisplayIcon -Value $exeDest
    Set-ItemProperty $uninstKey -Name UninstallString -Value "`"$exeDest`" -Uninstall"
} else {
    Set-ItemProperty $uninstKey -Name DisplayIcon -Value $icoDest
    Set-ItemProperty $uninstKey -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Uninstall.ps1')`""
}
Write-Host "Registered in Settings > Apps." -ForegroundColor DarkGreen

if ($builtExe) {
    Start-Process -FilePath $exeDest
} else {
    Start-Process -FilePath "$env:SystemRoot\System32\wscript.exe" -ArgumentList "`"$launchWindow`""
}
Write-Host "Launched Desktop Icon Toggle." -ForegroundColor DarkGreen

Write-Host ""
Write-Host "Done. A Desktop Icon Toggle window should be on screen." -ForegroundColor Green
Write-Host "Uninstall from Settings > Apps, or Uninstall.bat in this folder." -ForegroundColor Green
Write-Host "Hide/restore shortcut: Win+Shift+D (change it in Settings)." -ForegroundColor Green
Write-Host ""
Write-Host "Start menu: Desktop Icon Toggle"
Write-Host "It will also start with Windows (tray icon only until you open it)."
Write-Host ""
Read-Host "Press Enter to close this window"
