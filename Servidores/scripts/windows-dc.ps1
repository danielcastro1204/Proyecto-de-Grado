# =============================================================================
# windows-dc.ps1
# FASE 1 - Controlador de Dominio Windows Server 2019
# =============================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host ""
Write-Host "============================================================"
Write-Host " FASE 1 - CONFIGURACION DEL CONTROLADOR DE DOMINIO"
Write-Host "============================================================"
Write-Host ""


# =============================================================================
# VARIABLES
# =============================================================================

$VM_IP      = if ($env:VM_IP)      { $env:VM_IP }      else { "192.168.10.20" }
$VM_GATEWAY = if ($env:VM_GATEWAY) { $env:VM_GATEWAY } else { "192.168.10.1" }
$SIEM_IP    = if ($env:SIEM_IP)    { $env:SIEM_IP }    else { "192.168.30.10" }
$DOMAIN     = if ($env:DOMAIN)     { $env:DOMAIN }     else { "empresa.local" }

$SUBNET_PREFIX = 24

$HOSTNAME = "dc-empresa"
$NETBIOS  = "EMPRESA"

$SAFE_MODE_PASSWORD = ConvertTo-SecureString "P@ssw0rd" -AsPlainText -Force

Write-Host "IP DC       : $VM_IP"
Write-Host "Gateway     : $VM_GATEWAY"
Write-Host "SIEM        : $SIEM_IP"
Write-Host "Dominio     : $DOMAIN"
Write-Host "Hostname    : $HOSTNAME"
Write-Host ""


# =============================================================================
# VERIFICAR SI AD YA ESTA INSTALADO
# =============================================================================

$adFeature = Get-WindowsFeature -Name AD-Domain-Services

if ($adFeature.Installed) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $currentDomain = Get-ADDomain -ErrorAction Stop

        Write-Host ""
        Write-Host "AD DS ya esta instalado."
        Write-Host "Dominio detectado: $($currentDomain.DNSRoot)"
        Write-Host "No se vuelve a realizar la promocion."
        Write-Host ""
        exit 0
    }
    catch {
        Write-Host "AD DS aparece instalado pero el dominio no esta disponible."
        Write-Host "Se continuara con la configuracion."
    }
}


# =============================================================================
# HOSTNAME
# =============================================================================

Write-Host ""
Write-Host "[1/9] Verificando hostname..."

$currentHostname = $env:COMPUTERNAME

if ($currentHostname -ne $HOSTNAME) {
    Write-Warning "El hostname actual ($currentHostname) no coincide con el esperado ($HOSTNAME)."
    Write-Warning "Windows no permite renombrar y promover a DC en el mismo script sin reiniciar."
    Write-Warning "Por favor, configura 'vm.hostname = ""$HOSTNAME""' en tu Vagrantfile."
    throw "Requisito fallido: El hostname debe ser configurado antes de ejecutar este script."
}
else {
    Write-Host "Hostname validado correctamente: $HOSTNAME"
}


# =============================================================================
# ZONA HORARIA
# =============================================================================

Write-Host ""
Write-Host "[2/9] Configurando zona horaria..."

Set-TimeZone `
    -Id "SA Pacific Standard Time" `
    -ErrorAction Stop

Write-Host "Zona horaria configurada."


# =============================================================================
# NTP
# =============================================================================

Write-Host ""
Write-Host "Configurando NTP..."

try {
    w32tm /config /manualpeerlist:"pool.ntp.org" /syncfromflags:manual /reliable:yes /update | Out-Null
    Restart-Service w32time -Force -ErrorAction SilentlyContinue
    w32tm /resync /force | Out-Null
    Write-Host "NTP configurado."
}
catch {
    Write-Warning "No fue posible sincronizar NTP en este momento."
}


# =============================================================================
# IDENTIFICAR ADAPTADOR DE RED BRIDGE
# =============================================================================

Write-Host ""
Write-Host "[3/9] Identificando adaptador de red..."

$adapters = Get-NetAdapter |
    Where-Object {
        $_.Status -eq "Up"
    }

$bridgeAdapter = $null

# Primero intentamos encontrar el adaptador que NO sea NAT.
foreach ($adapter in $adapters) {
    $ips = Get-NetIPAddress `
        -InterfaceIndex $adapter.ifIndex `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue

    foreach ($ip in $ips) {
        if ($ip.IPAddress -notlike "10.0.2.*") {
            $bridgeAdapter = $adapter
            break
        }
    }
    if ($bridgeAdapter) {
        break
    }
}

# Si no se detectó, usar el adaptador con mayor InterfaceIndex
if (-not $bridgeAdapter) {
    $bridgeAdapter = $adapters |
        Sort-Object InterfaceIndex -Descending |
        Select-Object -First 1
}

if (-not $bridgeAdapter) {
    throw "No se pudo identificar el adaptador de red."
}

$ifIndex = $bridgeAdapter.ifIndex
$ifAlias = $bridgeAdapter.Name

