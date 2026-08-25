$ErrorActionPreference = 'Stop'
$PlatformDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExpectedPython = [System.IO.Path]::GetFullPath(
    (Join-Path $PlatformDirectory 'backend\.venv\Scripts\python.exe')
)

$Processes = Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
    Where-Object {
        $_.CommandLine -match '-m\s+app\.simulated_ais(?:\s|$)' -and
        $_.ExecutablePath -and
        [System.IO.Path]::GetFullPath($_.ExecutablePath) -eq $ExpectedPython
    }

if (-not $Processes) {
    Write-Host 'The simulated AIS service is not running.' -ForegroundColor Yellow
    exit 0
}

foreach ($Process in $Processes) {
    Stop-Process -Id $Process.ProcessId -Force
    Write-Host "Stopped simulated AIS process $($Process.ProcessId)." -ForegroundColor Green
}

