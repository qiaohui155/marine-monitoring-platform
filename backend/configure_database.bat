@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0configure_database.ps1"
if errorlevel 1 goto failed

echo.
echo Testing the database connection...
"%~dp0.venv\Scripts\python.exe" -m app.test_database
if errorlevel 1 goto failed

echo.
echo Configuration and connection test completed successfully.
pause
exit /b 0

:failed
echo.
echo Configuration or connection test failed. Please take a screenshot of this window.
pause
exit /b 1
