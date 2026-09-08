@echo off
REM OhosXray one-click install (calls PowerShell script)
setlocal
cd /d "%~dp0\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-ohosxray.ps1" %*
if errorlevel 1 (
  echo.
  echo Install failed. See docs\install-for-friends.md
  pause
  exit /b 1
)
echo.
pause
