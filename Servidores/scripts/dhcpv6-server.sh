#!/usr/bin/env bash
# =============================================================================
# dhcpv6-server.sh  |  Servidor DHCP para IPv6 (ISC Kea) - Ubuntu 22.04 LTS
# Proyecto SIEM - Integrante B | VLAN 10 (Servidores) | 192.168.10.40
# =============================================================================
# Este script aprovisiona el servidor DHCPv6 del laboratorio. Realiza:
#   1. Actualizacion del sistema
#   2. Configuracion de IP fija dual-stack (192.168.10.40/24 + fd00:10::40/64)
#   3. Instalacion de Kea DHCP6 y su configuracion para la VLAN 20 (Clientes)
#      -> Requiere DHCPv6 relay en el router (interfaz de VLAN 20)
#   4. Configuracion del firewall UFW (puerto 547/udp)
#   5. Instalacion del agente Wazuh (apuntando al SIEM 192.168.30.10)
#   6. Configuracion de /etc/hosts y resumen final
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# VARIABLES (inyectadas desde el Vagrantfile)
# ---------------------------------------------------------------------------
VM_IP="${VM_IP:-192.168.10.40}"
VM_IP6="${VM_IP6:-fd00:10::40}"
VM_GATEWAY="${VM_GATEWAY:-192.168.10.1}"
VM_GATEWAY6="${VM_GATEWAY6:-fd00:10::1}"
VM_DNS6="${VM_DNS6:-fd00:10::50}"          # DNS1 (IPv6)
VM_DNS6_2="${VM_DNS6_2:-fd00:10::60}"      # DNS2 (IPv6)
SIEM_IP="${SIEM_IP:-192.168.30.10}"
DOMAIN="${DOMAIN:-empresa.local}"
CLIENTS_NET6="${CLIENTS_NET6:-fd00:20::/64}"
CLIENTS_GATEWAY6="${CLIENTS_GATEWAY6:-fd00:20::1}"
CLIENTS_POOL6="${CLIENTS_POOL6:-fd00:20::150 - fd00:20::200}"

