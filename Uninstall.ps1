param(
    [switch]$Silent
)

trap {
    $msg = "$($_.Exception.Message)  (line $($_.InvocationInfo.ScriptLineNumber))"
    try {
        "$(Get-Date -Format 'u')  $msg" |
            Out-File -FilePath (Join-Path $env:TEMP 'DesktopIconToggle-uninstall.log') -Append -Encoding UTF8
    } catch {}
    if (-not $Silent) {
        Write-Host ""
        Write-Host "UNINSTALL FAILED:" -ForegroundColor Red
        Write-Host $msg -ForegroundColor Red
        Write-Host ""
        Read-Host "Press Enter to close this window"
    }
    exit 1
}

$ErrorActionPreference = 'Stop'

$installDir   = Join-Path $env:LOCALAPPDATA 'DesktopIconToggle'
$cliPath      = Join-Path $installDir 'DesktopIconManager.ps1'
$snapshotPath = Join-Path $installDir 'snapshot.json'
$startupLink  = Join-Path ([Environment]::GetFolderPath('Startup')) 'Desktop Icon Toggle.lnk'
$psExe        = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Write-Host "Uninstalling Desktop Icon Toggle..." -ForegroundColor Cyan

function Show-DesktopIconList {
    try {
        Add-Type -Namespace Win32Uninstall -Name Desk -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr FindWindowEx(System.IntPtr hwndParent, System.IntPtr hwndChildAfter, string lpszClass, string lpszWindow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@
        $zero = [IntPtr]::Zero
        $pm = [Win32Uninstall.Desk]::FindWindow('Progman', 'Program Manager')
        $def = [Win32Uninstall.Desk]::FindWindowEx($pm, $zero, 'SHELLDLL_DefView', $null)
        $list = [Win32Uninstall.Desk]::FindWindowEx($def, $zero, 'SysListView32', 'FolderView')
        if ($list -ne $zero) { [void][Win32Uninstall.Desk]::ShowWindow($list, 5) }
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        New-ItemProperty -Path $key -Name HideIcons -PropertyType DWord -Value 0 -Force | Out-Null
    } catch {}
}

if ((Test-Path -LiteralPath $snapshotPath) -and (Test-Path -LiteralPath $cliPath)) {
    Write-Host "Restoring desktop icons first..." -ForegroundColor Yellow
    try {
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $cliPath -Restore -Silent
    } catch {}
}
Show-DesktopIconList

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*DesktopIconTray.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Start-Sleep -Milliseconds 400
& schtasks.exe /Delete /TN 'DesktopIconToggleHelper' /F 2>$null | Out-Null

if (Test-Path -LiteralPath $startupLink) { Remove-Item -LiteralPath $startupLink -Force -ErrorAction SilentlyContinue }
$programsDir = [Environment]::GetFolderPath('Programs')
$desktopDir  = [Environment]::GetFolderPath('Desktop')
@(
    (Join-Path $programsDir 'Desktop Icon Toggle.lnk'),
    (Join-Path $programsDir 'Restore Desktop Icons.lnk'),
    (Join-Path $desktopDir 'Restore Desktop Icons.lnk')
) | ForEach-Object {
    if (Test-Path -LiteralPath $_) { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }
}

Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DesktopIconToggle' -Recurse -Force -ErrorAction SilentlyContinue

# The script may be running from the install folder. Delete the folder after this process exits.
if (Test-Path -LiteralPath $installDir) {
    $quoted = $installDir.Replace('"', '""')
    $delayCmd = "ping 127.0.0.1 -n 3 >nul & rmdir /s /q `"$quoted`""
    Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', $delayCmd -WindowStyle Hidden
}

if (-not $Silent) {
    Write-Host ""
    Write-Host "Desktop Icon Toggle has been removed from Apps." -ForegroundColor Green
    Write-Host "Install files are deleted a moment after this window closes." -ForegroundColor Green
    Write-Host ""
    Read-Host "Press Enter to close this window"
}

exit 0
