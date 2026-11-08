#!/usr/bin/env bash
# =============================================================================
# _common.sh — Funciones compartidas por los scripts de aprovisionamiento AWS
# Se obtiene con:  source "$(dirname "$0")/_common.sh"
#
# Diferencias clave frente a la versión Vagrant/VirtualBox:
#   - La IP fija YA la asigna AWS a la ENI (PrivateIpAddress del template), por
#     lo que NO se configura netplan ni se detecta la interfaz puente.
#   - El resto de la lógica (instalación de servicios, agente Wazuh, firewall,
#     configuración de la aplicación) se conserva tal cual del proyecto físico.
# =============================================================================
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

export DEBIAN_FRONTEND=noninteractive
LAB_DIR="${LAB_DIR:-/opt/lab}"

# Interfaz principal de red en AWS (Nitro = ens5; otras = eth0). Solo se usa
# para Suricata y para referencias informativas; NO se reconfigura la IP.
detectar_iface() {
  ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1
}

set_hostname() {
  local name="$1"
  hostnamectl set-hostname "$name" 2>/dev/null || true
  grep -q "127.0.1.1" /etc/hosts && sed -i "s/^127.0.1.1.*/127.0.1.1\t$name/" /etc/hosts || echo "127.0.1.1 $name" >> /etc/hosts
}

set_timezone() {
  timedatectl set-timezone "America/Bogota" 2>/dev/null || true
  timedatectl set-ntp true 2>/dev/null || true
}

# DUAL-STACK: habilita la IPv6 de la ENI. AWS asigna una direccion IPv6 a la
# interfaz (el template pide Ipv6AddressCount), pero el netplan por defecto de
# la AMI solo solicita DHCPv4. Aqui se habilita DHCPv6 + Router Advertisements
# para que la interfaz levante su IPv6 (dual-stack real, sin DHCPv6 propio).
habilitar_ipv6() {
  local iface; iface=$(detectar_iface); [ -n "$iface" ] || iface=ens5
  cat > /etc/netplan/99-ipv6.yaml <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp6: true
      accept-ra: true
EOF
  chmod 600 /etc/netplan/99-ipv6.yaml 2>/dev/null || true
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
  sysctl -w "net.ipv6.conf.${iface}.accept_ra=2" 2>/dev/null || true
  netplan apply 2>/dev/null || true
  sleep 3
  info "IPv6 habilitada en ${iface}: $(ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6/{print $2}' | head -1)"
}

# Entradas /etc/hosts del laboratorio (esquema AWS 10.0.x.y)
escribir_hosts_lab() {
  habilitar_ipv6
  local marker="# --- SIEM LAB (AWS) ---"
  grep -q "$marker" /etc/hosts && return 0
  cat >> /etc/hosts <<EOF
$marker
10.0.30.10   siem-wazuh siem-wazuh.empresa.local
10.0.30.30   fw-gateway
10.0.30.20   atacante
10.0.10.10   web-server web-server.empresa.local
10.0.10.20   dc-empresa dc-empresa.empresa.local
10.0.10.50   dns1-server
10.0.10.60   dns2-server
10.0.10.80   ntp-server
10.0.10.70   smtp-server
10.0.20.30   win-ws-01
10.0.20.40   linux-01
EOF
}

# -----------------------------------------------------------------------------
# instalar_agente_wazuh <nombre_agente>
# Replica el procedimiento oficial usado en los scripts del proyecto físico
# (repositorio 4.x de Wazuh), apuntando al manager indicado en SIEM_IP.
# -----------------------------------------------------------------------------
instalar_agente_wazuh() {
  local AGENT_NAME="${1:-$(hostname)}"
  local MANAGER="${SIEM_IP:-10.0.30.10}"

  if systemctl is-active --quiet wazuh-agent 2>/dev/null; then
    warn "El agente Wazuh ya está activo."
    return 0
  fi

  info "Instalando agente Wazuh (manager: ${MANAGER}, nombre: ${AGENT_NAME})..."
  curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
    gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
  chmod 644 /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
    > /etc/apt/sources.list.d/wazuh.list
  apt-get update -qq

  WAZUH_MANAGER="${MANAGER}" \
  WAZUH_MANAGER_PORT="1514" \
  WAZUH_REGISTRATION_SERVER="${MANAGER}" \
  WAZUH_REGISTRATION_PORT="1515" \
  WAZUH_AGENT_NAME="${AGENT_NAME}" \
  apt-get install -y -qq wazuh-agent || { warn "No se pudo instalar wazuh-agent"; return 1; }

  local OSSEC_CONF="/var/ossec/etc/ossec.conf"
  if [ -f "$OSSEC_CONF" ]; then
    sed -i "s|<address>MANAGER_IP</address>|<address>${MANAGER}</address>|g" "$OSSEC_CONF"
    sed -i "s|<address>[^<]*</address>|<address>${MANAGER}</address>|g" "$OSSEC_CONF"
  fi
  systemctl daemon-reload
  systemctl enable wazuh-agent
  systemctl restart wazuh-agent
  sleep 3
  systemctl is-active --quiet wazuh-agent && log "wazuh-agent ACTIVO" || warn "wazuh-agent inactivo (ver /var/ossec/logs/ossec.log)"
}

# Añade un <localfile> al ossec.conf del agente (para Apache, Suricata, etc.)
wazuh_localfile() {
  local fmt="$1" loc="$2"
  local OSSEC_CONF="/var/ossec/etc/ossec.conf"
  [ -f "$OSSEC_CONF" ] || return 0
  grep -q "$loc" "$OSSEC_CONF" && return 0
  sed -i "s|</ossec_config>|  <localfile>\n    <log_format>${fmt}</log_format>\n    <location>${loc}</location>\n  </localfile>\n\n</ossec_config>|" "$OSSEC_CONF"
}
