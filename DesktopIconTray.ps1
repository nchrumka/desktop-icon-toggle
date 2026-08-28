<#
.SYNOPSIS
    Desktop Icon Toggle - hide desktop icons for screenshots, then restore them.

.NOTES
    State lives next to this script. Press Win+Shift+D (changeable) to toggle.
#>

param(
    [switch]$ShowUi
)

Add-Type -Name NativeBoot -Namespace DesktopIconToggle -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
"@
try { [void][DesktopIconToggle.NativeBoot]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {
    [void][DesktopIconToggle.NativeBoot]::SetProcessDPIAware()
}
$consoleWnd = [DesktopIconToggle.NativeBoot]::GetConsoleWindow()
if ($consoleWnd -ne [IntPtr]::Zero) {
    [void][DesktopIconToggle.NativeBoot]::ShowWindow($consoleWnd, 0)
}

trap {
    $msg = "Desktop Icon Toggle hit an error and had to close:`n`n$($_.Exception.Message)`n`nLine $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    try {
        $logPath = Join-Path $PSScriptRoot 'error.log'
        "$(Get-Date -Format 'u')  $($_.Exception.Message)  (line $($_.InvocationInfo.ScriptLineNumber))" |
            Out-File -FilePath $logPath -Append -Encoding UTF8
    } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($msg, "Desktop Icon Toggle - Error", 'OK', 'Error') | Out-Null
    } catch {}
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$wfAsm = [System.Windows.Forms.NativeWindow].Assembly.Location
Add-Type -ReferencedAssemblies $wfAsm -TypeDefinition @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;

namespace DesktopIconToggle {
    public class HotKeyEventArgs : EventArgs {
        public int Id { get; private set; }
        public HotKeyEventArgs(int id) { Id = id; }
    }
    public class HotKeyWindow : NativeWindow, IDisposable {
        public event EventHandler<HotKeyEventArgs> HotKeyPressed;
        private const int WM_HOTKEY = 0x0312;
        public HotKeyWindow() {
            CreateParams cp = new CreateParams();
            CreateHandle(cp);
        }
        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        public bool TryRegister(int id, uint modifiers, uint vk) {
            UnregisterHotKey(Handle, id);
            return RegisterHotKey(Handle, id, modifiers, vk);
        }
        public void Clear(int id) { UnregisterHotKey(Handle, id); }
        public void Dispose() {
            for (int i = 1; i <= 8; i++) UnregisterHotKey(Handle, i);
            DestroyHandle();
        }
        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_HOTKEY) {
                var h = HotKeyPressed;
                if (h != null) h(this, new HotKeyEventArgs(m.WParam.ToInt32()));
            }
            base.WndProc(ref m);
        }
    }
}
"@

$script:SingleInstance = New-Object System.Threading.Mutex($false, 'Local\DesktopIconToggle')
if (-not $script:SingleInstance.WaitOne(0)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Desktop Icon Toggle is already running.`n`nPress your hide/restore shortcut, look next to the clock (click ^), or Start menu > Desktop Icon Toggle.",
        'Desktop Icon Toggle', 'OK', 'Information') | Out-Null
    exit 0
}

[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
$threadExceptionHandler = {
    param($sender, $e)
    $errMsg = $e.Exception.Message
    try {
        "$(Get-Date -Format 'u')  $errMsg" | Out-File -FilePath (Join-Path $PSScriptRoot 'error.log') -Append -Encoding UTF8
    } catch {}
    [System.Windows.Forms.MessageBox]::Show("Something went wrong:`n`n$errMsg", "Desktop Icon Toggle - Error", 'OK', 'Error') | Out-Null
}
[System.Windows.Forms.Application]::add_ThreadException($threadExceptionHandler)

$root             = $PSScriptRoot
foreach ($n in @('DesktopIconTray.ps1', 'DesktopIconManager.ps1', 'Uninstall.ps1')) {
    Unblock-File -LiteralPath (Join-Path $root $n) -ErrorAction SilentlyContinue
}
$snapshotPath     = Join-Path $root 'snapshot.json'
$configPath       = Join-Path $root 'config.json'
$layoutBackupPath = Join-Path $root 'iconlayout.reg'
$profilesDir      = Join-Path $root 'Profiles'
$elevateReqPath   = Join-Path $root 'elevate-request.json'
$elevateResPath   = Join-Path $root 'elevate-result.json'
$helperTaskName   = 'DesktopIconToggleHelper'
$sysIconGuids = @{
    Recycle = '{645FF040-5081-101B-9F08-00AA002F954E}'
    ThisPC  = '{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
    Network = '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}'
}
$sysIconKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
$toastKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$bagKey           = 'HKCU\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
$lookBackupPath   = Join-Path $root 'capture-wallpaper.bak'
$lookSolidPath    = Join-Path $root 'capture-solid.bmp'
$appVersion       = '1.4.6'
$script:hideBtn   = $null
$script:controlForm = $null
$script:countdownLeft = 0
$script:hotkeysBusy = $false

New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null

function Get-DefaultConfig {
    [PSCustomObject]@{
        PreservePositions     = $false
        KeepRestoreShortcut   = $false
        ConfirmLargeHide      = $true
        HideCountdownSeconds  = 3
        AutoRestoreMinutes    = 0
        StartWithWindows       = $true
        FirstRunDone          = $false
        HotkeyToggle          = 'Win+Shift+D'
        HotkeyDelayedHide     = 'Win+Shift+H'
        HotkeyRestore         = ''
        QuietToastsWhileHidden = $false
        HideSystemDesktopIcons = $false
        ApplyCaptureLook      = $true
        CaptureWallpaper      = 'LightGray'
        CapturePicturePath    = ''
        CaptureTheme          = 'Keep'
        AutoHideTaskbarWhileHidden = $false
    }
}

function Get-ToolConfig {
    $d = Get-DefaultConfig
    if (Test-Path $configPath) {
        try {
            $c = Get-Content $configPath -Raw | ConvertFrom-Json
            foreach ($p in $d.PSObject.Properties.Name) {
                if ($null -ne $c.$p) { $d.$p = $c.$p }
            }
        } catch {}
    }
    return $d
}

function Save-ToolConfig($cfg) {
    $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
}

function Get-StartupLinkPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'Desktop Icon Toggle.lnk'
}

function Test-StartWithWindows { Test-Path (Get-StartupLinkPath) }