Write-Host "Adaptador seleccionado : $ifAlias"
Write-Host "InterfaceIndex         : $ifIndex"


# =============================================================================
# CONFIGURACION IP
# =============================================================================

Write-Host ""
Write-Host "[4/9] Configurando IP estatica..."

# Eliminar direcciones IPv4 anteriores excepto loopback
Get-NetIPAddress `
    -InterfaceIndex $ifIndex `
    -AddressFamily IPv4 `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.IPAddress -ne "127.0.0.1"
    } |
    Remove-NetIPAddress `
        -Confirm:$false `
        -ErrorAction SilentlyContinue

# Eliminar rutas por defecto anteriores del bridge
Get-NetRoute `
    -InterfaceIndex $ifIndex `
    -AddressFamily IPv4 `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.DestinationPrefix -eq "0.0.0.0/0"
    } |
    Remove-NetRoute `
        -Confirm:$false `
        -ErrorAction SilentlyContinue

# Asignar IP
New-NetIPAddress `
    -InterfaceIndex $ifIndex `
    -IPAddress $VM_IP `
    -PrefixLength $SUBNET_PREFIX `
    -DefaultGateway $VM_GATEWAY `
    -ErrorAction SilentlyContinue

Write-Host "IP configurada: $VM_IP/$SUBNET_PREFIX"
Write-Host "Gateway: $VM_GATEWAY"


# =============================================================================
# DNS TEMPORAL
# =============================================================================

Write-Host ""
Write-Host "Configurando DNS temporal..."

# IMPORTANTE:
# No usamos 127.0.0.1 antes de que exista DNS.
# Usamos DNS publico temporal para que Windows pueda resolver nombres
# durante la instalacion.
Set-DnsClientServerAddress `
    -InterfaceIndex $ifIndex `
    -ServerAddresses @("8.8.8.8", "1.1.1.1") `
    -ErrorAction SilentlyContinue

Write-Host "DNS temporal configurado."


# =============================================================================
# RUTA HACIA VLAN 30
# =============================================================================

Write-Host ""
Write-Host "Configurando ruta hacia VLAN 30..."

