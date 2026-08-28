# Rebuild DesktopIconToggle.exe locally if you want a launcher. GitHub Releases do not ship the exe.
# Install.ps1 does not run this.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found: $csc" }
$wf = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.Windows.Forms.dll'
$exe = Join-Path $root 'DesktopIconToggle.exe'
$args = New-Object System.Collections.Generic.List[string]
[void]$args.Add('/nologo')
[void]$args.Add('/target:winexe')
[void]$args.Add('/optimize+')
[void]$args.Add("/r:$wf")
[void]$args.Add("/out:$exe")
$manifest = Join-Path $root 'app.manifest'
$ico = Join-Path $root 'App.ico'
if (Test-Path $manifest) { [void]$args.Add("/win32manifest:$manifest") }
if (Test-Path $ico) { [void]$args.Add("/win32icon:$ico") }
foreach ($n in @('DesktopIconTray.ps1','DesktopIconManager.ps1','Uninstall.ps1','App.ico','App-Hidden.ico','Run-Hidden.vbs')) {
    $p = Join-Path $root $n
    if (Test-Path $p) { [void]$args.Add("/resource:$p,$n") }
}
[void]$args.Add((Join-Path $root 'Launcher.cs'))
& $csc @($args.ToArray())
if ($LASTEXITCODE -ne 0) { throw "csc failed: $LASTEXITCODE" }
Write-Host "Built $exe ($((Get-Item $exe).Length) bytes)"