function Set-StartWithWindows([bool]$enabled) {
    $path = Get-StartupLinkPath
    if (-not $enabled) {
        if (Test-Path $path) { Remove-Item $path -Force }
        return
    }
    $vbs = Join-Path $PSScriptRoot 'Launch-Tray.vbs'
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($path)
    $sc.TargetPath = "$env:SystemRoot\System32\wscript.exe"
    $sc.Arguments = "`"$vbs`""
    $ico = Join-Path $PSScriptRoot 'App.ico'
    if (Test-Path $ico) { $sc.IconLocation = "$ico,0" }
    $sc.WorkingDirectory = $PSScriptRoot
    $sc.WindowStyle = 7
    $sc.Description = 'Desktop Icon Toggle - runs in the notification area'
    $sc.Save()
}

function Get-ProtectedNames {
    $names = @('desktop.ini')
    if ((Get-ToolConfig).KeepRestoreShortcut) { $names += 'Restore Desktop Icons.lnk' }
    return $names
}

function ConvertFrom-HotkeyString([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $mod = [uint32]0
    $vk = 0
    foreach ($part in ($text.ToUpperInvariant() -split '\+')) {
        switch ($part.Trim()) {
            'WIN'   { $mod = $mod -bor 8 }
            'CTRL'  { $mod = $mod -bor 2 }
            'CONTROL' { $mod = $mod -bor 2 }
            'ALT'   { $mod = $mod -bor 1 }
            'SHIFT' { $mod = $mod -bor 4 }
            default {
                if ($part.Length -eq 1 -and $part -match '^[A-Z]$') {
                    $vk = [int][char]$part
                }
            }
        }
    }
    if ($vk -eq 0) { return $null }
    if (($mod -band 8) -and ($mod -band 4) -and $vk -eq [int][char]'S') { return $null }
    return @{ Mod = $mod; Vk = $vk; Text = $text }
}

function ConvertTo-HotkeyString([bool]$win, [bool]$ctrl, [bool]$alt, [bool]$shift, [string]$key) {
    $parts = @()
    if ($win) { $parts += 'Win' }
    if ($ctrl) { $parts += 'Ctrl' }
    if ($alt) { $parts += 'Alt' }
    if ($shift) { $parts += 'Shift' }
    if ([string]::IsNullOrWhiteSpace($key)) { return '' }
    if ($parts.Count -eq 0) { return '' }
    return (($parts + $key.ToUpperInvariant()) -join '+')
}

Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("shell32.dll")]
public static extern void SHChangeNotify(int wEventId, int uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);
"@
Add-Type -Namespace Win32 -Name DesktopLook -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam, uint flags, uint timeout, out System.IntPtr result);
"@
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Win32 {
  public static class Taskbar {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
      public int left;
      public int top;
      public int right;
      public int bottom;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct APPBARDATA {
      public int cbSize;
      public IntPtr hWnd;
      public uint uCallbackMessage;
      public uint uEdge;
      public RECT rc;
      public int lParam;
    }
    [DllImport("shell32.dll")]
    public static extern IntPtr SHAppBarMessage(uint dwMessage, ref APPBARDATA pData);
    public static int GetState() {
      APPBARDATA abd = new APPBARDATA();
      abd.cbSize = Marshal.SizeOf(typeof(APPBARDATA));
      return (int)SHAppBarMessage(4, ref abd);
    }
    public static void SetState(int state) {
      APPBARDATA abd = new APPBARDATA();
      abd.cbSize = Marshal.SizeOf(typeof(APPBARDATA));
      abd.lParam = state;
      SHAppBarMessage(10, ref abd);
    }
  }
}
"@

function Get-TaskbarAppBarState {
    [Win32.Taskbar]::GetState()
}

function Set-TaskbarAppBarState([int]$state) {
    [Win32.Taskbar]::SetState($state)
}

function Set-StuckRectsAutoHide([bool]$on) {
    foreach ($name in @('StuckRects3', 'StuckRects2')) {
        $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\$name"
        try {
            $bytes = [byte[]](Get-ItemProperty -Path $key -Name Settings -ErrorAction Stop).Settings
            if ($null -eq $bytes -or $bytes.Length -lt 9) { continue }
            if ($on) { $bytes[8] = [byte]($bytes[8] -bor 1) }
            else { $bytes[8] = [byte]($bytes[8] -band (-bnot 1)) }
            Set-ItemProperty -Path $key -Name Settings -Value $bytes
        } catch {}
    }
}

function Enable-CaptureTaskbarAutoHide {
    Set-TaskbarAppBarState ((Get-TaskbarAppBarState) -bor 1)
    Set-StuckRectsAutoHide $true
}

function Restore-TaskbarAppBarState($saved) {
    if ($null -eq $saved) { return }
    Set-TaskbarAppBarState ([int]$saved)
    Set-StuckRectsAutoHide ([bool](([int]$saved) -band 1))
}

function Refresh-Desktop { [Win32.NativeMethods]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero) }

function Get-IconFromFile([string]$name) {
    $ico = Join-Path $PSScriptRoot $name
    if (Test-Path $ico) { return New-Object System.Drawing.Icon($ico) }
    return $null
}

function Backup-IconLayout {
    if (Test-Path $layoutBackupPath) { return }
    & reg.exe export $bagKey $layoutBackupPath /y *> $null
}
function Restore-IconLayout {
    if (-not (Test-Path $layoutBackupPath)) { return }
    & reg.exe import $layoutBackupPath *> $null
    Remove-Item $layoutBackupPath -Force -ErrorAction SilentlyContinue
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Process explorer.exe
}

function Get-DesktopPaths {
    @(
        [Environment]::GetFolderPath('Desktop'),
        "$env:PUBLIC\Desktop"
    ) | Where-Object { Test-Path $_ }
}
function Get-DesktopItems {
    foreach ($folder in Get-DesktopPaths) { Get-ChildItem -Path $folder -Force }
}

function Get-SystemIconState {
    $state = @{}
    if (-not (Test-Path $sysIconKey)) {
        New-Item -Path $sysIconKey -Force | Out-Null
    }
    $props = Get-ItemProperty -Path $sysIconKey -ErrorAction SilentlyContinue
    foreach ($name in $sysIconGuids.Keys) {
        $guid = $sysIconGuids[$name]
        $val = 0
        if ($props -and $null -ne $props.$guid) { $val = [int]$props.$guid }
        $state[$name] = $val
    }
    return $state
}

function Set-SystemIconHidden([bool]$hide, $savedState) {
    if (-not (Test-Path $sysIconKey)) { New-Item -Path $sysIconKey -Force | Out-Null }
    foreach ($name in $sysIconGuids.Keys) {
        $guid = $sysIconGuids[$name]
        $value = 0
        if ($hide) { $value = 1 }
        elseif ($savedState -and $null -ne $savedState.$name) { $value = [int]$savedState.$name }
        New-ItemProperty -Path $sysIconKey -Name $guid -PropertyType DWord -Value $value -Force | Out-Null
    }
}

function Get-ToastsEnabled {
    try {
        $p = Get-ItemProperty -Path $toastKey -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -ErrorAction Stop
        return [int]$p.NOC_GLOBAL_SETTING_TOASTS_ENABLED
    } catch {
        return 1
    }
}

function Set-ToastsEnabled([int]$enabled) {
    if (-not (Test-Path $toastKey)) { New-Item -Path $toastKey -Force | Out-Null }
    New-ItemProperty -Path $toastKey -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -PropertyType DWord -Value $enabled -Force | Out-Null
}

function Get-PersonalizeDword([string]$name, [int]$fallback) {
    try {
        return [int](Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name $name -ErrorAction Stop).$name
    } catch {
        return $fallback
    }
}

function Get-CaptureLookState {
    $desk = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop'
    $wall = [string]$desk.Wallpaper
    $backup = $null
    if ($wall -and (Test-Path -LiteralPath $wall)) {
        try {
            Copy-Item -LiteralPath $wall -Destination $lookBackupPath -Force
            $backup = $lookBackupPath
        } catch {
            $backup = $null
        }
    }
    $bg = ''
    try { $bg = [string](Get-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Background).Background } catch {}
    [PSCustomObject]@{
        Wallpaper            = $wall
        WallpaperBackup      = $backup
        WallpaperStyle       = [string]$desk.WallpaperStyle
        TileWallpaper        = [string]$desk.TileWallpaper
        BackgroundColor      = $bg
        AppsUseLightTheme    = Get-PersonalizeDword 'AppsUseLightTheme' 1
        SystemUsesLightTheme = Get-PersonalizeDword 'SystemUsesLightTheme' 1
    }
}

function Set-WallpaperFile([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
    [void][Win32.DesktopLook]::SystemParametersInfo(20, 0, $path, 3)
}

function New-SolidWallpaper([string]$path, [int]$r, [int]$g, [int]$b) {
    $bmp = New-Object System.Drawing.Bitmap 1920, 1080
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.Clear([System.Drawing.Color]::FromArgb($r, $g, $b))
    $gfx.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $bmp.Dispose()
}

function Set-WindowsLightTheme([int]$light) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name AppsUseLightTheme -PropertyType DWord -Value $light -Force | Out-Null
    New-ItemProperty -Path $key -Name SystemUsesLightTheme -PropertyType DWord -Value $light -Force | Out-Null
    $result = [IntPtr]::Zero
    [void][Win32.DesktopLook]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'ImmersiveColorSet', 2, 2000, [ref]$result)
}

function Apply-CaptureLook($saved) {
    $cfg = Get-ToolConfig
    if (-not $cfg.ApplyCaptureLook) { return }
    $canChangeWall = $true
    if ($saved -and $saved.Wallpaper -and -not $saved.WallpaperBackup) {
        if ([string]$saved.Wallpaper -match 'TranscodedWallpaper') { $canChangeWall = $false }
    }
    if ($canChangeWall) {
        switch ([string]$cfg.CaptureWallpaper) {
            'Keep' { }
            'Picture' {
                if ($cfg.CapturePicturePath -and (Test-Path -LiteralPath $cfg.CapturePicturePath)) {
                    Set-WallpaperFile $cfg.CapturePicturePath
                }
            }
            'White' {
                New-SolidWallpaper $lookSolidPath 255 255 255
                Set-WallpaperFile $lookSolidPath
            }
            'Black' {
                New-SolidWallpaper $lookSolidPath 0 0 0
                Set-WallpaperFile $lookSolidPath
            }
            default {
                New-SolidWallpaper $lookSolidPath 240 240 240
                Set-WallpaperFile $lookSolidPath
            }
        }
    }
    switch ([string]$cfg.CaptureTheme) {
        'Light' { Set-WindowsLightTheme 1 }
        'Dark'  { Set-WindowsLightTheme 0 }
    }
}

function Restore-CaptureLook($saved) {
    if (-not $saved) { return }
    $file = $null
    if ($saved.WallpaperBackup -and (Test-Path -LiteralPath $saved.WallpaperBackup)) {
        $file = [string]$saved.WallpaperBackup
    } elseif ($saved.Wallpaper -and (Test-Path -LiteralPath $saved.Wallpaper)) {
        $file = [string]$saved.Wallpaper
    }
    if ($saved.WallpaperStyle) {
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value $saved.WallpaperStyle
    }
    if ($saved.TileWallpaper) {
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value $saved.TileWallpaper
    }
    if ($file) { Set-WallpaperFile $file }
    elseif (-not $saved.Wallpaper) {
        [void][Win32.DesktopLook]::SystemParametersInfo(20, 0, '', 3)
    }
    if ($saved.BackgroundColor) {
        Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Background -Value $saved.BackgroundColor
    }
    if ($null -ne $saved.AppsUseLightTheme) {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        New-ItemProperty -Path $key -Name AppsUseLightTheme -PropertyType DWord -Value ([int]$saved.AppsUseLightTheme) -Force | Out-Null
        New-ItemProperty -Path $key -Name SystemUsesLightTheme -PropertyType DWord -Value ([int]$saved.SystemUsesLightTheme) -Force | Out-Null
        $result = [IntPtr]::Zero
        [void][Win32.DesktopLook]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'ImmersiveColorSet', 2, 2000, [ref]$result)
    }
    Remove-Item $lookBackupPath -Force -ErrorAction SilentlyContinue
    Remove-Item $lookSolidPath -Force -ErrorAction SilentlyContinue
}

function Get-WallpaperSizeHint {
    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    if ($screens.Count -eq 0) {
        return 'Could not read screen size. Use a picture that matches the monitor you will capture.'
    }
    $list = @()
    $maxW = 0
    $maxH = 0
    $maxPx = 0
    foreach ($s in $screens) {
        $w = [int]$s.Bounds.Width
        $h = [int]$s.Bounds.Height
        $list += "$w x $h"
        $px = $w * $h
        if ($px -gt $maxPx) {
            $maxPx = $px
            $maxW = $w
            $maxH = $h
        }
    }
    if ($screens.Count -eq 1) {
        return "Recommended custom picture: $maxW x $maxH (this screen). Display scaling does not change that. The picture is filled per monitor."
    }
    return "Recommended custom picture: $maxW x $maxH (largest of $($screens.Count) screens: $($list -join ', ')). Size it to the monitor you will capture. Fill crops extra pixels on smaller screens."
}

function Read-Snapshot {
    if (-not (Test-Path $snapshotPath)) { return $null }
    $raw = Get-Content $snapshotPath -Raw | ConvertFrom-Json
    if ($raw.PSObject.Properties.Name -contains 'Items') { return $raw }
    return [PSCustomObject]@{ Items = @($raw); SystemIcons = $null; ToastsEnabled = $null; CaptureLook = $null; TaskbarAppBarState = $null }
}

function Write-Snapshot($items, $sys, $toasts, $look, $taskbarState) {
    [PSCustomObject]@{
        Items = @($items)
        SystemIcons = $sys
        ToastsEnabled = $toasts
        CaptureLook = $look
        TaskbarAppBarState = $taskbarState
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $snapshotPath -Encoding UTF8
}

function Test-DesktopHidden { Test-Path $snapshotPath }

function Ensure-Baseline($look, $taskbarState) {
    if (Test-Path $snapshotPath) { return }
    $cfg = Get-ToolConfig
    if ($cfg.PreservePositions) { Backup-IconLayout }
    $items = foreach ($item in (Get-DesktopItems)) {
        [PSCustomObject]@{ Path = $item.FullName; WasHidden = [bool]($item.Attributes -band [IO.FileAttributes]::Hidden) }
    }
    Write-Snapshot $items (Get-SystemIconState) (Get-ToastsEnabled) $look $taskbarState
}

function Invoke-DesktopRefreshRetry {
    Refresh-Desktop
    Start-Sleep -Milliseconds 350
    Refresh-Desktop
}

function Hide-AllIcons {
    $cfg = Get-ToolConfig
    $fresh = -not (Test-Path $snapshotPath)
    $look = $null
    if ($fresh -and $cfg.ApplyCaptureLook) { $look = Get-CaptureLookState }
    if ($fresh) {
        $tb = $null
        if ($cfg.AutoHideTaskbarWhileHidden) { $tb = Get-TaskbarAppBarState }
        Ensure-Baseline $look $tb
    }
    $failed = Apply-HiddenWithElevate (Get-DesktopItems) $true $true
    Invoke-DesktopRefreshRetry
    $protect = Get-ProtectedNames
    $retry = @()
    foreach ($item in (Get-DesktopItems)) {
        if ($item.Name -in $protect) { continue }
        if (-not [bool]($item.Attributes -band [IO.FileAttributes]::Hidden)) { $retry += $item }
    }
    if ($retry.Count -gt 0) {
        $failed += Apply-HiddenWithElevate $retry $true $true
        Invoke-DesktopRefreshRetry
    }
    if ($fresh -and $cfg.HideSystemDesktopIcons) { Set-SystemIconHidden $true $null }
    if ($fresh -and $cfg.QuietToastsWhileHidden) { Set-ToastsEnabled 0 }
    if ($fresh -and $cfg.ApplyCaptureLook) { Apply-CaptureLook $look }
    if ($fresh -and $cfg.AutoHideTaskbarWhileHidden) { Enable-CaptureTaskbarAutoHide }
    Refresh-Desktop
    return $failed
}

function Restore-Original {
    if (-not (Test-Path $snapshotPath)) { return @() }
    $snapshot   = Read-Snapshot
    $knownPaths = @($snapshot.Items.Path)
    $failed = @()
    $toShow = @()
    foreach ($entry in @($snapshot.Items)) {
        if (-not (Test-Path $entry.Path)) { continue }
        $item = Get-Item $entry.Path -Force
        if (-not $entry.WasHidden) { $toShow += $item }
    }
    $failed += Apply-HiddenWithElevate $toShow $false $false
    $extraHidden = @()
    foreach ($item in (Get-DesktopItems)) {
        if ($item.Name -eq 'desktop.ini') { continue }
        if ($item.FullName -notin $knownPaths -and ($item.Attributes -band [IO.FileAttributes]::Hidden)) {
            $extraHidden += $item
        }
    }
    if ($extraHidden.Count -gt 0) {
        $failed += Apply-HiddenWithElevate $extraHidden $false $false
    }
    if ($null -ne $snapshot.SystemIcons) { Set-SystemIconHidden $false $snapshot.SystemIcons }
    if ($null -ne $snapshot.ToastsEnabled) { Set-ToastsEnabled ([int]$snapshot.ToastsEnabled) }
    Restore-CaptureLook $snapshot.CaptureLook
    Restore-TaskbarAppBarState $snapshot.TaskbarAppBarState
    Remove-Item $snapshotPath -Force
    $cfg = Get-ToolConfig
    if ($cfg.PreservePositions) { Restore-IconLayout } else { Invoke-DesktopRefreshRetry }
    return $failed
}

function Apply-VisibleSet([string[]]$visibleNames) {
    Ensure-Baseline
    $protect = Get-ProtectedNames
    $toHide = @()
    $toShow = @()
    foreach ($item in (Get-DesktopItems)) {
        if ($item.Name -in $protect) { continue }
        $shouldBeVisible = $item.Name -in $visibleNames
        if ($shouldBeVisible) { $toShow += $item } else { $toHide += $item }
    }
    $failed = @()
    $failed += Apply-HiddenWithElevate $toHide $true $true
    $failed += Apply-HiddenWithElevate $toShow $false $true
    Refresh-Desktop
    return $failed
}

function Reset-DesktopState {
    $snap = $null
    if (Test-Path $snapshotPath) { $snap = Read-Snapshot }
    $failed = Apply-HiddenWithElevate (Get-DesktopItems) $false $false
    if ($snap -and $null -ne $snap.SystemIcons) { Set-SystemIconHidden $false $snap.SystemIcons }
    else { Set-SystemIconHidden $false @{ Recycle = 0; ThisPC = 0; Network = 0 } }
    if ($snap -and $null -ne $snap.ToastsEnabled) { Set-ToastsEnabled ([int]$snap.ToastsEnabled) }
    else { Set-ToastsEnabled 1 }
    if ($snap) { Restore-CaptureLook $snap.CaptureLook }
    if ($snap) { Restore-TaskbarAppBarState $snap.TaskbarAppBarState }
    Remove-Item $snapshotPath -Force -ErrorAction SilentlyContinue
    Remove-Item $layoutBackupPath -Force -ErrorAction SilentlyContinue
    Invoke-DesktopRefreshRetry
    return $failed
}

function Test-HelperTask {
    & schtasks.exe /Query /TN $helperTaskName 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-ElevatedHiddenChange([string[]]$paths, [bool]$hidden) {
    $manager = Join-Path $PSScriptRoot 'DesktopIconManager.ps1'
    $paths = @(
        @($paths) | Where-Object {
            $_ -and $_.Length -gt 1 -and (Test-Path -LiteralPath $_)
        }
    )
    if ($paths.Count -eq 0) { return $true }
    if (-not (Test-Path $manager)) { return $false }

    $req = [PSCustomObject]@{ Hidden = $hidden; Paths = @($paths) }
    $req | ConvertTo-Json -Depth 3 | Set-Content -Path $elevateReqPath -Encoding UTF8
    Remove-Item $elevateResPath -Force -ErrorAction SilentlyContinue

    if (Test-HelperTask) {
        & schtasks.exe /Run /TN $helperTaskName | Out-Null
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path $elevateResPath) { break }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 150
        }
        if (Test-Path $elevateResPath) {
            try { return [bool](Get-Content $elevateResPath -Raw | ConvertFrom-Json).Ok } catch { return $true }
        }
        return $false
    }

    $listFile = Join-Path $env:TEMP ("DesktopIconToggle-{0}.txt" -f [guid]::NewGuid())
    $paths | Set-Content -Path $listFile -Encoding UTF8
    $flag = if ($hidden) { '-SetHidden' } else { '-SetVisible' }
    try {
        $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$manager`" -RegisterHelper $flag -ListFile `"$listFile`""
        $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList $arg
        return ($null -ne $proc -and $proc.ExitCode -eq 0)
    } catch {
        return $false
    } finally {
        Remove-Item $listFile -Force -ErrorAction SilentlyContinue
    }
}

function Set-ItemHiddenSafe($item, [bool]$hidden) {
    try {
        $isHidden = [bool]($item.Attributes -band [IO.FileAttributes]::Hidden)
        if ($hidden -and -not $isHidden) { $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden }
        elseif (-not $hidden -and $isHidden) { $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::Hidden) }
        return $true
    } catch {
        return $false
    }
}

function Apply-HiddenWithElevate($items, [bool]$hidden, [bool]$respectProtect) {
    $protect = Get-ProtectedNames
    $retry = @()
    $failed = @()
    foreach ($item in @($items)) {
        if (-not $item) { continue }
        if ($item.Name -eq 'desktop.ini') { continue }
        if ($respectProtect -and ($item.Name -in $protect)) { continue }
        if (-not (Set-ItemHiddenSafe $item $hidden)) { $retry += $item }
    }
    if ($retry.Count -gt 0) {
        $retryPaths = @($retry | ForEach-Object { $_.FullName })
        $elevated = Invoke-ElevatedHiddenChange $retryPaths $hidden
        foreach ($item in $retry) {
            try {
                $again = Get-Item -LiteralPath $item.FullName -Force
                $isHidden = [bool]($again.Attributes -band [IO.FileAttributes]::Hidden)
                if ($hidden -ne $isHidden) { $failed += $item.Name }
            } catch {
                $failed += $item.Name
            }
        }
        if (-not $elevated -and $failed.Count -eq 0) {
            $failed = @($retry | ForEach-Object { $_.Name })
        }
    }
    return $failed
}

function Report-Failures([string[]]$failedNames) {
    if (-not $failedNames -or $failedNames.Count -eq 0) { return }
    $list = ($failedNames | Select-Object -Unique) -join "`n  - "
    [System.Windows.Forms.MessageBox]::Show(
        "$($failedNames.Count) icon(s) could not be changed (left as-is):`n`n  - $list`n`n" +
        "Shared (Public Desktop) shortcuts need one administrator Yes the first time. After that, Hide should not ask again.",
        "Some icons were skipped", 'OK', 'Warning') | Out-Null
}

