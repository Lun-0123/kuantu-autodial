@echo off
setlocal
cd /d "%~dp0"
echo Running one AutoDialer cycle in console mode. This may dial the connection.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AutoDialer.ps1" -Once -Console
echo.
pause
exit /b %ERRORLEVEL%
