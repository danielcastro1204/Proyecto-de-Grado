# =============================================================================
# windows-dc-second.ps1
# FASE 2 - Configuracion posterior a la promocion
# =============================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host ""
Write-Host "============================================================"
Write-Host " FASE 2 - CONFIGURACION POSTERIOR DEL CONTROLADOR"
Write-Host "============================================================"
Write-Host ""


# =============================================================================
# VARIABLES
# =============================================================================

$SIEM_IP = if ($env:SIEM_IP) { $env:SIEM_IP } else { "192.168.30.10" }
$DOMAIN  = if ($env:DOMAIN)  { $env:DOMAIN }  else { "empresa.local" }

$HOSTNAME = "dc-empresa"

Write-Host "SIEM     : $SIEM_IP"
Write-Host "Dominio  : $DOMAIN"
Write-Host "Hostname : $HOSTNAME"
Write-Host ""


# =============================================================================
# ESPERAR A AD DS
# =============================================================================

Write-Host "[1/8] Esperando disponibilidad de Active Directory..."

$adReady = $false

for ($i = 1; $i -le 24; $i++) {

    try {

        Import-Module ActiveDirectory -ErrorAction Stop

        $domainInfo = Get-ADDomain -ErrorAction Stop

        if ($domainInfo) {

            $adReady = $true

            Write-Host "Active Directory disponible."
            Write-Host "Dominio detectado: $($domainInfo.DNSRoot)"

            break
        }

    }
    catch {

        Write-Host "AD aun no esta disponible. Intento $i de 24..."

        Start-Sleep -Seconds 5
    }
}


if (-not $adReady) {

    throw "Active Directory no estuvo disponible despues de 120 segundos."

}


# =============================================================================
# CONFIGURAR DNS
# =============================================================================

Write-Host ""
Write-Host "[2/8] Verificando DNS..."

try {

    Get-DnsServerZone -ErrorAction Stop | Out-Null

    Write-Host "Servidor DNS disponible."

}
catch {

    Write-Warning "No fue posible consultar el servidor DNS."

}


# =============================================================================
# CREAR OU
# =============================================================================

Write-Host ""
Write-Host "[3/8] Creando OU Usuarios..."

$ouPath = "OU=Usuarios,DC=empresa,DC=local"

