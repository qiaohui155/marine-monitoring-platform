$ErrorActionPreference = 'Stop'
$BackendDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetFile = Join-Path $BackendDirectory '.env'

Write-Host 'Configure the local Oman_Oil_Monitor database connection.' -ForegroundColor Cyan
$SecurePassword = Read-Host 'Enter the PostgreSQL password for user postgres' -AsSecureString
$Pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)

try {
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Pointer)
    $Values = [ordered]@{
        DB_HOST = '127.0.0.1'
        DB_PORT = '5432'
        DB_NAME = 'Oman_Oil_Monitor'
        DB_USER = 'postgres'
        DB_PASSWORD = $PlainPassword
        DB_SCHEMA = 'public'
    }
    $Lines = [Collections.Generic.List[string]]@()
    if (Test-Path -LiteralPath $TargetFile) {
        $Lines.AddRange([string[]](Get-Content -LiteralPath $TargetFile))
    }
    foreach ($Entry in $Values.GetEnumerator()) {
        $Found = $false
        for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
            if ($Lines[$Index] -match ('^' + [regex]::Escape($Entry.Key) + '=')) {
                $Lines[$Index] = "$($Entry.Key)=$($Entry.Value)"
                $Found = $true
                break
            }
        }
        if (-not $Found) {
            $Lines.Add("$($Entry.Key)=$($Entry.Value)")
        }
    }
    [IO.File]::WriteAllLines($TargetFile, $Lines, [Text.UTF8Encoding]::new($false))
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer)
    $PlainPassword = $null
}

Write-Host 'Database configuration saved locally. Do not share the .env file.' -ForegroundColor Green