function Get-ProfileNames {
    Get-ChildItem -Path $profilesDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }
}

function Show-Balloon([string]$text, [string]$title = 'Desktop Icon Toggle') {
    if (-not $notifyIcon) { return }
    $notifyIcon.BalloonTipTitle = $title
    $notifyIcon.BalloonTipText  = $text
    $notifyIcon.ShowBalloonTip(3500)
}

function Stop-Countdown {
    $script:countdownLeft = 0
    if ($script:countdownTimer) { $script:countdownTimer.Stop() }
}

function Stop-AutoRestore {
    if ($script:autoRestoreTimer) { $script:autoRestoreTimer.Stop() }
}

function Start-AutoRestoreIfNeeded {
    Stop-AutoRestore
    $mins = 0
    try { $mins = [int](Get-ToolConfig).AutoRestoreMinutes } catch {}
    if ($mins -le 0) { return }
    if (-not $script:autoRestoreTimer) {
        $script:autoRestoreTimer = New-Object System.Windows.Forms.Timer
        $script:autoRestoreTimer.Add_Tick({
            $script:autoRestoreTimer.Stop()
            if (Test-DesktopHidden) { Invoke-RestoreNow }
        })
    }
    $script:autoRestoreTimer.Interval = [Math]::Max(1, $mins) * 60 * 1000
    $script:autoRestoreTimer.Start()
}

