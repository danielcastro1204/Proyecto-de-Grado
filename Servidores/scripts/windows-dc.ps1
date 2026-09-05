# =============================================================================
# windows-dc.ps1  |  FASE 1 - Controlador de Dominio
# Proyecto SIEM - Integrante B | VLAN 10 | 192.168.10.20
# =============================================================================
# Este script se ejecuta ANTES del primer reinicio. Realiza:
#   1. Configuración de hostname y zona horaria (NTP requiere internet)
#   2. Asignación de IP fija (192.168.10.20/24) en el adaptador puente
#   3. Instalación de AD DS + DNS (requiere internet si es primera vez)
#   4. Promoción del servidor como Controlador de Dominio (empresa.local)
#
# REQUISITO: El Router Cisco ISR4321 debe estar activo en 192.168.10.1
#            para que pueda alcanzar internet (NTP, descargas, etc.)
# (El reinicio lo gestiona el plugin vagrant-reload del Vagrantfile)
# =============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Acelera Invoke-WebRequest

# ---------------------------------------------------------------------------
# VARIABLES GLOBALES - Inyectadas desde el Vagrantfile
# ---------------------------------------------------------------------------
$VM_IP          = $env:VM_IP           # Por defecto: 192.168.10.20
$VM_GATEWAY     = $env:VM_GATEWAY      # Por defecto: 192.168.10.1
$SIEM_IP        = $env:SIEM_IP         # Por defecto: 192.168.30.10 (VLAN 30)
$DOMAIN_NAME    = $env:DOMAIN          # Por defecto: empresa.local

$DC_IP          = if ($VM_IP) { $VM_IP } else { "192.168.10.20" }
$DC_SUBNET      = 24
$DC_GATEWAY     = if ($VM_GATEWAY) { $VM_GATEWAY } else { "192.168.10.1" }
$DC_DNS_SELF    = "127.0.0.1"
$NETBIOS_NAME   = "EMPRESA"
$SAFEMODE_PASS  = ConvertTo-SecureString "P@ssw0rd" -AsPlainText -Force
$HOSTNAME       = "dc-empresa"

# ---------------------------------------------------------------------------
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " FASE 1: Instalacion del Controlador de Dominio" -ForegroundColor Cyan
Write-Host " Dominio: $DOMAIN_NAME  |  IP: $DC_IP" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan


# ===========================================================================
# PASO 1: Verificar si AD ya fue instalado (idempotencia)
# Si ya existe NTDS, este script no vuelve a promover el servidor.
# ===========================================================================
if (Test-Path "C:\Windows\NTDS") {
    Write-Host "[SKIP] AD DS ya esta instalado (C:\Windows\NTDS existe). Saltando Fase 1." -ForegroundColor Yellow
    exit 0
}


# ===========================================================================
# PASO 2: Zona horaria y configuracion regional
# ===========================================================================
Write-Host "`n[PASO 2] Configurando zona horaria..." -ForegroundColor Green
try {
    Set-TimeZone -Id "SA Pacific Standard Time"   # UTC-5, Colombia
} catch {
    Write-Host "  [WARN] No se pudo establecer la zona horaria: $_" -ForegroundColor Yellow
}

# Sincronizar tiempo con un servidor NTP externo (requiere internet temporal)
w32tm /config /manualpeerlist:"pool.ntp.org" /syncfromflags:manual /reliable:YES /update | Out-Null
try {
    Restart-Service w32time -Force | Out-Null
    w32tm /resync /nowait | Out-Null
} catch {
    Write-Host "  [WARN] No se pudo sincronizar NTP: $_" -ForegroundColor Yellow
}
Write-Host "  Zona horaria configurada: SA Pacific Standard Time (UTC-5)"


# ===========================================================================
# PASO 3: Configurar IP fija en el adaptador puente (VLAN 10)
# El adaptador NAT de Vagrant (Ethernet 0) se deja intacto para que
# Vagrant pueda seguir comunicándose vía WinRM.
# El adaptador puente suele ser el segundo (InterfaceIndex mayor o nombre).
# ===========================================================================
Write-Host "`n[PASO 3] Configurando IP fija $DC_IP/$DC_SUBNET en adaptador puente..." -ForegroundColor Green

# Identificar el adaptador que NO es el de NAT de Vagrant.
# El adaptador NAT de Vagrant siempre tiene la IP 10.0.2.15
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
$bridgeAdapter = $null

