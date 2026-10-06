# =============================================================================
# conectar_todo.ps1 — Corrige la red de Kali (y de paso le instala/conecta
# un agente Wazuh, útil para ver en el SIEM qué pasa en la propia máquina
# atacante) y deja el SIEM listo para recibir agentes.
#
# EJECUTAR desde PowerShell, parado en la carpeta Gestion\:
#
#   .\Lab\conectar_todo.ps1
#
# NOTA sobre wazuh1: NO se toca. Esa VM está diseñada a propósito para usar
# la NAT como salida a internet y ya tiene las rutas que necesita hacia
# VLAN10/20; aplicarle este fix le quitaría su salida a internet.
#
# NOTA sobre pfsense: NO lleva agente Wazuh (es FreeBSD/appliance, no usa
# netplan ni apt). Para monitorearlo desde el SIEM, configura en pfSense
# el envío de syslog hacia 192.168.30.10:514 (Status > System Logs >
# Settings > Remote Logging), que el SIEM ya tiene habilitado para
# recibir.
# =============================================================================

$ErrorActionPreference = "Continue"
$VagrantDir = $PSScriptRoot | Split-Path -Parent      # carpeta Gestion\
$LabDir     = Join-Path (Split-Path $VagrantDir -Parent) "Lab"  # Desarrollo\Lab\

. (Join-Path $LabDir "_orquestador_common.ps1")

$linuxScript = Join-Path $LabDir "conectar_agente_linux.sh"

Write-Host ""
Write-Host "PASO 1 — Verificando/corrigiendo el lado del SIEM (wazuh1)..." -ForegroundColor Cyan
$fixServerScript = Join-Path $LabDir "00_fix_agentes_wazuh.sh"
Invoke-LinuxVm -VagrantDir $VagrantDir -VmName "wazuh1" -ScriptPath $fixServerScript

Write-Host ""
Write-Host "PASO 2 — Corrigiendo la red de Kali y conectando su agente..." -ForegroundColor Cyan
$job = Start-VmJob -VagrantDir $VagrantDir -VmName "kali" -Type "linux" -ScriptPath $linuxScript
Wait-AndShowJobs -Jobs @($job)

Write-Host ""
Write-Host "Recuerda: pfSense se monitorea por syslog, no por agente (ver nota arriba)." -ForegroundColor Yellow
Write-Host "Verifica en el dashboard: https://192.168.30.10 -> Agents" -ForegroundColor Yellow
