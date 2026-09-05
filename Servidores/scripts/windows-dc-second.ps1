# =============================================================================
# windows-dc-second.ps1  |  FASE 2 - Post-reinicio del Controlador de Dominio
# Proyecto SIEM - Integrante B | VLAN 10 | 192.168.10.20
# =============================================================================
# Este script se ejecuta DESPUES del reinicio que completa la promocion del DC.
# Realiza:
#   1. Verificacion de que AD DS esta activo
#   2. Creacion de OU "Usuarios" y usuario "user1" en el dominio
#   3. Configuracion de GPO de auditoria a nivel de dominio
#   4. Verificacion de zona DNS empresa.local
#   5. Instalacion y configuracion del agente Wazuh para Windows
#   6. Resumen final del estado del DC
# =============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# VARIABLES
# ---------------------------------------------------------------------------
$DOMAIN_NAME      = $env:DOMAIN         # Por defecto: empresa.local
$SIEM_IP          = $env:SIEM_IP        # Por defecto: 192.168.30.10 (VLAN 30)
$DOMAIN_ADMIN     = "Administrator"
$DOMAIN_PASS      = "P@ssw0rd"
$OU_NAME          = "Usuarios"
$USER1_NAME       = "user1"
$USER1_PASS       = "User123!"
$USER1_DISPLAY    = "Usuario Prueba 1"
$WAZUH_MANAGER_IP = if ($SIEM_IP) { $SIEM_IP } else { "192.168.30.10" }
$WAZUH_MSI_URL    = "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.9.2-1.msi"
$WAZUH_MSI_PATH   = "C:\Windows\Temp\wazuh-agent.msi"

# Credencial de administrador de dominio para cmdlets de AD
$SecPass   = ConvertTo-SecureString $DOMAIN_PASS -AsPlainText -Force
$DomainCred = New-Object System.Management.Automation.PSCredential("$DOMAIN_NAME\$DOMAIN_ADMIN", $SecPass)


Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " FASE 2: Configuracion post-reinicio del DC" -ForegroundColor Cyan
Write-Host " Dominio: $DOMAIN_NAME" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan


# ===========================================================================
# PASO 1: Esperar a que los servicios de AD DS esten activos
# Tras el reinicio, los servicios pueden tardar 30-60 segundos en arrancar.
# ===========================================================================
Write-Host "`n[PASO 1] Esperando a que Active Directory este listo..." -ForegroundColor Green

$maxWait   = 120   # segundos maximos de espera
$waited    = 0
$adReady   = $false

while ($waited -lt $maxWait) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $domain = Get-ADDomain -ErrorAction Stop
        $adReady = $true
        Write-Host "  AD DS activo: $($domain.DNSRoot)"
        break
    } catch {
        Write-Host "  Esperando servicios AD... ($waited s)"
        Start-Sleep -Seconds 10
        $waited += 10
    }
}

if (-not $adReady) {
    Write-Host "  [ERROR] Active Directory no respondio en $maxWait segundos." -ForegroundColor Red
    throw "Tiempo de espera agotado para AD DS."
}


# ===========================================================================
# PASO 2: Crear OU "Usuarios"
# ===========================================================================
Write-Host "`n[PASO 2] Creando OU '$OU_NAME' en $DOMAIN_NAME..." -ForegroundColor Green

$ouDN = "OU=$OU_NAME,DC=$($DOMAIN_NAME.Replace('.',',DC='))"

try {
    $existingOU = Get-ADOrganizationalUnit -Filter "Name -eq '$OU_NAME'" -ErrorAction SilentlyContinue
    if (-not $existingOU) {
        New-ADOrganizationalUnit `
            -Name                            $OU_NAME `
            -Path                            "DC=$($DOMAIN_NAME.Replace('.',',DC='))" `
            -Description                     "OU principal de usuarios del dominio" `
            -ProtectedFromAccidentalDeletion  $false
        Write-Host "  OU '$OU_NAME' creada exitosamente."
    } else {
        Write-Host "  [SKIP] OU '$OU_NAME' ya existe."
    }
} catch {
    Write-Host "  [WARN] Error al crear OU: $_" -ForegroundColor Yellow
}


