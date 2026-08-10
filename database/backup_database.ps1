param(
    [string]$OutputDirectory = 'D:\oman\database-backup'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $ProjectRoot 'backend\.env'
$PgBin = 'C:\Program Files\PostgreSQL\16\bin'

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw 'backend/.env is missing. Configure the local database first.'
}
if (-not (Test-Path -LiteralPath (Join-Path $PgBin 'pg_dump.exe'))) {
    throw 'PostgreSQL 16 command-line tools were not found.'
}

$Config = @{}
Get-Content -LiteralPath $EnvFile | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') {
        $Config[$matches[1].Trim()] = $matches[2].Trim()
    }
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
}
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupFile = Join-Path $OutputDirectory "Oman_Oil_Monitor_$Timestamp.backup"

try {
    $env:PGPASSWORD = $Config['DB_PASSWORD']
    & (Join-Path $PgBin 'pg_dump.exe') `
        "--host=$($Config['DB_HOST'])" `
        "--port=$($Config['DB_PORT'])" `
        "--username=$($Config['DB_USER'])" `
        "--dbname=$($Config['DB_NAME'])" `
        --format=custom --no-password "--file=$BackupFile"
    if ($LASTEXITCODE -ne 0) { throw 'Database backup failed.' }

    & (Join-Path $PgBin 'pg_restore.exe') --list $BackupFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The backup file could not be verified.' }
}
finally {
    $env:PGPASSWORD = $null
}

$Item = Get-Item -LiteralPath $BackupFile
Write-Host "Verified backup created: $($Item.FullName)" -ForegroundColor Green
Write-Host "Size: $([math]::Round($Item.Length / 1MB, 2)) MB"