try {

    Get-ADOrganizationalUnit `
        -Identity $ouPath `
        -ErrorAction Stop | Out-Null

    Write-Host "La OU Usuarios ya existe."

}
catch {

    New-ADOrganizationalUnit `
        -Name "Usuarios" `
        -Path "DC=empresa,DC=local" `
        -ProtectedFromAccidentalDeletion $false

    Write-Host "OU Usuarios creada."

}


# =============================================================================
# CREAR USUARIO user1
# =============================================================================

Write-Host ""
Write-Host "[4/8] Creando usuarios..."

# Se cambia la contraseña para no incluir el nombre del usuario
$userPassword = ConvertTo-SecureString `
    "Proyecto.2026*" `
    -AsPlainText `
    -Force

try {

    Get-ADUser `
        -Identity "user1" `
        -ErrorAction Stop | Out-Null

    Write-Host "El usuario user1 ya existe."

}
catch {

    New-ADUser `
        -Name "user1" `
        -SamAccountName "user1" `
        -UserPrincipalName "user1@$DOMAIN" `
        -AccountPassword $userPassword `
        -Enabled $true `
        -Path $ouPath `
        -ChangePasswordAtLogon $false

    Write-Host "Usuario user1 creado."

}


# =============================================================================
# CREAR USUARIO DE SERVICIO WAZUH
# =============================================================================

# Se cambia la contraseña para no incluir el nombre del usuario
$wazuhPassword = ConvertTo-SecureString `
    "AgenteSIEM.26*" `
    -AsPlainText `
    -Force

try {

    Get-ADUser `
        -Identity "wazuh-svc" `
        -ErrorAction Stop | Out-Null

    Write-Host "El usuario wazuh-svc ya existe."

}
catch {

    New-ADUser `
        -Name "wazuh-svc" `
        -SamAccountName "wazuh-svc" `
        -UserPrincipalName "wazuh-svc@$DOMAIN" `
        -AccountPassword $wazuhPassword `
        -Enabled $true `
        -Path $ouPath `
        -PasswordNeverExpires $true `
        -ChangePasswordAtLogon $false

    Write-Host "Usuario wazuh-svc creado."

}


# =============================================================================
# DNS REVERSO
# =============================================================================

Write-Host ""
Write-Host "[5/8] Configurando DNS reverso..."

$reverseZone = "10.168.192.in-addr.arpa"

try {

    Get-DnsServerZone `
        -Name $reverseZone `
        -ErrorAction Stop | Out-Null

    Write-Host "Zona reversa ya existe."

}
catch {

    Add-DnsServerPrimaryZone `
        -NetworkId "192.168.10.0/24" `
        -ReplicationScope "Domain" `
        -DynamicUpdate "Secure"

    Write-Host "Zona reversa creada."

}


# =============================================================================
# REGISTROS DNS
# =============================================================================

Write-Host ""
Write-Host "Creando registros DNS..."

try {

    Add-DnsServerResourceRecordA `
        -ZoneName $DOMAIN `
        -Name "dc-empresa" `
        -IPv4Address "192.168.10.20" `
        -ErrorAction SilentlyContinue

}
catch {}

try {

    Add-DnsServerResourceRecordA `
        -ZoneName $DOMAIN `
        -Name "web-server" `
        -IPv4Address "192.168.10.10" `
        -ErrorAction SilentlyContinue

}
catch {}

Write-Host "Registros DNS configurados."


# =============================================================================
# GPO
# =============================================================================

Write-Host ""
Write-Host "[6/8] Configurando GPO de auditoria..."

Import-Module GroupPolicy -ErrorAction SilentlyContinue

$gpoName = "SIEM-Auditoria-Seguridad"

try {

    Get-GPO `
        -Name $gpoName `
        -ErrorAction Stop | Out-Null

    Write-Host "La GPO ya existe."

}
catch {

    New-GPO `
        -Name $gpoName | Out-Null

    Write-Host "GPO creada."

}


try {

    New-GPLink `
        -Name $gpoName `
        -Target "DC=empresa,DC=local" `
        -LinkEnabled Yes `
        -ErrorAction SilentlyContinue

}
catch {}


# =============================================================================
# AUDITORIA LOCAL
# =============================================================================

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
# WAZUH AGENT
# =============================================================================

Write-Host ""
Write-Host "[7/8] Instalando agente Wazuh..."

$WAZUH_MSI_URL = "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.9.2-1.msi"

$WAZUH_MSI = "C:\Windows\Temp\wazuh-agent.msi"

$WAZUH_MANAGER = $SIEM_IP
$WAZUH_AGENT_NAME = $HOSTNAME


# Verificar conectividad al SIEM
Write-Host ""
Write-Host "Probando conectividad con SIEM $WAZUH_MANAGER..."

try {

    Test-NetConnection `
        -ComputerName $WAZUH_MANAGER `
        -Port 1514 `
        -InformationLevel Quiet

}
catch {

    Write-Warning "No fue posible comprobar el puerto 1514 del SIEM."

}


# Descargar MSI
if (-not (Test-Path $WAZUH_MSI)) {

    Write-Host "Descargando agente Wazuh..."

    try {

        Invoke-WebRequest `
            -Uri $WAZUH_MSI_URL `
            -OutFile $WAZUH_MSI `
            -UseBasicParsing `
            -ErrorAction Stop

        Write-Host "Agente descargado."

    }
    catch {

        Write-Warning "No se pudo descargar el agente Wazuh."
        Write-Warning $_.Exception.Message

    }

}


# Instalar Wazuh
if (Test-Path $WAZUH_MSI) {

    Write-Host "Instalando Wazuh Agent..."

    $arguments = @(
        "/i"
        "`"$WAZUH_MSI`""
        "/qn"
        "/norestart"
        "WAZUH_MANAGER=$WAZUH_MANAGER"
        "WAZUH_REGISTRATION_SERVER=$WAZUH_MANAGER"
        "WAZUH_AGENT_NAME=$WAZUH_AGENT_NAME"
        "WAZUH_MANAGER_PORT=1514"
        "WAZUH_REGISTRATION_PORT=1515"
    )

    $process = Start-Process `
        -FilePath "msiexec.exe" `
        -ArgumentList $arguments `
        -Wait `
        -PassThru

    Write-Host "Codigo de instalacion Wazuh: $($process.ExitCode)"

    if ($process.ExitCode -eq 0) {

        Write-Host "Wazuh Agent instalado correctamente."

    }
    else {

        Write-Warning "El instalador Wazuh devolvio codigo $($process.ExitCode)."

    }


    # Configurar servicio
    try {

        $wazuhService = Get-Service `
            -Name "WazuhSvc" `
            -ErrorAction Stop

        Set-Service `
            -Name "WazuhSvc" `
            -StartupType Automatic

        Start-Service `
            -Name "WazuhSvc" `
            -ErrorAction SilentlyContinue

        Write-Host "Servicio Wazuh iniciado."

    }
    catch {

        Write-Warning "No fue posible iniciar WazuhSvc."
        Write-Warning $_.Exception.Message

    }

}
else {

    Write-Warning "El MSI de Wazuh no esta disponible."
    Write-Warning "La instalacion del agente se omitio."

}


# =============================================================================
# RDP
# =============================================================================

Write-Host ""
Write-Host "[8/8] Habilitando RDP..."

Set-ItemProperty `
    -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" `
    -Value 0

Enable-NetFirewallRule `
    -DisplayGroup "Remote Desktop" `
    -ErrorAction SilentlyContinue

Write-Host "RDP habilitado."


# =============================================================================
# RESUMEN
# =============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " FASE 2 COMPLETADA"
Write-Host "============================================================"
Write-Host ""

Write-Host "CONTROLADOR DE DOMINIO"
Write-Host "----------------------"
Write-Host "Hostname : $HOSTNAME"
Write-Host "IP       : 192.168.10.20"
Write-Host "Dominio  : $DOMAIN"
Write-Host ""

Write-Host "USUARIOS"
Write-Host "--------"
Write-Host "user1 (Password: Proyecto.2026*)"
Write-Host "wazuh-svc (Password: AgenteSIEM.26*)"
Write-Host ""

Write-Host "DNS"
Write-Host "---"
Write-Host "dc-empresa.$DOMAIN -> 192.168.10.20"
Write-Host "web-server.$DOMAIN -> 192.168.10.10"
Write-Host ""

Write-Host "SIEM"
Write-Host "---"
Write-Host "Wazuh Manager -> $SIEM_IP"
Write-Host ""

Write-Host "RDP"
Write-Host "---"
Write-Host "Habilitado"
Write-Host ""

Write-Host "============================================================"
Write-Host " CONTROLADOR DE DOMINIO CONFIGURADO"
Write-Host "============================================================"
Write-Host ""