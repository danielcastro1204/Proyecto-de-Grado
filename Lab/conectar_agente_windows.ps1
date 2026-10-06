# =============================================================================
# conectar_agente_windows.ps1 — UNIVERSAL para toda VM Windows del laboratorio
# (windows-dc, win10-01, win10-02)
#
# QUÉ CORRIGE (misma causa raíz que en Linux, pero en Windows):
#   El adaptador NAT de Vagrant y el adaptador puente (VLAN real) a veces
#   reciben el mismo "Automatic metric" calculado por Windows según la
#   velocidad del enlace -- ambos adaptadores suelen reportar velocidades
#   parecidas, así que Windows puede preferir el NAT para la ruta 0.0.0.0/0,
#   que no tiene camino hacia las otras VLAN. Resultado: sin conectividad
#   real hacia el SIEM aunque la IP estática esté bien puesta.
#
# CORRECCIÓN:
#   1. Detecta el adaptador NAT (IP 10.0.2.x) y le fuerza un metric muy alto
#      (9999) -- lo deja utilizable pero nunca preferido.
#   2. Detecta el adaptador puente (IP 192.168.x.x) y le fuerza un metric
#      bajo (10), garantizando que siempre gane para cualquier ruta.
#
# Luego: instala (si falta) y registra el agente Wazuh contra el SIEM
# (192.168.30.10), de forma idempotente.
#
# USO (desde el host, sin carpeta compartida, via WinRM):
#   Ver Lab/conectar_todo.ps1 en cada carpeta (Servidores / Workstations),
#   que ya hace el envío de este script automáticamente.
#
# Ejecución manual directa (si hace falta depurar a mano):
#   vagrant powershell -c "<pegar contenido o usar -EncodedCommand>" <vm>
# =============================================================================

$ErrorActionPreference = "Stop"
$SIEM_IP = "192.168.30.10"
$HOSTNAME_VM = $env:COMPUTERNAME

