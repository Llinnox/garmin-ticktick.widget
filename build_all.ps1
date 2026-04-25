# 1. Get ngrok URL
$r = try { Invoke-RestMethod http://localhost:4040/api/tunnels } catch { $null }
if (-not $r) { Write-Error 'ngrok is not running. Run: ngrok http 8765'; exit 1 }
$t = $r.tunnels | Where-Object { $_.proto -eq "https" } | Select-Object -First 1
if (-not $t) { Write-Error 'No HTTPS tunnel found in ngrok'; exit 1 }
$url = $t.public_url
Write-Host "[1/2] ngrok URL: $url"

# 2. Patch TickTickView.mc
$mcFile = Join-Path $PSScriptRoot 'widget\source\TickTickView.mc'
$lines = [System.IO.File]::ReadAllLines($mcFile)
$patched = $lines | ForEach-Object {
    if ($_ -match 'private const SERVER') {
        "    private const SERVER     = `"$url`";".TrimEnd()
    } else { $_ }
}
[System.IO.File]::WriteAllLines($mcFile, $patched)
Write-Host '[1/2] TickTickView.mc patched.'

# 3. Build
Write-Host '[2/2] Compiling...'
$sdk  = 'C:\Users\User\AppData\Roaming\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-8.4.1-2026-02-03-e9f77eeaa\bin\monkeyc.bat'
$proj = Join-Path $PSScriptRoot 'widget'
cmd /c "`"$sdk`" -f `"$proj\monkey.jungle`" -o `"$proj\bin\widget.prg`" -y `"$proj\developer_key`" -d fr955"
if ($LASTEXITCODE -eq 0) { Write-Host 'BUILD SUCCESS: widget\bin\widget.prg' }
else { Write-Error 'BUILD FAILED'; exit 1 }