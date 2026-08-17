$ErrorActionPreference = 'Stop'

$PlatformDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackendDirectory = Join-Path $PlatformDirectory 'backend'
$Python = Join-Path $BackendDirectory '.venv\Scripts\python.exe'
$StartScript = Join-Path $PlatformDirectory 'start_platform.ps1'

function Stop-PlatformService {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$ExpectedCommand,
        [Parameter(Mandatory = $true)][string]$ServiceName
    )

    $Listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if ($Listeners.Count -eq 0) {
        Write-Host "[OK] $ServiceName is not running." -ForegroundColor DarkGray
        return
    }

    $ProcessIds = @($Listeners | Select-Object -ExpandProperty OwningProcess -Unique)
    foreach ($ProcessId in $ProcessIds) {
        $ProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId"
        if ($null -eq $ProcessInfo) {
            continue
        }

        $CommandLine = [string]$ProcessInfo.CommandLine
        $IsProjectPython = [string]::Equals(
            [string]$ProcessInfo.ExecutablePath,
            $Python,
            [System.StringComparison]::OrdinalIgnoreCase
        )
        if (-not $IsProjectPython -or $CommandLine -notmatch $ExpectedCommand) {
            throw "Port $Port is occupied by another program. It was not stopped for safety."
        }

        Write-Host "Stopping $ServiceName process $ProcessId..."
        Stop-Process -Id $ProcessId -Force
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

Write-Host '[1/3] Stopping the existing backend API...'
Stop-PlatformService -Port 8000 -ExpectedCommand 'uvicorn.*app\.main:app' -ServiceName 'Backend API'

Write-Host '[2/3] Stopping the existing frontend service...'
Stop-PlatformService -Port 5173 -ExpectedCommand 'http\.server.*5173' -ServiceName 'Frontend service'

Write-Host '[3/3] Starting the platform with the current configuration...'
& $StartScript
