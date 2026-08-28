<#
.SYNOPSIS
    Hide all desktop icons (except Recycle Bin) for clean documentation screenshots,
    then restore your original desktop exactly as it was.

.USAGE
    .\DesktopIconManager.ps1            (no args = toggle: hides if currently shown,
                                          restores if currently hidden)
    .\DesktopIconManager.ps1 -Hide
    .\DesktopIconManager.ps1 -Restore
    .\DesktopIconManager.ps1 -Reset          (force-show everything, wipe saved state)
    .\DesktopIconManager.ps1 -ClearProfiles  (permanently delete all saved profiles)

.NOTES
    - Covers both your personal Desktop and the "Public" (all users) Desktop.
    - Refresh is done via SHChangeNotify (a native Windows API call) so Explorer
      updates instantly - no restart, no flicker, no closed windows.
    - This is the command-line/scripting version. Most people should use
      DesktopIconTray.ps1 instead (a notification-area icon with a menu).
    - Special non-file desktop icons (This PC, Network, Control Panel) are
      controlled by a different registry setting and are NOT affected here.
    - State (snapshot.json) is stored in the same folder as this script, so
      the whole tool is self-contained in one directory.
#>

param(
    [switch]$Hide,
    [switch]$Restore,
    [switch]$Reset,
    [switch]$ClearProfiles,
    [switch]$SetHidden,
    [switch]$SetVisible,
    [string]$ListFile,
    [switch]$RegisterHelper,
    [switch]$ElevatedJob,
    [switch]$Silent
)

if ($SetHidden -or $SetVisible -or $Reset -or $RegisterHelper -or $ElevatedJob) {
    Add-Type -Name ConsoleWin -Namespace DesktopIconToggle -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@
    $consoleWnd = [DesktopIconToggle.ConsoleWin]::GetConsoleWindow()
    if ($consoleWnd -ne [IntPtr]::Zero) {
        [void][DesktopIconToggle.ConsoleWin]::ShowWindow($consoleWnd, 0)
    }
}

$snapshotPath     = Join-Path $PSScriptRoot 'snapshot.json'
$configPath       = Join-Path $PSScriptRoot 'config.json'
$layoutBackupPath = Join-Path $PSScriptRoot 'iconlayout.reg'
$lookBackupPath   = Join-Path $PSScriptRoot 'capture-wallpaper.bak'
$lookSolidPath    = Join-Path $PSScriptRoot 'capture-solid.bmp'
$profilesDir      = Join-Path $PSScriptRoot 'Profiles'
$bagKey           = 'HKCU\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
$AlwaysVisible    = @('Restore Desktop Icons.lnk')
$helperTaskName   = 'DesktopIconToggleHelper'
$elevateReqPath   = Join-Path $PSScriptRoot 'elevate-request.json'
$elevateResPath   = Join-Path $PSScriptRoot 'elevate-result.json'

function Get-ToolConfig {
    $defaults = [PSCustomObject]@{
        PreservePositions   = $false
        KeepRestoreShortcut = $false
    }
    if (Test-Path $configPath) {
        try {
            $c = Get-Content $configPath -Raw | ConvertFrom-Json
            foreach ($p in $defaults.PSObject.Properties.Name) {
                if ($null -ne $c.$p) { $defaults.$p = $c.$p }
            }
        } catch {}
    }
    return $defaults
}

function Get-ProtectedNames {
    $names = @('desktop.ini')
    if ((Get-ToolConfig).KeepRestoreShortcut) { $names += 'Restore Desktop Icons.lnk' }
    return $names
}

