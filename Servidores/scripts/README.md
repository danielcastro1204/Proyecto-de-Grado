# Laboratorio SIEM — Integrante B
## Máquinas virtuales de la VLAN 10 (Servidores)

Portátil: **Lenovo Legion 5** | Hipervisor: VirtualBox | Automatización: Vagrant

---

## Contenido del repositorio

```
proyecto_siem_integrante_B/
├── Vagrantfile
├── scripts/
│   ├── windows-dc.ps1          # Fase 1: Instala AD DS, IP fija, promueve DC
│   ├── windows-dc-second.ps1   # Fase 2: Usuarios AD, DNS, Wazuh agent (post-reinicio)
│   └── web-server.sh           # Ubuntu: Apache2, IP fija, Wazuh agent
└── README.md
```

---

## Contexto del proyecto

Este conjunto de VMs representa la infraestructura de servidores (`VLAN 10 – 192.168.10.0/24`) dentro de un laboratorio de ciberseguridad segmentado por VLANs. El objetivo es simular un entorno corporativo real donde se generan eventos de seguridad (autenticaciones, accesos web, errores de dominio) que el **SIEM Wazuh** (integrante A, `192.168.30.10`) recolecta y correlaciona.

| VM | OS | IP | Rol |
|---|---|---|---|
| `dc` | Windows Server 2019 | `192.168.10.20` | Controlador de Dominio AD DS + DNS |
| `web` | Ubuntu Server 22.04 | `192.168.10.10` | Servidor web Apache2 |

**Relaciones con otros integrantes:**
- **Integrante A** (`192.168.30.10`, VLAN 30): ejecuta Wazuh Manager + Kali. Recibe logs de los agentes instalados en estas VMs.
- **Integrante C** (`VLAN 20`): ejecuta estaciones de trabajo que se unirán al dominio `empresa.local` gestionado por el DC de esta VLAN.

---

## Requisitos previos

### En el host (portátil Lenovo Legion 5)

| Herramienta | Versión mínima | Descarga |
|---|---|---|
| VirtualBox | 7.0+ | https://www.virtualbox.org |
| Vagrant | 2.4+ | https://www.vagrantup.com |
| Plugin `vagrant-reload` | cualquiera | ver abajo |

```bash
# Instalar el plugin vagrant-reload (necesario para el reinicio del DC)
vagrant plugin install vagrant-reload

# Verificar plugins instalados
vagrant plugin list
```

> **¿Por qué `vagrant-reload`?** La promoción de un servidor a Controlador de Dominio requiere un reinicio obligatorio. Este plugin le indica a Vagrant que espere a que la VM vuelva a estar disponible antes de continuar con la fase 2 del aprovisionamiento.

---

## Ajuste obligatorio: interfaz de red puente

Antes de ejecutar `vagrant up`, debes indicar el nombre del adaptador de red físico de tu portátil que está conectado al **Switch 1 (VLAN 10)**.

### Cómo encontrar el nombre del adaptador

**En Windows (host):**
```powershell
# Opción 1: PowerShell
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status

# Opción 2: VBoxManage (muestra los adaptadores disponibles para modo puente)
VBoxManage list bridgedifs | grep "^Name:"
```

**En Linux (host):**
```bash
ip link show
# o
VBoxManage list bridgedifs | grep "^Name:"
```

### Editar el Vagrantfile

Abre `Vagrantfile` y modifica la línea:

```ruby
BRIDGE_INTERFACE = ""   # <--- AJUSTAR ANTES DE EJECUTAR
```

Ejemplos según tu sistema:
```ruby
# Windows con adaptador Ethernet
BRIDGE_INTERFACE = "Realtek PCIe GbE Family Controller"

# Windows con Wi-Fi
BRIDGE_INTERFACE = "Intel(R) Wi-Fi 6 AX200 160MHz"

# Linux con Ethernet
BRIDGE_INTERFACE = "enp4s0"

# Linux con Wi-Fi
BRIDGE_INTERFACE = "wlp3s0"
```

> Si dejas `BRIDGE_INTERFACE = ""`, Vagrant preguntará interactivamente qué adaptador usar al ejecutar `vagrant up`. Esto es útil si no conoces el nombre exacto.

---

## Ejecución

### Levantar ambas máquinas

```bash
cd proyecto_siem_integrante_B/
vagrant up
```

