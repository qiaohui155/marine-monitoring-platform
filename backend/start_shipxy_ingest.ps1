$ErrorActionPreference = 'Stop'
$BackendDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $BackendDirectory

if (-not (Test-Path '.env')) {
    throw 'Configuration is missing. Run configure_database.bat and configure_shipxy.bat first.'
}
if (-not (Test-Path '.venv\Scripts\python.exe')) {
    throw 'Backend environment is missing. Run setup_backend.ps1 first.'
}

Write-Host 'Starting the ShipXY real AIS collector. Keep this window open.' -ForegroundColor Cyan
Write-Host 'Press Ctrl+C or close this window to stop collection.' -ForegroundColor Yellow
& '.\.venv\Scripts\python.exe' -m app.shipxy_ingest
