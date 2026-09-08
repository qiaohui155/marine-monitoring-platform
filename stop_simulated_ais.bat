@echo off
title Stop Simulated AIS Service
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop_simulated_ais.ps1"
echo.
pause
