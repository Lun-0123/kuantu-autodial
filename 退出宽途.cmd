@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stop-KuanTu.ps1"

echo.
echo KuanTu stopped. You can now rename or move this folder.
echo To re-enable: run the settings program and save, or run Install.cmd.
echo.
pause
exit /b 0