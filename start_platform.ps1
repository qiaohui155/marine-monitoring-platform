$ErrorActionPreference = 'Stop'
$PlatformDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackendDirectory = Join-Path $PlatformDirectory 'backend'
$FrontendDirectory = Join-Path $PlatformDirectory 'frontend'
$Python = Join-Path $BackendDirectory '.venv\Scripts\python.exe'
$BackendUrl = 'http://127.0.0.1:8000/'
$DatabaseHealthUrl = 'http://127.0.0.1:8000/api/health'
$FrontendUrl = 'http://127.0.0.1:5173/'

function Test-ServiceUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    try {
        $Response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
        return $Response.StatusCode -ge 200 -and $Response.StatusCode -lt 500
    }
    catch {
        return $false
    }
}

function Wait-ServiceUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [int]$TimeoutSeconds = 20
    )
    $Timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-ServiceUrl -Url $Url) {
            Write-Host "[OK] $ServiceName is ready." -ForegroundColor Green
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw "$ServiceName did not become ready within $TimeoutSeconds seconds."
}

if (-not (Test-Path $Python)) {
    throw 'The backend environment is missing.'
}
if (-not (Test-Path (Join-Path $BackendDirectory '.env'))) {
    throw 'The database configuration is missing.'
}

Write-Host '[1/3] Checking backend API...'
if (-not (Test-ServiceUrl -Url $BackendUrl)) {
    $BackendProcess = Start-Process -FilePath $Python `
        -ArgumentList @('-m', 'uvicorn', 'app.main:app', '--host', '127.0.0.1', '--port', '8000') `
        -WorkingDirectory $BackendDirectory `
        -WindowStyle Hidden `
        -PassThru
    Write-Host "      Started backend process $($BackendProcess.Id)."
    Wait-ServiceUrl -Url $BackendUrl -ServiceName 'Backend API'
}
else {
    Write-Host '[OK] Backend API is already running.' -ForegroundColor Green
}

try {
    $DatabaseHealth = Invoke-RestMethod -Uri $DatabaseHealthUrl -TimeoutSec 8
    if ($DatabaseHealth.database_connection -eq 'ok') {
        Write-Host '[OK] PostgreSQL/PostGIS connection is ready.' -ForegroundColor Green
    }
    else {
        Write-Warning 'The API started, but the database connection is not ready.'
    }
}
catch {
    Write-Warning 'The API started, but the database health check timed out.'
}

Write-Host '[2/3] Checking frontend service...'
if (-not (Test-ServiceUrl -Url $FrontendUrl)) {
    $FrontendProcess = Start-Process -FilePath $Python `
        -ArgumentList @('-m', 'http.server', '5173', '--bind', '127.0.0.1') `
        -WorkingDirectory $FrontendDirectory `
        -WindowStyle Hidden `
        -PassThru
    Write-Host "      Started frontend process $($FrontendProcess.Id)."
    Wait-ServiceUrl -Url $FrontendUrl -ServiceName 'Frontend service'
}
else {
    Write-Host '[OK] Frontend service is already running.' -ForegroundColor Green
}

Write-Host '[3/3] Opening the monitoring platform...'
Start-Process $FrontendUrl
Write-Host ''
Write-Host 'Platform URL: http://127.0.0.1:5173/' -ForegroundColor Cyan
Write-Host 'API docs:     http://127.0.0.1:8000/docs' -ForegroundColor Cyan
