param(
    [switch]$ConfirmReset
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmReset) {
    throw 'This operation deletes current ship positions and tracks. Re-run with -ConfirmReset only for an intentional simulation reset.'
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $ProjectRoot 'backend\.env'
$SeedFile = Join-Path $PSScriptRoot 'reset_simulation.sql'
$Psql = 'C:\Program Files\PostgreSQL\16\bin\psql.exe'

& (Join-Path $PSScriptRoot 'backup_database.ps1')

$Config = @{}
Get-Content -LiteralPath $EnvFile | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') {
        $Config[$matches[1].Trim()] = $matches[2].Trim()
    }
}

try {
    $env:PGPASSWORD = $Config['DB_PASSWORD']
    & $Psql `
        "--host=$($Config['DB_HOST'])" `
        "--port=$($Config['DB_PORT'])" `
        "--username=$($Config['DB_USER'])" `
        "--dbname=$($Config['DB_NAME'])" `
        --no-password --set=ON_ERROR_STOP=1 "--file=$SeedFile"
    if ($LASTEXITCODE -ne 0) { throw 'Simulation rebuild failed.' }
}
finally {
    $env:PGPASSWORD = $null
}

Write-Host 'Simulation data rebuilt successfully.' -ForegroundColor Green
