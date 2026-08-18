$ErrorActionPreference = 'Stop'
$PlatformDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackendDirectory = Join-Path $PlatformDirectory 'backend'
$FrontendDirectory = Join-Path $PlatformDirectory 'frontend'
$Python = Join-Path $BackendDirectory '.venv\Scripts\python.exe'
$BackendUrl = 'http://127.0.0.1:8000/'
$DatabaseHealthUrl = 'http://127.0.0.1:8000/api/health'
$FrontendUrl = 'http://127.0.0.1:5173/'
$EnvironmentFile = Join-Path $BackendDirectory '.env'

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)
    $Values = @{}
    Get-Content -LiteralPath $Path | ForEach-Object {
        if ($_ -match '^\s*([^#=]+)=(.*)$') {
            $Values[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $Values
}

function Get-ShipxyCollectorProcesses {
    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'python.exe' -and
        [string]$_.CommandLine -match '(?:-m\s+app\.shipxy_ingest|app[\\/]shipxy_ingest\.py)'
    })
}

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
if (-not (Test-Path $EnvironmentFile)) {
    throw 'The database configuration is missing.'
}
$Environment = Read-DotEnv -Path $EnvironmentFile

Write-Host '[1/4] Checking backend API...'
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

Write-Host '[2/4] Checking live AIS collector...'
$AutoStartCollector = [string]$Environment['SHIPXY_AUTO_START'] -match '^(?i:true|1|yes|on)$'
$CollectorTargetDatabase = [string]$Environment['SHIPXY_TARGET_DB']
$ActiveDatabase = [string]$Environment['DB_NAME']
if (-not $AutoStartCollector) {
    Write-Host '[OK] Automatic AIS collection is disabled.' -ForegroundColor DarkGray
}
elseif (
    -not [string]::IsNullOrWhiteSpace($CollectorTargetDatabase) -and
    -not [string]::Equals($CollectorTargetDatabase, $ActiveDatabase, [System.StringComparison]::OrdinalIgnoreCase)
) {
    Write-Warning "AIS collection was not started because DB_NAME is '$ActiveDatabase', not '$CollectorTargetDatabase'."
}
elseif (
    [string]::IsNullOrWhiteSpace([string]$Environment['SHIPXY_API_KEY']) -or
    [string]::IsNullOrWhiteSpace([string]$Environment['SHIPXY_MMSI_LIST'])
) {
    Write-Warning 'AIS collection was not started because the ShipXY key or MMSI list is missing.'
}
else {
    $CollectorProcesses = Get-ShipxyCollectorProcesses
    if ($CollectorProcesses.Count -eq 0) {
        $LogDirectory = Join-Path $BackendDirectory 'logs'
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        $CollectorProcess = Start-Process -FilePath $Python `
            -ArgumentList @('-m', 'app.shipxy_ingest') `
            -WorkingDirectory $BackendDirectory `
            -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $LogDirectory 'shipxy-collector.out.log') `
            -RedirectStandardError (Join-Path $LogDirectory 'shipxy-collector.err.log') `
            -PassThru
        Start-Sleep -Seconds 1
        if ($CollectorProcess.HasExited) {
            throw 'The AIS collector exited during startup. Check backend/logs/shipxy-collector.err.log.'
        }
        Write-Host "[OK] Started live AIS collector process $($CollectorProcess.Id)." -ForegroundColor Green
    }
    else {
        Write-Host '[OK] Live AIS collector is already running.' -ForegroundColor Green
    }
}

Write-Host '[3/4] Checking frontend service...'
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

Write-Host '[4/4] Opening the monitoring platform...'
Start-Process $FrontendUrl
Write-Host ''
Write-Host 'Platform URL: http://127.0.0.1:5173/' -ForegroundColor Cyan
Write-Host 'API docs:     http://127.0.0.1:8000/docs' -ForegroundColor Cyan
