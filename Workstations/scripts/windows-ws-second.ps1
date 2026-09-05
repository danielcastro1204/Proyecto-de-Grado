# =============================================================================
# windows-ws-second.ps1 — FASE 2: Instalación de Sysmon y Agente Wazuh
# =============================================================================
# Se ejecuta DESPUÉS del reinicio (post-unión al dominio).
# Variables de entorno esperadas:
#   VM_HOSTNAME       - Nombre del equipo (solo para logging)
#   WAZUH_MANAGER_IP  - IP del manager Wazuh (192.168.30.10)
# =============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$VM_HOSTNAME      = $env:VM_HOSTNAME
$WAZUH_MANAGER_IP = $env:WAZUH_MANAGER_IP
$WAZUH_VERSION    = "4.9.2"   # Actualizar según la versión más reciente disponible
$TempDir          = "C:\Temp\Vagrant"

Write-Host "============================================================"
Write-Host " FASE 2 | $VM_HOSTNAME | Post-Reinicio"
Write-Host "============================================================"

# Crear directorio temporal
if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}
Set-Location $TempDir

# Función auxiliar para descargas con reintentos
function Download-File {
    param(
        [string]$Url,
        [string]$Dest,
        [int]$MaxRetries = 3
    )
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-Host "   Descargando (intento $i/$MaxRetries): $([System.IO.Path]::GetFileName($Dest))"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120
            Write-Host "   Descarga completada."
            return
        } catch {
            Write-Warning "   Intento $i fallido: $_"
            Start-Sleep -Seconds 5
        }
    }
    throw "No se pudo descargar $Url después de $MaxRetries intentos."
}

# ============================================================
# 1. INSTALAR SYSMON
# ============================================================
Write-Host "[1/3] Verificando instalación de Sysmon..."

$sysmonService = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue

if ($sysmonService) {
    Write-Host "   Sysmon64 ya está instalado. Actualizando configuración..."
    $configPath = "$TempDir\sysmonconfig.xml"
    if (-not (Test-Path $configPath)) {
        # Copiar desde la carpeta de scripts de Vagrant
        Copy-Item "C:\tmp\scripts\sysmonconfig.xml" $configPath -ErrorAction SilentlyContinue
        if (-not (Test-Path $configPath)) {
            Download-File `
                -Url  "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" `
                -Dest $configPath
        }
    }
    & "$TempDir\Sysmon64.exe" -c $configPath 2>$null
    Write-Host "   Configuración de Sysmon actualizada."
} else {
    Write-Host "   Instalando Sysmon64..."

    # Descargar Sysmon
    $sysmonUrl = "https://live.sysinternals.com/Sysmon64.exe"
    Download-File -Url $sysmonUrl -Dest "$TempDir\Sysmon64.exe"

    # Obtener configuración XML (primero buscar en /tmp/scripts, luego GitHub)
    $configPath = "$TempDir\sysmonconfig.xml"
    $localConfig = "C:\tmp\scripts\sysmonconfig.xml"

    if (Test-Path $localConfig) {
        Copy-Item $localConfig $configPath
        Write-Host "   Usando sysmonconfig.xml local."
    } else {
        Write-Host "   Descargando configuración de SwiftOnSecurity desde GitHub..."
        Download-File `
            -Url  "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" `
            -Dest $configPath
    }

    # Instalar Sysmon (aceptar EULA automáticamente)
    Write-Host "   Ejecutando instalador de Sysmon..."
    $proc = Start-Process -FilePath "$TempDir\Sysmon64.exe" `
        -ArgumentList "-accepteula -i `"$configPath`"" `
        -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 1) {
        throw "Sysmon instalación falló con código: $($proc.ExitCode)"
    }
    Write-Host "   Sysmon64 instalado exitosamente."
}

# Verificar que el servicio esté corriendo
$sysmonSvc = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
if ($sysmonSvc -and $sysmonSvc.Status -ne 'Running') {
    Start-Service "Sysmon64"
    Write-Host "   Servicio Sysmon64 iniciado."
} elseif ($sysmonSvc) {
    Write-Host "   Servicio Sysmon64 activo: $($sysmonSvc.Status)"
}

# ============================================================
# 2. INSTALAR AGENTE WAZUH
# ============================================================
Write-Host "[2/3] Verificando instalación del agente Wazuh..."

$wazuhService = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue

