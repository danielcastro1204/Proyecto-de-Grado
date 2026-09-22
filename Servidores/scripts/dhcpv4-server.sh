#!/usr/bin/env bash
# =============================================================================
# dhcpv4-server.sh  |  Servidor DHCP para IPv4 (ISC Kea) - Ubuntu 22.04 LTS
# Proyecto SIEM - Integrante B | VLAN 10 (Servidores) | 192.168.10.30
# =============================================================================
# Este script aprovisiona el servidor DHCPv4 del laboratorio. Realiza:
#   1. Actualizacion del sistema
#   2. Configuracion de IP fija dual-stack (192.168.10.30/24 + fd00:10::30/64)
#   3. Instalacion de Kea DHCP4 y su configuracion para la VLAN 20 (Clientes)
#      -> Requiere DHCP relay en el router (ip helper-address 192.168.10.30)
#   4. Configuracion del firewall UFW (puerto 67/udp)
#   5. Instalacion del agente Wazuh (apuntando al SIEM 192.168.30.10)
#   6. Configuracion de /etc/hosts y resumen final
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# VARIABLES (inyectadas desde el Vagrantfile)
# ---------------------------------------------------------------------------
VM_IP="${VM_IP:-192.168.10.30}"
VM_IP6="${VM_IP6:-fd00:10::30}"
VM_GATEWAY="${VM_GATEWAY:-192.168.10.1}"
VM_GATEWAY6="${VM_GATEWAY6:-fd00:10::1}"
VM_DNS="${VM_DNS:-192.168.10.50}"          # DNS1
VM_DNS2="${VM_DNS2:-192.168.10.60}"        # DNS2
SIEM_IP="${SIEM_IP:-192.168.30.10}"
DOMAIN="${DOMAIN:-empresa.local}"
CLIENTS_GATEWAY="${CLIENTS_GATEWAY:-192.168.20.1}"    # Gateway de la VLAN 20 entregado a los clientes
CLIENTS_POOL4="${CLIENTS_POOL4:-192.168.20.150 - 192.168.20.200}"

SRV_IP="$VM_IP"
SRV_MASK="24"
SRV_IP6="$VM_IP6"
SRV_PREFIX6="64"
WAZUH_MANAGER="$SIEM_IP"
WAZUH_VERSION="4.9.2"

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Aprovisionamiento: Servidor DHCPv4 (Kea) - Ubuntu 22.04${NC}"
echo -e "${CYAN} IP: ${SRV_IP}/${SRV_MASK}  |  ${SRV_IP6}/${SRV_PREFIX6}${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ===========================================================================
# Detectar el adaptador puente (igual criterio que en web-server.sh)
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
# Generado por Vagrant/dhcpv4-server.sh
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
          - ${VM_DNS}
          - ${VM_DNS2}
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
# PASO 4: Instalar y configurar Kea DHCP4
# ===========================================================================
info "PASO 4: Instalando ISC Kea DHCP4..."
apt-get install -y -qq kea-dhcp4-server kea-common
log "Paquete kea-dhcp4-server instalado."

info "Configurando ${SRV_IP}/${SRV_MASK} para atender la VLAN 20 (Clientes) via DHCP relay..."
cat > "/etc/kea/kea-dhcp4.conf" << EOF
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [ "${BRIDGE_IFACE}" ]
    },

    "control-socket": {
      "socket-type": "unix",
      "socket-name": "/run/kea/kea4-ctrl-socket"
    },

    "lease-database": {
      "type": "memfile",
      "name": "/var/lib/kea/kea-leases4.csv"
    },

    "expired-leases-processing": {
      "reclaim-timer-wait-time": 10,
      "flush-reclaimed-timer-wait-time": 25,
      "hold-reclaimed-time": 3600,
      "max-reclaim-leases": 100,
      "max-reclaim-time": 250,
      "unwarned-reclaim-cycles": 5
    },

    "renew-timer": 900,
    "rebind-timer": 1800,
    "valid-lifetime": 3600,

    "option-data": [
      { "name": "domain-name", "data": "${DOMAIN}" },
      { "name": "domain-name-servers", "data": "${VM_DNS}, ${VM_DNS2}" }
    ],

    "subnet4": [
      {
        "id": 1,
        "subnet": "192.168.20.0/24",
        "pools": [
          { "pool": "${CLIENTS_POOL4}" }
        ],
        "option-data": [
          { "name": "routers", "data": "${CLIENTS_GATEWAY}" },
          { "name": "domain-name-servers", "data": "${VM_DNS}, ${VM_DNS2}" },
          { "name": "domain-name", "data": "${DOMAIN}" }
        ]
      }
    ],

    "loggers": [
      {
        "name": "kea-dhcp4",
        "output_options": [
          { "output": "/var/log/kea-dhcp4.log" }
        ],
        "severity": "INFO",
        "debuglevel": 0
      }
    ]
  }
}
EOF

