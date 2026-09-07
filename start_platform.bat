@echo off
title Oman Marine Monitoring Platform
echo ================================================
echo   Oman Marine Monitoring Platform
echo ================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_platform.ps1" -AlertTest
if errorlevel 1 (
  echo.
  echo Platform startup failed. Keep this window open and check the message above.
  pause
) else (
  echo.
  echo Startup completed. This window will close automatically.
  powershell.exe -NoProfile -Command "Start-Sleep -Seconds 2"
)
