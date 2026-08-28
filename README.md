# Desktop Icon Toggle

Windows tray app that hides desktop file icons for screenshots or recordings, then restores them exactly as they were.

This is **not** a screenshot tool. Hide the icons, then use **Win+Shift+S** (Snipping Tool) or any recorder you already use.

**Version 1.4.1** · Windows 10/11 · per-user, no admin for a normal desktop

[User manual](USER-MANUAL.md) · [Install](#install) · [Uninstall](#uninstall)

## What it does

- Hides desktop **files and shortcuts** (Hidden attribute). It does not delete anything.
- Recycle Bin is not a file. Leave it, or hide Recycle Bin / This PC / Network in Settings.
- Optional **Look**: solid wallpaper (light gray, white, black) or a picture, plus light/dark mode, applied on Hide and undone on Restore.
- Hotkeys (defaults): **Win+Shift+D** hide/restore, **Win+Shift+H** delayed hide. **Win+Shift+S** stays with Snipping Tool.
- Emergency shortcut on the desktop: **Restore Desktop Icons**. Capture mode hides that shortcut so it is not in the shot (change in Settings).
- Works with a OneDrive Desktop. Shared **Public Desktop** items may prompt once for elevation.

## Install

1. Clone or unzip this folder.
2. Double-click **Install.bat**.
3. If Windows shows **Windows protected your PC**, click **More info**, then **Run anyway**.
4. A Desktop Icon Toggle window opens.

Install adds:

- Start menu: **Desktop Icon Toggle**
- Desktop: **Restore Desktop Icons**
- Settings > Apps uninstall entry
- Tray icon (click **^** next to the clock, then pin it)
- Start with Windows (turn off in Settings)

Installed files live in `%LOCALAPPDATA%\DesktopIconToggle`.

## Uninstall

Settings > Apps > **Desktop Icon Toggle**, or **Uninstall.bat**. Hidden icons and capture look are restored first.

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (included with Windows)
- .NET Framework 4.x (used only to build the small launcher at install time)

## Repository layout

| File | Purpose |
|------|---------|
| `Install.bat` / `Install.ps1` | Per-user install, Start menu, tray launcher |
| `Uninstall.bat` / `Uninstall.ps1` | Restore desktop, then remove the app |
| `DesktopIconTray.ps1` | Window, tray, hotkeys, Look tab |
| `DesktopIconManager.ps1` | CLI hide/restore/reset and elevated Public Desktop helper |
| `Launcher.cs` | `DesktopIconToggle.exe` (built at install) |
| `USER-MANUAL.md` | Full how-to |

## License

Use and share for your own documentation and recordings. No warranty.
