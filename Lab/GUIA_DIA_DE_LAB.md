# Guía del Día de Laboratorio — Proyecto SIEM

Esta guía dice exactamente qué hacer, en qué máquina y en qué orden.
**Novedad:** la conexión de agentes y la ejecución de ataques/tráfico ya
están automatizadas con un solo comando por host — ya no hace falta entrar
VM por VM. Tiempo estimado total: **2–3 horas**.

---

## ANTES DE EMPEZAR — Lista de chequeo

- [ ] Router encendido y con la configuración aplicada (R1-CORE), incluida la
      ruta por defecto IPv4 (`ip route 0.0.0.0 0.0.0.0 Serial0/1/0`)
- [ ] SW1 y SW2 encendidos con la configuración aplicada
- [ ] Cables físicos conectados según la tabla de cableado
- [ ] Los tres hosts físicos encendidos (servidores, clientes, gestión)
- [ ] `vagrant` y PowerShell disponibles en cada uno de los tres hosts

---

## PASO 1 — Levantar las VMs (solo la primera vez del día)

En el **host de gestión**:
```powershell
cd Desarrollo\Gestion
vagrant up
```

En el **host de servidores**:
```powershell
cd Desarrollo\Servidores
vagrant up
```

En el **host de workstations**:
```powershell
cd Desarrollo\Workstations
vagrant up
```

Esperar a que las tres terminen antes de continuar.

---

## PASO 2 — Conectar TODOS los agentes al SIEM (un comando por host)

Esto corrige automáticamente el problema de la ruta NAT (la causa de que
varias VMs no llegaran al SIEM) y registra el agente Wazuh en cada máquina.
**No hace falta entrar manualmente a ninguna VM.**

### 2a. En el host de Gestión (primero — deja el SIEM listo para recibir)
```powershell
cd Desarrollo\Gestion
.\Lab\conectar_todo.ps1
```
Corrige el SIEM (wazuh1) y conecta Kali.

### 2b. En el host de Servidores (en paralelo, las 8 VMs a la vez)
```powershell
cd Desarrollo\Servidores
.\Lab\conectar_todo.ps1
```

### 2c. En el host de Workstations (en paralelo, las 4 VMs a la vez)
```powershell
cd Desarrollo\Workstations
.\Lab\conectar_todo.ps1
```

Cada script muestra en vivo el progreso de cada máquina y, al final, un
resumen OK/FALLÓ por VM. Si alguna falla, el mensaje de error indica la
causa (sin conectividad, SIEM no listo, etc.) — vuelve a correr solo ese
host después de corregir.

> **pfSense no lleva agente** (es FreeBSD, no usa netplan/apt). Para
> monitorearlo, configúralo para enviar syslog a `192.168.30.10:514`
> (Status -> System Logs -> Settings -> Remote Logging). El SIEM ya tiene
> ese puerto escuchando.

### 2d. Verificar en el dashboard

Abrir **https://192.168.30.10** -> **Agents**. Deben aparecer **todos**
en estado **Active** (web-server, windows-dc, dhcpv4-server, dhcpv6-server,
dns1-server, dns2-server, smtp-server, ntp-server, win10-01, win10-02,
linux-01, linux-02, kali).

---

## PASO 3 — Reglas de correlación (ya incluido en el Paso 2a)

El script `conectar_todo.ps1` de Gestión ya copia `local_rules.xml` al SIEM
y reinicia el manager. Para confirmar manualmente:
```powershell
vagrant ssh wazuh1 -c "ls /var/ossec/etc/rules/local_rules.xml"
```

| ID     | Ataque              | MITRE      |
|--------|---------------------|------------|
| 100010 | Fuerza bruta SSH    | T1110.001  |
| 100020 | Escaneo de puertos  | T1046      |
| 100030 | Pass-the-Hash       | T1550.002  |
| 100040 | Inyección SQL       | T1190      |
| 100050 | Ejecución payload   | T1059.001  |

---

## PASO 4 — ESCENARIO 1: Línea base (tráfico normal)

**Objetivo:** medir cuántos falsos positivos genera el SIEM sin ataques.

**Un comando, corre en paralelo en todas las estaciones de un host:**

En Servidores (web-server):
```powershell
cd Desarrollo\Servidores
.\Lab\ejecutar_trafico.ps1              # 30 min por defecto
.\Lab\ejecutar_trafico.ps1 -DuracionMin 15
```

En Workstations (las 4 estaciones a la vez):
```powershell
cd Desarrollo\Workstations
.\Lab\ejecutar_trafico.ps1
```

**Qué ver en el SIEM mientras corre:** Dashboard -> Security Events,
filtrar por `rule.groups: attack`. No debería aparecer nada; si aparece,
son falsos positivos — anótalos.

---

## PASO 5 — ESCENARIO 2: Ataques controlados (en paralelo)

**Objetivo:** medir la tasa de detección de los 5 ataques.

Los 3 ataques automatizables (SSH, escaneo, SQLi) ahora corren **los tres al
mismo tiempo** dentro de Kali (ya no uno tras otro), lo que además simula
una condición más realista de amenazas concurrentes.

**Un solo comando**, desde el host de Gestión:
```powershell
cd Desarrollo\Gestion
.\Lab\ejecutar_ataques.ps1                 # 5 repeticiones (default)
.\Lab\ejecutar_ataques.ps1 -Reps 3         # 3 repeticiones
```

Esto lanza los ataques, espera a que terminen (~15-20 min con 5 reps) y
**trae automáticamente** el CSV resultante a `Gestion\Lab\log_ataques.csv`
en tu propio host — no hace falta copiarlo a mano.

### Ataques 4 y 5 (manuales — mientras corre el script anterior o después)

