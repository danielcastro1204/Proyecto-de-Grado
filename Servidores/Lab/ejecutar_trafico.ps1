# =============================================================================
# ejecutar_trafico.ps1 — UN SOLO COMANDO para generar tráfico normal
# (Escenario 1 - línea base) EN PARALELO en todas las VMs de Servidores
# que pueden generar tráfico de cliente (no tiene sentido correrlo en el
# propio DC o DNS, que son servicios, así que se usa el web-server).
#
# EJECUTAR desde PowerShell, parado en la carpeta Servidores\:
#
#   .\Lab\ejecutar_trafico.ps1
#
# Déjalo correr (30 min por defecto) mientras en otra ventana, en el host
# de Gestión, se dispara Lab\ejecutar_ataques.ps1 -- eso simula el
# Escenario 3 (tráfico mixto) de forma manual coordinada entre los dos
# hosts físicos (ver GUIA_DIA_DE_LAB.md).
# =============================================================================
param(
    [int]$DuracionMin = 30
)

$ErrorActionPreference = "Continue"
$VagrantDir = $PSScriptRoot | Split-Path -Parent
$LabDir     = Join-Path (Split-Path $VagrantDir -Parent) "Lab"

. (Join-Path $LabDir "_orquestador_common.ps1")

$linuxScript = Join-Path $LabDir "escenario1_linea_base.sh"

Write-Host ""
Write-Host "Generando tráfico normal en web-server por $DuracionMin minutos..." -ForegroundColor Cyan

$job = Start-VmJob -VagrantDir $VagrantDir -VmName "web-server" -Type "linux" `
    -ScriptPath $linuxScript -ExtraArgs "$DuracionMin"

Wait-AndShowJobs -Jobs @($job)