# ===========================================================================
# PASO 3: Crear usuario user1 dentro de la OU Usuarios
# ===========================================================================
Write-Host "`n[PASO 3] Creando usuario '$USER1_NAME' en OU $OU_NAME..." -ForegroundColor Green

$user1Pass = ConvertTo-SecureString $USER1_PASS -AsPlainText -Force

try {
    $existingUser = Get-ADUser -Filter "SamAccountName -eq '$USER1_NAME'" -ErrorAction SilentlyContinue
    if (-not $existingUser) {
        New-ADUser `
            -Name              $USER1_DISPLAY `
            -GivenName         "Usuario" `
            -Surname           "Prueba1" `
            -SamAccountName    $USER1_NAME `
            -UserPrincipalName "$USER1_NAME@$DOMAIN_NAME" `
            -AccountPassword   $user1Pass `
            -Path              $ouDN `
            -Enabled           $true `
            -PasswordNeverExpires $true `
            -Description       "Usuario de prueba para laboratorio SIEM"

        Write-Host "  Usuario '$USER1_NAME' creado en $ouDN"
        Write-Host "  UPN: $USER1_NAME@$DOMAIN_NAME  |  Pass: $USER1_PASS"
    } else {
        Write-Host "  [SKIP] El usuario '$USER1_NAME' ya existe."
    }
} catch {
    Write-Host "  [ERROR] No se pudo crear usuario: $_" -ForegroundColor Red
}


# ===========================================================================
# PASO 4: Crear usuario adicional "wazuh-svc" (cuenta de servicio para SIEM)
# (Opcional pero util para vincular el SIEM con el dominio)
# ===========================================================================
Write-Host "`n[PASO 4] Creando cuenta de servicio 'wazuh-svc'..." -ForegroundColor Green

try {
    $svcUser = Get-ADUser -Filter "SamAccountName -eq 'wazuh-svc'" -ErrorAction SilentlyContinue
    if (-not $svcUser) {
        $svcPass = ConvertTo-SecureString "WazuhSvc2024!" -AsPlainText -Force
        New-ADUser `
            -Name              "wazuh-svc" `
            -SamAccountName    "wazuh-svc" `
            -UserPrincipalName "wazuh-svc@$DOMAIN_NAME" `
            -AccountPassword   $svcPass `
            -Path              $ouDN `
            -Enabled           $true `
            -PasswordNeverExpires $true `
            -Description       "Cuenta de servicio Wazuh SIEM"
        Write-Host "  Cuenta 'wazuh-svc' creada. Pass: WazuhSvc2024!"
    } else {
        Write-Host "  [SKIP] La cuenta 'wazuh-svc' ya existe."
    }
} catch {
    Write-Host "  [WARN] No se pudo crear wazuh-svc: $_" -ForegroundColor Yellow
}


# ===========================================================================
# PASO 5: Verificar y agregar zona DNS inversa (PTR) para VLAN 10
# ===========================================================================
Write-Host "`n[PASO 5] Configurando zona DNS inversa para 192.168.10.x..." -ForegroundColor Green

