$ErrorActionPreference = 'Stop'
$BackendDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $BackendDirectory

if (-not (Test-Path '.env')) {
    throw 'Database configuration is missing. Run configure_database.ps1 first.'
}
if (-not (Test-Path '.venv\Scripts\python.exe')) {
    throw 'Backend environment is missing. Run setup_backend.ps1 first.'
}

& '.\.venv\Scripts\python.exe' -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
