# =============================================================================
# windows-ws.ps1 (AWS) — Estación de trabajo Windows (miembro de dominio)
# VLAN20 -> 10.0.20.30 / .31
#
# Migración de Workstations/scripts/windows-ws.ps1 + windows-ws-second.ps1.
# AWS no ofrece AMI de Windows 10 cliente; se usa Windows Server 2019 como
# estación miembro del dominio. Para las fuentes de detección del proyecto
# (Sysmon: Pass-the-Hash, ejecución de payload) el comportamiento es equivalente.
#
# Reinicios resueltos con máquina de estados (EC2Launch <persist>true</persist>).
# Fases: RENAME -> JOIN -> POSTJOIN -> DONE.
# =============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Evitar doble ejecución simultánea (EC2Launch + tarea programada)
$mtx = New-Object System.Threading.Mutex($false, "Global\SiemLabProvision")
if (-not $mtx.WaitOne(0)) { Write-Host "Otra ejecución en curso; se omite."; exit 0 }

$VM_HOSTNAME      = if ($env:VM_HOSTNAME) { $env:VM_HOSTNAME } else { "win-ws-01" }
$VM_DNS           = if ($env:VM_DNS) { $env:VM_DNS } else { "10.0.10.20" }
$WAZUH_MANAGER_IP = if ($env:WAZUH_MANAGER_IP) { $env:WAZUH_MANAGER_IP } else { "10.0.30.10" }
$DOMAIN           = if ($env:DOMAIN) { $env:DOMAIN } else { "empresa.local" }
$DOMAIN_ADMIN     = "Administrator"
$DOMAIN_ADMIN_PASS = "P@ssw0rd"
$WAZUH_AGENT_VER  = "4.9.2"
$STATE_FILE = "C:\siem-state.txt"
$COUNT_FILE = "C:\siem-join-attempts.txt"

$SELF_PATH = "C:\lab\userdata\windows-ws.ps1"
$TASK_NAME = "SiemLabProvision"

function Get-State { if (Test-Path $STATE_FILE) { (Get-Content $STATE_FILE -Raw).Trim() } else { "RENAME" } }
function Set-State($s) { Set-Content -Path $STATE_FILE -Value $s -Force }
function Log($m) { Write-Host ("[WS:" + $VM_HOSTNAME + "][" + (Get-State) + "] " + $m) }

