param(
    [Parameter(Mandatory = $true)]
    [string]$File
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$MigrationRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'migrations'))
$MigrationFile = [IO.Path]::GetFullPath($File)
$EnvFile = Join-Path $ProjectRoot 'backend\.env'
$Psql = 'C:\Program Files\PostgreSQL\16\bin\psql.exe'

if (-not $MigrationFile.StartsWith($MigrationRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Only SQL files inside database/migrations may be applied with this script.'
}
if (-not (Test-Path -LiteralPath $MigrationFile -PathType Leaf)) {
    throw "Migration file does not exist: $MigrationFile"
}

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
        --no-password --set=ON_ERROR_STOP=1 "--file=$MigrationFile"
    if ($LASTEXITCODE -ne 0) { throw 'Migration failed. The SQL transaction should be reviewed.' }
}
finally {
    $env:PGPASSWORD = $null
}

Write-Host "Migration applied: $MigrationFile" -ForegroundColor Green
