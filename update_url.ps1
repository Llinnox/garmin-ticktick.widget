$r = try { Invoke-RestMethod http://localhost:4040/api/tunnels } catch { $null }
if (-not $r) { Write-Host 'ERROR: ngrok is not running. Start ngrok first: ngrok http 8765'; exit 1 }
$t = $r.tunnels | Where-Object { $_.proto -eq "https" } | Select-Object -First 1
if (-not $t) { Write-Host 'ERROR: No HTTPS tunnel found'; exit 1 }
$url = $t.public_url
Write-Host "ngrok URL: $url"
$file = Join-Path $PSScriptRoot 'widget\source\TickTickView.mc'
$lines = [System.IO.File]::ReadAllLines($file)
$out = foreach ($line in $lines) {
    if ($line -match 'private const SERVER') { "    private const SERVER     = `"$url`";" } else { $line }
}
[System.IO.File]::WriteAllLines($file, $out)
Write-Host 'TickTickView.mc updated.'