function Sync-UiState {
    $hidden = Test-DesktopHidden
    $cfg = Get-ToolConfig
    $toggle = $cfg.HotkeyToggle
    if ($notifyIcon) {
        if ($hidden) {
            $notifyIcon.Text = "Desktop Icon Toggle - Hidden  ($toggle to restore)"
            if ($script:iconHidden) { $notifyIcon.Icon = $script:iconHidden } else { $notifyIcon.Icon = $script:iconVisible }
        } else {
            $notifyIcon.Text = "Desktop Icon Toggle - Visible  ($toggle to hide)"
            $notifyIcon.Icon = $script:iconVisible
        }
    }
    if ($script:statusTitle -and -not $script:statusTitle.IsDisposed) {
        if ($hidden) {
            $script:statusPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 243, 224)
            $script:statusTitle.Text = 'Desktop hidden'
            $script:statusHint.Text = "Press $toggle to restore, or click the tray icon."
        } else {
            $script:statusPanel.BackColor = [System.Drawing.Color]::FromArgb(227, 242, 253)
            $script:statusTitle.Text = 'Desktop visible'
            $script:statusHint.Text = "Press $toggle to hide icons for a screenshot. Recycle Bin stays."
        }
    }
    if ($script:hideBtn -and -not $script:hideBtn.IsDisposed) {
        if ($script:countdownLeft -gt 0) {
            $script:hideBtn.Text = "Cancel ($($script:countdownLeft))"
        } else {
            $script:hideBtn.Text = if ($hidden) { 'Restore desktop icons' } else { 'Hide desktop icons' }
        }
    }
    if ($script:hotkeyStatus -and -not $script:hotkeyStatus.IsDisposed) {
        if ($script:hotkeyFailures -and $script:hotkeyFailures.Count -gt 0) {
            $script:hotkeyStatus.ForeColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
            $script:hotkeyStatus.Text = 'In use by another app (pick a different key): ' + ($script:hotkeyFailures -join ', ')
        } else {
            $script:hotkeyStatus.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
            $script:hotkeyStatus.Text = 'Shortcuts are active. Win+Shift+S stays with Snipping Tool.'
        }
    }
    if ($script:delayBtn -and -not $script:delayBtn.IsDisposed) {
        $secs = [int]$cfg.HideCountdownSeconds
        $script:delayBtn.Visible = (-not $hidden -and $secs -gt 0)
        $script:delayBtn.Text = "Hide in $secs seconds"
    }
    if ($script:lookSizeHint -and -not $script:lookSizeHint.IsDisposed) {
        $script:lookSizeHint.Text = Get-WallpaperSizeHint
    }
}

function Invoke-HideNow([bool]$fromUi) {
    if (Test-DesktopHidden) { return }
    $cfg = Get-ToolConfig
    if ($fromUi -and $cfg.ConfirmLargeHide) {
        $count = @((Get-DesktopItems) | Where-Object { $_.Name -ne 'desktop.ini' }).Count
        if ($count -ge 100) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "$count items will be hidden.`n`nRestore with $($cfg.HotkeyToggle), the tray icon, or Restore Desktop Icons on the desktop.",
                'Hide desktop icons', 'OKCancel', 'Information')
            if ($r -ne 'OK') { return }
        }
    }
    if ($fromUi -and $script:controlForm -and -not $script:controlForm.IsDisposed) {
        $script:controlForm.Hide()
        [System.Windows.Forms.Application]::DoEvents()
    }
    $failed = Hide-AllIcons
    Start-AutoRestoreIfNeeded
    Sync-UiState
    Show-Balloon "Icons hidden. Press $($cfg.HotkeyToggle) to restore."
    Report-Failures $failed
}

function Invoke-RestoreNow {
    Stop-Countdown
    Stop-AutoRestore
    if (-not (Test-DesktopHidden)) { Sync-UiState; return }
    $failed = Restore-Original
    Sync-UiState
    Show-Balloon 'Desktop restored to normal.'
    Report-Failures $failed
}

function Invoke-ToggleAction {
    if ($script:hotkeysBusy) { return }
    $script:hotkeysBusy = $true
    try {
        if ($script:countdownLeft -gt 0) {
            Stop-Countdown
            Sync-UiState
            Show-Balloon 'Delayed hide cancelled.'
            return
        }
        if (Test-DesktopHidden) { Invoke-RestoreNow } else { Invoke-HideNow $false }
    } finally {
        $script:hotkeysBusy = $false
    }
}

function Start-DelayedHide {
    if (Test-DesktopHidden) { return }
    $secs = 3
    try { $secs = [int](Get-ToolConfig).HideCountdownSeconds } catch {}
    if ($secs -le 0) { Invoke-HideNow $false; return }
    if ($script:controlForm -and -not $script:controlForm.IsDisposed) { $script:controlForm.Hide() }
    $script:countdownLeft = $secs
    if (-not $script:countdownTimer) {
        $script:countdownTimer = New-Object System.Windows.Forms.Timer
        $script:countdownTimer.Interval = 1000
        $script:countdownTimer.Add_Tick({
            $script:countdownLeft = $script:countdownLeft - 1
            if ($script:countdownLeft -le 0) {
                Stop-Countdown
                Invoke-HideNow $false
            } else {
                $notifyIcon.Text = "Desktop Icon Toggle - hiding in $($script:countdownLeft)s"
            }
        })
    }
    $script:countdownTimer.Start()
    Show-Balloon "Hiding icons in $secs seconds. Press $((Get-ToolConfig).HotkeyToggle) to cancel."
}

