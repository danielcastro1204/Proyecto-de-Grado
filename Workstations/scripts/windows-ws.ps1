# =============================================================================
# windows-ws.ps1 — FASE 1: Configuración de red, hostname y unión al dominio
# =============================================================================
# Variables de entorno esperadas (inyectadas por Vagrant):
#   VM_IP             - IP estática de la máquina (ej: 192.168.20.30)
#   VM_HOSTNAME       - Nombre del equipo (ej: win10-01)
#   VM_GW             - Gateway (192.168.20.1)
#   VM_DNS            - DNS / IP del DC (192.168.10.20)
#   DOMAIN_ADMIN_PASS - Contraseña del Admin del dominio
#   WAZUH_MANAGER_IP  - IP del manager Wazuh (192.168.30.10)
# =============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'  # Acelera downloads

# ---- Leer variables de entorno ----
$VM_IP            = $env:VM_IP
$VM_HOSTNAME      = $env:VM_HOSTNAME
$VM_GW            = $env:VM_GW
$VM_DNS           = $env:VM_DNS
$DOMAIN_ADMIN_PASS = $env:DOMAIN_ADMIN_PASS
$WAZUH_MANAGER_IP = $env:WAZUH_MANAGER_IP
$DOMAIN_NAME      = "empresa.local"
$DOMAIN_ADMIN     = "Administrator"

Write-Host "============================================================"
Write-Host " FASE 1 | $VM_HOSTNAME | IP: $VM_IP"
Write-Host "============================================================"

# ============================================================
# 1. CONFIGURAR IP ESTÁTICA
# ============================================================
Write-Host "[1/5] Configurando IP estática $VM_IP en la interfaz puente..."

# Identificar el adaptador de red correcto (el que NO tiene IP 10.x — evitar NAT de Vagrant)
$adapter = Get-NetAdapter | Where-Object {
    $_.Status -eq 'Up' -and $_.Name -notmatch 'Loopback'
} | Where-Object {
    # Excluir la interfaz NAT de Vagrant (usualmente 10.0.2.x)
    -not ((Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue) |
          Where-Object { $_.IPAddress -like "10.0.2.*" })
} | Select-Object -First 1

if (-not $adapter) {
    # Fallback: tomar el adaptador con nombre "Ethernet 2" o similar (bridge)
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } |
               Sort-Object -Property ifIndex -Descending | Select-Object -First 1
}

$iface = $adapter.Name
Write-Host "   Adaptador seleccionado: $iface (index: $($adapter.ifIndex))"

# Eliminar IP existente en ese adaptador para evitar duplicados
Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-NetIPAddress -IPAddress $_.IPAddress -Confirm:$false -ErrorAction SilentlyContinue }

# Eliminar ruta de gateway existente
Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

# Asignar nueva IP
New-NetIPAddress `
    -InterfaceAlias $iface `
    -IPAddress      $VM_IP `
    -PrefixLength   24 `
    -DefaultGateway $VM_GW

# Configurar DNS
Set-DnsClientServerAddress `
    -InterfaceAlias   $iface `
    -ServerAddresses  $VM_DNS

Write-Host "   IP $VM_IP/24 configurada. Gateway: $VM_GW  DNS: $VM_DNS"

# ============================================================
# 2. CONFIGURAR HOSTNAME
# ============================================================
Write-Host "[2/5] Verificando hostname..."
$currentName = $env:COMPUTERNAME
if ($currentName -ne $VM_HOSTNAME) {
    Write-Host "   Renombrando equipo de '$currentName' a '$VM_HOSTNAME'..."
    Rename-Computer -NewName $VM_HOSTNAME -Force
    Write-Host "   Hostname actualizado (requiere reinicio para aplicar completamente)."
} else {
    Write-Host "   Hostname ya es '$VM_HOSTNAME'. Sin cambios."
}

# ============================================================
# 3. HABILITAR AUDITORÍA DE SEGURIDAD AVANZADA
# ============================================================
Write-Host "[3/5] Habilitando auditoría de seguridad avanzada..."