try {
    $reverseZone = "10.168.192.in-addr.arpa"
    $existingZone = Get-DnsServerZone -Name $reverseZone -ErrorAction SilentlyContinue
    if (-not $existingZone) {
        Add-DnsServerPrimaryZone `
            -NetworkID  "192.168.10.0/24" `
            -ReplicationScope "Forest" `
            -ErrorAction Stop
        Write-Host "  Zona inversa '$reverseZone' creada."
    } else {
        Write-Host "  [SKIP] Zona inversa '$reverseZone' ya existe."
    }

    # Agregar registros A para los servidores de VLAN 10
    $dnsRecords = @(
        @{ Name="dc-empresa";   IP="192.168.10.20" },
        @{ Name="web-server";   IP="192.168.10.10" }
    )

    foreach ($rec in $dnsRecords) {
        $existing = Get-DnsServerResourceRecord -ZoneName $DOMAIN_NAME -Name $rec.Name -RRType "A" -ErrorAction SilentlyContinue
        if (-not $existing) {
            Add-DnsServerResourceRecordA -ZoneName $DOMAIN_NAME -Name $rec.Name -IPv4Address $rec.IP -ErrorAction SilentlyContinue
            Write-Host "  Registro DNS A: $($rec.Name).$DOMAIN_NAME -> $($rec.IP)"
        } else {
            Write-Host "  [SKIP] Registro DNS '$($rec.Name)' ya existe."
        }
    }
} catch {
    Write-Host "  [WARN] Error en configuracion DNS: $_" -ForegroundColor Yellow
}


# ===========================================================================
# PASO 6: Configurar GPO de auditoria avanzada de seguridad
# ===========================================================================
Write-Host "`n[PASO 6] Aplicando GPO de auditoria de seguridad..." -ForegroundColor Green

try {
    Import-Module GroupPolicy -ErrorAction SilentlyContinue

    $gpoName = "SIEM-Auditoria-Seguridad"
    $existingGPO = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue

    if (-not $existingGPO) {
        $gpo = New-GPO -Name $gpoName -Comment "GPO de auditoria para proyecto SIEM"
        New-GPLink -Name $gpoName -Target "DC=$($DOMAIN_NAME.Replace('.',',DC='))" | Out-Null
        Write-Host "  GPO '$gpoName' creada y vinculada al dominio."
    } else {
        Write-Host "  [SKIP] GPO '$gpoName' ya existe."
    }

    # Configurar politica de auditoria de Logon/Logoff via auditpol
    # (Complementa el GPO; auditpol es mas directo en un entorno de lab)
    auditpol /set /subcategory:"Logon"                    /success:enable /failure:enable 2>&1 | Out-Null
    auditpol /set /subcategory:"Logoff"                   /success:enable /failure:enable 2>&1 | Out-Null
    auditpol /set /subcategory:"Other Logon/Logoff Events" /success:enable /failure:enable 2>&1 | Out-Null
    auditpol /set /subcategory:"Account Lockout"           /success:enable /failure:enable 2>&1 | Out-Null
    auditpol /set /subcategory:"Kerberos Authentication Service" /success:enable /failure:enable 2>&1 | Out-Null
    auditpol /set /subcategory:"Kerberos Service Ticket Operations" /success:enable /failure:enable 2>&1 | Out-Null
    Write-Host "  Politicas de auditoria auditpol aplicadas."

} catch {
    Write-Host "  [WARN] Error configurando GPO/auditpol: $_" -ForegroundColor Yellow
}


# ===========================================================================
# PASO 7: Instalar agente Wazuh para Windows
# ===========================================================================
Write-Host "`n[PASO 7] Instalando agente Wazuh (manager: $WAZUH_MANAGER_IP)..." -ForegroundColor Green

# Verificar si Wazuh ya esta instalado
$wazuhService = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
if ($wazuhService) {
    Write-Host "  [SKIP] El agente Wazuh ya esta instalado (servicio WazuhSvc encontrado)."
} else {
    try {
        # Descargar el MSI del agente
        Write-Host "  Descargando MSI desde Wazuh..."
        if (-not (Test-Path $WAZUH_MSI_PATH)) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $WAZUH_MSI_URL -OutFile $WAZUH_MSI_PATH -UseBasicParsing
            Write-Host "  MSI descargado en $WAZUH_MSI_PATH"
        } else {
            Write-Host "  MSI ya descargado, usando cache."
        }

        # Instalar en modo silencioso con parametros de configuracion
        Write-Host "  Ejecutando instalacion silenciosa..."
        $msiArgs = @(
            "/i", $WAZUH_MSI_PATH,
            "/q",
            "WAZUH_MANAGER=$WAZUH_MANAGER_IP",
            "WAZUH_MANAGER_PORT=1514",
            "WAZUH_REGISTRATION_SERVER=$WAZUH_MANAGER_IP",
            "WAZUH_REGISTRATION_PORT=1515",
            "WAZUH_AGENT_NAME=dc-empresa"
        )
        $proc = Start-Process "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-Host "  Agente Wazuh instalado exitosamente."
        } else {
            Write-Host "  [WARN] msiexec retorno codigo: $($proc.ExitCode)" -ForegroundColor Yellow
        }

        # Iniciar el servicio Wazuh
        Start-Sleep -Seconds 5
        $wazuhSvc = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
        if ($wazuhSvc) {
            if ($wazuhSvc.Status -ne 'Running') {
                Start-Service -Name "WazuhSvc"
                Write-Host "  Servicio WazuhSvc iniciado."
            }
            # Configurar inicio automatico
            Set-Service -Name "WazuhSvc" -StartupType Automatic
            Write-Host "  Servicio WazuhSvc configurado para inicio automatico."
        }

        # Verificar el archivo de configuracion
        $ossecConf = "C:\Program Files (x86)\ossec-agent\ossec.conf"
        if (Test-Path $ossecConf) {
            # Asegurar que el manager este correctamente configurado
            $confContent = Get-Content $ossecConf -Raw
            if ($confContent -notmatch $WAZUH_MANAGER_IP) {
                Write-Host "  [WARN] El archivo ossec.conf no contiene la IP del manager. Verificar manualmente." -ForegroundColor Yellow
            } else {
                Write-Host "  ossec.conf contiene la IP del manager: $WAZUH_MANAGER_IP"
            }
        }

    } catch {
        Write-Host "  [WARN] Error durante la instalacion de Wazuh: $_" -ForegroundColor Yellow
        Write-Host "  El agente Wazuh puede instalarse manualmente con el MSI descargado." -ForegroundColor Yellow
    }
}


