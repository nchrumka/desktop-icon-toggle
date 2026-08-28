@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
echo.
echo (Window will stay open - press any key to close.)
pause >nul