kea-dhcp4 -t /etc/kea/kea-dhcp4.conf && log "Sintaxis de kea-dhcp4.conf validada." || warn "kea-dhcp4.conf presenta advertencias de sintaxis."

systemctl daemon-reload
systemctl enable kea-dhcp4-server
systemctl restart kea-dhcp4-server
sleep 2
systemctl is-active --quiet kea-dhcp4-server && log "Servicio kea-dhcp4-server activo." || warn "kea-dhcp4-server no esta activo. Revisar: journalctl -u kea-dhcp4-server"

# ===========================================================================
# PASO 5: Firewall UFW
# ===========================================================================
info "PASO 5: Configurando firewall UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment 'SSH - Acceso de gestion'
ufw allow 67/udp    comment 'DHCPv4 - solicitudes de clientes/relay'
ufw allow out to "${SIEM_IP}" port 1514 proto tcp comment 'Wazuh logs'
ufw allow out to "${SIEM_IP}" port 1515 proto tcp comment 'Wazuh registro'
ufw --force enable
log "Firewall UFW configurado."
ufw status verbose

# ===========================================================================
# PASO 6: Agente Wazuh
# ===========================================================================
info "PASO 6: Instalando agente Wazuh (manager: ${WAZUH_MANAGER})..."
if systemctl is-active --quiet wazuh-agent 2>/dev/null; then
    warn "El agente Wazuh ya esta activo. Saltando instalacion."
else
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
        gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
    chmod 644 /usr/share/keyrings/wazuh.gpg
    # CORRECCIÓN: Se cambia a la rama principal 4.x
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
        | tee /etc/apt/sources.list.d/wazuh.list
    apt-get update -qq
    WAZUH_MANAGER="${WAZUH_MANAGER}" WAZUH_MANAGER_PORT="1514" \
    WAZUH_REGISTRATION_SERVER="${WAZUH_MANAGER}" WAZUH_REGISTRATION_PORT="1515" \
    WAZUH_AGENT_NAME="dhcpv4-server" \
    apt-get install -y -qq wazuh-agent
    log "Paquete wazuh-agent instalado."

    OSSEC_CONF="/var/ossec/etc/ossec.conf"
    if [[ -f "$OSSEC_CONF" ]]; then
        grep -q "<address>MANAGER_IP</address>" "$OSSEC_CONF" && \
            sed -i "s|<address>MANAGER_IP</address>|<address>${WAZUH_MANAGER}</address>|g" "$OSSEC_CONF"
        if ! grep -q "kea-dhcp4.log" "$OSSEC_CONF"; then
            sed -i 's|</ossec_config>|  <localfile>\n    <log_format>syslog</log_format>\n    <location>/var/log/kea-dhcp4.log</location>\n  </localfile>\n\n</ossec_config>|' "$OSSEC_CONF"
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
# PASO 7: Zona horaria
# ===========================================================================
info "PASO 7: Configurando sincronizacion de tiempo..."
timedatectl set-timezone "America/Bogota"
timedatectl set-ntp true
log "Zona horaria: America/Bogota (UTC-5)."

# ===========================================================================
# PASO 8: /etc/hosts
# ===========================================================================
info "PASO 8: Actualizando /etc/hosts..."
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
echo -e "${CYAN} RESUMEN FINAL - Servidor DHCPv4 (Kea)${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e " ${GREEN}Servicio kea-dhcp4-server:${NC}"
systemctl is-active kea-dhcp4-server && echo "   Estado: ACTIVO" || echo "   Estado: INACTIVO"
echo "   Config    : /etc/kea/kea-dhcp4.conf"
echo "   Leases    : /var/lib/kea/kea-leases4.csv"
echo "   Log       : /var/log/kea-dhcp4.log"
echo "   Subred atendida : 192.168.20.0/24 (VLAN Clientes)"
echo "   Pool            : ${CLIENTS_POOL4}"
echo ""
echo -e " ${YELLOW}Nota:${NC} este servidor esta en la VLAN 10, distinta a la VLAN 20"
echo "   que atiende. El router debe reenviar las solicitudes DHCP con:"
echo "   ip helper-address ${SRV_IP}   (en la subinterfaz de VLAN 20)"
echo ""
echo -e " ${GREEN}Red:${NC}"
echo "   IPv4      : ${SRV_IP}/${SRV_MASK}  Gateway: ${VM_GATEWAY}"
echo "   IPv6      : ${SRV_IP6}/${SRV_PREFIX6}  Gateway: ${VM_GATEWAY6}"
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN} APROVISIONAMIENTO COMPLETADO - dhcpv4-server listo${NC}"
echo -e "${CYAN}============================================================${NC}"