# ===========================================================================
# PASO 8: Habilitar RDP (opcional, util para acceso remoto al DC)
# ===========================================================================
Write-Host "`n[PASO 8] Habilitando Remote Desktop (RDP)..." -ForegroundColor Green
try {
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
                     -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    Write-Host "  RDP habilitado. Puerto 3389 abierto en firewall."
} catch {
    Write-Host "  [WARN] No se pudo habilitar RDP: $_" -ForegroundColor Yellow
}


# ===========================================================================
# PASO 9: Resumen final del estado del DC
# ===========================================================================
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " RESUMEN FINAL - Controlador de Dominio" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

try {
    $domain       = Get-ADDomain
    $forest       = Get-ADForest
    $users        = Get-ADUser -Filter * | Measure-Object
    $ous          = Get-ADOrganizationalUnit -Filter * | Measure-Object
    $dnsZones     = Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated } | Measure-Object

    Write-Host " Dominio        : $($domain.DNSRoot)"
    Write-Host " NetBIOS        : $($domain.NetBIOSName)"
    Write-Host " Nivel funcional: $($domain.DomainMode)"
    Write-Host " Bosque         : $($forest.Name)"
    Write-Host " Usuarios AD    : $($users.Count)"
    Write-Host " OUs            : $($ous.Count)"
    Write-Host " Zonas DNS      : $($dnsZones.Count)"
    Write-Host ""
    Write-Host " Credenciales:" -ForegroundColor Yellow
    Write-Host "   Admin local  : Administrator / P@ssw0rd" -ForegroundColor Yellow
    Write-Host "   Admin dominio: empresa.local\Administrator / P@ssw0rd" -ForegroundColor Yellow
    Write-Host "   Usuario AD   : empresa.local\user1 / User123!" -ForegroundColor Yellow
    Write-Host "   Svc SIEM     : empresa.local\wazuh-svc / WazuhSvc2024!" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " SIEM (Wazuh Manager): $WAZUH_MANAGER_IP" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " FASE 2 COMPLETADA - DC listo para el laboratorio SIEM" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
} catch {
    Write-Host " [WARN] No se pudo obtener resumen completo de AD: $_" -ForegroundColor Yellow
}
