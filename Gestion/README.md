# Proyecto de Grado — Laboratorio de Ciberseguridad
## Integrante A · VLAN 30 (Gestión) · ASUS TUF Gaming A15

---

## Propósito de estas máquinas

Este directorio automatiza el despliegue de las **dos VMs del Integrante A** dentro del laboratorio segmentado por VLANs del proyecto de grado en ciberseguridad:

| VM | Rol | IP | Box |
|----|-----|----|-----|
| `wazuh` | Servidor SIEM (Wazuh all-in-one) | `192.168.30.10/24` | ubuntu/jammy64 |
| `kali`  | Estación atacante (pentesting)   | `192.168.30.20/24` | kalilinux/rolling |

### Contexto global de la red

```
Internet (temporal, solo durante aprovisionamiento)
        │
   Router Cisco ISR4321
   ├── Gig0/0/0 → Switch 1 (Cisco Catalyst 2960)
   │     ├── VLAN 10 Servidores  192.168.10.0/24  (Integrante B)
   │     │     ├── DC Windows Server  192.168.10.20
   │     │     └── Web Ubuntu Server  192.168.10.10
   │     └── VLAN 20 Usuarios    192.168.20.0/24  (Integrante C)
   │           ├── Windows 10/11  192.168.20.30, .31
   │           └── Ubuntu Desktop 192.168.20.40, .41
   └── Gig0/0/1 → Switch 2 (no administrable)
         └── VLAN 30 Gestión     192.168.30.0/24  (Integrante A ← AQUÍ)
               ├── SIEM Wazuh    192.168.30.10  ← esta VM
               └── Kali Linux    192.168.30.20  ← esta VM
```

- El **SIEM** recibe logs de todos los agentes (VLANs 10 y 20) y syslog del router Cisco (UDP 514).
- **Kali** lanza ataques controlados contra objetivos en VLAN 10 y VLAN 20, generando eventos que el SIEM captura y correlaciona.
- El enrutamiento inter-VLAN está habilitado en el router con ACL que limitan acceso desde VLAN 20 a VLAN 10 (puertos 80, 443, 53, 88, 445).

---

## Estructura del proyecto

```
proyecto_siem_integrante_A/
├── Vagrantfile              ← Define las dos VMs (wazuh + kali)
├── scripts/
│   ├── wazuh-server.sh      ← Aprovisionamiento Wazuh all-in-one
│   └── kali-attacker.sh     ← Aprovisionamiento Kali + herramientas
└── README.md                ← Este archivo
```

---

## Requisitos previos

| Software | Versión mínima | Descarga |
|----------|---------------|---------|
| VirtualBox | 6.1+ | https://www.virtualbox.org |
| Vagrant | 2.3+ | https://www.vagrantup.com |
| RAM disponible | 6 GB+ | — |
| Espacio en disco | 40 GB+ | — |
| Conexión a Internet | Requerida durante `vagrant up` | — |

---

## Ajustar la interfaz de red puente (OBLIGATORIO)

En el archivo `Vagrantfile`, la variable `BRIDGE_INTERFACE` debe coincidir con el nombre de la interfaz física de tu portátil que está conectada al **Switch 2**.

```ruby
# Línea 22 del Vagrantfile:
BRIDGE_INTERFACE = "enp3s0"   # <-- CAMBIA ESTO
```

### Cómo encontrar el nombre correcto

**Linux:**
```bash
ip link show
# o
nmcli device status
```
Busca la NIC que tiene el cable conectado al switch (estado UP). Ejemplo: `enp3s0`, `eth0`, `eno1`.

**Windows (WSL o Git Bash):**
```bash
ipconfig /all
```
Copia el nombre completo tal como aparece, por ejemplo: `"Intel(R) Wi-Fi 6 AX200 160MHz"` o `"Realtek PCIe GbE Family Controller"`.

> **Nota:** Si dejas `BRIDGE_INTERFACE = ""` (vacío) o usas una interfaz incorrecta, Vagrant te preguntará interactivamente cuál usar durante `vagrant up`.

---

## Ejecutar el laboratorio

### Primera vez (aprovisionamiento completo)

```bash
cd proyecto_siem_integrante_A/

# Levantar ambas VMs (puede tardar 20-40 minutos)
vagrant up

# O levantar solo una:
vagrant up wazuh
vagrant up kali
```

> **Tiempo estimado:**
> - `kali` : ~5-10 minutos (descarga box + instalación herramientas)
> - `wazuh`: ~20-35 minutos (descarga box + instalación Wazuh all-in-one)

### Comandos útiles

