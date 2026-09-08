@echo off
title Restart Oman Marine Monitoring Platform
echo ================================================
echo   Restart Oman Marine Monitoring Platform
echo ================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart_platform.ps1"
if errorlevel 1 (
  echo.
  echo Platform restart failed. Check the message above.
  pause
) else (
  echo.
  echo Platform restarted successfully.
  powershell.exe -NoProfile -Command "Start-Sleep -Seconds 2"
)