# --- Reinicios robustos (independiente de EC2Launch v1/v2) -------------------
foreach ($v in @("VM_HOSTNAME","VM_DNS","WAZUH_MANAGER_IP","DOMAIN")) {
  $val = [Environment]::GetEnvironmentVariable($v, "Process")
  if ($val) { [Environment]::SetEnvironmentVariable($v, $val, "Machine") }
}
function Register-ResumeTask {
  # Tarea de reanudacion ROBUSTA (ver windows-dc.ps1): disparador AtStartup MAS
  # repeticion cada 3 min durante 2 h, para que el aprovisionamiento se reanude
  # y complete solo aunque una corrida pille el DC/DNS a medias. EC2Launch v2 no
  # re-ejecuta el user-data en cada boot, asi que esta tarea es el mecanismo
  # fiable de reanudacion. Se auto-elimina al llegar a DONE.
  $a  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$SELF_PATH`""
  $t1 = New-ScheduledTaskTrigger -AtStartup
  $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
          -RepetitionInterval (New-TimeSpan -Minutes 3) -RepetitionDuration (New-TimeSpan -Hours 2)
  $p  = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  $s  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskName $TASK_NAME -Action $a -Trigger $t1,$t2 -Principal $p -Settings $s -Force | Out-Null
}
function Unregister-ResumeTask { Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue }
if (Test-Path $SELF_PATH) { Register-ResumeTask }

$state = Get-State
Log "Iniciando fase: $state"

switch ($state) {

  "RENAME" {
    Set-TimeZone -Id "SA Pacific Standard Time" -ErrorAction SilentlyContinue
    # La regla de firewall sola no basta: hay que habilitar el servicio WinRM
    # (WinRM no escucha por defecto), necesario para attack5_payload_exec.sh.
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction SilentlyContinue | Out-Null
    Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true -ErrorAction SilentlyContinue
    Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "WinRM-Lab" -Direction Inbound -Protocol TCP -LocalPort 5985,5986 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null

    # DNS -> Controlador de dominio (necesario para unirse al dominio)
    $ifIndex = (Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1).ifIndex
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses @($VM_DNS) -ErrorAction SilentlyContinue

    # Auditoría avanzada (telemetría de seguridad)
    foreach ($c in @("Account Logon","Account Management","Detailed Tracking","Logon/Logoff","Object Access","Policy Change","Privilege Use","System")) {
      auditpol /set /category:"$c" /success:enable /failure:enable 2>$null | Out-Null
    }

    if ($env:COMPUTERNAME -ne $VM_HOSTNAME) {
      Log "Renombrando equipo a $VM_HOSTNAME..."
      Rename-Computer -NewName $VM_HOSTNAME -Force
    }
    Set-State "JOIN"
    Log "Reiniciando para aplicar hostname y DNS..."
    Restart-Computer -Force
  }

  "JOIN" {
    # Contador de intentos para evitar bucles infinitos de reinicio
    $attempts = 0
    if (Test-Path $COUNT_FILE) { $attempts = [int](Get-Content $COUNT_FILE -Raw).Trim() }
    $attempts++; Set-Content $COUNT_FILE $attempts -Force

    $cs = Get-WmiObject Win32_ComputerSystem
    if ($cs.PartOfDomain -and $cs.Domain -eq $DOMAIN) {
      Log "Ya es miembro de $DOMAIN."
      Set-State "POSTJOIN"; Restart-Computer -Force; return
    }

    Log "Esperando al Controlador de Dominio ($VM_DNS)... intento de arranque $attempts"
    $dcReady = $false
    for ($i=1; $i -le 40; $i++) {
      if (Test-NetConnection -ComputerName $VM_DNS -Port 389 -InformationLevel Quiet -WarningAction SilentlyContinue) { $dcReady=$true; break }
      Start-Sleep -Seconds 15
    }

    if (-not $dcReady) {
      if ($attempts -ge 6) { throw "DC no disponible tras varios reinicios. Revisar el DC (10.0.10.20)." }
      Log "DC aún no responde; se reintentará tras reinicio."
      Restart-Computer -Force; return
    }

    $cred = New-Object System.Management.Automation.PSCredential(
      "$DOMAIN_ADMIN@$DOMAIN", (ConvertTo-SecureString $DOMAIN_ADMIN_PASS -AsPlainText -Force))
    try {
      Add-Computer -DomainName $DOMAIN -Credential $cred -OUPath "OU=Equipos,DC=empresa,DC=local" -Force -ErrorAction Stop
    } catch {
      Log "Unión con OU personalizada falló; intentando unión estándar..."
      Add-Computer -DomainName $DOMAIN -Credential $cred -Force
    }
    Log "Unido a $DOMAIN. Reiniciando..."
    Set-State "POSTJOIN"
    Restart-Computer -Force
  }

  "POSTJOIN" {
    $labCfg = "C:\lab\config\sysmonconfig.xml"
    $tmp = "C:\Temp\Vagrant"; New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    # --- Sysmon (fuente de log #4: telemetría de endpoints Windows) ---
    if (-not (Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue)) {
      Log "Instalando Sysmon64..."
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      try { Invoke-WebRequest -Uri "https://live.sysinternals.com/Sysmon64.exe" -OutFile "$tmp\Sysmon64.exe" -UseBasicParsing } catch { Write-Warning "Descarga Sysmon falló: $_" }
      $cfg = $labCfg
      if (-not (Test-Path $cfg)) {
        try { Invoke-WebRequest -Uri "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" -OutFile "$tmp\sysmonconfig.xml" -UseBasicParsing; $cfg = "$tmp\sysmonconfig.xml" } catch {}
      }
      if (Test-Path "$tmp\Sysmon64.exe") {
        Start-Process "$tmp\Sysmon64.exe" -ArgumentList "-accepteula -i `"$cfg`"" -Wait -NoNewWindow
        Log "Sysmon64 instalado."
      }
    } else {
      if (Test-Path $labCfg) { & "C:\Windows\Sysmon64.exe" -c $labCfg 2>$null }
    }

    # --- PowerShell logging (ScriptBlock + Module) ---
    foreach ($p in @("HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging",
                     "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging")) {
      if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    }
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -Value 1 -Type DWord
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" -Name "EnableModuleLogging" -Value 1 -Type DWord
    wevtutil sl Security /ms:102400000 | Out-Null
    foreach ($s in @("Process Creation","Process Termination","Logon","Special Logon","Account Lockout")) {
      auditpol /set /subcategory:"$s" /success:enable /failure:enable 2>$null | Out-Null
    }

    # --- Agente Wazuh ---
    if (-not (Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue)) {
      Log "Instalando agente Wazuh (manager $WAZUH_MANAGER_IP)..."
      $msi = "$tmp\wazuh-agent.msi"
      try {
        Invoke-WebRequest -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-$WAZUH_AGENT_VER-1.msi" -OutFile $msi -UseBasicParsing
        Start-Process msiexec.exe -ArgumentList @("/i","`"$msi`"","/qn","WAZUH_MANAGER=$WAZUH_MANAGER_IP",
          "WAZUH_REGISTRATION_SERVER=$WAZUH_MANAGER_IP","WAZUH_AGENT_NAME=$VM_HOSTNAME",
          "WAZUH_MANAGER_PORT=1514","WAZUH_REGISTRATION_PORT=1515") -Wait
        Set-Service -Name WazuhSvc -StartupType Automatic -ErrorAction SilentlyContinue
        Log "Agente Wazuh instalado."
      } catch { Write-Warning "No se pudo instalar el agente Wazuh: $_" }
    }

    # --- Suscripcion del agente al canal de Sysmon (IMPRESCINDIBLE) ----------
    # Por defecto el agente de Wazuh en Windows solo lee Application/Security/
    # System. Los eventos de Sysmon (creacion de proceso con linea de comando,
    # Event ID 1) viven en 'Microsoft-Windows-Sysmon/Operational' y NO se
    # recogen salvo que se anada este <localfile>. Sin esto, las reglas de
    # ejecucion de payload (100050/100051) y la deteccion de herramientas de
    # movimiento lateral via Sysmon (100031) nunca se disparan.
    # --- PowerShell Script Block Logging (Event 4104) -----------------------
    # Registra el contenido DECODIFICADO de los scripts de PowerShell, incluidos
    # los ejecutados con -EncodedCommand. Refuerza la deteccion de payloads
    # ofuscados (download cradles IEX/DownloadString) junto con Sysmon Event 1.
    try {
      $sbl = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
      New-Item -Path $sbl -Force | Out-Null
      Set-ItemProperty -Path $sbl -Name EnableScriptBlockLogging -Value 1 -Type DWord
    } catch { Write-Warning "No se pudo habilitar Script Block Logging: $_" }

    $ossecConf = "C:\Program Files (x86)\ossec-agent\ossec.conf"
    if ((Test-Path $ossecConf) -and -not (Select-String -Path $ossecConf -Pattern "Sysmon/Operational" -SimpleMatch -Quiet)) {
      Log "Suscribiendo el agente al canal Microsoft-Windows-Sysmon/Operational..."
      $block = @"
  <localfile>
    <location>Microsoft-Windows-Sysmon/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>
"@
      $raw = Get-Content -Raw -Path $ossecConf
      # Insertar el bloque antes del cierre del ultimo </ossec_config>
      $idx = $raw.LastIndexOf("</ossec_config>")
      if ($idx -ge 0) {
        $new = $raw.Substring(0,$idx) + $block + "`r`n" + $raw.Substring($idx)
        Set-Content -Path $ossecConf -Value $new -Encoding UTF8
      }
    }
    Restart-Service WazuhSvc -ErrorAction SilentlyContinue
    Start-Service WazuhSvc -ErrorAction SilentlyContinue

    # RDP para administración
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

    Set-State "DONE"
    Log "============================================================"
    Log " ESTACIÓN $VM_HOSTNAME LISTA (dominio $DOMAIN, Sysmon + Wazuh)"
    Log "============================================================"
  }

  "DONE" { Log "Estación ya configurada." }
}

if ((Get-State) -eq "DONE") { Unregister-ResumeTask }