```bash
# Ver estado de las VMs
vagrant status

# Conectarse por SSH
vagrant ssh wazuh
vagrant ssh kali

# Reiniciar una VM
vagrant reload wazuh

# Re-ejecutar aprovisionamiento (idempotente)
vagrant provision wazuh
vagrant provision kali

# Apagar las VMs
vagrant halt

# Destruir y recrear desde cero
vagrant destroy -f && vagrant up
```

---

## Credenciales

| VM | Usuario | Contraseña | Notas |
|----|---------|-----------|-------|
| wazuh | `vagrant` | `vagrant` | SSH estándar de Vagrant |
| wazuh | `root` | — | Acceso via `sudo -i` desde vagrant |
| kali | `vagrant` | `vagrant` | SSH estándar de Vagrant |
| kali | `attacker` | `attacker` | Usuario de pentesting (sudo sin pass) |
| Wazuh Dashboard | `admin` | *generada* | Ver `/root/wazuh_passwords.txt` en la VM |

### Obtener contraseña del Dashboard Wazuh

```bash
# Opción 1: desde la VM
vagrant ssh wazuh
sudo cat /root/wazuh_passwords.txt

# Opción 2: con el script oficial de Wazuh
vagrant ssh wazuh
sudo /usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh --api
```

Accede al dashboard en: **https://192.168.30.10**
(acepta el certificado autofirmado en el navegador)

---

## Verificación de conectividad

Una vez levantadas las VMs, verifica la red desde cada máquina:

### Desde la VM Wazuh (`vagrant ssh wazuh`)

```bash
# Verificar IP asignada
ip addr show enp0s8

# Ping al gateway (VLAN 30)
ping -c 3 192.168.30.1

# Ping a otras VLANs (routing inter-VLAN)
ping -c 3 192.168.10.1    # Gateway VLAN 10
ping -c 3 192.168.20.1    # Gateway VLAN 20

# Verificar servicios Wazuh activos
sudo systemctl status wazuh-manager
sudo systemctl status wazuh-indexer
sudo systemctl status wazuh-dashboard

# Verificar que el dashboard responde
curl -sk https://localhost | head -20

# Verificar puerto syslog UDP 514
sudo ss -ulnp | grep 514
```

### Desde la VM Kali (`vagrant ssh kali`)

```bash
# Verificar IP asignada
ip addr show eth1

# Ping al gateway
ping -c 3 192.168.30.1

# Ping al SIEM
ping -c 3 192.168.30.10

# Ping a otras VLANs
ping -c 3 192.168.10.1
ping -c 3 192.168.20.1

# Verificar herramientas disponibles
nmap --version
msfconsole --version
sqlmap --version
hydra --version
```

### Verificar recepción de syslog (Wazuh)

Desde el router Cisco, configura el envío de logs:
```cisco
logging host 192.168.30.10 transport udp port 514
logging trap informational
```

Luego en Wazuh verifica:
```bash
sudo tail -f /var/ossec/logs/alerts/alerts.json | grep -i "cisco\|syslog"
```

---

## Troubleshooting frecuente

### La VM no obtiene la IP estática

La IP estática se configura en la segunda NIC (interfaz puente). Verifica el nombre de la interfaz dentro de la VM:
```bash
vagrant ssh wazuh
ip link show    # debería mostrar enp0s8 o similar
```
Si el nombre es diferente, edita `scripts/wazuh-server.sh` y cambia la variable `IFACE="enp0s8"` por el nombre correcto. Lo mismo para Kali con `IFACE_BRIDGE="eth1"`.

### Vagrant pregunta qué interfaz puente usar

Ajusta `BRIDGE_INTERFACE` en el `Vagrantfile` con el nombre exacto de tu NIC (ver sección anterior).

### Error de instalación de Wazuh por falta de Internet

Durante `vagrant up`, el portátil necesita acceso a Internet (puede ser WiFi temporal). Si el laboratorio está aislado, conecta temporalmente a otra red durante el aprovisionamiento.

### Puerto 514 no escucha

Verifica que `ossec.conf` tenga el bloque `<remote>` para syslog y reinicia el manager:
```bash
vagrant ssh wazuh
sudo grep -A5 "syslog" /var/ossec/etc/ossec.conf
sudo systemctl restart wazuh-manager
```

---

## Notas de seguridad del laboratorio

- Las contraseñas de `attacker/attacker` y `vagrant/vagrant` son intencionalmente débiles para facilidad en laboratorio controlado. **No usar en producción.**
- El certificado SSL del dashboard Wazuh es autofirmado; los navegadores mostrarán advertencia.
- Los ataques desde Kali generarán alertas visibles en el dashboard SIEM, lo cual es el comportamiento esperado del laboratorio.
