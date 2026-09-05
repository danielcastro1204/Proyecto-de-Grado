# Laboratorio SIEM — Integrante C | Estaciones de Trabajo VLAN 20

Configuración automatizada con Vagrant + VirtualBox para las cuatro estaciones de trabajo del **Integrante C** en el proyecto de grado de ciberseguridad.

---

## Topología de Red

```
Router Cisco ISR4321
├── VLAN 10 (192.168.10.0/24) — Switch 1 → Integrante B (DC + Web Server)
├── VLAN 20 (192.168.20.0/24) — Switch 1 → Integrante C (Este equipo)
└── VLAN 30 (192.168.30.0/24) — Switch 2 → Integrante A (SIEM + Kali)

Máquinas de este Vagrantfile:
  win10-01   192.168.20.30  Windows 10 Pro
  win10-02   192.168.20.31  Windows 10 Pro
  linux-01   192.168.20.40  Ubuntu Desktop 22.04
  linux-02   192.168.20.41  Ubuntu Desktop 22.04

Servicios externos:
  DC/DNS     192.168.10.20  (Integrante B — debe estar UP)
  SIEM       192.168.30.10  (Integrante A — debe estar UP)
  Gateway    192.168.20.1   (Router VLAN 20)
```

---

## Estructura de Archivos

```
proyecto_siem_integrante_C/
├── Vagrantfile
├── scripts/
│   ├── windows-ws.ps1          # Fase 1 Windows: red, hostname, dominio
│   ├── windows-ws-second.ps1   # Fase 2 Windows: Sysmon + Wazuh
│   ├── linux-desktop.sh        # Ubuntu: red, Wazuh, auditd, UFW
│   └── sysmonconfig.xml        # Reglas de Sysmon (basadas en SwiftOnSecurity)
└── README.md
```

---

## Prerrequisitos

### Software en el anfitrión (portátil Integrante C)

| Software | Versión mínima | Descarga |
|---|---|---|
| VirtualBox | 7.0+ | https://www.virtualbox.org/wiki/Downloads |
| Vagrant | 2.4+ | https://developer.hashicorp.com/vagrant/downloads |
| Plugin `vagrant-reload` | Cualquiera | `vagrant plugin install vagrant-reload` |

```bash
# Instalar el plugin requerido (obligatorio antes del primer vagrant up)
vagrant plugin install vagrant-reload
```

### Hardware recomendado

| Recurso | Mínimo | Recomendado |
|---|---|---|
| RAM | 10 GB libres | 16 GB totales |
| CPU | 4 núcleos | 8 núcleos (i7/Ryzen 7) |
| Disco | 80 GB libres | 120 GB libres (SSD) |
| Red | Adaptador Ethernet | Gigabit al Switch 1 |

> **Nota sobre RAM**: Con 16 GB en el portátil y 8 GB asignados a las VMs (2 GB × 4), quedan 8 GB para el anfitrión. Si tienes menos de 16 GB, reduce la RAM de cada VM a 1536 MB editando la línea `vb.memory` en el `Vagrantfile`.

### Dependencias de Red

> ⚠️ **IMPORTANTE**: Antes de ejecutar `vagrant up`, verifica que:
>
> 1. **El Controlador de Dominio del Integrante B** (`192.168.10.20`) esté encendido y el dominio `empresa.local` operativo. Las VMs Windows necesitan alcanzar el DC para unirse al dominio durante el aprovisionamiento.
>
> 2. **El servidor SIEM del Integrante A** (`192.168.30.10`) esté accesible para que los agentes Wazuh puedan registrarse. (Los agentes se instalan aunque el SIEM no esté disponible, pero el registro automático fallará.)
>
> 3. **El portátil tiene acceso a Internet** durante el aprovisionamiento para descargar: Wazuh, Sysmon, y actualizaciones de paquetes.

---

## Configuración Inicial

### Paso 1: Configurar la Interfaz de Red Puente

Edita el `Vagrantfile` y ajusta la variable `BRIDGE_IFACE` con el nombre exacto del adaptador de red físico que conecta el portátil al Switch 1:

**En Windows (anfitrión):**
```powershell
# Listar adaptadores disponibles
Get-NetAdapter | Select-Object Name, Status, LinkSpeed
# Ejemplo de valor: "Realtek PCIe GbE Family Controller"
# o simplemente "Ethernet"
```

**En Linux (anfitrión):**
```bash
ip link show
# Ejemplo de valor: "enp3s0" o "eth0"
```

Luego en `Vagrantfile`:
```ruby
BRIDGE_IFACE = "Realtek PCIe GbE Family Controller"  # Windows
# BRIDGE_IFACE = "enp3s0"                            # Linux
```

Si dejas `BRIDGE_IFACE = ""`, Vagrant preguntará interactivamente qué adaptador usar al levantar cada VM.

### Paso 2: Verificar/Actualizar Versión de Wazuh

En `scripts/windows-ws-second.ps1`, verifica que `$WAZUH_VERSION` coincida con la versión más reciente disponible en https://packages.wazuh.com/4.x/windows/.

### Paso 3: Ajustar Credenciales del Dominio

Si la contraseña del Administrador del dominio es diferente, edita en `Vagrantfile`:
```ruby
DOMAIN_ADMIN_PASS = "TuContraseña"
```

---

## Uso

### Levantar todas las VMs
```bash
vagrant up
```

### Levantar una sola VM
```bash
vagrant up win10-01
vagrant up linux-01
```

### Ver estado de todas las VMs
```bash
vagrant status
```