### Levantar solo una máquina

```bash
vagrant up dc     # Solo el Controlador de Dominio
vagrant up web    # Solo el Servidor Web
```

### Tiempos estimados

| VM | Tiempo aproximado | Notas |
|---|---|---|
| `web` (Ubuntu) | 8–15 minutos | Descarga de paquetes + Wazuh agent |
| `dc` – Fase 1 | 15–25 minutos | Descarga de la box + instalación AD DS |
| `dc` – Reinicio | 3–5 minutos | vagrant-reload espera automáticamente |
| `dc` – Fase 2 | 5–10 minutos | Usuarios AD + Wazuh agent |
| **Total DC** | **~35–45 minutos** | Primera ejecución |

> La primera vez se descarga la box de Windows Server (~6 GB). Las siguientes ejecuciones son más rápidas.

---

## Flujo de aprovisionamiento del DC

```
vagrant up dc
     │
     ├─ windows-dc.ps1 (Fase 1)
     │   ├─ Configura IP fija 192.168.10.20
     │   ├─ Instala roles AD DS + DNS
     │   ├─ Promueve servidor a DC (empresa.local)
     │   ├─ Configura firewall y auditoría
     │   └─ REINICIA el servidor
     │
     ├─ :reload (vagrant-reload)
     │   └─ Espera a que Windows vuelva a estar disponible
     │
     └─ windows-dc-second.ps1 (Fase 2)
         ├─ Espera a que AD DS esté activo
         ├─ Crea OU "Usuarios"
         ├─ Crea usuario user1
         ├─ Crea cuenta wazuh-svc
         ├─ Configura DNS inverso y registros A
         ├─ Aplica GPO de auditoría
         ├─ Instala y configura agente Wazuh
         └─ Habilita RDP
```

Si por algún motivo el aprovisionamiento de Fase 2 falla, puedes re-ejecutarlo manualmente:

```bash
vagrant provision dc
```

---

## Credenciales

> ⚠️ Estas credenciales son exclusivamente para el entorno de laboratorio. No usar en producción.

| Cuenta | Usuario | Contraseña |
|---|---|---|
| Admin local Windows (box) | `Administrator` | `vagrant` |
| Admin Dominio empresa.local | `EMPRESA\Administrator` | `P@ssw0rd` |
| Admin Safe Mode (DSRM) | `Administrator` (modo recuperación) | `P@ssw0rd` |
| Usuario de dominio | `EMPRESA\user1` | `User123!` |
| Cuenta servicio SIEM | `EMPRESA\wazuh-svc` | `WazuhSvc2024!` |
| Ubuntu root/sudo | `vagrant` | `vagrant` |

---

## Verificación del entorno

### Conectividad básica (desde cualquier VM o desde el host)

```bash
# Desde web-server → verificar gateway
ping 192.168.10.1

# Desde web-server → verificar DC
ping 192.168.10.20
nslookup empresa.local 192.168.10.20

# Desde web-server → verificar SIEM (requiere enrutamiento entre VLANs)
ping 192.168.30.10

# Desde dc-empresa → verificar web-server
ping 192.168.10.10

# Desde host → verificar web (abrir en navegador)
# http://192.168.10.10/
```

### Verificar AD DS (dentro del DC)

```powershell
# Estado del dominio
Get-ADDomain

# Listar usuarios
Get-ADUser -Filter * | Select-Object Name, SamAccountName, Enabled

# Listar OUs
Get-ADOrganizationalUnit -Filter *

# Verificar DNS
Resolve-DnsName empresa.local
Resolve-DnsName web-server.empresa.local
```

### Verificar Apache2 (dentro del servidor web)

```bash
# Estado del servicio
systemctl status apache2

# Acceso local
curl http://localhost/
curl http://localhost/login.html

# Ver logs en tiempo real
tail -f /var/log/apache2/access.log
tail -f /var/log/apache2/error.log
```

### Verificar agentes Wazuh

```bash
# En Ubuntu (web-server)
systemctl status wazuh-agent
cat /var/ossec/logs/ossec.log | grep "Connected"

# En Windows (dc-empresa) — PowerShell
Get-Service WazuhSvc
Get-Content "C:\Program Files (x86)\ossec-agent\ossec.log" -Tail 20
```

