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

# ---- Dual-stack: direccionamiento IPv6 (VLAN10 - fd00:10::/64, segun topologia) ----
$VM_IP6      = if ($env:VM_IP6)      { $env:VM_IP6 }      else { "fd00:10::20" }
$VM_GATEWAY6 = if ($env:VM_GATEWAY6) { $env:VM_GATEWAY6 } else { "fd00:10::1" }
$PREFIX6     = 64

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
# FUNCION: DUAL-STACK IPv6 (autocontenida e idempotente)
#
# Se llama en 3 puntos del script:
#   1) Antes del "exit 0" si AD ya estaba instalado (retrofit en un DC
#      que ya funciona, ej. al correr "vagrant provision windows-dc").
#   2) En el flujo normal de un DC nuevo, en el lugar donde antes se
#      DESHABILITABA IPv6.
#   3) Al final, justo cuando ya existe el rol DNS, para poder registrar
#      los AAAA (en los dos primeros puntos el rol DNS puede no estar listo
#      y esa parte simplemente se omite sin error).
# =============================================================================

function Set-DualStackIPv6 {
    param(
        [string]$Ip6Address,
        [string]$Gateway6,
        [int]$Prefix6 = 64,
        [string]$Domain,
        [switch]$TryRegisterAAAA
    )

    Write-Host ""
    Write-Host "Configurando IPv6 dual-stack ($Ip6Address/$Prefix6 via $Gateway6)..."

    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    $bridgeAdapter = $null

    foreach ($adapter in $adapters) {
        $ips4 = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        foreach ($ip in $ips4) {
            if ($ip.IPAddress -notlike "10.0.2.*") {
                $bridgeAdapter = $adapter
                break
            }
        }
        if ($bridgeAdapter) { break }
    }
    if (-not $bridgeAdapter) {
        $bridgeAdapter = $adapters | Sort-Object InterfaceIndex -Descending | Select-Object -First 1
    }
    if (-not $bridgeAdapter) {
        Write-Warning "No se pudo identificar el adaptador para configurar IPv6."
        return
    }

    $ifIndex = $bridgeAdapter.ifIndex
    $ifAlias = $bridgeAdapter.Name

    # Re-habilitar IPv6 en el adaptador (por si una corrida anterior lo deshabilito)
    Enable-NetAdapterBinding -Name $ifAlias -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Quitar una asignacion previa identica antes de re-crearla (idempotente)
    Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $Ip6Address } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    Get-NetRoute -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq "::/0" } |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress `
        -InterfaceIndex $ifIndex `
        -AddressFamily IPv6 `
        -IPAddress $Ip6Address `
        -PrefixLength $Prefix6 `
        -DefaultGateway $Gateway6 `
        -ErrorAction SilentlyContinue | Out-Null

    Write-Host "IPv6 configurada: $Ip6Address/$Prefix6 via $Gateway6 en $ifAlias"

    # Ruta hacia VLAN 30 (gestion) tambien por IPv6, igual que ya existe para IPv4
    try {
        New-NetRoute `
            -DestinationPrefix "fd00:30::/64" `
            -InterfaceIndex $ifIndex `
            -AddressFamily IPv6 `
            -NextHop $Gateway6 `
            -PolicyStore ActiveStore `
            -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        # No es critico; puede ya existir.
    }

    # Agregar "::1" al DNS del adaptador SIN quitar el/los DNS IPv4 existentes
    try {
        $existingV4Dns = (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        if (-not $existingV4Dns -or $existingV4Dns.Count -eq 0) { $existingV4Dns = @("127.0.0.1") }
        $combinedDns = @($existingV4Dns) + @("::1")
        Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $combinedDns -ErrorAction SilentlyContinue
        Write-Host "DNS del adaptador (dual-stack): $($combinedDns -join ', ')"
    }
    catch {
        Write-Warning "No se pudo ajustar el DNS dual-stack del adaptador."
    }

    # Registrar AAAA en la zona del dominio (solo si el rol DNS ya existe; si no, se omite sin error)
    if ($TryRegisterAAAA) {
        try {
            Import-Module DnsServer -ErrorAction Stop

            $records = @{
                "dc-empresa" = $Ip6Address
                "web-server" = "fd00:10::10"
            }

            foreach ($name in $records.Keys) {
                $addr = $records[$name]
                $exists = Get-DnsServerResourceRecord -ZoneName $Domain -Name $name -RRType AAAA -ErrorAction SilentlyContinue |
                    Where-Object { $_.RecordData.IPv6Address.IPAddressToString -eq $addr }

                if (-not $exists) {
                    Add-DnsServerResourceRecordAAAA -ZoneName $Domain -Name $name -IPv6Address $addr -ErrorAction SilentlyContinue
                    Write-Host "  AAAA agregado: $name.$Domain -> $addr"
                }
                else {
                    Write-Host "  AAAA ya existia: $name.$Domain -> $addr"
                }
            }
        }
        catch {
            Write-Host "  (Rol DNS aun no disponible; los registros AAAA se intentaran mas adelante en el aprovisionamiento)"
        }
    }
}


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

        # Retrofit dual-stack: aunque no se repromueva el DC, si se asegura
        # que tenga IPv6 configurado (por si viene de una corrida anterior
        # sin dual-stack, o de "vagrant provision windows-dc").
        Set-DualStackIPv6 -Ip6Address $VM_IP6 -Gateway6 $VM_GATEWAY6 -Prefix6 $PREFIX6 -Domain $DOMAIN -TryRegisterAAAA

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
# CONFIGURAR IPv6 (DUAL-STACK)
# =============================================================================

Set-DualStackIPv6 -Ip6Address $VM_IP6 -Gateway6 $VM_GATEWAY6 -Prefix6 $PREFIX6 -Domain $DOMAIN


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
    # Ahora que DNS ya existe, podemos apuntar el DC a si mismo (dual-stack).
    Set-DnsClientServerAddress `
        -InterfaceIndex $ifIndex `
        -ServerAddresses @("127.0.0.1", "::1") `
        -ErrorAction SilentlyContinue

    Write-Host "DNS del DC configurado hacia 127.0.0.1 y ::1."
}
catch {
    Write-Warning "No se pudo configurar DNS hacia localhost."
}

# Con el rol DNS ya instalado y promovido, este es el punto correcto para
# registrar los AAAA de forma definitiva.
Set-DualStackIPv6 -Ip6Address $VM_IP6 -Gateway6 $VM_GATEWAY6 -Prefix6 $PREFIX6 -Domain $DOMAIN -TryRegisterAAAA


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
Write-Host "IPv6     : $VM_IP6"
Write-Host "Dominio  : $DOMAIN"
Write-Host "NetBIOS  : $NETBIOS"
Write-Host ""
Write-Host "IMPORTANTE:"
Write-Host "El sistema sera reiniciado por vagrant-reload."
Write-Host "No se ejecuta Restart-Computer desde este script."
Write-Host ""