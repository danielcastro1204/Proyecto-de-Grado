# �️ Servidores VLAN 10 — Integrante B (Lenovo Legion 5)

Componentes de **Integrante B** del laboratorio de ciberseguridad SIEM con Wazuh. Este computador ejecuta los servidores críticos de la infraestructura en la VLAN 10 (Servidores).

---

## 📋 Contenido

1. [Topología y objetivo](#topología-y-objetivo)
2. [Máquinas virtuales](#máquinas-virtuales)
3. [Requisitos previos](#requisitos-previos)
4. [Instalación](#instalación)
5. [Verificación](#verificación)
6. [Credenciales](#credenciales)
7. [Arquitectura de red](#arquitectura-de-red)

---

## 🌐 Topología y objetivo

Este proyecto implementa un laboratorio de ciberseguridad **distribuido en 3 equipos diferentes**:

| Integrante | Equipo | VLAN | Rol | IPs |
|---|---|---|---|---|
| **A** | ASUS TUF | 30 (Gestión) | SIEM Wazuh + Kali | 192.168.30.10 / 192.168.30.20 |
| **B** (Tú) | Lenovo Legion 5 | 10 (Servidores) | DC + Servidor Web | 192.168.10.10 / 192.168.10.20 |
| **C** | Acer Nitro | 20 (Usuarios) | Estaciones Windows/Linux | 192.168.20.30-41 |

**Tu responsabilidad:** Ejecutar los servidores en VLAN 10 (este directorio).

---

## 💻 Máquinas virtuales a crear

Solo **2 VMs** en VLAN 10:

| Nombre | Box | IP | CPU | RAM | Rol |
|---|---|---|---|---|---|
| web-server | ubuntu/jammy64 | 192.168.10.10 | 1 | 1 GB | Servidor Apache2 |
| windows-dc | windows_server_2019 | 192.168.10.20 | 2 | 2 GB | Controlador de Dominio AD |

> **Nota:** Los equipos de Integrante C ejecutan las estaciones (VLAN 20). Los de Integrante A ejecutan el SIEM (VLAN 30).

---

## ✅ Requisitos previos

### En tu portátil (Lenovo Legion 5)

| Software | Versión | Descarga |
|---|---|---|
| VirtualBox | 7.0+ | https://www.virtualbox.org |
| Vagrant | 2.3+ | https://www.vagrantup.com |
| Git | cualquiera | https://git-scm.com |

### Plugin Vagrant obligatorio

```bash
vagrant plugin install vagrant-reload
```

### Configuración de red física

Tu portátil debe estar conectado al **Switch 1 (Catalyst 2960)** en un **puerto configurado como access VLAN 10**.

### ⚠️ Requisito crítico: Acceso a internet

**Durante el aprovisionamiento (vagrant up), las VMs necesitan internet para:**
- ✅ Descargar paquetes del sistema (apt-get, Windows Update)
- ✅ Descargar el agente Wazuh (desde wazuh.com)
- ✅ Sincronizar NTP (pool.ntp.org)
- ✅ Resolver DNS

**Dependencia: El Router Cisco ISR4321 DEBE estar activo en 192.168.10.1**

Sin el router, los scripts se bloquearán en descarga de paquetes. Si no tienes router físico aún, considera:

1. **Opción A (Recomendado):** Configurar un adaptador NAT en VirtualBox antes de bridge para bootstrap inicial
2. **Opción B:** Usar caché de paquetes local si ya existe
3. **Opción C:** Saltarse algunas fases si tienes paquetes preinstalados

---

## 🚀 Instalación

### Paso 0: Configurar adaptador de red

El Vagrantfile necesita saber el nombre de tu adaptador de red física. Encuentra el nombre:

**En Windows (PowerShell):**
```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription
```

**En Linux/macOS:**
```bash
ip link show
# o
ifconfig
```

Anota el nombre exacto (ej: "Ethernet 1", "enp3s0", etc.)

### Paso 1: Editar el Vagrantfile

Abre [Servidores/Vagrantfile](Vagrantfile) y reemplaza:

```ruby
BRIDGE_INTERFACE = ""   # <-- Cambiar esto
```

Con tu adaptador real:

```ruby
BRIDGE_INTERFACE = "Ethernet 1"   # Ejemplo Windows
# o
BRIDGE_INTERFACE = "enp3s0"       # Ejemplo Linux
```

### Paso 2: Levantar el Controlador de Dominio

**IMPORTANTE:** Levanta primero el DC, antes que web-server.

```bash
cd Servidores
vagrant up windows-dc

# Esperar a que finalice (30-40 minutos con reinicios automáticos)
# Monitoriza el progreso con:
vagrant status
```

**¿Por qué primero?** Porque web-server.sh lo usa como DNS (192.168.10.20)

### Paso 3: Levantar el servidor Web

```bash
vagrant up web-server

# Esperar a que finalice (10-15 minutos)
```

### Paso 4: Verificar que el SIEM está accesible

Antes de considerar completado este integrante, verifica que:
- ✅ El SIEM en 192.168.30.10 (Integrante A) esté UP
- ✅ Los agentes Wazuh en ambas VMs estén registrados

```bash
# Desde web-server
vagrant ssh web-server -c "curl -s http://192.168.30.10/api/info"

# O verifica logs
vagrant ssh web-server -c "sudo tail -20 /var/log/wazuh-agent.log"
```

### Alternativa: Levantarlos juntos (si el SIEM ya está UP)

```bash
vagrant up   # Levanta ambas VMs

# Pero espera a que windows-dc termine completamente antes de ver web-server
```

---

## 🌍 Acceso a internet durante aprovisionamiento

### Flujo de conectividad esperado:

```
Tu portátil (Lenovo Legion 5)
    ↓
Adaptador de red física (BRIDGE_INTERFACE)
    ↓
Switch 1 (Cisco Catalyst 2960)
    ↓ (Puerto access VLAN 10)
Router Cisco ISR4321 (192.168.10.1) ← NECESARIO
    ↓
Internet (si existe ruta hacia allá)
    ↓
Repositorios APT / wazuh.com / pool.ntp.org
```

### ¿Qué pasa si no hay Router?

| Escenario | Resultado |
|---|---|
| **Router está DOWN** | `apt-get update` se bloquea, vagrant up falla tras timeout ~15 min |
| **Router existe pero sin salida a internet** | VMs obtienen IP local (192.168.10.x) pero no pueden descargar paquetes |
| **No hay acceso a pool.ntp.org** | Sincronización NTP falla (DC post-reinicio puede tener reloj desincronizado) |

### Soluciones si aún no tienes router físico:

1. **Usar bridge + NAT local (temporal):**
   - Modifica Vagrantfile: Agrega adaptador NAT adicional además de bridge
   - Permite bootstrap inicial
   - Después remueve NAT para producción

2. **Descargar paquetes en host y servir localmente:**
   - Crea repositorio APT local en tu portátil
   - Configura VMs para usar caché local

3. **Esperar:** Configura VMs cuando el Router esté listo

---

## ✔️ Verificación del entorno

### Estado de las VMs

```bash
vagrant status
```

Salida esperada:
```
windows-dc       running (virtualbox)
web-server       running (virtualbox)
```

### Verificar conectividad entre VLANs

Desde una VM de Integrante C (VLAN 20):
```bash
ping 192.168.10.20   # Ping al DC
ping 192.168.10.10   # Ping al servidor web
```

### Ver logs del servidor web

```bash
vagrant ssh web-server -c "sudo tail -f /var/log/apache2/access.log"
```

### Ver estado del DC

```bash
vagrant winrm windows-dc -c "Get-ADDomain" --shell=powershell
```

---

## 🔑 Credenciales

### Máquinas Vagrant (SSH/WinRM)

| VM | Usuario | Contraseña |
|---|---|---|
| web-server | vagrant | vagrant |
| windows-dc | vagrant | vagrant |

### Active Directory — dominio `empresa.local`

| Usuario | Contraseña | Rol |
|---|---|---|
| Administrator | P@ssw0rd | Admin dominio |
| user1 | User123! | Usuario estándar |
| wazuh-svc | WazuhSvc2024! | Cuenta de servicio |

---

## 🌐 Arquitectura de red

```
        ┌─────────────────────┐
        │ Router Cisco ISR4321 │
        │  (192.168.10.1)      │
        └──────────┬───────────┘
                   │
        (Puerto Gig0/0/0 — trunk)
                   │
        ┌──────────┴─────────┐
        │   Switch 1 (2960)   │
        │  (VLAN 10 + 20)     │
        └──────────┬──────────┘
                   │
    ┌──────────────┴──────────────┐
    │                              │
 VLAN 10                        VLAN 20
    │                              │
 Equipo B (TU PORTÁTIL)      Equipo C (Otro portátil)
 Lenovo Legion 5              Acer Nitro
    │                              │
 ┌──┴──┐                      ┌────┴─────┐
 │     │                      │    │  │   │
web   DC                    Win1 Win2 Lx1 Lx2

Tu equipo solo ejecuta las VMs en VLAN 10 (web-server y windows-dc).
Conectados vía Switch 1 a través de red puente (bridge).
```

---

## 🔧 Comandos útiles

```bash
# Ver estado
vagrant status

# SSH a una VM
vagrant ssh web-server

# WinRM a Windows (PowerShell)
vagrant winrm windows-dc --shell=powershell

# Reprovisionar (re-ejecutar scripts)
vagrant provision windows-dc

# Detener (suspender)
vagrant suspend

# Apagar
vagrant halt

# Destruir y recrear
vagrant destroy -f && vagrant up windows-dc && vagrant up web-server
```

---

## 📝 Notas importantes

1. **Tu adaptador de red debe estar en VLAN 10** en el Switch 1.
2. **El SIEM (Integrante A) debe estar UP** antes de levantar tus servidores.
3. **Los agentes Wazuh** se instalan automáticamente en web-server y windows-dc, apuntando a 192.168.30.10.
4. **El DC gestiona el dominio `empresa.local`** que usan los equipos de Integrante C.
5. **IP fija configurada automáticamente** por los scripts mediante Netplan (Linux) y PowerShell (Windows).

---

## ❓ Solución de problemas

### "No puedo conectar al puente"

- Verifica que tu portátil esté conectado físicamente al Switch 1.
- Comprueba el nombre correcto del adaptador con `ipconfig` o `ip link`.
- Reinicia VirtualBox.

### "El DC no obtiene IP"

- Verifica que el Switch 1 tenga configurado el puerto como access VLAN 10.
- Revisa que BRIDGE_INTERFACE esté correctamente configurado en el Vagrantfile.

### "Los agentes no se conectan al SIEM"

- Verifica que el SIEM (192.168.30.10) esté accesible desde tu VLAN.
- Confirma que el Integrante A tiene el servidor Wazuh UP.
- Revisa firewall en el router Cisco (ACL).



---

*Proyecto de Grado — Laboratorio de Ciberseguridad SIEM — Integrante B*