### Conectarse a una VM
```bash
# Linux (SSH)
vagrant ssh linux-01

# Windows (RDP — abre GUI directamente en VirtualBox)
# O usar: vagrant rdp win10-01  (requiere cliente RDP)
```

### Detener VMs (sin destruir)
```bash
vagrant halt
vagrant halt win10-01
```

### Destruir y recrear desde cero
```bash
vagrant destroy -f
vagrant up
```

### Re-ejecutar el aprovisionamiento
```bash
vagrant provision win10-01
vagrant reload --provision linux-02
```

---

## Flujo de Aprovisionamiento Detallado

### Máquinas Windows (win10-01 y win10-02)

El aprovisionamiento se divide en dos fases separadas por un reinicio:

```
vagrant up win10-01
    │
    ├── [Fase 1] windows-ws.ps1
    │     ├── Configura IP estática (192.168.20.30/31)
    │     ├── Renombra equipo (win10-01/02)
    │     ├── Habilita auditoría de seguridad
    │     ├── Crea reglas de firewall (Wazuh + Dominio)
    │     └── Une al dominio empresa.local → REQUIERE DC UP
    │
    ├── [vagrant-reload] — Reinicio automático
    │
    └── [Fase 2] windows-ws-second.ps1
          ├── Instala Sysmon64 con sysmonconfig.xml
          ├── Instala agente Wazuh (MSI silencioso)
          ├── Configura Wazuh manager: 192.168.30.10
          ├── Habilita logging de PowerShell
          └── Configura tamaño de logs de seguridad
```

### Máquinas Linux (linux-01 y linux-02)

```
vagrant up linux-01
    │
    └── [Único script] linux-desktop.sh
          ├── Actualiza paquetes del sistema
          ├── Configura hostname (linux-01/02)
          ├── Añade DC a /etc/hosts
          ├── Configura IP estática via Netplan
          ├── (Opcional) Instala escritorio si INSTALL_DESKTOP=true
          ├── Instala agente Wazuh desde repositorio oficial
          ├── Configura ossec.conf con manager IP
          ├── Configura UFW (firewall)
          └── Configura auditd con reglas de monitoreo
```

---

## Solución de Problemas

### "Cannot find a bridged network adapter"
Vagrant no puede encontrar el adaptador especificado. Verifica que `BRIDGE_IFACE` en el `Vagrantfile` coincida exactamente con el nombre del adaptador.

### "The domain controller could not be contacted"
El DC del Integrante B no está accesible. Verifica:
1. El equipo B está encendido y el Vagrantfile del DC fue ejecutado.
2. El portátil C está conectado físicamente al Switch 1.
3. El puerto del switch está en modo access VLAN 20.
4. La IP `192.168.10.20` responde a ping desde el anfitrión.

### Las VMs Windows no obtienen IP en VLAN 20
El script configura la IP en la interfaz de red que NO es la NAT de Vagrant (10.0.2.x). Si hay problemas:
1. Abre la consola de VirtualBox.
2. En la VM, ejecuta `ipconfig /all` para ver la interfaz.
3. Si la interfaz se llama diferente a "Ethernet 2", ajusta el script o usa el selector manual.

### El agente Wazuh no se registra
1. Verifica que el SIEM (`192.168.30.10`) esté activo: `ping 192.168.30.10`
2. En Linux: `sudo systemctl status wazuh-agent && sudo tail -f /var/ossec/logs/ossec.log`
3. En Windows: Revisar `C:\Program Files (x86)\ossec-agent\ossec.log`
4. Asegúrate de que los puertos 1514-1515 TCP/UDP no estén bloqueados por ACLs del router.

### La instalación de escritorio en Ubuntu tarda demasiado
Si usas la box `ubuntu/jammy64` con `INSTALL_DESKTOP=true`, la descarga e instalación del escritorio puede tomar 20-40 minutos con una buena conexión. Se recomienda usar la box `lxdware/ubuntu-desktop-22-04` que ya incluye GUI.

### vagrant-reload no está instalado
```bash
vagrant plugin install vagrant-reload
```

---

## IPs y Servicios del Laboratorio

| Máquina | IP | Función | Integrante |
|---|---|---|---|
| DC / DNS | 192.168.10.20 | Controlador de Dominio Windows Server | B |
| Web Server | 192.168.10.10 | Servidor Web Ubuntu | B |
| SIEM / Wazuh | 192.168.30.10 | Servidor Wazuh | A |
| Kali Attacker | 192.168.30.20 | Máquina atacante | A |
| win10-01 | **192.168.20.30** | Estación Windows 10 | **C** |
| win10-02 | **192.168.20.31** | Estación Windows 10 | **C** |
| linux-01 | **192.168.20.40** | Estación Ubuntu Desktop | **C** |
| linux-02 | **192.168.20.41** | Estación Ubuntu Desktop | **C** |

---

## Notas de Seguridad del Laboratorio

- Las ACLs del router solo permiten tráfico desde VLAN 20 hacia VLAN 10 en puertos: 80, 443, 53, 88, 445.
- El tráfico de agentes Wazuh (puertos 1514-1516) debe estar permitido desde VLAN 20 hacia VLAN 30 (`192.168.30.10`). Verificar con el Integrante A si los agentes no se conectan.
- Las estaciones Windows se unen al dominio `empresa.local` con usuario `Administrator`. Para usuarios normales de dominio, usar `user1@empresa.local` (coordinar con Integrante B).
- La contraseña del dominio (`P@ssw0rd`) debe coincidir con la configurada por el Integrante B al crear el DC.

---

*Generado para el proyecto de grado — Laboratorio de Ciberseguridad SIEM*
