$ErrorActionPreference = 'Stop'

$PlatformDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackendDirectory = Join-Path $PlatformDirectory 'backend'
$Python = Join-Path $BackendDirectory '.venv\Scripts\python.exe'
$StartScript = Join-Path $PlatformDirectory 'start_platform.ps1'

function Stop-ShipxyCollector {
    $CollectorProcesses = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'python.exe' -and
        [string]$_.CommandLine -match '(?:-m\s+app\.shipxy_ingest|app[\\/]shipxy_ingest\.py)'
    })
    if ($CollectorProcesses.Count -eq 0) {
        Write-Host '[OK] Live AIS collector is not running.' -ForegroundColor DarkGray
        return
    }

    foreach ($CollectorProcess in $CollectorProcesses) {
        Write-Host "Stopping Live AIS collector process $($CollectorProcess.ProcessId)..."
        Stop-Process -Id $CollectorProcess.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Write-Host '[OK] Live AIS collector stopped.' -ForegroundColor Green
}

function Stop-PlatformService {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$ExpectedCommand,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$ValidationUrl,
        [Parameter(Mandatory = $true)][string]$ValidationPattern
    )

    $Listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if ($Listeners.Count -eq 0) {
        Write-Host "[OK] $ServiceName is not running." -ForegroundColor DarkGray
        return
    }

    $ListenerProcessIds = @($Listeners | Select-Object -ExpandProperty OwningProcess -Unique)
    $ProcessIdsToStop = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($ProcessId in $ListenerProcessIds) {
        $ProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId"
        if ($null -eq $ProcessInfo) {
            continue
        }

        $CommandLine = [string]$ProcessInfo.CommandLine
        if ($ProcessInfo.Name -ne 'python.exe' -or $CommandLine -notmatch $ExpectedCommand) {
            throw "Port $Port is occupied by another program. It was not stopped for safety."
        }

        try {
            $ValidationResponse = Invoke-WebRequest `
                -Uri $ValidationUrl `
                -UseBasicParsing `
                -TimeoutSec 3
            if ([string]$ValidationResponse.Content -notmatch $ValidationPattern) {
                throw 'Platform marker was not found.'
            }
        }
        catch {
            throw "Port $Port did not return the expected $ServiceName response. It was not stopped for safety."
        }

        [void]$ProcessIdsToStop.Add([int]$ProcessId)

        # A Windows virtual environment may use a small python launcher which
        # starts the real interpreter as a child process. Stop both members of
        # that pair so the listening child cannot remain behind.
        $ParentProcessInfo = Get-CimInstance Win32_Process `
            -Filter "ProcessId = $($ProcessInfo.ParentProcessId)"
        if (
            $null -ne $ParentProcessInfo -and
            $ParentProcessInfo.Name -eq 'python.exe' -and
            [string]$ParentProcessInfo.CommandLine -match $ExpectedCommand
        ) {
            [void]$ProcessIdsToStop.Add([int]$ParentProcessInfo.ProcessId)
        }
    }

    foreach ($ProcessId in $ProcessIdsToStop) {
        Write-Host "Stopping $ServiceName process $ProcessId..."
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }

    $Timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Timer.Elapsed.TotalSeconds -lt 10) {
        if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
            Write-Host "[OK] $ServiceName stopped." -ForegroundColor Green
            return
        }
        Start-Sleep -Milliseconds 300
    }
    throw "$ServiceName did not stop within 10 seconds."
}

if (-not (Test-Path -LiteralPath $Python)) {
    throw 'The backend Python environment is missing.'
}
if (-not (Test-Path -LiteralPath $StartScript)) {
    throw 'start_platform.ps1 is missing.'
}

Write-Host '[1/4] Stopping the live AIS collector...'
Stop-ShipxyCollector

Write-Host '[2/4] Stopping the existing backend API...'
Stop-PlatformService `
    -Port 8000 `
    -ExpectedCommand 'uvicorn.*app\.main:app' `
    -ServiceName 'Backend API' `
    -ValidationUrl 'http://127.0.0.1:8000/openapi.json' `
    -ValidationPattern 'Oman Marine Monitoring API'

Write-Host '[3/4] Stopping the existing frontend service...'
Stop-PlatformService `
    -Port 5173 `
    -ExpectedCommand 'http\.server.*5173' `
    -ServiceName 'Frontend service' `
    -ValidationUrl 'http://127.0.0.1:5173/' `
    -ValidationPattern 'Oman Marine Intelligence Center'

Write-Host '[4/4] Starting the platform with the current configuration...'
& $StartScript
