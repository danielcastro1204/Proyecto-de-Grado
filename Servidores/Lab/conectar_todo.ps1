# =============================================================================
# conectar_todo.ps1 — UN SOLO COMANDO para conectar TODOS los servidores
# de esta carpeta (Servidores) al SIEM, corrigiendo de paso el problema de
# la ruta por defecto NAT en cada uno.
#
# EJECUTAR desde PowerShell, parado en la carpeta Servidores\ (donde está
# el Vagrantfile de este host):
#
#   .\Lab\conectar_todo.ps1
#
# Requiere que las 8 VMs ya estén levantadas (vagrant up).
# No modifica el Vagrantfile ni ningún archivo de aprovisionamiento.
# =============================================================================

$ErrorActionPreference = "Continue"
$VagrantDir = $PSScriptRoot | Split-Path -Parent      # carpeta Servidores\
$LabDir     = Join-Path (Split-Path $VagrantDir -Parent) "Lab"  # Desarrollo\Lab\

. (Join-Path $LabDir "_orquestador_common.ps1")

$linuxScript   = Join-Path $LabDir "conectar_agente_linux.sh"
$windowsScript = Join-Path $LabDir "conectar_agente_windows.ps1"

# VMs definidas en Servidores\Vagrantfile (ver config.vm.define)
$vms = @(
    @{ Name = "web-server";     Type = "linux"   },
    @{ Name = "windows-dc";     Type = "windows" },
    @{ Name = "dhcpv4-server";  Type = "linux"   },
    @{ Name = "dhcpv6-server";  Type = "linux"   },
    @{ Name = "dns1-server";    Type = "linux"   },
    @{ Name = "dns2-server";    Type = "linux"   },
    @{ Name = "smtp-server";    Type = "linux"   },
    @{ Name = "ntp-server";     Type = "linux"   }
)

Write-Host ""
Write-Host "Conectando $($vms.Count) máquinas de SERVIDORES al SIEM, en paralelo..." -ForegroundColor Cyan

$jobs = foreach ($vm in $vms) {
    $script = if ($vm.Type -eq "linux") { $linuxScript } else { $windowsScript }
    Start-VmJob -VagrantDir $VagrantDir -VmName $vm.Name -Type $vm.Type -ScriptPath $script
}

Wait-AndShowJobs -Jobs $jobs

Write-Host ""
Write-Host "Verifica en el dashboard: https://192.168.30.10 -> Agents" -ForegroundColor Yellow