function Register-AppHotkeys {
    if (-not $script:hotKeyWindow) { return @() }
    $cfg = Get-ToolConfig
    $norepeat = [uint32]0x4000
    foreach ($id in 1, 2, 3) { $script:hotKeyWindow.Clear($id) }
    $failed = @()
    $pairs = @(
        @{ Id = 1; Text = $cfg.HotkeyToggle },
        @{ Id = 2; Text = $cfg.HotkeyDelayedHide },
        @{ Id = 3; Text = $cfg.HotkeyRestore }
    )
    foreach ($p in $pairs) {
        $parsed = ConvertFrom-HotkeyString $p.Text
        if (-not $parsed) { continue }
        $ok = $script:hotKeyWindow.TryRegister($p.Id, ($parsed.Mod -bor $norepeat), $parsed.Vk)
        if (-not $ok) { $failed += $p.Text }
    }
    $script:hotkeyFailures = $failed
    return $failed
}

function Show-FirstRun {
    $cfg = Get-ToolConfig
    if ($cfg.FirstRunDone) { return }
    [System.Windows.Forms.MessageBox]::Show(
        "Hide desktop icons for screenshots, then bring them back.`n`n" +
        "Hide or restore: $($cfg.HotkeyToggle)`n" +
        "Hide in a few seconds: $($cfg.HotkeyDelayedHide)`n`n" +
        "If icons disappear:`n" +
        "- Press $($cfg.HotkeyToggle)`n" +
        "- Click the tray icon (click ^ next to the clock, then pin it)`n" +
        "- Desktop shortcut: Restore Desktop Icons (if you left it visible)`n`n" +
        "Capture mode hides the Restore Desktop Icons shortcut so it is not in your screenshot. Change that in Settings if you want it left on the desktop.",
        'Desktop Icon Toggle', 'OK', 'Information') | Out-Null
    $cfg.FirstRunDone = $true
    Save-ToolConfig $cfg
}

function New-UiFont([single]$size, [bool]$bold) {
    $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    New-Object System.Drawing.Font('Segoe UI', $size, $style)
}

