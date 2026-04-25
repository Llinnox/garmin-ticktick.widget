$prg = Join-Path $PSScriptRoot 'widget\bin\widget.prg'
if (-not (Test-Path $prg)) { Write-Error 'widget.prg not found. Run build_all.ps1 first.'; exit 1 }
$found = $false
foreach ($d in 68..90) {
    $letter = [char]$d
    $path = "${letter}:\GARMIN\Apps"
    if (Test-Path $path) {
        Write-Host "Found Garmin at ${letter}:\ - copying..."
        Copy-Item $prg $path -Force
        Write-Host 'Done! Safely eject watch, disconnect USB, then find TickTick in widget list.'
        $found = $true
        break
    }
}
if (-not $found) {
    Write-Host 'Garmin watch not found.'
    Write-Host 'Connect via USB, then on watch: hold UP > Settings > System > USB Mode > Garmin/MTP'
}