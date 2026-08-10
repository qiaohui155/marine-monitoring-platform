$ErrorActionPreference = 'Stop'
$BackendDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $BackendDirectory

if (Get-Command py -ErrorAction SilentlyContinue) {
    $PythonCommand = 'py'
    $PythonArguments = @('-3')
}
elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $PythonCommand = 'python'
    $PythonArguments = @()
}
else {
    throw 'Python 3 was not found. Install Python 3 and run this file again.'
}

if (-not (Test-Path '.venv')) {
    & $PythonCommand @PythonArguments -m venv .venv
}

& '.\.venv\Scripts\python.exe' -m pip install --upgrade pip
& '.\.venv\Scripts\python.exe' -m pip install -r requirements.txt

Write-Host 'Backend dependencies installed.' -ForegroundColor Green