function Show-ControlWindow {
    if ($script:controlForm -and -not $script:controlForm.IsDisposed) {
        $script:controlForm.Show()
        $script:controlForm.WindowState = 'Normal'
        $script:controlForm.Activate()
        Sync-UiState
        return
    }

    $font = New-UiFont 9.75 $false
    $fontTitle = New-UiFont 14 $true
    $accent = [System.Drawing.Color]::FromArgb(11, 92, 171)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Desktop Icon Toggle'
    $form.Size = New-Object System.Drawing.Size(540, 620)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.ShowInTaskbar = $true
    $form.Font = $font
    $form.BackColor = [System.Drawing.Color]::White
    $form.Icon = $script:iconVisible
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(12, 12)
    $tabs.Size = New-Object System.Drawing.Size(500, 556)
    $form.Controls.Add($tabs)

    $tabHome = New-Object System.Windows.Forms.TabPage
    $tabHome.Text = 'Home'
    $tabHome.BackColor = [System.Drawing.Color]::White
    $tabLook = New-Object System.Windows.Forms.TabPage
    $tabLook.Text = 'Look'
    $tabLook.BackColor = [System.Drawing.Color]::White
    $tabCust = New-Object System.Windows.Forms.TabPage
    $tabCust.Text = 'Customize'
    $tabCust.BackColor = [System.Drawing.Color]::White
    $tabSet = New-Object System.Windows.Forms.TabPage
    $tabSet.Text = 'Settings'
    $tabSet.BackColor = [System.Drawing.Color]::White
    [void]$tabs.TabPages.Add($tabHome)
    [void]$tabs.TabPages.Add($tabLook)
    [void]$tabs.TabPages.Add($tabCust)
    [void]$tabs.TabPages.Add($tabSet)

    $status = New-Object System.Windows.Forms.Panel
    $status.Location = New-Object System.Drawing.Point(16, 16)
    $status.Size = New-Object System.Drawing.Size(456, 88)
    $tabHome.Controls.Add($status)
    $script:statusPanel = $status

    $st = New-Object System.Windows.Forms.Label
    $st.Font = $fontTitle
    $st.AutoSize = $true
    $st.Location = New-Object System.Drawing.Point(16, 14)
    $status.Controls.Add($st)
    $script:statusTitle = $st

    $sh = New-Object System.Windows.Forms.Label
    $sh.Location = New-Object System.Drawing.Point(16, 46)
    $sh.Size = New-Object System.Drawing.Size(420, 34)
    $status.Controls.Add($sh)
    $script:statusHint = $sh

    $hideBtn = New-Object System.Windows.Forms.Button
    $hideBtn.Location = New-Object System.Drawing.Point(16, 116)
    $hideBtn.Size = New-Object System.Drawing.Size(456, 44)
    $hideBtn.FlatStyle = 'Flat'
    $hideBtn.BackColor = $accent
    $hideBtn.ForeColor = [System.Drawing.Color]::White
    $hideBtn.Font = New-UiFont 11 $true
    $hideBtn.Add_Click({
        if ($script:countdownLeft -gt 0) { Stop-Countdown; Sync-UiState; return }
        if (Test-DesktopHidden) { Invoke-RestoreNow } else { Invoke-HideNow $true }
    })
    $tabHome.Controls.Add($hideBtn)
    $script:hideBtn = $hideBtn

    $delayBtn = New-Object System.Windows.Forms.Button
    $delayBtn.Location = New-Object System.Drawing.Point(16, 170)
    $delayBtn.Size = New-Object System.Drawing.Size(456, 34)
    $delayBtn.Add_Click({ Start-DelayedHide })
    $tabHome.Controls.Add($delayBtn)
    $script:delayBtn = $delayBtn

    $resetBtn = New-Object System.Windows.Forms.Button
    $resetBtn.Text = 'Show all icons (reset)'
    $resetBtn.Location = New-Object System.Drawing.Point(16, 214)
    $resetBtn.Size = New-Object System.Drawing.Size(220, 32)
    $resetBtn.Add_Click({
        $failed = Reset-DesktopState
        Stop-Countdown
        Stop-AutoRestore
        Sync-UiState
        Show-Balloon 'All icons visible.'
        Report-Failures $failed
    })
    $tabHome.Controls.Add($resetBtn)

    $note = New-Object System.Windows.Forms.Label
    $note.Location = New-Object System.Drawing.Point(16, 262)
    $note.Size = New-Object System.Drawing.Size(456, 96)
    $note.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $note.Text = "Closing this window keeps the tool in the tray.`nThis is not a screenshot app - use Win+Shift+S after icons are hidden.`nWallpaper and theme for captures: Look tab. Shortcuts: Settings.`nPin the tray icon: click ^ next to the clock, then drag this app onto the taskbar."
    $tabHome.Controls.Add($note)

    $ver = New-Object System.Windows.Forms.Label
    $ver.Location = New-Object System.Drawing.Point(16, 360)
    $ver.AutoSize = $true
    $ver.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $ver.Text = "Version $appVersion"
    $tabHome.Controls.Add($ver)

    $lookIntro = New-Object System.Windows.Forms.Label
    $lookIntro.Location = New-Object System.Drawing.Point(16, 16)
    $lookIntro.Size = New-Object System.Drawing.Size(456, 40)
    $lookIntro.Text = 'When you hide icons, optionally switch to a clean wallpaper and light or dark mode. Restore puts your real look back. Customize does not change this.'
    $tabLook.Controls.Add($lookIntro)

    $cfgLook = Get-ToolConfig
    $applyLook = New-Object System.Windows.Forms.CheckBox
    $applyLook.Text = 'Apply this look when hiding icons'
    $applyLook.Location = New-Object System.Drawing.Point(16, 64)
    $applyLook.Size = New-Object System.Drawing.Size(456, 24)
    $applyLook.Checked = [bool]$cfgLook.ApplyCaptureLook
    $tabLook.Controls.Add($applyLook)

    $wallLbl = New-Object System.Windows.Forms.Label
    $wallLbl.Text = 'Wallpaper'
    $wallLbl.Location = New-Object System.Drawing.Point(16, 100)
    $wallLbl.AutoSize = $true
    $tabLook.Controls.Add($wallLbl)

    $wallCombo = New-Object System.Windows.Forms.ComboBox
    $wallCombo.DropDownStyle = 'DropDownList'
    $wallCombo.Location = New-Object System.Drawing.Point(16, 122)
    $wallCombo.Size = New-Object System.Drawing.Size(456, 24)
    @('Keep current wallpaper', 'Light gray', 'White', 'Black', 'A picture I choose') | ForEach-Object { [void]$wallCombo.Items.Add($_) }
    $wallLabels = @{
        Keep = 'Keep current wallpaper'
        LightGray = 'Light gray'
        White = 'White'
        Black = 'Black'
        Picture = 'A picture I choose'
    }
    $selWall = $wallLabels[[string]$cfgLook.CaptureWallpaper]
    if (-not $selWall) { $selWall = 'Light gray' }
    $wallCombo.SelectedItem = $selWall
    $tabLook.Controls.Add($wallCombo)

    $picPath = New-Object System.Windows.Forms.TextBox
    $picPath.Location = New-Object System.Drawing.Point(16, 158)
    $picPath.Size = New-Object System.Drawing.Size(340, 24)
    $picPath.ReadOnly = $true
    $picPath.Text = [string]$cfgLook.CapturePicturePath
    $tabLook.Controls.Add($picPath)

    $picBrowse = New-Object System.Windows.Forms.Button
    $picBrowse.Text = 'Browse...'
    $picBrowse.Location = New-Object System.Drawing.Point(362, 156)
    $picBrowse.Size = New-Object System.Drawing.Size(110, 28)
    $tabLook.Controls.Add($picBrowse)

    $sizeHint = New-Object System.Windows.Forms.Label
    $sizeHint.Location = New-Object System.Drawing.Point(16, 188)
    $sizeHint.Size = New-Object System.Drawing.Size(456, 52)
    $sizeHint.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $sizeHint.Text = Get-WallpaperSizeHint
    $tabLook.Controls.Add($sizeHint)
    $script:lookSizeHint = $sizeHint

    $themeLbl = New-Object System.Windows.Forms.Label
    $themeLbl.Text = 'Windows light / dark'
    $themeLbl.Location = New-Object System.Drawing.Point(16, 248)
    $themeLbl.AutoSize = $true
    $tabLook.Controls.Add($themeLbl)

    $themeCombo = New-Object System.Windows.Forms.ComboBox
    $themeCombo.DropDownStyle = 'DropDownList'
    $themeCombo.Location = New-Object System.Drawing.Point(16, 270)
    $themeCombo.Size = New-Object System.Drawing.Size(456, 24)
    @('Keep current theme', 'Light', 'Dark') | ForEach-Object { [void]$themeCombo.Items.Add($_) }
    $themeLabels = @{ Keep = 'Keep current theme'; Light = 'Light'; Dark = 'Dark' }
    $selTheme = $themeLabels[[string]$cfgLook.CaptureTheme]
    if (-not $selTheme) { $selTheme = 'Keep current theme' }
    $themeCombo.SelectedItem = $selTheme
    $tabLook.Controls.Add($themeCombo)

    $autoHideTb = New-Object System.Windows.Forms.CheckBox
    $autoHideTb.Text = 'Auto-hide the taskbar while icons are hidden'
    $autoHideTb.Location = New-Object System.Drawing.Point(16, 302)
    $autoHideTb.Size = New-Object System.Drawing.Size(456, 24)
    $autoHideTb.Checked = [bool]$cfgLook.AutoHideTaskbarWhileHidden
    $tabLook.Controls.Add($autoHideTb)

    $lookNote = New-Object System.Windows.Forms.Label
    $lookNote.Location = New-Object System.Drawing.Point(16, 334)
    $lookNote.Size = New-Object System.Drawing.Size(456, 96)
    $lookNote.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $lookNote.Text = "This is not a full Personalization settings page.`nHide (or Win+Shift+D) applies the look. Restore puts yours back, including the Restore Desktop Icons shortcut.`nAuto-hide uses the Windows taskbar setting and is undone on Restore. Use your hide/restore shortcut if the tray is tucked away."
    $tabLook.Controls.Add($lookNote)

    $script:lookApply = $applyLook
    $script:lookWall = $wallCombo
    $script:lookPic = $picPath
    $script:lookBrowse = $picBrowse
    $script:lookTheme = $themeCombo
    $script:SyncLookEnabled = {
        $on = $script:lookApply.Checked
        $script:lookWall.Enabled = $on
        $script:lookTheme.Enabled = $on
        $isPic = ($script:lookWall.SelectedItem -eq 'A picture I choose')
        $script:lookPic.Enabled = ($on -and $isPic)
        $script:lookBrowse.Enabled = ($on -and $isPic)
    }
    & $script:SyncLookEnabled

    $applyLook.Add_CheckedChanged({
        param($sender, $e)
        $cfg = Get-ToolConfig
        $cfg.ApplyCaptureLook = $sender.Checked
        Save-ToolConfig $cfg
        & $script:SyncLookEnabled
    })
    $autoHideTb.Add_CheckedChanged({
        param($sender, $e)
        $cfg = Get-ToolConfig
        $cfg.AutoHideTaskbarWhileHidden = $sender.Checked
        Save-ToolConfig $cfg
    })
    $wallCombo.Add_SelectedIndexChanged({
        param($sender, $e)
        $map = @{
            'Keep current wallpaper' = 'Keep'
            'Light gray' = 'LightGray'
            'White' = 'White'
            'Black' = 'Black'
            'A picture I choose' = 'Picture'
        }
        $cfg = Get-ToolConfig
        $cfg.CaptureWallpaper = $map[[string]$sender.SelectedItem]
        Save-ToolConfig $cfg
        & $script:SyncLookEnabled
    })
    $themeCombo.Add_SelectedIndexChanged({
        param($sender, $e)
        $map = @{ 'Keep current theme' = 'Keep'; 'Light' = 'Light'; 'Dark' = 'Dark' }
        $cfg = Get-ToolConfig
        $cfg.CaptureTheme = $map[[string]$sender.SelectedItem]
        Save-ToolConfig $cfg
    })
    $picBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'Images|*.jpg;*.jpeg;*.png;*.bmp|All files|*.*'
        $ofd.Title = 'Picture for capture wallpaper'
        if ($script:lookPic.Text -and (Test-Path -LiteralPath $script:lookPic.Text)) {
            $ofd.InitialDirectory = [IO.Path]::GetDirectoryName($script:lookPic.Text)
        }
        if ($ofd.ShowDialog() -eq 'OK') {
            $script:lookPic.Text = $ofd.FileName
            $cfg = Get-ToolConfig
            $cfg.CapturePicturePath = $ofd.FileName
            $cfg.CaptureWallpaper = 'Picture'
            Save-ToolConfig $cfg
            $script:lookWall.SelectedItem = 'A picture I choose'
        }
    })

    $custLbl = New-Object System.Windows.Forms.Label
    $custLbl.Text = 'Checked icons stay visible. Everything else is hidden.'
    $custLbl.Location = New-Object System.Drawing.Point(12, 12)
    $custLbl.Size = New-Object System.Drawing.Size(460, 24)
    $tabCust.Controls.Add($custLbl)

    $checklist = New-Object System.Windows.Forms.CheckedListBox
    $checklist.Location = New-Object System.Drawing.Point(12, 40)
    $checklist.Size = New-Object System.Drawing.Size(464, 250)
    $checklist.CheckOnClick = $true
    $tabCust.Controls.Add($checklist)
    $script:checklist = $checklist

    $script:PopulateChecklist = {
        $script:checklist.Items.Clear()
        foreach ($item in (Get-DesktopItems | Sort-Object Name)) {
            if ($item.Name -eq 'desktop.ini') { continue }
            $isHidden = [bool]($item.Attributes -band [IO.FileAttributes]::Hidden)
            [void]$script:checklist.Items.Add($item.Name, -not $isHidden)
        }
    }
    & $script:PopulateChecklist

    $refreshBtn = New-Object System.Windows.Forms.Button
    $refreshBtn.Text = 'Refresh'
    $refreshBtn.Location = New-Object System.Drawing.Point(12, 300)
    $refreshBtn.Size = New-Object System.Drawing.Size(90, 28)
    $refreshBtn.Add_Click({ & $script:PopulateChecklist })
    $tabCust.Controls.Add($refreshBtn)

    $checkAllBtn = New-Object System.Windows.Forms.Button
    $checkAllBtn.Text = 'Check all'
    $checkAllBtn.Location = New-Object System.Drawing.Point(108, 300)
    $checkAllBtn.Size = New-Object System.Drawing.Size(90, 28)
    $checkAllBtn.Add_Click({ for ($i = 0; $i -lt $script:checklist.Items.Count; $i++) { $script:checklist.SetItemChecked($i, $true) } })
    $tabCust.Controls.Add($checkAllBtn)

    $uncheckAllBtn = New-Object System.Windows.Forms.Button
    $uncheckAllBtn.Text = 'Uncheck all'
    $uncheckAllBtn.Location = New-Object System.Drawing.Point(204, 300)
    $uncheckAllBtn.Size = New-Object System.Drawing.Size(100, 28)
    $uncheckAllBtn.Add_Click({ for ($i = 0; $i -lt $script:checklist.Items.Count; $i++) { $script:checklist.SetItemChecked($i, $false) } })
    $tabCust.Controls.Add($uncheckAllBtn)

    $applyBtn = New-Object System.Windows.Forms.Button
    $applyBtn.Text = 'Apply now'
    $applyBtn.Location = New-Object System.Drawing.Point(320, 300)
    $applyBtn.Size = New-Object System.Drawing.Size(156, 28)
    $applyBtn.Add_Click({
        $visible = @()
        for ($i = 0; $i -lt $script:checklist.Items.Count; $i++) {
            if ($script:checklist.GetItemChecked($i)) { $visible += $script:checklist.Items[$i] }
        }
        $failed = Apply-VisibleSet -visibleNames $visible
        & $script:PopulateChecklist
        Sync-UiState
        Show-Balloon 'Desktop updated.'
        Report-Failures $failed
    })
    $tabCust.Controls.Add($applyBtn)

    $profileLbl = New-Object System.Windows.Forms.Label
    $profileLbl.Text = 'Saved layouts'
    $profileLbl.Location = New-Object System.Drawing.Point(12, 342)
    $profileLbl.AutoSize = $true
    $tabCust.Controls.Add($profileLbl)

    $profileCombo = New-Object System.Windows.Forms.ComboBox
    $profileCombo.Location = New-Object System.Drawing.Point(12, 364)
    $profileCombo.Size = New-Object System.Drawing.Size(250, 24)
    $profileCombo.DropDownStyle = 'DropDownList'
    $tabCust.Controls.Add($profileCombo)
    $script:profileCombo = $profileCombo
    $script:PopulateProfiles = {
        $script:profileCombo.Items.Clear()
        foreach ($name in (Get-ProfileNames | Sort-Object)) { [void]$script:profileCombo.Items.Add($name) }
    }
    & $script:PopulateProfiles

    $loadBtn = New-Object System.Windows.Forms.Button
    $loadBtn.Text = 'Load'
    $loadBtn.Location = New-Object System.Drawing.Point(270, 362)
    $loadBtn.Size = New-Object System.Drawing.Size(70, 26)
    $loadBtn.Add_Click({
        if (-not $script:profileCombo.SelectedItem) { return }
        $path = Join-Path $profilesDir "$($script:profileCombo.SelectedItem).json"
        if (Test-Path $path) {
            $visible = (Get-Content $path -Raw | ConvertFrom-Json).VisibleNames
            for ($i = 0; $i -lt $script:checklist.Items.Count; $i++) {
                $script:checklist.SetItemChecked($i, ($script:checklist.Items[$i] -in $visible))
            }
        }
    })
    $tabCust.Controls.Add($loadBtn)

    $saveBtn = New-Object System.Windows.Forms.Button
    $saveBtn.Text = 'Save...'
    $saveBtn.Location = New-Object System.Drawing.Point(346, 362)
    $saveBtn.Size = New-Object System.Drawing.Size(70, 26)
    $saveBtn.Add_Click({
        $name = [Microsoft.VisualBasic.Interaction]::InputBox('Layout name:', 'Save layout', '')
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $safeName = ($name -replace '[\\/:*?"<>|]', '').Trim()
        if ([string]::IsNullOrWhiteSpace($safeName)) { return }
        $visible = @()
        for ($i = 0; $i -lt $script:checklist.Items.Count; $i++) {
            if ($script:checklist.GetItemChecked($i)) { $visible += $script:checklist.Items[$i] }
        }
        [PSCustomObject]@{ Name = $safeName; VisibleNames = $visible } |
            ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $profilesDir "$safeName.json") -Encoding UTF8
        & $script:PopulateProfiles
    })
    $tabCust.Controls.Add($saveBtn)

    $deleteBtn = New-Object System.Windows.Forms.Button
    $deleteBtn.Text = 'Delete'
    $deleteBtn.Location = New-Object System.Drawing.Point(422, 362)
    $deleteBtn.Size = New-Object System.Drawing.Size(54, 26)
    $deleteBtn.Add_Click({
        if (-not $script:profileCombo.SelectedItem) { return }
        $path = Join-Path $profilesDir "$($script:profileCombo.SelectedItem).json"
        if (Test-Path $path) { Remove-Item $path -Force }
        & $script:PopulateProfiles
    })
    $tabCust.Controls.Add($deleteBtn)

    $preserveCheck = New-Object System.Windows.Forms.CheckBox
    $preserveCheck.Text = 'Preserve icon positions on restore (restarts Explorer briefly)'
    $preserveCheck.Location = New-Object System.Drawing.Point(12, 402)
    $preserveCheck.Size = New-Object System.Drawing.Size(464, 24)
    $preserveCheck.Checked = [bool](Get-ToolConfig).PreservePositions
    $preserveCheck.Add_CheckedChanged({
        param($sender, $e)
        $cfg = Get-ToolConfig
        $cfg.PreservePositions = $sender.Checked
        Save-ToolConfig $cfg
    })
    $tabCust.Controls.Add($preserveCheck)

    $y = 16
    function Add-SettingCheck([string]$text, [bool]$checked, [string]$field) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $text
        $cb.Location = New-Object System.Drawing.Point(16, $script:setY)
        $cb.Size = New-Object System.Drawing.Size(460, 28)
        $cb.Checked = $checked
        $cb.Tag = $field
        $cb.Add_CheckedChanged({
            param($sender, $e)
            $cfg = Get-ToolConfig
            $cfg.($sender.Tag) = $sender.Checked
            Save-ToolConfig $cfg
        })
        $tabSet.Controls.Add($cb)
        $script:setY += 32
        return $cb
    }
    $script:setY = 16
    $cfg0 = Get-ToolConfig
    [void](Add-SettingCheck 'Leave Restore Desktop Icons on the desktop during hide' ([bool]$cfg0.KeepRestoreShortcut) 'KeepRestoreShortcut')
    [void](Add-SettingCheck 'Ask before hiding 100 or more icons (window Hide only)' ([bool]$cfg0.ConfirmLargeHide) 'ConfirmLargeHide')
    [void](Add-SettingCheck 'Silence notification toasts while icons are hidden (for recordings)' ([bool]$cfg0.QuietToastsWhileHidden) 'QuietToastsWhileHidden')
    [void](Add-SettingCheck 'Also hide Recycle Bin, This PC, and Network (off by default)' ([bool]$cfg0.HideSystemDesktopIcons) 'HideSystemDesktopIcons')

    $startWin = New-Object System.Windows.Forms.CheckBox
    $startWin.Text = 'Start with Windows (tray only)'
    $startWin.Location = New-Object System.Drawing.Point(16, $script:setY)
    $startWin.Size = New-Object System.Drawing.Size(460, 28)
    $startWin.Checked = Test-StartWithWindows
    $startWin.Add_CheckedChanged({
        param($sender, $e)
        Set-StartWithWindows $sender.Checked
        $cfg = Get-ToolConfig
        $cfg.StartWithWindows = $sender.Checked
        Save-ToolConfig $cfg
    })
    $tabSet.Controls.Add($startWin)
    $script:setY += 32

    $delayLbl = New-Object System.Windows.Forms.Label
    $delayLbl.Text = 'Hide-in-seconds delay (0 = off)'
    $delayLbl.Location = New-Object System.Drawing.Point(16, $script:setY)
    $delayLbl.AutoSize = $true
    $tabSet.Controls.Add($delayLbl)
    $script:setY += 22
    $delayNum = New-Object System.Windows.Forms.NumericUpDown
    $delayNum.Location = New-Object System.Drawing.Point(16, $script:setY)
    $delayNum.Minimum = 0
    $delayNum.Maximum = 15
    $delayNum.Value = [Math]::Min(15, [Math]::Max(0, [int]$cfg0.HideCountdownSeconds))
    $delayNum.Add_ValueChanged({
        param($sender, $e)
        $cfg = Get-ToolConfig
        $cfg.HideCountdownSeconds = [int]$sender.Value
        Save-ToolConfig $cfg
        Sync-UiState
    })
    $tabSet.Controls.Add($delayNum)
    $script:setY += 36

    $arLbl = New-Object System.Windows.Forms.Label
    $arLbl.Text = 'Auto-restore after minutes (0 = off)'
    $arLbl.Location = New-Object System.Drawing.Point(16, $script:setY)
    $arLbl.AutoSize = $true
    $tabSet.Controls.Add($arLbl)
    $script:setY += 22
    $arNum = New-Object System.Windows.Forms.NumericUpDown
    $arNum.Location = New-Object System.Drawing.Point(16, $script:setY)
    $arNum.Minimum = 0
    $arNum.Maximum = 120
    $arNum.Value = [Math]::Min(120, [Math]::Max(0, [int]$cfg0.AutoRestoreMinutes))
    $arNum.Add_ValueChanged({
        param($sender, $e)
        $cfg = Get-ToolConfig
        $cfg.AutoRestoreMinutes = [int]$sender.Value
        Save-ToolConfig $cfg
        if (Test-DesktopHidden) { Start-AutoRestoreIfNeeded }
    })
    $tabSet.Controls.Add($arNum)
    $script:setY += 40

    $hkLbl = New-Object System.Windows.Forms.Label
    $hkLbl.Font = New-UiFont 9.75 $true
    $hkLbl.Text = 'Keyboard shortcuts (Win+Shift+S is reserved for Snipping Tool)'
    $hkLbl.Location = New-Object System.Drawing.Point(16, $script:setY)
    $hkLbl.AutoSize = $true
    $tabSet.Controls.Add($hkLbl)
    $script:setY += 28

    function Add-HotkeyRow([string]$label, [string]$current, [string]$field) {
        $rowY = $script:setY
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $label
        $l.Location = New-Object System.Drawing.Point(16, ($rowY + 4))
        $l.Size = New-Object System.Drawing.Size(130, 22)
        $tabSet.Controls.Add($l)

        $parsed = ConvertFrom-HotkeyString $current
        $win = $false; $ctrl = $false; $alt = $false; $shift = $false; $key = 'D'
        if ($parsed) {
            $win = [bool]($parsed.Mod -band 8)
            $ctrl = [bool]($parsed.Mod -band 2)
            $alt = [bool]($parsed.Mod -band 1)
            $shift = [bool]($parsed.Mod -band 4)
            $key = [char]$parsed.Vk
        }
        $none = [string]::IsNullOrWhiteSpace($current)

        $cbNone = New-Object System.Windows.Forms.CheckBox
        $cbNone.Text = 'Off'
        $cbNone.Location = New-Object System.Drawing.Point(150, $rowY)
        $cbNone.Size = New-Object System.Drawing.Size(46, 24)
        $cbNone.Checked = $none
        $tabSet.Controls.Add($cbNone)

        $cbW = New-Object System.Windows.Forms.CheckBox
        $cbW.Text = 'Win'
        $cbW.Location = New-Object System.Drawing.Point(196, $rowY)
        $cbW.Size = New-Object System.Drawing.Size(50, 24)
        $cbW.Checked = $win
        $tabSet.Controls.Add($cbW)
        $cbC = New-Object System.Windows.Forms.CheckBox
        $cbC.Text = 'Ctrl'
        $cbC.Location = New-Object System.Drawing.Point(246, $rowY)
        $cbC.Size = New-Object System.Drawing.Size(50, 24)
        $cbC.Checked = $ctrl
        $tabSet.Controls.Add($cbC)
        $cbA = New-Object System.Windows.Forms.CheckBox
        $cbA.Text = 'Alt'
        $cbA.Location = New-Object System.Drawing.Point(296, $rowY)
        $cbA.Size = New-Object System.Drawing.Size(46, 24)
        $cbA.Checked = $alt
        $tabSet.Controls.Add($cbA)
        $cbS = New-Object System.Windows.Forms.CheckBox
        $cbS.Text = 'Shift'
        $cbS.Location = New-Object System.Drawing.Point(342, $rowY)
        $cbS.Size = New-Object System.Drawing.Size(54, 24)
        $cbS.Checked = $shift
        $tabSet.Controls.Add($cbS)

        $combo = New-Object System.Windows.Forms.ComboBox
        $combo.DropDownStyle = 'DropDownList'
        $combo.Location = New-Object System.Drawing.Point(400, $rowY)
        $combo.Size = New-Object System.Drawing.Size(56, 24)
        65..90 | ForEach-Object { [void]$combo.Items.Add([string][char]$_) }
        $combo.SelectedItem = "$key"
        $tabSet.Controls.Add($combo)

        $bundle = @{
            None = $cbNone; Win = $cbW; Ctrl = $cbC; Alt = $cbA; Shift = $cbS; Key = $combo
            Field = $field
        }
        foreach ($ctl in @($cbNone, $cbW, $cbC, $cbA, $cbS, $combo)) { $ctl.Tag = $bundle }
        $apply = {
            param($sender, $e)
            $b = $sender.Tag
            if ($b.None.Checked) { $val = '' }
            else {
                $val = ConvertTo-HotkeyString $b.Win.Checked $b.Ctrl.Checked $b.Alt.Checked $b.Shift.Checked ([string]$b.Key.SelectedItem)
                if (-not (ConvertFrom-HotkeyString $val)) {
                    [System.Windows.Forms.MessageBox]::Show('Choose at least one modifier, and do not use Win+Shift+S (Snipping Tool).', 'Shortcut', 'OK', 'Warning') | Out-Null
                    return
                }
            }
            $cfg = Get-ToolConfig
            $cfg.($b.Field) = $val
            Save-ToolConfig $cfg
            Register-AppHotkeys
            if ($script:hotkeyFailures -and $script:hotkeyFailures.Count -gt 0) {
                [System.Windows.Forms.MessageBox]::Show(
                    'That shortcut is already used by another app. Pick a different key.`n`n' + ($script:hotkeyFailures -join ', '),
                    'Shortcut in use', 'OK', 'Warning') | Out-Null
            }
            Sync-UiState
        }
        $cbNone.Add_CheckedChanged($apply)
        $cbW.Add_CheckedChanged($apply)
        $cbC.Add_CheckedChanged($apply)
        $cbA.Add_CheckedChanged($apply)
        $cbS.Add_CheckedChanged($apply)
        $combo.Add_SelectedIndexChanged($apply)
        $script:setY += 32
    }

    Add-HotkeyRow 'Hide / restore' $cfg0.HotkeyToggle 'HotkeyToggle'
    Add-HotkeyRow 'Hide after delay' $cfg0.HotkeyDelayedHide 'HotkeyDelayedHide'
    Add-HotkeyRow 'Restore only' $cfg0.HotkeyRestore 'HotkeyRestore'

    $about = New-Object System.Windows.Forms.Label
    $about.Location = New-Object System.Drawing.Point(16, 430)
    $about.Size = New-Object System.Drawing.Size(460, 36)
    $about.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $about.Text = "Desktop Icon Toggle $appVersion   |   Uninstall from Settings > Apps   |   Files are never deleted"
    $tabSet.Controls.Add($about)

    $hkStatus = New-Object System.Windows.Forms.Label
    $hkStatus.Location = New-Object System.Drawing.Point(16, 468)
    $hkStatus.Size = New-Object System.Drawing.Size(460, 36)
    $tabSet.Controls.Add($hkStatus)
    $script:hotkeyStatus = $hkStatus

    $tabs.Add_SelectedIndexChanged({
        param($sender, $e)
        if ($sender.SelectedTab.Text -eq 'Customize') { & $script:PopulateChecklist }
        if ($sender.SelectedTab.Text -eq 'Look' -and $script:lookSizeHint -and -not $script:lookSizeHint.IsDisposed) {
            $script:lookSizeHint.Text = Get-WallpaperSizeHint
        }
    })

    $form.Add_FormClosing({
        param($sender, $e)
        if ($e.CloseReason -eq 'UserClosing') {
            $e.Cancel = $true
            $sender.Hide()
        }
    })

    $form.Show()
    $script:controlForm = $form
    Sync-UiState
}