if ($wazuhService) {
    Write-Host "   El agente Wazuh ya está instalado."
    # Verificar/actualizar la IP del manager en ossec.conf
    $ossecConf = "C:\Program Files (x86)\ossec-agent\ossec.conf"
    if (Test-Path $ossecConf) {
        $content = Get-Content $ossecConf -Raw
        if ($content -notmatch [regex]::Escape($WAZUH_MANAGER_IP)) {
            Write-Host "   Actualizando IP del manager en ossec.conf..."
            $content = $content -replace '<address>[^<]+</address>', "<address>$WAZUH_MANAGER_IP</address>"
            Set-Content $ossecConf $content
            Restart-Service WazuhSvc
            Write-Host "   Servicio Wazuh reiniciado con nueva configuración."
        } else {
            Write-Host "   IP del manager ya configurada correctamente."
        }
    }
} else {
    Write-Host "   Descargando agente Wazuh $WAZUH_VERSION..."

    # Construir URL del MSI de Wazuh (64-bit)
    $wazuhMsiUrl  = "https://packages.wazuh.com/4.x/windows/wazuh-agent-$WAZUH_VERSION-1.msi"
    $wazuhMsiPath = "$TempDir\wazuh-agent.msi"

    Download-File -Url $wazuhMsiUrl -Dest $wazuhMsiPath

    Write-Host "   Instalando agente Wazuh (modo silencioso)..."
    $msiArgs = @(
        "/i", $wazuhMsiPath,
        "/qn",
        "WAZUH_MANAGER=`"$WAZUH_MANAGER_IP`"",
        "WAZUH_MANAGER_PORT=`"1514`"",
        "WAZUH_REGISTRATION_SERVER=`"$WAZUH_MANAGER_IP`"",
        "WAZUH_REGISTRATION_PORT=`"1515`"",
        "WAZUH_AGENT_NAME=`"$VM_HOSTNAME`"",
        "/log", "$TempDir\wazuh-install.log"
    )

    $proc = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList $msiArgs `
        -Wait -PassThru -NoNewWindow

    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Get-Content "$TempDir\wazuh-install.log" -ErrorAction SilentlyContinue | Select-Object -Last 20
        throw "Instalación Wazuh MSI falló con código: $($proc.ExitCode)"
    }
    Write-Host "   Agente Wazuh instalado."
}

# Iniciar servicio Wazuh
$wazuhSvc = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
if ($wazuhSvc) {
    if ($wazuhSvc.Status -ne 'Running') {
        Start-Service "WazuhSvc"
        Write-Host "   Servicio WazuhSvc iniciado."
    } else {
        Write-Host "   Servicio WazuhSvc ya está corriendo."
    }
    # Configurar inicio automático
    Set-Service -Name "WazuhSvc" -StartupType Automatic
} else {
    Write-Warning "No se encontró el servicio WazuhSvc. Verifica la instalación manualmente."
}

# ============================================================
# 3. CONFIGURAR AUDITORÍA Y POLÍTICAS ADICIONALES
# ============================================================
Write-Host "[3/3] Aplicando configuraciones de seguridad adicionales..."

# Habilitar registro de eventos de PowerShell (útil para SIEM)
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}
Set-ItemProperty -Path $regPath -Name "EnableScriptBlockLogging" -Value 1 -Type DWord

# Habilitar Module Logging
$regPath2 = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging"
if (-not (Test-Path $regPath2)) {
    New-Item -Path $regPath2 -Force | Out-Null
}
Set-ItemProperty -Path $regPath2 -Name "EnableModuleLogging" -Value 1 -Type DWord

# Asegurar que el log de seguridad tenga tamaño adecuado
wevtutil sl Security /ms:102400000

# Habilitar inicio de sesión de procesos (Process Tracking)
auditpol /set /subcategory:"Process Creation" /success:enable /failure:enable 2>$null
auditpol /set /subcategory:"Process Termination" /success:enable 2>$null
auditpol /set /subcategory:"Logon" /success:enable /failure:enable 2>$null
auditpol /set /subcategory:"Special Logon" /success:enable 2>$null
auditpol /set /subcategory:"Account Lockout" /failure:enable 2>$null

Write-Host "   Auditoría y logging de PowerShell habilitados."

# ============================================================
# RESUMEN FINAL
# ============================================================
Write-Host ""
Write-Host "============================================================"
Write-Host " FASE 2 COMPLETADA — $VM_HOSTNAME"
Write-Host "------------------------------------------------------------"
Write-Host " Sysmon64  : $(if (Get-Service 'Sysmon64' -EA SilentlyContinue) { 'INSTALADO' } else { 'ERROR' })"
Write-Host " WazuhSvc  : $(if (Get-Service 'WazuhSvc' -EA SilentlyContinue) { 'INSTALADO' } else { 'ERROR' })"
Write-Host " Dominio   : $((Get-WmiObject Win32_ComputerSystem).Domain)"
Write-Host " IP        : $((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.20.*' }).IPAddress)"
Write-Host "============================================================"
