# =============================================================================
# ejecutar_trafico.ps1 — UN SOLO COMANDO para generar tráfico normal
# (Escenario 1 - línea base) EN PARALELO en las 4 estaciones de trabajo
# (win10-01, win10-02, linux-01, linux-02).
#
# EJECUTAR desde PowerShell, parado en la carpeta Workstations\:
#
#   .\Lab\ejecutar_trafico.ps1
#
# Duración: 30 minutos en las Linux (parametrizable); fija en 30 min en las
# Windows (editar $DuracionMin dentro de escenario1_trafico_windows.ps1 si
# hace falta cambiarla).
# =============================================================================
param(
    [int]$DuracionMin = 30
)

$ErrorActionPreference = "Continue"
$VagrantDir = $PSScriptRoot | Split-Path -Parent
$LabDir     = Join-Path (Split-Path $VagrantDir -Parent) "Lab"

. (Join-Path $LabDir "_orquestador_common.ps1")

$linuxScript   = Join-Path $LabDir "escenario1_linea_base.sh"
$windowsScript = Join-Path $LabDir "escenario1_trafico_windows.ps1"

Write-Host ""
Write-Host "Generando tráfico normal en las 4 estaciones, en paralelo ($DuracionMin min)..." -ForegroundColor Cyan

$jobs = @(
    (Start-VmJob -VagrantDir $VagrantDir -VmName "linux-01" -Type "linux"   -ScriptPath $linuxScript -ExtraArgs "$DuracionMin"),
    (Start-VmJob -VagrantDir $VagrantDir -VmName "linux-02" -Type "linux"   -ScriptPath $linuxScript -ExtraArgs "$DuracionMin"),
    (Start-VmJob -VagrantDir $VagrantDir -VmName "win10-01" -Type "windows" -ScriptPath $windowsScript),
    (Start-VmJob -VagrantDir $VagrantDir -VmName "win10-02" -Type "windows" -ScriptPath $windowsScript)
)

Wait-AndShowJobs -Jobs $jobs