$script:iconVisible = Get-IconFromFile 'App.ico'
if (-not $script:iconVisible) { $script:iconVisible = [System.Drawing.SystemIcons]::Application }
$script:iconHidden = Get-IconFromFile 'App-Hidden.ico'
if (-not $script:iconHidden) { $script:iconHidden = $script:iconVisible }

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $script:iconVisible
$notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openWindowItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open window...'
$openWindowItem.Add_Click({ Show-ControlWindow })
[void]$menu.Items.Add($openWindowItem)

$toggleItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Hide desktop icons'
$toggleItem.Add_Click({ Invoke-ToggleAction })
[void]$menu.Items.Add($toggleItem)

$delayItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Hide after delay'
$delayItem.Add_Click({ Start-DelayedHide })
[void]$menu.Items.Add($delayItem)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$resetItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Show all icons (reset)'
$resetItem.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        'Show every desktop icon and clear the saved original-desktop snapshot? Settings and layouts are kept.',
        'Reset desktop', 'YesNo', 'Warning')
    if ($confirm -eq 'Yes') {
        $failed = Reset-DesktopState
        Stop-Countdown
        Stop-AutoRestore
        Sync-UiState
        Show-Balloon 'All icons visible.'
        Report-Failures $failed
    }
})
[void]$menu.Items.Add($resetItem)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
$exitItem.Add_Click({
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if ($script:hotKeyWindow) { $script:hotKeyWindow.Dispose() }
    [System.Windows.Forms.Application]::Exit()
})
[void]$menu.Items.Add($exitItem)