SRV_IP="$VM_IP"
SRV_MASK="24"
SRV_IP6="$VM_IP6"
SRV_PREFIX6="64"
WAZUH_MANAGER="$SIEM_IP"
WAZUH_VERSION="4.9.2"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Aprovisionamiento: Servidor DHCPv6 (Kea) - Ubuntu 22.04${NC}"
echo -e "${CYAN} IP: ${SRV_IP}/${SRV_MASK}  |  ${SRV_IP6}/${SRV_PREFIX6}${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ===========================================================================
# Detectar el adaptador puente
# ===========================================================================
BRIDGE_IFACE=""
for iface in $(ls /sys/class/net | grep -v lo); do
    iface_ip=$(ip addr show "$iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || true)
    if [[ -n "$iface_ip" && "$iface_ip" != "10.0.2"* ]]; then
        BRIDGE_IFACE="$iface"; break
    fi
    if [[ -z "$iface_ip" && "$iface" != "lo" ]]; then
        BRIDGE_IFACE="$iface"
    fi
done
[[ -z "$BRIDGE_IFACE" ]] && BRIDGE_IFACE="enp0s8" && warn "No se identifico el adaptador puente. Usando $BRIDGE_IFACE."
info "Adaptador puente detectado: $BRIDGE_IFACE"
ip link set dev "$BRIDGE_IFACE" up 2>/dev/null || true
sleep 2

# ===========================================================================
# PASO 1: Actualizar el sistema
# ===========================================================================
info "PASO 1: Actualizando paquetes del sistema..."
export DEBIAN_FRONTEND=noninteractive

# Limpiar repositorios corruptos de ejecuciones fallidas anteriores
rm -f /etc/apt/sources.list.d/wazuh.list

apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
log "Sistema actualizado."

# ===========================================================================
# PASO 2: Paquetes base
# ===========================================================================
info "PASO 2: Instalando paquetes base..."
apt-get install -y -qq curl wget gnupg lsb-release ca-certificates apt-transport-https net-tools htop vim ufw
log "Paquetes base instalados."

# ===========================================================================
# PASO 3: IP fija dual-stack via Netplan
# ===========================================================================
info "PASO 3: Configurando IP fija ${SRV_IP}/${SRV_MASK} y ${SRV_IP6}/${SRV_PREFIX6}..."
NETPLAN_FILE="/etc/netplan/99-siem-static.yaml"
cat > "$NETPLAN_FILE" << EOF
# Configuracion de red estatica dual-stack - VLAN 10 - Proyecto SIEM
# Generado por Vagrant/dhcpv6-server.sh
network:
  version: 2
  renderer: networkd
  ethernets:
    ${BRIDGE_IFACE}:
      dhcp4: no
      dhcp6: no
      addresses:
        - ${SRV_IP}/${SRV_MASK}
        - ${SRV_IP6}/${SRV_PREFIX6}
      routes:
        - to: default
          via: ${VM_GATEWAY}
          metric: 100
        - to: ::/0
          via: ${VM_GATEWAY6}
          metric: 100
      nameservers:
        addresses:
          - ${VM_DNS6}
          - ${VM_DNS6_2}
        search:
          - ${DOMAIN}
EOF
chmod 600 "$NETPLAN_FILE"
netplan generate 2>/dev/null || warn "netplan generate produjo advertencias."
netplan apply 2>/dev/null || warn "netplan apply produjo advertencias."
sleep 3
log "Red dual-stack configurada en $BRIDGE_IFACE."

RETRY_COUNT=0
while [ $RETRY_COUNT -lt 10 ]; do
    if ping -c 1 -W 1 "$VM_GATEWAY" &>/dev/null; then log "Gateway $VM_GATEWAY accesible."; break; fi
    info "Gateway $VM_GATEWAY no accesible. Reintentando... ($RETRY_COUNT/10)"
    sleep 2; RETRY_COUNT=$((RETRY_COUNT + 1))
done

# ===========================================================================
# PASO 4: Habilitar reenvio de anuncios y forwarding IPv6 (requerido por Kea6)
# ===========================================================================
info "PASO 4: Habilitando forwarding IPv6..."
sed -i '/^net.ipv6.conf.all.forwarding/d' /etc/sysctl.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true
log "Forwarding IPv6 habilitado."

# ===========================================================================
# PASO 5: Instalar y configurar Kea DHCP6
# ===========================================================================
info "PASO 5: Instalando ISC Kea DHCP6..."
apt-get install -y -qq kea-dhcp6-server kea-common
log "Paquete kea-dhcp6-server instalado."

info "Configurando ${SRV_IP6}/${SRV_PREFIX6} para atender la VLAN 20 (Clientes) via DHCPv6 relay..."
cat > "/etc/kea/kea-dhcp6.conf" << EOF
{
  "Dhcp6": {
    "interfaces-config": {
      "interfaces": [ "${BRIDGE_IFACE}" ]
    },

    "control-socket": {
      "socket-type": "unix",
      "socket-name": "/run/kea/kea6-ctrl-socket"
    },

    "lease-database": {
      "type": "memfile",
      "name": "/var/lib/kea/kea-leases6.csv"
    },

    "expired-leases-processing": {
      "reclaim-timer-wait-time": 10,
      "flush-reclaimed-timer-wait-time": 25,
      "hold-reclaimed-time": 3600,
      "max-reclaim-leases": 100,
      "max-reclaim-time": 250,
      "unwarned-reclaim-cycles": 5
    },

    "renew-timer": 1000,
    "rebind-timer": 2000,
    "preferred-lifetime": 3600,
    "valid-lifetime": 7200,

    "subnet6": [
      {
        "id": 1,
        "subnet": "${CLIENTS_NET6}",
        "relay": {
          "ip-addresses": [ "${CLIENTS_GATEWAY6}" ]
        },
        "pools": [
          { "pool": "${CLIENTS_POOL6}" }
        ],
        "option-data": [
          { "name": "dns-servers", "data": "${VM_DNS6}, ${VM_DNS6_2}" },
          { "name": "domain-search", "data": "${DOMAIN}" }
        ]
      }
    ],

    "loggers": [
      {
        "name": "kea-dhcp6",
        "output_options": [
          { "output": "/var/log/kea-dhcp6.log" }
        ],
        "severity": "INFO",
        "debuglevel": 0
      }
    ]
  }
}
EOF

kea-dhcp6 -t /etc/kea/kea-dhcp6.conf && log "Sintaxis de kea-dhcp6.conf validada." || warn "kea-dhcp6.conf presenta advertencias de sintaxis."

systemctl daemon-reload
systemctl enable kea-dhcp6-server
systemctl restart kea-dhcp6-server
sleep 2
systemctl is-active --quiet kea-dhcp6-server && log "Servicio kea-dhcp6-server activo." || warn "kea-dhcp6-server no esta activo. Revisar: journalctl -u kea-dhcp6-server"

# ===========================================================================
# PASO 6: Firewall UFW
# ===========================================================================
info "PASO 6: Configurando firewall UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment 'SSH - Acceso de gestion'
ufw allow 547/udp   comment 'DHCPv6 - solicitudes de clientes/relay'
ufw allow out to "${SIEM_IP}" port 1514 proto tcp comment 'Wazuh logs'
ufw allow out to "${SIEM_IP}" port 1515 proto tcp comment 'Wazuh registro'
ufw --force enable
log "Firewall UFW configurado."
ufw status verbose

# ===========================================================================
# PASO 7: Agente Wazuh
# ===========================================================================
info "PASO 7: Instalando agente Wazuh (manager: ${WAZUH_MANAGER})..."
if systemctl is-active --quiet wazuh-agent 2>/dev/null; then
    warn "El agente Wazuh ya esta activo. Saltando instalacion."
else
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
        gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
    chmod 644 /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
        | tee /etc/apt/sources.list.d/wazuh.list
    apt-get update -qq
    WAZUH_MANAGER="${WAZUH_MANAGER}" WAZUH_MANAGER_PORT="1514" \
    WAZUH_REGISTRATION_SERVER="${WAZUH_MANAGER}" WAZUH_REGISTRATION_PORT="1515" \
    WAZUH_AGENT_NAME="dhcpv6-server" \
    apt-get install -y -qq wazuh-agent
    log "Paquete wazuh-agent instalado."

    OSSEC_CONF="/var/ossec/etc/ossec.conf"
    if [[ -f "$OSSEC_CONF" ]]; then
        grep -q "<address>MANAGER_IP</address>" "$OSSEC_CONF" && \
            sed -i "s|<address>MANAGER_IP</address>|<address>${WAZUH_MANAGER}</address>|g" "$OSSEC_CONF"
        if ! grep -q "kea-dhcp6.log" "$OSSEC_CONF"; then
            sed -i 's|</ossec_config>|  <localfile>\n    <log_format>syslog</log_format>\n    <location>/var/log/kea-dhcp6.log</location>\n  </localfile>\n\n</ossec_config>|' "$OSSEC_CONF"
            log "Monitoreo de logs de Kea agregado a ossec.conf."
        fi
    fi
    systemctl daemon-reload
    systemctl enable wazuh-agent
    systemctl start wazuh-agent
    sleep 3
    systemctl is-active --quiet wazuh-agent && log "Servicio wazuh-agent activo." || warn "wazuh-agent no esta activo."
fi

# ===========================================================================
# PASO 8: Zona horaria
# ===========================================================================
info "PASO 8: Configurando sincronizacion de tiempo..."
timedatectl set-timezone "America/Bogota"
timedatectl set-ntp true
log "Zona horaria: America/Bogota (UTC-5)."

# ===========================================================================
# PASO 9: /etc/hosts
# ===========================================================================
info "PASO 9: Actualizando /etc/hosts..."
declare -A HOSTS=(
    ["192.168.10.10"]="web-server web-server.${DOMAIN}"
    ["192.168.10.20"]="dc-empresa dc-empresa.${DOMAIN}"
    ["192.168.10.30"]="dhcpv4-server dhcpv4-server.${DOMAIN}"
    ["192.168.10.40"]="dhcpv6-server dhcpv6-server.${DOMAIN}"
    ["192.168.10.50"]="dns1-server dns1-server.${DOMAIN}"
    ["192.168.10.60"]="dns2-server dns2-server.${DOMAIN}"
    ["192.168.10.70"]="smtp-server smtp-server.${DOMAIN}"
    ["192.168.10.80"]="ntp-server ntp-server.${DOMAIN}"
    ["192.168.10.1"]="gateway-vlan10"
    ["192.168.30.10"]="siem-wazuh siem-wazuh.${DOMAIN}"
)
for ip in "${!HOSTS[@]}"; do
    hostname="${HOSTS[$ip]}"
    grep -q "$ip" /etc/hosts || echo "$ip    $hostname" >> /etc/hosts
done
log "/etc/hosts actualizado."

# ===========================================================================
# RESUMEN FINAL
# ===========================================================================
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} RESUMEN FINAL - Servidor DHCPv6 (Kea)${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e " ${GREEN}Servicio kea-dhcp6-server:${NC}"
systemctl is-active kea-dhcp6-server && echo "   Estado: ACTIVO" || echo "   Estado: INACTIVO"
echo "   Config    : /etc/kea/kea-dhcp6.conf"
echo "   Leases    : /var/lib/kea/kea-leases6.csv"
echo "   Log       : /var/log/kea-dhcp6.log"
echo "   Subred atendida : ${CLIENTS_NET6} (VLAN Clientes)"
echo "   Pool            : ${CLIENTS_POOL6}"
echo ""
echo -e " ${YELLOW}Nota:${NC} el router debe reenviar las solicitudes DHCPv6 con"
echo "   'relay-agent interface-id' hacia ${SRV_IP6} en la subinterfaz de VLAN 20."
echo ""
echo -e " ${GREEN}Red:${NC}"
echo "   IPv4      : ${SRV_IP}/${SRV_MASK}  Gateway: ${VM_GATEWAY}"
echo "   IPv6      : ${SRV_IP6}/${SRV_PREFIX6}  Gateway: ${VM_GATEWAY6}"
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN} APROVISIONAMIENTO COMPLETADO - dhcpv6-server listo${NC}"
echo -e "${CYAN}============================================================${NC}"