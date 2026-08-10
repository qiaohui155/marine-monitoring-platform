@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0configure_shipxy.ps1"
if errorlevel 1 (
  echo.
  echo ShipXY configuration failed. Please take a screenshot of this window.
  pause
  exit /b 1
)
echo.
echo ShipXY configuration completed successfully.
pause