$auditCategories = @(
    "Account Logon",
    "Account Management",
    "Detailed Tracking",
    "Logon/Logoff",
    "Object Access",
    "Policy Change",
    "Privilege Use",
    "System"
)
foreach ($cat in $auditCategories) {
    auditpol /set /category:"$cat" /success:enable /failure:enable 2>$null
}
Write-Host "   Auditoría configurada."

# ============================================================
# 4. CONFIGURAR FIREWALL (reglas para agentes SIEM y dominio)
# ============================================================
Write-Host "[4/5] Configurando reglas de Firewall..."

$fwRules = @(
    @{ Name="Wazuh-Agent-Out-1514"; Dir="Outbound"; Port=1514; Protocol="TCP" },
    @{ Name="Wazuh-Agent-Out-1515"; Dir="Outbound"; Port=1515; Protocol="TCP" },
    @{ Name="Wazuh-Agent-Out-1516"; Dir="Outbound"; Port=1516; Protocol="TCP" },
    @{ Name="Wazuh-Agent-Out-UDP";  Dir="Outbound"; Port=1514; Protocol="UDP" },
    @{ Name="Domain-DNS-Out";       Dir="Outbound"; Port=53;   Protocol="UDP" },
    @{ Name="Domain-Kerberos-Out";  Dir="Outbound"; Port=88;   Protocol="TCP" },
    @{ Name="Domain-LDAP-Out";      Dir="Outbound"; Port=389;  Protocol="TCP" },
    @{ Name="Domain-SMB-Out";       Dir="Outbound"; Port=445;  Protocol="TCP" },
    @{ Name="Domain-RPC-Out";       Dir="Outbound"; Port=135;  Protocol="TCP" }
)

foreach ($rule in $fwRules) {
    $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule `
            -DisplayName  $rule.Name `
            -Direction    $rule.Dir `
            -Protocol     $rule.Protocol `
            -LocalPort    $rule.Port `
            -Action       Allow `
            -Enabled      True | Out-Null
        Write-Host "   Regla creada: $($rule.Name)"
    } else {
        Write-Host "   Regla ya existe: $($rule.Name)"
    }
}

# ============================================================
# 5. UNIRSE AL DOMINIO empresa.local
# ============================================================
Write-Host "[5/5] Verificando membresía al dominio '$DOMAIN_NAME'..."

$computerInfo = Get-WmiObject Win32_ComputerSystem
if ($computerInfo.PartOfDomain -and $computerInfo.Domain -eq $DOMAIN_NAME) {
    Write-Host "   La máquina ya pertenece al dominio '$DOMAIN_NAME'. Saltando unión."
} else {
    Write-Host "   Uniendo al dominio '$DOMAIN_NAME' con credenciales de $DOMAIN_ADMIN..."

    # Verificar conectividad al DC antes de unirse
    $pingResult = Test-Connection -ComputerName $VM_DNS -Count 2 -Quiet
    if (-not $pingResult) {
        Write-Warning "ADVERTENCIA: No se puede alcanzar el DC en $VM_DNS."
        Write-Warning "Asegúrate de que el equipo del Integrante B esté encendido y operativo."
        Write-Warning "El aprovisionamiento continuará pero la unión al dominio puede fallar."
    }

    $securePass = ConvertTo-SecureString $DOMAIN_ADMIN_PASS -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential(
        "$DOMAIN_ADMIN@$DOMAIN_NAME",
        $securePass
    )

    try {
        Add-Computer `
            -DomainName   $DOMAIN_NAME `
            -Credential   $credential `
            -OUPath       "OU=Computers,DC=empresa,DC=local" `
            -Force `
            -ErrorAction  Stop
        Write-Host "   ¡Unión al dominio exitosa! Se reiniciará para aplicar cambios."
    } catch {
        Write-Warning "No se pudo unir con OU personalizada. Intentando unión estándar..."
        Add-Computer `
            -DomainName  $DOMAIN_NAME `
            -Credential  $credential `
            -Force
        Write-Host "   Unión al dominio completada (OU estándar)."
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host " FASE 1 COMPLETADA — El sistema se reiniciará ahora."
Write-Host " Vagrant continuará automáticamente con la FASE 2."
Write-Host "============================================================"