**Ataque 4 — Pass-the-Hash:**
1. RDP al DC: `192.168.10.20`. Abrir mimikatz como Administrador:
   ```
   privilege::debug
   sekurlsa::logonpasswords
   ```
2. Copiar el hash NT del Administrator. En Kali:
   ```bash
   INICIO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
   crackmapexec smb 192.168.10.20 -u Administrator -H <HASH_NT>
   FIN=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
   echo "pass_the_hash,T1550.002,192.168.10.20,$INICIO,$FIN,1" >> /tmp/log_ataques.csv
   ```
3. Repetir 5 veces (cambiar el número final).

**Ataque 5 — Payload PowerShell:**
1. RDP a un Windows 10 (`192.168.20.x`). En PowerShell:
   ```powershell
   $INICIO = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
   powershell -nop -w hidden -enc UwB0AGEAcgB0AC0AUwBsAGUAZQBwACAALQBTAGUAYwBvAG4AZABzACAAMQA=
   $FIN = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
   ```
2. En Kali: `echo "payload_execution,T1059.001,192.168.20.30,$INICIO,$FIN,1" >> /tmp/log_ataques.csv`
3. Repetir 5 veces.

**Después de 4 y 5**, vuelve a traer el CSV actualizado:
```powershell
cd Desarrollo\Gestion
vagrant ssh kali -c "cat /tmp/log_ataques.csv" | Out-File Lab\log_ataques.csv -Encoding utf8
```

---

## PASO 6 — ESCENARIO 3: Tráfico mixto (coordinado entre hosts)

Como el tráfico normal corre en un host físico (Servidores/Workstations) y
los ataques en otro (Gestión), este escenario necesita que dos personas
(o tú mismo yendo de un equipo a otro) arranquen los dos comandos con
pocos minutos de diferencia:

**Equipo de Gestión:**
```powershell
cd Desarrollo\Gestion
.\Lab\ejecutar_ataques.ps1
```

**Al mismo tiempo, en el equipo de Workstations:**
```powershell
cd Desarrollo\Workstations
.\Lab\ejecutar_trafico.ps1 -DuracionMin 20
```

Acuerden la hora de inicio (ej. "a las 3:15 ambos corremos el comando").
Anota la hora real de inicio de cada uno para la ventana de análisis.

---

## PASO 7 — Calcular métricas

Desde el host de Gestión, con el CSV ya en `Gestion\Lab\log_ataques.csv`:

```powershell
cd Desarrollo\Gestion

# Subir el CSV combinado al SIEM
Get-Content Lab\log_ataques.csv -Raw | vagrant ssh wazuh1 -c "cat > /tmp/log_ataques.csv"

# Ejecutar el análisis (ajustar las horas al periodo real del día)
Get-Content ..\Lab\calcular_metricas.sh -Raw | vagrant ssh wazuh1 -c "sudo bash -s -- /tmp/log_ataques.csv '2026-10-05T14:00:00Z' '2026-10-05T18:00:00Z'"

# Traer el reporte de vuelta
vagrant ssh wazuh1 -c "cat /tmp/reporte_metricas.md" | Out-File Lab\reporte_metricas.md -Encoding utf8
```

Abre `Gestion\Lab\reporte_metricas.md` — tiene la tasa de detección global,
el desglose por tipo de ataque y la tabla de reglas disparadas.

---

## Resumen: qué comando va en qué máquina

| Acción | Host | Comando |
|--------|------|---------|
| Levantar VMs | Cada uno | `vagrant up` |
| Conectar agentes (SIEM + Kali) | Gestión | `.\Lab\conectar_todo.ps1` |
| Conectar agentes (8 servidores, paralelo) | Servidores | `.\Lab\conectar_todo.ps1` |
| Conectar agentes (4 estaciones, paralelo) | Workstations | `.\Lab\conectar_todo.ps1` |
| Escenario 1 (tráfico, servidores) | Servidores | `.\Lab\ejecutar_trafico.ps1` |
| Escenario 1 (tráfico, estaciones, paralelo) | Workstations | `.\Lab\ejecutar_trafico.ps1` |
| Escenario 2 (3 ataques en paralelo + recolecta CSV) | Gestión | `.\Lab\ejecutar_ataques.ps1` |
| Escenario 2, ataques 4-5 (manuales) | DC/Win10 + Kali | Ver Paso 5 |
| Escenario 3 (mixto, coordinado) | Gestión + otro host | Ver Paso 6 |
| Calcular métricas | Gestión | Ver Paso 7 |
| Ver dashboard | Navegador | https://192.168.30.10 |

---

## Solución rápida de problemas comunes

**Un job de PowerShell no muestra nada / parece colgado:**
```powershell
Get-Job | Format-Table           # ver el estado real de cada job
Receive-Job -Name <nombre_vm>    # ver su salida acumulada
```

**`vagrant ssh` o `vagrant winrm` fallan desde el script:**
Confirma que estás parado en la carpeta correcta (donde está el
Vagrantfile de ese host) antes de correr el script — los orquestadores
asumen que `Lab\` está un nivel bajo esa carpeta.

**Un agente específico sigue sin aparecer tras `conectar_todo.ps1`:**
Revisa el resumen final del script — te dice cuál VM falló. Puedes
reintentar solo esa, manualmente:
```powershell
Get-Content ..\Lab\conectar_agente_linux.sh -Raw | vagrant ssh web-server -c "sudo bash -s"
```

**No hay ping entre VLANs:**
```
# En el router:
show ip route
show ip interface brief
```

**El dashboard del SIEM no carga:**
```bash
vagrant ssh wazuh1 -c "sudo systemctl restart wazuh-dashboard"
```
