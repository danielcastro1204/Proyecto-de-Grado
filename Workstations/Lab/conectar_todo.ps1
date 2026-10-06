# =============================================================================
# conectar_todo.ps1 — UN SOLO COMANDO para conectar TODAS las estaciones
# de trabajo de esta carpeta (Workstations) al SIEM, corrigiendo de paso
# el problema de la ruta por defecto NAT en cada una.
#
# EJECUTAR desde PowerShell, parado en la carpeta Workstations\:
#
#   .\Lab\conectar_todo.ps1
#
# Requiere que las 4 VMs ya estén levantadas (vagrant up).
# No modifica el Vagrantfile ni ningún archivo de aprovisionamiento.
# =============================================================================

$ErrorActionPreference = "Continue"
$VagrantDir = $PSScriptRoot | Split-Path -Parent      # carpeta Workstations\
$LabDir     = Join-Path (Split-Path $VagrantDir -Parent) "Lab"  # Desarrollo\Lab\

. (Join-Path $LabDir "_orquestador_common.ps1")

$linuxScript   = Join-Path $LabDir "conectar_agente_linux.sh"
$windowsScript = Join-Path $LabDir "conectar_agente_windows.ps1"

# VMs definidas en Workstations\Vagrantfile (ver config.vm.define)
$vms = @(
    @{ Name = "win10-01";  Type = "windows" },
    @{ Name = "win10-02";  Type = "windows" },
    @{ Name = "linux-01";  Type = "linux"   },
    @{ Name = "linux-02";  Type = "linux"   }
)

Write-Host ""
Write-Host "Conectando $($vms.Count) estaciones de WORKSTATIONS al SIEM, en paralelo..." -ForegroundColor Cyan

$jobs = foreach ($vm in $vms) {
    $script = if ($vm.Type -eq "linux") { $linuxScript } else { $windowsScript }
    Start-VmJob -VagrantDir $VagrantDir -VmName $vm.Name -Type $vm.Type -ScriptPath $script
}

Wait-AndShowJobs -Jobs $jobs

Write-Host ""
Write-Host "Verifica en el dashboard: https://192.168.30.10 -> Agents" -ForegroundColor Yellow
