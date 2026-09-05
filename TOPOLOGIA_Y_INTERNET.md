# 🌐 Topología de Red y Acceso a Internet - Proyecto SIEM

## 📋 Resumen de cambios realizados

### ✅ Distribución de equipos (CORREGIDA)

Cada integrante ejecuta **SOLO sus VMs** en su VLAN asignada:

```
┌─────────────────────────────────────────────────────────────┐
│                  Router Cisco ISR4321                        │
│          (192.168.10.1 / 192.168.20.1 / 192.168.30.1)      │
└──────────────┬──────────────────────┬──────────────────────┘
               │                      │
          Switch 1              Switch 2 (no admin)
         (2960 Admin)                 │
         ┌────┴────┐                  │
       VLAN10    VLAN20           VLAN30
         │         │                  │
    [IntB]    [IntC]             [IntA]
  (Lenovo)   (Acer)             (ASUS)
```

| Integrante | Equipo | VLAN | Vagrantfile ubicación | VMs | IPs |
|---|---|---|---|---|---|
| **A** | ASUS TUF | 30 | Gestión/ | wazuh, kali | 192.168.30.10-20 |
| **B** (Tú) | Lenovo Legion | 10 | Servidores/ | web-server, windows-dc | 192.168.10.10, 192.168.10.20 |
| **C** | Acer Nitro | 20 | Workstations/ | win10-01/02, linux-01/02 | 192.168.20.30-41 |

---

## 🌍 Acceso a Internet

### ✅ SÍ, tendrán acceso a internet SI:

1. **El Router Cisco ISR4321 está activo** en 192.168.10.1
2. **Tu adaptador de red está en VLAN 10** (Switch 1, puerto access)
3. **El router tiene salida a internet** (conexión física/lógica)

### ⚠️ ¿Qué necesitan descargar?

Durante `vagrant up`, las VMs descargarán:

| Componente | Fuente | Tamaño | Requerido |
|---|---|---|---|
| Paquetes Ubuntu | archive.ubuntu.com | ~500 MB | ✅ Sí |
| Agente Wazuh | packages.wazuh.com | ~150 MB | ✅ Sí (se intenta instalar) |
| NTP (pool.ntp.org) | pool.ntp.org | - | ✅ Sí (sincronización) |
| Roles Windows (AD DS) | Windows Update (en box) | ~200 MB | ✅ Sí (si no está en box) |

**Total aprox:** ~900 MB descargables

### Flujo de conectividad actual:

```
VirtualBox VM (web-server)
    ↓ IP 192.168.10.10
Bridge adapter
    ↓
tu adaptador físico (BRIDGE_INTERFACE)
    ↓
Switch 1 - Puerto Access VLAN 10
    ↓
Router Cisco ISR4321 (192.168.10.1) ← AQUÍ ES CRÍTICO
    ↓
Fuera de VLAN (si el router permite)
    ↓
Internet
```

---

## 🔧 Cambios específicos realizados

### 1. Servidores/Vagrantfile
- ✅ Hostname DC: `dc-empresa` → `WIN-DC01`
- ✅ Ambas VMs usan `public_network` bridge (no private_network)
- ✅ `auto_config: false` (IP se configura por script, no DHCP)

### 2. Servidores/scripts/web-server.sh
- ✅ **NUEVO PASO 0:** Valida conectividad ANTES de descargar
  - Espera a que interfaz obtenga IP
  - Verifica que gateway (192.168.10.1) esté accesible
  - Reintenta 30 veces (60 segundos)
  - Advierte si falla: "Gateway no accesible, posiblemente Router Cisco está DOWN"

- ✅ Wazuh versión: `4.x` → `4.9.2`
- ✅ DNS fallback: Configura 8.8.8.8 como respaldo si DC no responde

### 3. Servidores/scripts/windows-dc.ps1
- ✅ Comentario actualizado: Advierte sobre requisito de NTP (requiere internet)
- ✅ Comentario: "El Router Cisco ISR4321 DEBE estar activo en 192.168.10.1"

### 4. Servidores/README.md
- ✅ Nueva sección: "⚠️ Requisito crítico: Acceso a internet"
- ✅ Tabla de escenarios: ¿Qué pasa si no hay router?
- ✅ Soluciones: NAT temporal, repositorio local, esperar al router
- ✅ Orden de instalación: DC primero, luego web-server

---

## ⏱️ Orden de levantamiento IMPORTANTE

```bash
# 1. PRIMERO: Asegurar que el SIEM (Integrante A) está UP
#    IP: 192.168.30.10

# 2. LUEGO: Levantar DC (tarda 30-40 min)
cd Servidores
vagrant up windows-dc

# 3. FINALMENTE: Levantar web-server (tarda 10-15 min)
vagrant up web-server

# 4. VERIFICAR: Agentes Wazuh registrados en SIEM
```

---

## 📝 Dependencias resumidas

| Componente | Depende de | Impacto si falla |
|---|---|---|
| **web-server.sh** | DNS (DC 192.168.10.20) | Bloquea descarga de paquetes |
| **web-server.sh** | Internet (vía router) | Falla apt-get, Wazuh agent |
| **windows-dc.ps1** | NTP (pool.ntp.org) | Reloj del DC desincronizado |
| **windows-dc.ps1** | Internet | Falla descarga de roles AD |
| **Ambas** | Gateway 192.168.10.1 | Sin conectividad de salida |

---

## ✅ Validación final

**Todo quedó consistente en:**
- ✅ IPs por VLAN (10, 20, 30)
- ✅ SIEM siempre en 192.168.30.10
- ✅ Gateways correctos (10.1, 20.1, 30.1)
- ✅ DNS configurado dinámicamente
- ✅ Redes usando bridge (topología física)
- ✅ Documentación clara sobre internet
- ✅ Orden de levantamiento claro

**Status:** 🟢 **Listo para usar**