Add-Type -Namespace Win32 -Name DesktopIcons -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr FindWindowEx(System.IntPtr hwndParent, System.IntPtr hwndChildAfter, string lpszClass, string lpszWindow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
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


function Refresh-Desktop {
    [Win32.NativeMethods]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Get-ExplorerHideIcons {
    try {
        return [int](Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideIcons -ErrorAction Stop).HideIcons
    } catch {
        return 0
    }
}

function Invoke-DesktopIconViewToggle {
    $zero = [IntPtr]::Zero
    $cmd = [uint32]0x0111
    $id = [IntPtr]0x7402
    try {
        $progman = [Win32.DesktopIcons]::FindWindow('Progman', $null)
        if ($progman -ne $zero) {
            $def = [Win32.DesktopIcons]::FindWindowEx($progman, $zero, 'SHELLDLL_DefView', $null)
            if ($def -ne $zero) { [void][Win32.DesktopIcons]::SendMessage($def, $cmd, $id, $zero) }
        }
        $worker = $zero
        for ($i = 0; $i -lt 24; $i++) {
            $worker = [Win32.DesktopIcons]::FindWindowEx($zero, $worker, 'WorkerW', $null)
            if ($worker -eq $zero) { break }
            $def = [Win32.DesktopIcons]::FindWindowEx($worker, $zero, 'SHELLDLL_DefView', $null)
            if ($def -ne $zero) { [void][Win32.DesktopIcons]::SendMessage($def, $cmd, $id, $zero) }
        }
    } catch {}
}

function Set-ExplorerHideIcons([int]$hide) {
    $want = if ($hide) { 1 } else { 0 }
    $now = Get-ExplorerHideIcons
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    try {
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name HideIcons -PropertyType DWord -Value $want -Force | Out-Null
    } catch {}
    if ($now -ne $want) { Invoke-DesktopIconViewToggle }
    Refresh-Desktop
}

function Restore-ExplorerHideIcons($snap) {
    if ($snap -and $null -ne $snap.ExplorerHideIcons) { Set-ExplorerHideIcons ([int]$snap.ExplorerHideIcons) }
    else { Set-ExplorerHideIcons 0 }
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
    if ($file) {
        [void][Win32.DesktopLook]::SystemParametersInfo(20, 0, $file, 3)
    } elseif (-not $saved.Wallpaper) {
        [void][Win32.DesktopLook]::SystemParametersInfo(20, 0, '', 3)
    }
    if ($saved.BackgroundColor) {
        Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Background -Value $saved.BackgroundColor
    }
    if ($null -ne $saved.AppsUseLightTheme) {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name AppsUseLightTheme -PropertyType DWord -Value ([int]$saved.AppsUseLightTheme) -Force | Out-Null
        New-ItemProperty -Path $key -Name SystemUsesLightTheme -PropertyType DWord -Value ([int]$saved.SystemUsesLightTheme) -Force | Out-Null
        $result = [IntPtr]::Zero
        [void][Win32.DesktopLook]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'ImmersiveColorSet', 2, 2000, [ref]$result)
    }
    Remove-Item $lookBackupPath -Force -ErrorAction SilentlyContinue
    Remove-Item $lookSolidPath -Force -ErrorAction SilentlyContinue
}

function Backup-IconLayout {
    # Snapshots Windows' internal icon-position data for the desktop, once,
    # so it can be restored exactly later. Silently does nothing if the key
    # doesn't exist yet or export fails - position preservation is best-effort.
    if (Test-Path $layoutBackupPath) { return }
    & reg.exe export $bagKey $layoutBackupPath /y *> $null
}

function Restore-IconLayout {
    # Restoring icon positions requires Explorer to reload its cached layout,
    # which means a brief restart (closes open Explorer windows for ~1 sec).
    if (-not (Test-Path $layoutBackupPath)) { return }
    & reg.exe import $layoutBackupPath *> $null
    Remove-Item $layoutBackupPath -Force -ErrorAction SilentlyContinue
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Process explorer.exe
}

function Set-ItemHiddenTry($item, [bool]$hidden) {
    try {
        $isHidden = [bool]($item.Attributes -band [IO.FileAttributes]::Hidden)
        if ($hidden -and -not $isHidden) { $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden }
        elseif (-not $hidden -and $isHidden) { $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::Hidden) }
        return $true
    } catch {
        return $false
    }
}

function Invoke-ElevatedHiddenChange([string[]]$paths, [bool]$hidden) {
    $paths = @(
        @($paths) | Where-Object {
            $_ -and $_.Length -gt 1 -and (Test-Path -LiteralPath $_)
        }
    )
    if ($paths.Count -eq 0) { return $true }

    $listFile = Join-Path $env:TEMP ("DesktopIconToggle-{0}.txt" -f [guid]::NewGuid())
    $paths | Set-Content -Path $listFile -Encoding UTF8
    $flag = if ($hidden) { '-SetHidden' } else { '-SetVisible' }
    try {
        $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $flag -ListFile `"$listFile`""
        $proc = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList $arg
        return ($null -ne $proc -and $proc.ExitCode -eq 0)
    } catch {
        return $false
    } finally {
        Remove-Item $listFile -Force -ErrorAction SilentlyContinue
    }
}

