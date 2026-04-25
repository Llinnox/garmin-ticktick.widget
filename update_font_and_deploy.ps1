$ROOT    = $PSScriptRoot
$SDK     = "C:\Users\User\AppData\Roaming\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-8.4.1-2026-02-03-e9f77eeaa\bin"
$WIDGET  = "$ROOT\widget"
$PRG     = "$WIDGET\bin\widget.prg"

Write-Host "`n[1/3] Generating font from TickTick..." -ForegroundColor Cyan
python "$ROOT\gen_font.py"
if ($LASTEXITCODE -ne 0) { Write-Host "Font generation failed!" -ForegroundColor Red; exit 1 }

Write-Host "`n[2/3] Compiling widget..." -ForegroundColor Cyan
& "$SDK\monkeyc.bat" -f "$WIDGET\monkey.jungle" -o $PRG -y "$WIDGET\developer_key" -d fr955
if ($LASTEXITCODE -ne 0) { Write-Host "Compile failed!" -ForegroundColor Red; exit 1 }

Write-Host "`n[3/3] Deploying to watch..." -ForegroundColor Cyan
$found = $false
foreach ($d in 68..90) {
    $letter = [char]$d
    $path = "${letter}:\GARMIN\Apps"
    if (Test-Path $path) {
        Write-Host "Found Garmin at ${letter}:\ - copying..."
        Copy-Item $PRG $path -Force
        $found = $true
        break
    }
}
if (-not $found) {
    Write-Host "Watch not found via USB. Copy manually:" -ForegroundColor Yellow
    Write-Host "  $PRG" -ForegroundColor Yellow
}

Write-Host "`nDone!" -ForegroundColor Green