foreach ($adapter in $adapters) {
    $ipInfo = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ipInfo -and $ipInfo.IPAddress -notmatch "^10\.0\.2\." -and $ipInfo.IPAddress -ne $DC_IP) {
        $bridgeAdapter = $adapter
        break
    }
    # Si no tiene IP asignada aún, también puede ser el adaptador puente
    if (-not $ipInfo) {
        $bridgeAdapter = $adapter
        break
    }
}

# Fallback: buscar el adaptador con el índice de interfaz más alto (el puente)
if (-not $bridgeAdapter) {
    $bridgeAdapter = $adapters | Sort-Object InterfaceIndex -Descending | Select-Object -First 1
}

$ifIndex = $bridgeAdapter.InterfaceIndex
Write-Host "  Adaptador seleccionado: '$($bridgeAdapter.Name)' (Index: $ifIndex)"

# Verificar si la IP ya está configurada
$existingIP = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -eq $DC_IP }

if (-not $existingIP) {
    # Eliminar IPs previas en ese adaptador para evitar conflictos
    $oldIPs = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    foreach ($old in $oldIPs) {
        if ($old.PrefixOrigin -ne 'WellKnown') {
            Remove-NetIPAddress -InputObject $old -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    # Eliminar rutas del gateway anteriores en este adaptador
    Remove-NetRoute -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue

    # Asignar IP fija
    New-NetIPAddress `
        -InterfaceIndex  $ifIndex `
        -IPAddress       $DC_IP `
        -PrefixLength    $DC_SUBNET `
        -DefaultGateway  $DC_GATEWAY
    Write-Host "  IP $DC_IP/$DC_SUBNET asignada. Gateway: $DC_GATEWAY"
} else {
    Write-Host "  [SKIP] IP $DC_IP ya estaba configurada."
}

# Configurar DNS (apuntarse a sí mismo)
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $DC_DNS_SELF
Write-Host "  DNS primario configurado: $DC_DNS_SELF"


# ===========================================================================
# PASO 4: Deshabilitar IPv6 en el adaptador puente (reduce ruido en logs)
# ===========================================================================
Write-Host "`n[PASO 4] Deshabilitando IPv6 en adaptador puente..." -ForegroundColor Green
Disable-NetAdapterBinding -InterfaceAlias $bridgeAdapter.Name -ComponentID "ms_tcpip6" -ErrorAction SilentlyContinue
Write-Host "  IPv6 deshabilitado en '$($bridgeAdapter.Name)'"


# ===========================================================================
# PASO 5: Instalar roles de Windows (AD DS + DNS + herramientas)
# ===========================================================================
Write-Host "`n[PASO 5] Instalando roles: AD-Domain-Services, DNS, RSAT-ADDS..." -ForegroundColor Green

$features = @(
    "AD-Domain-Services",
    "DNS",
    "RSAT-ADDS",
    "RSAT-AD-Tools",
    "RSAT-DNS-Server"
)

$installResult = Install-WindowsFeature -Name $features -IncludeManagementTools
if ($installResult.Success) {
    Write-Host "  Roles instalados correctamente."
} else {
    Write-Host "  [ERROR] Fallo al instalar roles de Windows." -ForegroundColor Red
    throw "Fallo instalacion de roles."
}


# ===========================================================================
# PASO 6: Promover el servidor a Controlador de Dominio
# Crea un nuevo bosque con el dominio empresa.local
# ===========================================================================
Write-Host "`n[PASO 6] Promoviendo a Controlador de Dominio (bosque: $DOMAIN_NAME)..." -ForegroundColor Green

Import-Module ADDSDeployment

$dcParams = @{
    DomainName                    = $DOMAIN_NAME
    DomainNetbiosName             = $NETBIOS_NAME
    DomainMode                    = "WinThreshold"      # Windows Server 2016+
    ForestMode                    = "WinThreshold"
    SafeModeAdministratorPassword = $SAFEMODE_PASS
    InstallDns                    = $true
    CreateDnsDelegation           = $false
    DatabasePath                  = "C:\Windows\NTDS"
    LogPath                       = "C:\Windows\NTDS"
    SysvolPath                    = "C:\Windows\SYSVOL"
    NoRebootOnCompletion          = $true    # vagrant-reload maneja el reinicio
    Force                         = $true
}

try {
    Install-ADDSForest @dcParams
    Write-Host "  Promocion a DC completada. El servidor se reiniciara ahora." -ForegroundColor Green
} catch {
    # Install-ADDSForest puede lanzar excepcion incluso con exito (bug conocido)
    if ($_ -match "computer must be restarted" -or $_ -match "The system will restart") {
        Write-Host "  Promocion completada. Reinicio pendiente (esperado)." -ForegroundColor Green
    } else {
        Write-Host "  [ERROR] Fallo la promocion: $_" -ForegroundColor Red
        throw $_
    }
}


# ===========================================================================
# PASO 7: Configurar reglas de firewall necesarias para VLAN 10
# (Kerberos, DNS, SMB, RPC, WinRM, y puertos del agente Wazuh)
# ===========================================================================
Write-Host "`n[PASO 7] Configurando reglas de firewall..." -ForegroundColor Green

$firewallRules = @(
    @{ Name="AD-Kerberos-TCP";    Protocol="TCP"; LocalPort=88;   Dir="Inbound"; Desc="Kerberos TCP" },
    @{ Name="AD-Kerberos-UDP";    Protocol="UDP"; LocalPort=88;   Dir="Inbound"; Desc="Kerberos UDP" },
    @{ Name="AD-DNS-TCP";         Protocol="TCP"; LocalPort=53;   Dir="Inbound"; Desc="DNS TCP" },
    @{ Name="AD-DNS-UDP";         Protocol="UDP"; LocalPort=53;   Dir="Inbound"; Desc="DNS UDP" },
    @{ Name="AD-LDAP";            Protocol="TCP"; LocalPort=389;  Dir="Inbound"; Desc="LDAP" },
    @{ Name="AD-LDAPS";           Protocol="TCP"; LocalPort=636;  Dir="Inbound"; Desc="LDAP SSL" },
    @{ Name="AD-GC";              Protocol="TCP"; LocalPort=3268; Dir="Inbound"; Desc="Global Catalog" },
    @{ Name="AD-SMB";             Protocol="TCP"; LocalPort=445;  Dir="Inbound"; Desc="SMB" },
    @{ Name="AD-RPC";             Protocol="TCP"; LocalPort=135;  Dir="Inbound"; Desc="RPC Endpoint Mapper" },
    @{ Name="Wazuh-Agent-Out-1";  Protocol="TCP"; LocalPort=1514; Dir="Outbound"; Desc="Wazuh agente (logs)" },
    @{ Name="Wazuh-Agent-Out-2";  Protocol="TCP"; LocalPort=1515; Dir="Outbound"; Desc="Wazuh agente (registro)" },
    @{ Name="Wazuh-Agent-Out-3";  Protocol="TCP"; LocalPort=1516; Dir="Outbound"; Desc="Wazuh agente (control)" }
)

foreach ($rule in $firewallRules) {
    $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule `
            -DisplayName  $rule.Name `
            -Direction    $rule.Dir `
            -Protocol     $rule.Protocol `
            -LocalPort    $rule.LocalPort `
            -Action       "Allow" `
            -Description  $rule.Desc `
            -Enabled      True | Out-Null
        Write-Host "  Regla creada: $($rule.Name) ($($rule.Dir) $($rule.Protocol):$($rule.LocalPort))"
    } else {
        Write-Host "  [SKIP] Regla ya existe: $($rule.Name)"
    }
}


# ===========================================================================
# PASO 8: Configurar politica de auditoria de seguridad
# (Se aplica antes del reinicio; persiste después)
# ===========================================================================
Write-Host "`n[PASO 8] Configurando politica de auditoria de seguridad..." -ForegroundColor Green

# Habilitar auditoria de inicio/cierre de sesion (exito y fallo)
auditpol /set /subcategory:"Logon"                 /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Logoff"                /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Account Logon"         /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Account Management"    /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Directory Service Access" /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Policy Change"         /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Privilege Use"         /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Process Creation"      /success:enable /failure:enable | Out-Null

Write-Host "  Auditoria de seguridad configurada correctamente."


# ===========================================================================
# PASO 9: Aumentar tamano del registro de eventos de Seguridad
# ===========================================================================
Write-Host "`n[PASO 9] Ajustando tamano maximo del log de Seguridad..." -ForegroundColor Green
wevtutil sl Security /ms:102400000   # 100 MB
Write-Host "  Security Event Log: 100 MB"


# ===========================================================================
# FINALIZAR FASE 1 - El plugin vagrant-reload reiniciara la VM
# ===========================================================================
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " FASE 1 COMPLETADA" -ForegroundColor Cyan
Write-Host " El sistema se reiniciara para completar la promocion del DC." -ForegroundColor Cyan
Write-Host " Vagrant ejecutara automaticamente la Fase 2 despues del reinicio." -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Iniciar reinicio (vagrant-reload esperara que la VM vuelva a estar accesible)
Restart-Computer -Force