function Write-Info($m)  { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok($m)    { Write-Host "[OK]   $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err2($m)  { Write-Host "[ERROR] $m" -ForegroundColor Red }

Write-Host ""
Write-Host "============================================================"
Write-Host "  Corrigiendo red + conectando agente Wazuh: $HOSTNAME_VM"
Write-Host "============================================================"

# =============================================================================
# PARTE 1 — Corregir métricas de interfaz (NAT vs. puente)
# =============================================================================

Write-Info "Detectando adaptadores de red..."

$allAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
$natAdapter = $null
$bridgeAdapter = $null
$bridgeIp = $null

foreach ($adapter in $allAdapters) {
    $ips = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    foreach ($ip in $ips) {
        if ($ip.IPAddress -like "10.0.2.*") {
            $natAdapter = $adapter
        } elseif ($ip.IPAddress -like "192.168.*") {
            $bridgeAdapter = $adapter
            $bridgeIp = $ip.IPAddress
        }
    }
}

if (-not $bridgeAdapter) {
    Write-Err2 "No se detectó el adaptador puente (IP 192.168.x.x). Abortando."
    exit 1
}

if (-not $natAdapter) {
    Write-Warn2 "No se detectó adaptador NAT (10.0.2.x). Puede que ya esté corregido."
}

$octets = $bridgeIp.Split(".")
$gateway = "$($octets[0]).$($octets[1]).$($octets[2]).1"

Write-Info "Puente (VLAN real) : $($bridgeAdapter.Name) ($bridgeIp) -> metric 10"
if ($natAdapter) {
    Write-Info "NAT (a deprizar)   : $($natAdapter.Name) -> metric 9999"
}
Write-Info "Gateway calculado  : $gateway"

# ---- 1a. Metric bajo y fijo en el adaptador puente -------------------------
Set-NetIPInterface -InterfaceIndex $bridgeAdapter.ifIndex -AddressFamily IPv4 `
    -InterfaceMetric 10 -ErrorAction SilentlyContinue
Write-Ok "Metric del adaptador puente fijado a 10."

# Asegurar que exista una ruta por defecto explícita por el puente
Get-NetRoute -InterfaceIndex $bridgeAdapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

New-NetRoute -InterfaceIndex $bridgeAdapter.ifIndex -DestinationPrefix "0.0.0.0/0" `
    -NextHop $gateway -RouteMetric 10 -ErrorAction SilentlyContinue | Out-Null
Write-Ok "Ruta por defecto explícita agregada vía $gateway."

# ---- 1b. Metric muy alto (deprioridad) en el adaptador NAT -----------------
if ($natAdapter) {
    Set-NetIPInterface -InterfaceIndex $natAdapter.ifIndex -AddressFamily IPv4 `
        -InterfaceMetric 9999 -ErrorAction SilentlyContinue
    Write-Ok "Metric del adaptador NAT fijado a 9999 (deprioritizado)."
}

Start-Sleep -Seconds 2

# ---- 1c. Verificar ----------------------------------------------------------
Write-Host ""
Write-Info "Rutas 0.0.0.0/0 actuales (ordenadas por metric efectivo):"
Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric |
    Format-Table ifIndex, InterfaceAlias, NextHop, RouteMetric -AutoSize | Out-String | Write-Host

# ---- 1d. Probar conectividad real hacia el SIEM ----------------------------
$pingOk = Test-Connection -ComputerName $SIEM_IP -Count 2 -Quiet -ErrorAction SilentlyContinue
if ($pingOk) {
    Write-Ok "Ping a SIEM ($SIEM_IP) exitoso."
} else {
    Write-Err2 "Sin ping al SIEM ($SIEM_IP) incluso después de corregir rutas."
    Write-Err2 "Verifica el router, los switches y que la VM del SIEM esté levantada."
    exit 1
}

# =============================================================================
# PARTE 2 — Instalar / conectar el agente Wazuh
# =============================================================================
Write-Host ""
Write-Info "Configurando agente Wazuh..."

$ossecConf = "C:\Program Files (x86)\ossec-agent\ossec.conf"
$wazuhInstalled = Test-Path "C:\Program Files (x86)\ossec-agent\wazuh-agent.exe"

if (-not $wazuhInstalled) {
    Write-Info "wazuh-agent no está instalado. Instalando..."
    $msiUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.9.2-1.msi"
    $msiPath = "$env:TEMP\wazuh-agent.msi"
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /q WAZUH_MANAGER=`"$SIEM_IP`" WAZUH_REGISTRATION_SERVER=`"$SIEM_IP`" WAZUH_AGENT_NAME=`"$HOSTNAME_VM`"" -Wait
    Write-Ok "wazuh-agent instalado."
} else {
    Write-Ok "wazuh-agent ya estaba instalado."
}

# Verificar puerto de enrollment
$tcp = Test-NetConnection -ComputerName $SIEM_IP -Port 1515 -WarningAction SilentlyContinue
if (-not $tcp.TcpTestSucceeded) {
    Write-Err2 "Puerto 1515 (enrollment) no accesible en $SIEM_IP."
    Write-Err2 "Corre primero el fix del lado del SIEM: 00_fix_agentes_wazuh.sh"
    exit 1
}

# Corregir manager en ossec.conf
if (Test-Path $ossecConf) {
    (Get-Content $ossecConf) -replace '<address>.*</address>', "<address>$SIEM_IP</address>" |
        Set-Content $ossecConf
    Write-Ok "ossec.conf apunta a $SIEM_IP."
}

Write-Info "Re-enrollment (clave limpia) contra $SIEM_IP..."
Stop-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Remove-Item "C:\Program Files (x86)\ossec-agent\client.keys" -ErrorAction SilentlyContinue

$agentAuth = "C:\Program Files (x86)\ossec-agent\agent-auth.exe"
& $agentAuth -m $SIEM_IP -p 1515 -A $HOSTNAME_VM 2>&1 | Tee-Object -FilePath "$env:TEMP\wazuh_enroll.log"

Start-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
Set-Service -Name "WazuhSvc" -StartupType Automatic -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4

$svc = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-Ok "WazuhSvc ACTIVO en $HOSTNAME_VM."
} else {
    Write-Err2 "WazuhSvc no está corriendo. Revisar C:\Program Files (x86)\ossec-agent\ossec.log"
    exit 1
}

Write-Host ""
Write-Host "============================================================"
Write-Ok "$HOSTNAME_VM : red corregida y agente Wazuh conectado."
Write-Host "============================================================"