function Apply-HiddenToItems($items, [bool]$hidden) {
    $retry = @()
    foreach ($item in $items) {
        if ($item.Name -in (Get-ProtectedNames)) { continue }
        if (-not (Set-ItemHiddenTry $item $hidden)) { $retry += $item.FullName }
    }
    if ($retry.Count -gt 0) {
        [void](Invoke-ElevatedHiddenChange $retry $hidden)
    }
}

function Invoke-ListFileHidden {
    if (-not $ListFile -or -not (Test-Path $ListFile)) { exit 1 }
    $ok = $true
    foreach ($raw in Get-Content -Path $ListFile -Encoding UTF8) {
        $path = $raw.Trim()
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        $name = Split-Path $path -Leaf
        if ($name -eq 'desktop.ini') { continue }
        $flag = if ($SetHidden) { '+H' } else { '-H' }
        & attrib.exe $flag $path | Out-Null
        try {
            $item = Get-Item -LiteralPath $path -Force
            $isHidden = [bool]($item.Attributes -band [IO.FileAttributes]::Hidden)
            if ($SetHidden -and -not $isHidden) { $ok = $false }
            if ($SetVisible -and $isHidden) { $ok = $false }
        } catch {
            $ok = $false
        }
    }
    if ($ok) { exit 0 } else { exit 1 }
}

function Get-DesktopPaths {
    @(
        [Environment]::GetFolderPath('Desktop'),
        "$env:PUBLIC\Desktop"
    ) | Where-Object { Test-Path $_ }
}

function Hide-Icons {
    if (Test-Path $snapshotPath) {
        Write-Warning "Icons already appear to be hidden. Run -Restore first, or delete snapshot.json if this seems wrong."
        return
    }

    $cfg = Get-ToolConfig
    if ($cfg.PreservePositions) { Backup-IconLayout }

    $items = foreach ($folder in Get-DesktopPaths) {
        Get-ChildItem -Path $folder -Force | Where-Object { $_.Name -notin (Get-ProtectedNames) }
    }

    $snapshot = @()
    foreach ($item in $items) {
        $wasHidden = [bool]($item.Attributes -band [IO.FileAttributes]::Hidden)
        $snapshot += [PSCustomObject]@{ Path = $item.FullName; WasHidden = $wasHidden }
    }
    $snapshot | ConvertTo-Json -Depth 3 | Set-Content -Path $snapshotPath -Encoding UTF8
    Apply-HiddenToItems $items $true
    try { Set-ExplorerHideIcons 1 } catch {}
    Refresh-Desktop
    Write-Host "Hid $($snapshot.Count) icon(s). Recycle Bin and Restore Desktop Icons stay visible." -ForegroundColor Green
}

function Get-SnapshotObject {
    if (-not (Test-Path $snapshotPath)) { return $null }
    Get-Content $snapshotPath -Raw | ConvertFrom-Json
}

function Get-SnapshotEntries {
    $raw = Get-SnapshotObject
    if ($raw.PSObject.Properties.Name -contains 'Items') { return @($raw.Items) }
    return @($raw)
}

function Restore-Icons {
    if (-not (Test-Path $snapshotPath)) {
        Write-Warning "Nothing to restore - icons aren't currently hidden."
        return
    }
    $snap       = Get-SnapshotObject
    $entries    = Get-SnapshotEntries
    $knownPaths = @($entries.Path)

    $toShow = @()
    foreach ($entry in $entries) {
        if ($entry.WasHidden) { continue }
        if (Test-Path $entry.Path) {
            $toShow += Get-Item $entry.Path -Force
        }
    }
    Apply-HiddenToItems $toShow $false

    $currentItems = foreach ($folder in Get-DesktopPaths) {
        Get-ChildItem -Path $folder -Force | Where-Object { $_.Name -notin (Get-ProtectedNames) }
    }
    $newItems = $currentItems | Where-Object { $_.FullName -notin $knownPaths }

    if ($newItems -and -not $Silent) {
        Write-Host "`nYou added $($newItems.Count) new icon(s) while things were hidden:" -ForegroundColor Yellow
        $newItems | ForEach-Object { Write-Host "  - $($_.Name)" }
        $choice = Read-Host "`nType 'keep' to leave them visible, 'hide' to hide them, or 'delete' to remove them"
        switch ($choice.ToLower()) {
            'hide'   { Apply-HiddenToItems @($newItems) $true }
            'delete' { $newItems | ForEach-Object { Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue } }
            default  { } # keep as-is
        }
    }

    Restore-CaptureLook $snap.CaptureLook
    Restore-TaskbarAppBarState $snap.TaskbarAppBarState
    Restore-ExplorerHideIcons $snap
    Remove-Item $snapshotPath -Force

    $cfg = Get-ToolConfig
    if ($cfg.PreservePositions) { Restore-IconLayout } else { Refresh-Desktop }

    Write-Host "Desktop restored to normal." -ForegroundColor Green
}