**Desde el Wazuh Manager (integrante A, `192.168.30.10`):**
```bash
# Listar agentes registrados
/var/ossec/bin/agent_control -l

# o desde la API
curl -k -u admin:admin https://localhost:55000/agents
```

---

## Comandos Vagrant útiles

```bash
# Estado de las VMs
vagrant status

# SSH/RDP a las VMs
vagrant ssh web          # SSH al servidor web
vagrant rdp dc           # RDP al controlador de dominio (requiere cliente RDP)

# Re-provisionar
vagrant provision web    # Re-ejecutar web-server.sh
vagrant provision dc     # Re-ejecutar ambos scripts del DC

# Suspender / reanudar
vagrant suspend
vagrant resume

# Apagar
vagrant halt
vagrant halt dc

# Destruir y recrear desde cero
vagrant destroy -f
vagrant up
```

---

## Arquitectura de red completa

```
Internet
    │
Cisco ISR4321 (Router)
    │  ├─ VLAN 10: 192.168.10.1/24  (Servidores)
    │  ├─ VLAN 20: 192.168.20.1/24  (Usuarios)
    │  └─ VLAN 30: 192.168.30.1/24  (Gestión)
    │
    ├── Switch 1 (Cisco Catalyst 2960)
    │     ├─ Puerto access VLAN 10 ── Lenovo Legion 5 (Integrante B)
    │     │     ├─ VM: dc  (Windows Server 2019)  → 192.168.10.20
    │     │     └─ VM: web (Ubuntu 22.04)         → 192.168.10.10
    │     │
    │     └─ Puerto access VLAN 20 ── Acer Nitro (Integrante C)
    │           └─ VMs: Estaciones de trabajo VLAN 20
    │
    └── Switch 2
          └─ Puerto access VLAN 30 ── ASUS TUF (Integrante A)
                ├─ VM: Wazuh SIEM Manager → 192.168.30.10
                └─ VM: Kali Linux (atacante)
```

---

## Solución de problemas

### El DC no promueve correctamente a Controlador de Dominio

```powershell
# Verificar en el DC si la instalación está completa
Test-Path "C:\Windows\NTDS"           # debe existir
Get-WindowsFeature AD-Domain-Services  # debe estar Installed

# Revisar log de aprovisionamiento
Get-Content C:\Windows\Temp\vagrant-*.log -ErrorAction SilentlyContinue
```

### La Fase 2 falla porque AD no está listo

El script de Fase 2 espera automáticamente hasta 120 segundos a que AD DS responda. Si el tiempo no es suficiente (máquinas lentas), puedes aumentar `$maxWait` en `windows-dc-second.ps1`.

### La IP fija no aparece en la interfaz puente

En Windows:
```powershell
# Ver adaptadores y sus IPs
Get-NetAdapter
Get-NetIPAddress -AddressFamily IPv4
```

En Ubuntu:
```bash
ip addr show
cat /etc/netplan/99-siem-static.yaml
sudo netplan apply
```

### El agente Wazuh no se conecta al manager

1. Verificar que `192.168.30.10` es alcanzable: `ping 192.168.30.10`
2. Verificar que el enrutamiento inter-VLAN está configurado en el router
3. Revisar que el puerto 1514/TCP no está bloqueado por el firewall
4. Verificar la configuración del agente:
   - Linux: `cat /var/ossec/etc/ossec.conf | grep address`
   - Windows: `Get-Content "C:\Program Files (x86)\ossec-agent\ossec.conf" | Select-String "address"`

### Error con vagrant-reload: "Plugin not installed"

```bash
vagrant plugin install vagrant-reload
# Verificar:
vagrant plugin list | grep reload
```

---

## Notas de seguridad del laboratorio

- El entorno está **aislado de Internet** durante las pruebas. Los scripts requieren acceso temporal a Internet solo durante el aprovisionamiento inicial (descarga de paquetes).
- Las ACLs del router Cisco **restringen** el tráfico desde VLAN 20 (usuarios) hacia VLAN 10 (servidores), permitiendo únicamente los puertos 80, 443, 53, 88, 445.
- El DC actúa como servidor **DNS autoritativo** para `empresa.local`. Las estaciones de trabajo del integrante C deben configurar su DNS primario en `192.168.10.20`.
- Para unir una estación de trabajo al dominio desde VLAN 20, usar:
  ```powershell
  Add-Computer -DomainName "empresa.local" -Credential (Get-Credential) -Restart
  ```
