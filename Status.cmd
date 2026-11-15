@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Control.ps1" -Action Status
echo.
pause
exit /b %ERRORLEVEL%