try {
    New-NetRoute `
        -DestinationPrefix "192.168.30.0/24" `
        -InterfaceIndex $ifIndex `
        -NextHop $VM_GATEWAY `
        -PolicyStore ActiveStore `
        -ErrorAction SilentlyContinue

    Write-Host "Ruta 192.168.30.0/24 -> $VM_GATEWAY configurada."
}
catch {
    Write-Warning "No se pudo crear la ruta hacia VLAN 30."
}


# =============================================================================
# DESHABILITAR IPV6
# =============================================================================

Write-Host ""
Write-Host "Deshabilitando IPv6 en el adaptador VLAN 10..."

Disable-NetAdapterBinding `
    -Name $ifAlias `
    -ComponentID ms_tcpip6 `
    -ErrorAction SilentlyContinue

Write-Host "IPv6 deshabilitado."


# =============================================================================
# PROBAR CONECTIVIDAD
# =============================================================================

Write-Host ""
Write-Host "Probando conectividad..."

try {
    Test-Connection `
        -ComputerName $VM_GATEWAY `
        -Count 2 `
        -Quiet

    Write-Host "Prueba hacia gateway completada."
}
catch {
    Write-Warning "No fue posible comprobar el gateway."
}


# =============================================================================
# INSTALAR ROLES
# =============================================================================

Write-Host ""
Write-Host "[5/9] Instalando roles y herramientas..."

$features = @(
    "AD-Domain-Services",
    "DNS",
    "RSAT-ADDS",
    "RSAT-AD-Tools",
    "RSAT-DNS-Server"
)

foreach ($feature in $features) {
    Write-Host "Instalando $feature..."
    Install-WindowsFeature `
        -Name $feature `
        -IncludeManagementTools `
        -ErrorAction Stop
}

Write-Host "Roles instalados correctamente."


# =============================================================================
# PROMOVER A CONTROLADOR DE DOMINIO
# =============================================================================

Write-Host ""
Write-Host "[6/9] Promoviendo servidor a Controlador de Dominio..."

Import-Module ADDSDeployment

try {
    Install-ADDSForest `
        -DomainName $DOMAIN `
        -DomainNetbiosName $NETBIOS `
        -DomainMode "WinThreshold" `
        -ForestMode "WinThreshold" `
        -InstallDns:$true `
        -SafeModeAdministratorPassword $SAFE_MODE_PASSWORD `
        -NoRebootOnCompletion:$true `
        -Force:$true

    Write-Host ""
    Write-Host "Promocion a controlador de dominio completada."
}
catch {
    Write-Host ""
    Write-Host "ERROR DURANTE LA PROMOCION:"
    Write-Host $_.Exception.Message
    throw
}


# =============================================================================
# FIREWALL
# =============================================================================

Write-Host ""
Write-Host "[7/9] Configurando Firewall..."

# DNS
New-NetFirewallRule `
    -DisplayName "AD-DNS-TCP" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 53 `
    -Action Allow `
    -ErrorAction SilentlyContinue

New-NetFirewallRule `
    -DisplayName "AD-DNS-UDP" `
    -Direction Inbound `
    -Protocol UDP `
    -LocalPort 53 `
    -Action Allow `
    -ErrorAction SilentlyContinue

# Kerberos
New-NetFirewallRule `
    -DisplayName "AD-Kerberos-TCP" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 88 `
    -Action Allow `
    -ErrorAction SilentlyContinue

New-NetFirewallRule `
    -DisplayName "AD-Kerberos-UDP" `
    -Direction Inbound `
    -Protocol UDP `
    -LocalPort 88 `
    -Action Allow `
    -ErrorAction SilentlyContinue

# LDAP
New-NetFirewallRule `
    -DisplayName "AD-LDAP-TCP" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 389 `
    -Action Allow `
    -ErrorAction SilentlyContinue

New-NetFirewallRule `
    -DisplayName "AD-LDAP-UDP" `
    -Direction Inbound `
    -Protocol UDP `
    -LocalPort 389 `
    -Action Allow `
    -ErrorAction SilentlyContinue

# Global Catalog
New-NetFirewallRule `
    -DisplayName "AD-GC-TCP" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 3268 `
    -Action Allow `
    -ErrorAction SilentlyContinue

New-NetFirewallRule `
    -DisplayName "AD-GC-SSL-TCP" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 3269 `
    -Action Allow `
    -ErrorAction SilentlyContinue

# SMB
New-NetFirewallRule `
    -DisplayName "AD-SMB-TCP" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 445 `
    -Action Allow `
    -ErrorAction SilentlyContinue

# RPC
New-NetFirewallRule `
    -DisplayName "AD-RPC-TCP" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 135 `
    -Action Allow `
    -ErrorAction SilentlyContinue

# Wazuh
New-NetFirewallRule `
    -DisplayName "Wazuh-Agent-1514" `
    -Direction Outbound `
    -Protocol TCP `
    -RemotePort 1514 `
    -Action Allow `
    -ErrorAction SilentlyContinue

New-NetFirewallRule `
    -DisplayName "Wazuh-Agent-1515" `
    -Direction Outbound `
    -Protocol TCP `
    -RemotePort 1515 `
    -Action Allow `
    -ErrorAction SilentlyContinue

New-NetFirewallRule `
    -DisplayName "Wazuh-Agent-1516" `
    -Direction Outbound `
    -Protocol TCP `
    -RemotePort 1516 `
    -Action Allow `
    -ErrorAction SilentlyContinue

Write-Host "Firewall configurado."


# =============================================================================
# AUDITORIA
# =============================================================================

Write-Host ""
Write-Host "[8/9] Configurando auditoria de seguridad..."

auditpol /set /subcategory:"Logon" /success:enable /failure:enable
auditpol /set /subcategory:"Logoff" /success:enable /failure:enable
auditpol /set /subcategory:"Account Lockout" /success:enable /failure:enable
auditpol /set /subcategory:"User Account Management" /success:enable /failure:enable
auditpol /set /subcategory:"Security Group Management" /success:enable /failure:enable
auditpol /set /subcategory:"Process Creation" /success:enable /failure:enable
auditpol /set /subcategory:"Process Termination" /success:enable /failure:enable
auditpol /set /subcategory:"Directory Service Access" /success:enable /failure:enable
auditpol /set /subcategory:"Directory Service Changes" /success:enable /failure:enable

Write-Host "Auditoria configurada."


# =============================================================================
# EVENT LOG
# =============================================================================

Write-Host ""
Write-Host "Configurando Security Event Log..."

wevtutil sl Security /ms:104857600

Write-Host "Security Event Log configurado."


# =============================================================================
# CONFIGURAR DNS DESPUES DE INSTALAR AD
# =============================================================================

Write-Host ""
Write-Host "[9/9] Configurando DNS del controlador..."

try {
    # Ahora que DNS ya existe, podemos apuntar el DC a si mismo.
    Set-DnsClientServerAddress `
        -InterfaceIndex $ifIndex `
        -ServerAddresses @("127.0.0.1") `
        -ErrorAction SilentlyContinue

    Write-Host "DNS del DC configurado hacia 127.0.0.1."
}
catch {
    Write-Warning "No se pudo configurar DNS hacia localhost."
}


# =============================================================================
# FINAL
# =============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " FASE 1 COMPLETADA"
Write-Host "============================================================"
Write-Host ""
Write-Host "Hostname : $HOSTNAME"
Write-Host "IP       : $VM_IP"
Write-Host "Dominio  : $DOMAIN"
Write-Host "NetBIOS  : $NETBIOS"
Write-Host ""
Write-Host "IMPORTANTE:"
Write-Host "El sistema sera reiniciado por vagrant-reload."
Write-Host "No se ejecuta Restart-Computer desde este script."
Write-Host ""