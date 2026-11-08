# Reporte — Conversión del laboratorio SIEM a red dual-stack (IPv4 + IPv6)

**Fecha:** 8 de noviembre de 2026
**Objetivo:** añadir direccionamiento IPv6 a toda la infraestructura existente (VPC, subredes, instancias y servicios) para que la red opere en **dual-stack**, sin introducir un servicio DHCPv6, y validar que el SIEM detecta amenazas también sobre IPv6.

---

## 1. Resumen

El laboratorio pasó de ser IPv4 puro a **dual-stack IPv4+IPv6 real**. Se añadió IPv6 a la red y a los servicios ya existentes (no se agregó DHCPv6). Se validó conectividad, servicios y **detección de ataques con origen IPv6** de extremo a extremo.

| Capa | Estado dual-stack |
|---|---|
| VPC / subredes / enrutamiento | ✅ IPv6 /56 de Amazon, /64 por subred, ruta ::/0 (egress-only) |
| Instancias (9) | ✅ cada una con dirección IPv6 (GUA) |
| Conectividad intra-VPC IPv6 | ✅ ping6 y TCP entre VLANs, 0% pérdida |
| Servicios (HTTP, SSH, DNS) | ✅ escuchan y responden sobre IPv6 |
| Resolución de nombres | ✅ /etc/hosts dual-stack + DNS con registros AAAA (y BIND sirviendo por IPv6) |
| Detección SIEM sobre IPv6 | ✅ escaneo, SQLi y fuerza bruta SSH detectados con `srcip` IPv6 |

---

## 2. Cambios realizados (sobre lo que ya existía)

### 2.1 Red (CloudFormation `cloudformation/siem-lab.yaml`)

- **VPC:** se asocia un bloque **IPv6 /56 de Amazon** (`AWS::EC2::VPCCidrBlock`, `AmazonProvidedIpv6CidrBlock`).
- **Subredes (3):** cada una recibe un **/64** derivado del /56 (`Fn::Cidr`) y `AssignIpv6AddressOnCreation: true`.
- **Enrutamiento IPv6:** se añade un **Egress-Only Internet Gateway** y la ruta `::/0` hacia él. Las instancias obtienen IPv6 saliente e intra-VPC **sin quedar expuestas al Internet IPv6** (los ataques del laboratorio son intra-VPC; la administración entra por IPv4).
- **Security Groups:** reglas de ingreso IPv6 para tráfico intra-lab (alcanzables solo dentro de la VPC por el egress-only gateway).
- **Instancias (9):** cada una solicita una dirección IPv6 (`Ipv6AddressCount: 1`).

### 2.2 Servicios (scripts `userdata/`)

- **`_common.sh` → `habilitar_ipv6()`:** configura netplan (`dhcp6: true`, `accept-ra: true`) para que cada host **levante su IPv6**. Se invoca en el aprovisionamiento común de todos los hosts Linux.
- **`dns1-server.sh`:** BIND con `listen-on-v6 { any; }` → **DNS dual-stack**; se añadieron registros **AAAA** para los servidores.
- **Firewall:** ya usaba nftables `table inet` (**dual-stack nativo**): registra también las conexiones IPv6, por lo que la correlación de escaneo (regla 100022) funciona sobre IPv6 sin cambios.
- **Apache y SSH:** escuchan sobre IPv6 con su configuración por defecto (verificado).

---

## 3. Direccionamiento IPv6 asignado

Bloque de la VPC: **`2600:1f18:11e4:1300::/56`** — un /64 por subred (…1300 servidores, …1301 clientes, …1302 gestión).

| Host | IPv4 privada | IPv6 (GUA) |
|---|---|---|
| siem-wazuh | 10.0.30.10 | 2600:1f18:11e4:1302:e086:25c2:4691:950d |
| fw-gateway | 10.0.30.30 | 2600:1f18:11e4:1302:5383:fd40:27af:a01c |
| atacante | 10.0.30.20 | 2600:1f18:11e4:1302:7f18:7eaf:bbb7:23ea |
| web-server | 10.0.10.10 | 2600:1f18:11e4:1300:d032:3b84:dba0:68c8 |
| dc-empresa | 10.0.10.20 | 2600:1f18:11e4:1300:224c:fae8:8c79:60eb |
| dns1-server | 10.0.10.50 | 2600:1f18:11e4:1300:1cf1:f83c:5:82e4 |
| ntp-server | 10.0.10.80 | 2600:1f18:11e4:1300:d93a:a73f:aeac:3937 |
| win-ws-01 | 10.0.20.30 | 2600:1f18:11e4:1301:60a7:208b:fad7:363e |
| linux-01 | 10.0.20.40 | 2600:1f18:11e4:1301:500:56aa:e0ef:bddd |

> Nota: con IPv6 proporcionado por Amazon, el prefijo /56 se asigna en el despliegue (no es predecible de antemano), por lo que las direcciones de host son dinámicas. La resolución de nombres se resuelve con DNS (AAAA) y `/etc/hosts` dual-stack generados tras el despliegue.

