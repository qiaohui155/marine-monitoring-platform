$ErrorActionPreference = 'Stop'
$FrontendDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $FrontendDirectory

if (Get-Command py -ErrorAction SilentlyContinue) {
    py -3 -m http.server 5173 --bind 127.0.0.1
}
elseif (Get-Command python -ErrorAction SilentlyContinue) {
    python -m http.server 5173 --bind 127.0.0.1
}
else {
    throw 'Python 3 was not found.'
}