$menu.add_Opening({
    $toggleItem.Text = if (Test-DesktopHidden) { 'Restore desktop icons' } else { 'Hide desktop icons' }
})
$notifyIcon.ContextMenuStrip = $menu
$notifyIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Show-ControlWindow
    }
})
$notifyIcon.Add_MouseDoubleClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Show-ControlWindow
    }
})

$script:hotKeyWindow = New-Object DesktopIconToggle.HotKeyWindow
$script:hotKeyWindow.add_HotKeyPressed({
    param($sender, $e)
    switch ($e.Id) {
        1 { Invoke-ToggleAction }
        2 { Start-DelayedHide }
        3 { Invoke-RestoreNow }
    }
})
Register-AppHotkeys
if ($script:hotkeyFailures -and $script:hotkeyFailures.Count -gt 0) {
    Show-Balloon ('Shortcut in use, pick another in Settings: ' + ($script:hotkeyFailures -join ', '))
}
Sync-UiState

if (Test-DesktopHidden) { Start-AutoRestoreIfNeeded }

if ($ShowUi) {
    Show-ControlWindow
    Show-FirstRun
} elseif (Test-DesktopHidden) {
    Show-Balloon "Desktop is still hidden. Press $((Get-ToolConfig).HotkeyToggle) to restore."
} elseif (-not (Get-ToolConfig).FirstRunDone) {
    Show-ControlWindow
    Show-FirstRun
}

[System.Windows.Forms.Application]::Run()
