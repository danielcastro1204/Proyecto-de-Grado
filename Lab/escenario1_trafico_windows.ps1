# =============================================================================
# escenario1_trafico_windows.ps1 — Tráfico normal (línea base) para Windows
# Equivalente de escenario1_linea_base.sh, para win10-01 / win10-02.
# Duración fija de 30 minutos (ajustar $DuracionMin si hace falta).
# =============================================================================

$DuracionMin = 30
$WebIp  = "192.168.10.10"
$DcIp   = "192.168.10.20"
$GwIp   = "192.168.20.1"
$LogFile = "$env:TEMP\trafico_normal.log"
$VentanaFile = "$env:TEMP\escenario1_ventana.txt"

function Info($m) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }

$inicio = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
"inicio=$inicio" | Out-File -FilePath $VentanaFile -Encoding utf8

Write-Host ""
Write-Host "============================================================"
Write-Host "  ESCENARIO 1 (Windows) — Tráfico normal ($DuracionMin min)"
Write-Host "============================================================"

$fin = (Get-Date).AddMinutes($DuracionMin)
$iter = 0

while ((Get-Date) -lt $fin) {
    $iter++
    $restantes = [math]::Round(($fin - (Get-Date)).TotalMinutes)
    Info "Iteración $iter - $restantes min restantes"

    try { Invoke-WebRequest -Uri "http://$WebIp/" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
    try { Invoke-WebRequest -Uri "http://$WebIp/login.html" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
    Test-Connection -ComputerName $GwIp -Count 1 -Quiet -ErrorAction SilentlyContinue | Out-Null
    Test-Connection -ComputerName $DcIp -Count 1 -Quiet -ErrorAction SilentlyContinue | Out-Null
    try { Resolve-DnsName -Name "empresa.local" -Server $DcIp -ErrorAction SilentlyContinue | Out-Null } catch {}

    "$(Get-Date) - acceso normal usuario" | Out-File -FilePath $LogFile -Append -Encoding utf8

    Start-Sleep -Seconds (Get-Random -Minimum 15 -Maximum 45)
}

$fin_iso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
"fin=$fin_iso" | Add-Content -Path $VentanaFile -Encoding utf8

Write-Host ""
Ok "ESCENARIO 1 (Windows) completado. Ventana: $VentanaFile"