---

## 4. Validación

### 4.1 Conectividad IPv6 (desde el atacante)

- `ping6` al web-server (cruza de VLAN30 a VLAN10): **0% de pérdida**.
- `ping6` al firewall (misma VLAN) y a linux-01 (VLAN clientes): **0% de pérdida**.
- `curl -6 http://[web-server-IPv6]/` → **HTTP 200** (Apache responde por IPv6).

### 4.2 Resolución de nombres dual-stack

- `dig AAAA web-server.empresa.local @dns1` → devuelve la IPv6.
- Consulta DNS dirigida a la **IPv6 del servidor DNS** → responde (BIND escucha por IPv6).
- `curl -6 http://web-server/` (por nombre) → **HTTP 200** sobre IPv6.
- `getent ahosts web-server` → devuelve **IPv4 e IPv6** (dual-stack).

### 4.3 Detección de ataques con origen IPv6 (el SIEM)

Se lanzaron tres ataques desde el atacante usando su IPv6 (`2600:1f18:11e4:1302:7f18:7eaf:bbb7:23ea`) como origen. El SIEM los detectó, registrando la IPv6 en el campo `srcip`:

| Ataque (IPv6) | Regla disparada | Evidencia |
|---|---|---|
| Escaneo de puertos (`nmap -6` al firewall) | **100022** | `srcip=2600:1f18:11e4:1302:7f18:7eaf:bbb7:23ea` |
| Inyección SQL (`curl -6` al web) | **100040** | `srcip=2600:1f18:11e4:1302:7f18:7eaf:bbb7:23ea` |
| Fuerza bruta SSH (`hydra -6` a linux-01) | **5760** | `srcip=2600:1f18:11e4:1302:7f18:7eaf:bbb7:23ea` |

Esto confirma que las fuentes de log (firewall nftables `inet`, Apache, sshd) y las reglas de correlación del proyecto operan **independientemente de la familia de direcciones**: la detección funciona igual sobre IPv6 que sobre IPv4.

---

## 5. Conclusión

El laboratorio SIEM es ahora **dual-stack IPv4+IPv6**: toda la infraestructura y los servicios existentes recibieron direccionamiento IPv6, la red enruta IPv6 intra-VPC, los servicios responden por ambas familias, la resolución de nombres es dual-stack y **el SIEM detecta amenazas con origen IPv6** con las mismas reglas. El direccionamiento IPv6 y la configuración de servicios se aprovisionan automáticamente desde CloudFormation/userdata, de modo que la propiedad dual-stack es reproducible. No se añadió DHCPv6: las instancias obtienen su IPv6 por SLAAC/RA de la VPC.

---

## 9. Validación formal: los 3 escenarios ejecutados SOBRE IPv6

Además de la validación de conectividad y detección puntual, se ejecutaron los **3 escenarios completos de la metodología con los ataques y el tráfico dirigidos a direcciones IPv6**, para medir la detección de forma cuantitativa sobre IPv6. Las herramientas de ataque se adaptaron a dual-stack (hallazgo de tooling): nmap `-6`, hydra `-6`, sqlmap/curl con `[IPv6]`, Impacket con `-target-ip`, y evil-winrm por nombre que resuelve a IPv6.

| Escenario (IPv6) | Detección estricta | Amplia | Precisión | F1 | FP accionables |
|---|---|---|---|---|---|
| **E1 — Línea base** | — (sin ataques) | — | — | — | **0** (1631 alertas, 224 con IPv6) |
| **E2 — Ataques** | **77.5%** (31/40) · **núcleo 5 técnicas 100%** | 100% | **100%** | 87.3% | **0 / 1593** |
| **E3 — Mixto (bajo carga)** | **100%** (12/12) | 100% | **96.7%** | 98.3% | 21 / 645 |

- Las **5 técnicas MITRE de la metodología se detectan al 100% de forma estricta sobre IPv6** (igual que sobre IPv4), con los objetivos y el `srcip` en direcciones IPv6 (`2600:1f18:11e4:…`).
- Las variantes de evasión (escaneo sigiloso, SQLi ofuscado) evaden parcialmente, igual que en IPv4 — es un comportamiento **independiente de la familia de direcciones**.
- **0 falsas alarmas accionables** en la línea base IPv6.

**Conclusión:** la capacidad de detección del SIEM es **equivalente sobre IPv4 e IPv6**. Las fuentes de log (firewall nftables `inet`, Apache, sshd, Sysmon) y las reglas de correlación operan igual con direcciones IPv6, confirmando que el laboratorio es dual-stack de extremo a extremo tanto en la red como en la detección.

### Evidencia complementaria (carpeta `evidencias/`)
- `evidencia_dualstack_terminal.txt` — conectividad IPv6, HTTP/IPv6, DNS AAAA, firewall registrando IPv6.
- `evidencia_ataques_terminal.txt` — ejecución de los ataques sobre IPv6 (hydra -6, nmap -6, secretsdump -target-ip, evil-winrm).