function Reset-DesktopState {
    # Force-shows every desktop item regardless of saved state, then wipes
    # snapshot/layout-backup files. Saved profiles and settings are left untouched.
    $snap = Get-SnapshotObject
    $items = foreach ($folder in Get-DesktopPaths) {
        Get-ChildItem -Path $folder -Force | Where-Object { $_.Name -ne 'desktop.ini' }
    }
    Apply-HiddenToItems $items $false
    if ($snap) { Restore-CaptureLook $snap.CaptureLook }
    if ($snap) { Restore-TaskbarAppBarState $snap.TaskbarAppBarState }
    Restore-ExplorerHideIcons $snap
    Remove-Item $snapshotPath -Force -ErrorAction SilentlyContinue
    Remove-Item $layoutBackupPath -Force -ErrorAction SilentlyContinue
    Refresh-Desktop
    Write-Host "All desktop icons are now visible, and saved state has been cleared." -ForegroundColor Green
}

function Register-HelperTask {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $file = $PSCommandPath
    function Escape-Xml([string]$text) {
        if (-not $text) { return '' }
        $text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    }
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Applies Hidden attributes for Desktop Icon Toggle (shared Public Desktop items).</Description>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$(Escape-Xml "$env:USERDOMAIN\$env:USERNAME")</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(Escape-Xml $ps)</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$(Escape-Xml $file)" -ElevatedJob</Arguments>
      <WorkingDirectory>$(Escape-Xml $PSScriptRoot)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
    $xmlPath = Join-Path $env:TEMP 'DesktopIconToggle-helper.xml'
    $xml | Out-File -FilePath $xmlPath -Encoding Unicode
    & schtasks.exe /Create /TN $helperTaskName /XML $xmlPath /F | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
    return $ok
}

function Invoke-ElevatedJob {
    if (-not (Test-Path $elevateReqPath)) { exit 1 }
    $data = Get-Content $elevateReqPath -Raw | ConvertFrom-Json
    $hidden = [bool]$data.Hidden
    $ok = $true
    foreach ($path in @($data.Paths)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        if ((Split-Path $path -Leaf) -eq 'desktop.ini') { continue }
        $flag = if ($hidden) { '+H' } else { '-H' }
        & attrib.exe $flag $path | Out-Null
        try {
            $item = Get-Item -LiteralPath $path -Force
            $isHidden = [bool]($item.Attributes -band [IO.FileAttributes]::Hidden)
            if ($hidden -ne $isHidden) { $ok = $false }
        } catch {
            $ok = $false
        }
    }
    [PSCustomObject]@{ Ok = $ok } | ConvertTo-Json | Set-Content -Path $elevateResPath -Encoding UTF8
    if ($ok) { exit 0 } else { exit 1 }
}

function Clear-AllProfiles {
    Get-ChildItem -Path $profilesDir -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force
    Write-Host "All saved profiles have been deleted." -ForegroundColor Green
}

if ($ElevatedJob) {
    Invoke-ElevatedJob
}
elseif ($RegisterHelper) {
    $registered = Register-HelperTask
    if ($SetHidden -or $SetVisible) {
        Invoke-ListFileHidden
    }
    elseif ($registered) { exit 0 } else { exit 1 }
}
elseif ($SetHidden -or $SetVisible) {
    Invoke-ListFileHidden
}
elseif ($Reset) {
    Reset-DesktopState
}
elseif ($ClearProfiles) {
    Clear-AllProfiles
}
elseif ($Hide)        { Hide-Icons }
elseif ($Restore) { Restore-Icons }
else {
    if (Test-Path $snapshotPath) { Restore-Icons } else { Hide-Icons }
}
