$ErrorActionPreference = 'Stop'
$BackendDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetFile = Join-Path $BackendDirectory '.env'

if (-not (Test-Path -LiteralPath $TargetFile)) {
    throw 'Database configuration is missing. Run configure_database.bat first.'
}

Write-Host 'Configure ShipXY real AIS collection.' -ForegroundColor Cyan
$SecureApiKey = Read-Host 'Enter the ShipXY API key' -AsSecureString
$DefaultMmsi = '357867000'
$MmsiList = Read-Host "Enter MMSI numbers separated by commas, or press Enter for $DefaultMmsi"
if ([string]::IsNullOrWhiteSpace($MmsiList)) { $MmsiList = $DefaultMmsi }

$Pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureApiKey)
try {
    $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Pointer)
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'The ShipXY API key cannot be empty.'
    }

    $Values = [ordered]@{
        SHIPXY_API_KEY = $ApiKey
        SHIPXY_MMSI_LIST = ($MmsiList -replace '\s+', '')
        SHIPXY_POLL_SECONDS = '15'
        SHIPXY_TRACK_MIN_SECONDS = '60'
        SHIPXY_TRACK_MIN_METERS = '20'
    }
    $Lines = [Collections.Generic.List[string]](Get-Content -LiteralPath $TargetFile)
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
    $ApiKey = $null
}

Write-Host 'ShipXY settings were saved locally in .env.' -ForegroundColor Green
Write-Host 'Do not share the .env file or screenshots containing the API key.' -ForegroundColor Yellow
