# Desktop Icon Toggle

Windows tray app that hides desktop file icons for screenshots or recordings, then restores them exactly as they were.

This is **not** a screenshot tool. Hide the icons, then use **Win+Shift+S** (Snipping Tool) or any recorder you already use.

**Version 1.5.0** · Windows 10/11 · per-user, no admin for a normal desktop

[User manual](USER-MANUAL.md) · [Install](#install) · [Uninstall](#uninstall)

## What it does

- Hides desktop **files and shortcuts**. It does not delete anything.
- Recycle Bin is not a file. Leave it, or hide Recycle Bin / This PC / Network in Settings.
- Optional **Look**: solid wallpaper (light gray, white, black) or a picture, plus light/dark mode, applied on Hide and undone on Restore.
- Optional Look checkbox **Auto-hide the taskbar while icons are hidden** (off by default). It applies on Hide only; Restore puts the previous taskbar auto-hide setting back.
- **Customize**: keep selected files on the wallpaper while the rest of the desktop is hidden.
- Hotkeys (defaults): **Win+Shift+D** hide/restore, **Win+Shift+H** delayed hide. **Win+Shift+S** stays with Snipping Tool.
- Emergency shortcut on the desktop: **Restore Desktop Icons**. Capture mode hides that shortcut so it is not in the shot (change in Settings).
- Works with a OneDrive Desktop. Shared **Public Desktop** items may prompt once for elevation.

## Install

Download the zip from the **[latest GitHub Release](https://github.com/nchrumka/desktop-icon-toggle/releases/latest)**. Releases are script-only (no `.exe`).

1. Download **DesktopIconToggle-1.5.0.zip** from that page.
2. Unzip the folder so `Install.bat` is next to the other files, not inside the zip.
3. Double-click **Install.bat** (Start menu, tray at logon, uninstall entry).
4. If Windows shows **Windows protected your PC**, click **More info**, then **Run anyway**.
5. A Desktop Icon Toggle window opens.

Start menu, Startup, and Restore Desktop Icons launch PowerShell scripts, not a custom exe.

On a managed PC, ask IT to allow `%LOCALAPPDATA%\DesktopIconToggle\` if CrowdStrike or another EDR blocks the scripts.

Install adds:

- Start menu: **Desktop Icon Toggle**
- Desktop: **Restore Desktop Icons**
- Settings > Apps uninstall entry
- Tray icon (click **^** next to the clock, then pin it)
- Start with Windows (turn off in Settings)

Installed files live in `%LOCALAPPDATA%\DesktopIconToggle`.

The SHA-256 of each zip is in that release’s notes so you can check the download.

## Uninstall

Settings > Apps > **Desktop Icon Toggle**, or **Uninstall.bat**. Hidden icons and capture look are restored first.

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (included with Windows)

## Repository layout

| File | Purpose |
|------|---------|
| `Install.bat` / `Install.ps1` | Per-user install, Start menu, tray launcher |
| `Uninstall.bat` / `Uninstall.ps1` | Restore desktop, then remove the app |
| `DesktopIconTray.ps1` | Window, tray, hotkeys, Look and Customize |
| `DesktopIconManager.ps1` | CLI hide/restore/reset and elevated Public Desktop helper |
| `Publish-Release.ps1` | Builds the script-only zip and prints SHA-256 |
| `Launcher.cs` / `Build-Launcher.ps1` | Optional local launcher source (not shipped in the zip) |
| `USER-MANUAL.md` | Full how-to |

## License

Use and share for your own documentation and recordings. No warranty.
