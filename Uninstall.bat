@echo off
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0' -File | Unblock-File -ErrorAction SilentlyContinue"
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Uninstall.ps1"
