$ErrorActionPreference = 'Stop'
$PlatformDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExpectedPython = [System.IO.Path]::GetFullPath(
    (Join-Path $PlatformDirectory 'backend\.venv\Scripts\python.exe')
)

$AllProcesses = @(Get-CimInstance Win32_Process)
$Processes = @($AllProcesses | Where-Object {
    $_.Name -eq 'python.exe' -and
    $_.CommandLine -match '-m\s+app\.simulated_ais(?:\s|$)' -and
    $_.ExecutablePath -and
    [System.IO.Path]::GetFullPath($_.ExecutablePath) -eq $ExpectedPython
})

if (-not $Processes) {
    Write-Host 'The simulated AIS service is not running.' -ForegroundColor Yellow
    exit 0
}

foreach ($Process in $Processes) {
    # On Windows, a virtual-environment python.exe can launch the bundled base
    # interpreter as a child. Stop descendants first so the database advisory
    # lock and update loop cannot survive after the visible launcher is closed.
    $DescendantIds = [System.Collections.Generic.List[int]]::new()
    $PendingParentIds = [System.Collections.Generic.Queue[int]]::new()
    $PendingParentIds.Enqueue([int]$Process.ProcessId)
    while ($PendingParentIds.Count -gt 0) {
        $ParentId = $PendingParentIds.Dequeue()
        foreach ($Child in $AllProcesses | Where-Object { $_.ParentProcessId -eq $ParentId }) {
            $DescendantIds.Add([int]$Child.ProcessId)
            $PendingParentIds.Enqueue([int]$Child.ProcessId)
        }
    }

    for ($Index = $DescendantIds.Count - 1; $Index -ge 0; $Index--) {
        Stop-Process -Id $DescendantIds[$Index] -Force -ErrorAction SilentlyContinue
        Write-Host "Stopped simulated AIS child process $($DescendantIds[$Index])." -ForegroundColor Green
    }
    Stop-Process -Id $Process.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped simulated AIS process $($Process.ProcessId)." -ForegroundColor Green
}

