$prg = Join-Path $PSScriptRoot 'widget\bin\widget.prg'
if (-not (Test-Path $prg)) { Write-Error 'widget.prg not found. Run build_all.ps1 first.'; exit 1 }

$shell    = New-Object -ComObject Shell.Application
$mypc     = $shell.Namespace(0x11)
$garmin   = $mypc.Items() | Where-Object { $_.Name -match 'Forerunner|Garmin' } | Select-Object -First 1
if (-not $garmin) { Write-Error 'Garmin device not found.'; exit 1 }
Write-Host "Found: $($garmin.Name)"

$root     = $shell.Namespace($garmin.Path)
$internal = $root.Items() | Select-Object -First 1
$intFolder = $internal.GetFolder

$garminDir = $intFolder.Items() | Where-Object { $_.Name -eq 'GARMIN' } | Select-Object -First 1
if (-not $garminDir) { Write-Error 'GARMIN folder not found'; exit 1 }

$appsDir = $garminDir.GetFolder.Items() | Where-Object { $_.Name -eq 'Apps' } | Select-Object -First 1
if (-not $appsDir) { Write-Error 'Apps folder not found'; exit 1 }

$dest = $appsDir.GetFolder
$src  = $shell.Namespace((Split-Path $prg))

Write-Host 'Copying widget.prg via MTP...'
$dest.CopyHere($src.ParseName('widget.prg'))
Start-Sleep -Seconds 5
Write-Host 'Done! Safely eject and disconnect the watch, then find TickTick in the widget list.'