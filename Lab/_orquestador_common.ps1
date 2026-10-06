# =============================================================================
# _orquestador_common.ps1
# Funciones compartidas por los orquestadores de cada carpeta (Gestion,
# Servidores, Workstations). No se ejecuta solo: se importa con "dot-sourcing"
# desde los scripts conectar_todo.ps1 / ejecutar_trafico.ps1 de cada carpeta:
#
#   . "$PSScriptRoot\..\..\Lab\_orquestador_common.ps1"
#
# No depende de carpetas compartidas (/vagrant): el contenido de los scripts
# se lee del propio checkout en el host y se envía por stdin (SSH) o como
# -EncodedCommand en base64 (WinRM), así que funciona aunque
# config.vm.synced_folder esté deshabilitado, como es el caso en este
# proyecto.
# =============================================================================

# Ruta de este propio archivo, capturada de forma robusta en el momento del
# dot-sourcing (NO usar $PSCommandPath dentro de las funciones de abajo: al
# llamarse desde otro script, $PSCommandPath apuntaría al script que LLAMA,
# no a este archivo -- $MyInvocation.MyCommand.Path sí es estable).
$script:ComunPath = $MyInvocation.MyCommand.Path

function Invoke-LinuxVm {
    <#
      Ejecuta un script bash (por contenido, no por ruta dentro de la VM)
      en una VM Linux via "vagrant ssh -c", como root.
    #>
    param(
        [Parameter(Mandatory)] [string]$VagrantDir,
        [Parameter(Mandatory)] [string]$VmName,
        [Parameter(Mandatory)] [string]$ScriptPath,
        [string]$ExtraArgs = ""
    )
    $scriptContent = Get-Content -Raw -Path $ScriptPath
    Push-Location $VagrantDir
    try {
        $scriptContent | & vagrant ssh $VmName -c "sudo bash -s -- $ExtraArgs" 2>&1 |
            ForEach-Object { "[$VmName] $_" }
    } finally {
        Pop-Location
    }
}

function Invoke-WindowsVm {
    <#
      Ejecuta un script PowerShell (por contenido) en una VM Windows via
      "vagrant winrm", usando -EncodedCommand (base64 UTF-16LE) para evitar
      problemas de comillas con scripts largos/multilínea.
    #>
    param(
        [Parameter(Mandatory)] [string]$VagrantDir,
        [Parameter(Mandatory)] [string]$VmName,
        [Parameter(Mandatory)] [string]$ScriptPath
    )
    $scriptContent = Get-Content -Raw -Path $ScriptPath
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($scriptContent)
    $encoded = [Convert]::ToBase64String($bytes)
    $remoteCmd = "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"

    Push-Location $VagrantDir
    try {
        & vagrant winrm -c $remoteCmd $VmName 2>&1 | ForEach-Object { "[$VmName] $_" }
    } finally {
        Pop-Location
    }
}

function Start-VmJob {
    <#
      Lanza Invoke-LinuxVm o Invoke-WindowsVm como un Job en segundo plano,
      para poder correr todas las VMs de una carpeta EN PARALELO.
    #>
    param(
        [Parameter(Mandatory)] [string]$VagrantDir,
        [Parameter(Mandatory)] [string]$VmName,
        [Parameter(Mandatory)] [ValidateSet("linux","windows")] [string]$Type,
        [Parameter(Mandatory)] [string]$ScriptPath,
        [string]$ExtraArgs = ""
    )
    return Start-Job -Name $VmName -ScriptBlock {
        param($dir, $name, $type, $path, $args_, $commonPath)
        . $commonPath
        if ($type -eq "linux") {
            Invoke-LinuxVm -VagrantDir $dir -VmName $name -ScriptPath $path -ExtraArgs $args_
        } else {
            Invoke-WindowsVm -VagrantDir $dir -VmName $name -ScriptPath $path
        }
    } -ArgumentList $VagrantDir, $VmName, $Type, $ScriptPath, $ExtraArgs, $script:ComunPath
}

function Wait-AndShowJobs {
    <#
      Espera a que todos los Jobs lanzados terminen, imprime su salida en
      vivo según van llegando, y al final muestra un resumen OK/FALLÓ por VM.
    #>
    param([Parameter(Mandatory)] [System.Management.Automation.Job[]]$Jobs)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Ejecutando en paralelo en $($Jobs.Count) máquina(s)..." -ForegroundColor Cyan
    Write-Host "  (esto puede tardar varios minutos, es normal)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    while ($Jobs | Where-Object { $_.State -eq "Running" }) {
        $Jobs | Receive-Job | ForEach-Object { Write-Host $_ }
        Start-Sleep -Seconds 2
    }
    $Jobs | Receive-Job | ForEach-Object { Write-Host $_ }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  RESUMEN" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    foreach ($j in $Jobs) {
        $status = if ($j.State -eq "Completed") { "[OK]" } else { "[FAIL] $($j.State)" }
        $color = if ($j.State -eq "Completed") { "Green" } else { "Red" }
        Write-Host ("  {0,-20} {1}" -f $j.Name, $status) -ForegroundColor $color
    }
    $Jobs | Remove-Job -Force
}
