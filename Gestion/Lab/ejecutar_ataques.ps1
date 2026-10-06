# =============================================================================
# ejecutar_ataques.ps1 — UN SOLO COMANDO para lanzar el Escenario 2
# (los 3 ataques automatizados corriendo EN PARALELO dentro de Kali) y traer
# de vuelta el CSV resultante a este host, listo para el análisis.
#
# EJECUTAR desde PowerShell, parado en la carpeta Gestion\:
#
#   .\Lab\ejecutar_ataques.ps1              # 5 repeticiones (default)
#   .\Lab\ejecutar_ataques.ps1 -Reps 3      # 3 repeticiones
#
# Requiere que Kali esté levantada y ya conectada (Lab\conectar_todo.ps1).
# =============================================================================
param(
    [int]$Reps = 5
)

$ErrorActionPreference = "Continue"
$VagrantDir = $PSScriptRoot | Split-Path -Parent
$LabDir     = Join-Path (Split-Path $VagrantDir -Parent) "Lab"
$attackScript = Join-Path $LabDir "escenario2_ataques.sh"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ESCENARIO 2 — Lanzando ataques en paralelo en Kali ($Reps reps c/u)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$scriptContent = Get-Content -Raw -Path $attackScript

Push-Location $VagrantDir
try {
    $scriptContent | & vagrant ssh kali -c "sudo bash -s -- $Reps"
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "Recuperando el CSV de ataques (log_ataques.csv) desde Kali..." -ForegroundColor Cyan

$localCsv = Join-Path $PSScriptRoot "log_ataques.csv"
Push-Location $VagrantDir
try {
    & vagrant ssh kali -c "cat /tmp/log_ataques.csv" | Out-File -FilePath $localCsv -Encoding utf8
} finally {
    Pop-Location
}

if (Test-Path $localCsv) {
    Write-Host "OK. Guardado en: $localCsv" -ForegroundColor Green
    Write-Host ""
    Get-Content $localCsv | Select-Object -First 10
} else {
    Write-Host "No se pudo recuperar el CSV. Revisa la conexión SSH a Kali." -ForegroundColor Red
}

Write-Host ""
Write-Host "RECORDATORIO: los ataques 4 (Pass-the-Hash) y 5 (Payload) son" -ForegroundColor Yellow
Write-Host "manuales -- ver GUIA_DIA_DE_LAB.md. Agrégalos a este mismo CSV" -ForegroundColor Yellow
Write-Host "antes de correr el análisis de métricas." -ForegroundColor Yellow
