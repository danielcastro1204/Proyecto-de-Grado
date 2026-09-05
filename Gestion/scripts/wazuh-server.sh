#!/usr/bin/env bash
# =============================================================================
# wazuh-server.sh — Aprovisionamiento del Servidor SIEM Wazuh
# Integrante A - VLAN 30 (Gestión) - IP fija: 192.168.30.10/24
#
# Pasos:
#   1. Configurar IP estática con Netplan
#   2. Instalar prerequisitos del sistema
#   3. Descargar e instalar Wazuh all-in-one (manager + indexer + dashboard)
#   4. Configurar recepción de syslog UDP/514 (logs del router Cisco)
#   5. Abrir puertos en ufw
#   6. Mostrar credenciales del dashboard
# =============================================================================

set -euo pipefail

# ── Colores para mensajes ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[WAZUH-PROV]${NC} $*"; }
warning() { echo -e "${YELLOW}[WAZUH-WARN]${NC} $*"; }
error()   { echo -e "${RED}[WAZUH-ERROR]${NC} $*"; exit 1; }

# ── Variables de red ─────────────────────────────────────────────────────────
STATIC_IP="192.168.30.10"
PREFIX="24"
GATEWAY="192.168.30.1"
DNS="${GATEWAY}"
IFACE="enp0s8"          # Segunda NIC de VirtualBox (la puente); la primera (enp0s3) es NAT de Vagrant

# ── Versión de Wazuh ─────────────────────────────────────────────────────────
WAZUH_VERSION="4.x"
WAZUH_PASSWORDS_FILE="/root/wazuh_passwords.txt"

# =============================================================================
# PASO 1 — Configurar IP estática con Netplan
# =============================================================================
configure_network() {
  info "Configurando IP estática ${STATIC_IP}/${PREFIX} en ${IFACE}..."

  NETPLAN_FILE="/etc/netplan/60-wazuh-static.yaml"

  if grep -q "${STATIC_IP}" "${NETPLAN_FILE}" 2>/dev/null; then
    warning "La configuración de red ya existe en ${NETPLAN_FILE}. Omitiendo."
    return 0
  fi

  cat > "${NETPLAN_FILE}" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses:
        - ${STATIC_IP}/${PREFIX}
      routes:
        - to: 0.0.0.0/0
          via: ${GATEWAY}
      nameservers:
        addresses:
          - ${DNS}
          - 8.8.8.8
EOF

  chmod 600 "${NETPLAN_FILE}"
  netplan apply || warning "netplan apply retornó error; puede que la interfaz aún no esté activa."
  info "Red configurada: ${STATIC_IP}/${PREFIX} vía ${IFACE}"
}

# =============================================================================
# PASO 2 — Prerequisitos del sistema
# =============================================================================
install_prerequisites() {
  info "Actualizando sistema e instalando prerequisitos..."
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -qq
  apt-get upgrade -y -qq
  apt-get install -y -qq \
    curl wget gnupg apt-transport-https \
    software-properties-common lsb-release \
    net-tools ufw rsyslog ca-certificates

  info "Prerequisitos instalados."
}

# =============================================================================
# PASO 3 — Instalar Wazuh all-in-one
# =============================================================================
install_wazuh() {
  # Verificar si ya está instalado (idempotencia)
  if systemctl is-active --quiet wazuh-manager 2>/dev/null; then
    warning "Wazuh Manager ya está corriendo. Omitiendo instalación."
    return 0
  fi

  if [ -f /usr/share/wazuh-dashboard/bin/opensearch-dashboards ]; then
    warning "Wazuh Dashboard ya existe. Omitiendo instalación."
    return 0
  fi

  info "=========================================="
  info "  Iniciando instalación Wazuh all-in-one  "
  info "  (puede tardar 15-30 minutos)            "
  info "=========================================="

  local INSTALL_DIR="/tmp/wazuh-install"
  mkdir -p "${INSTALL_DIR}"
  cd "${INSTALL_DIR}"

  # Descargar script oficial de instalación
  info "Descargando wazuh-install.sh..."
  curl -sO "https://packages.wazuh.com/${WAZUH_VERSION}/wazuh-install.sh" \
    || error "No se pudo descargar el script de instalación de Wazuh. ¿Hay acceso a Internet?"

  curl -sO "https://packages.wazuh.com/${WAZUH_VERSION}/config.yml" \
    || error "No se pudo descargar config.yml de Wazuh."

  # Generar config.yml con hostname correcto
  cat > config.yml <<'CONFIGEOF'
nodes:
  indexer:
    - name: node-1
      ip: "127.0.0.1"
  server:
    - name: wazuh-1
      ip: "127.0.0.1"
  dashboard:
    - name: dashboard
      ip: "127.0.0.1"
CONFIGEOF

  info "Generando archivos de configuración (certificados, claves)..."
  bash wazuh-install.sh --generate-config-files -i \
    || error "Fallo en --generate-config-files"

  info "Instalando Wazuh Indexer (OpenSearch)..."
  bash wazuh-install.sh --wazuh-indexer node-1 -i \
    || error "Fallo en instalación del Indexer"

  info "Iniciando cluster del Indexer..."
  bash wazuh-install.sh --start-cluster -i \
    || error "Fallo en --start-cluster"

  info "Instalando Wazuh Server (Manager + API)..."
  bash wazuh-install.sh --wazuh-server wazuh-1 -i \
    || error "Fallo en instalación del Server"

  info "Instalando Wazuh Dashboard..."
  bash wazuh-install.sh --wazuh-dashboard dashboard -i 2>&1 | tee /tmp/wazuh-dashboard-install.log \
    || error "Fallo en instalación del Dashboard"

  # Capturar contraseña generada
  if grep -q "admin" /tmp/wazuh-dashboard-install.log; then
    grep -E "(User|Password|admin)" /tmp/wazuh-dashboard-install.log > "${WAZUH_PASSWORDS_FILE}" 2>/dev/null || true
  fi

  # También intentar extraer con el extractor oficial
  if [ -f wazuh-passwords.txt ]; then
    cp wazuh-passwords.txt "${WAZUH_PASSWORDS_FILE}"
  fi

  # Si no se capturó nada, intentar con la herramienta wazuh-passwords
  if [ ! -s "${WAZUH_PASSWORDS_FILE}" ]; then
    /usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh \
      --api --change-all 2>/dev/null >> "${WAZUH_PASSWORDS_FILE}" || true
  fi

  info "Wazuh instalado correctamente."
}

# =============================================================================
# PASO 4 — Configurar recepción de syslog UDP 514 (router Cisco)
# =============================================================================
configure_syslog() {
  info "Configurando recepción de syslog UDP/514 para logs del router Cisco..."

  WAZUH_CONF="/var/ossec/etc/ossec.conf"

  if [ ! -f "${WAZUH_CONF}" ]; then
    warning "No se encontró ${WAZUH_CONF}. Omitiendo configuración syslog."
    return 0
  fi

  # Idempotencia: no agregar si ya existe
  if grep -q "514" "${WAZUH_CONF}" 2>/dev/null; then
    warning "Syslog UDP/514 ya está configurado en ossec.conf. Omitiendo."
    return 0
  fi

  # Añadir bloque remote para syslog antes del cierre de </ossec_config>
  sed -i 's|</ossec_config>||' "${WAZUH_CONF}"
  cat >> "${WAZUH_CONF}" <<'SYSLOGEOF'

  <!-- Recepción de logs syslog del Router Cisco ISR4321 -->
  <remote>
    <connection>syslog</connection>
    <port>514</port>
    <protocol>udp</protocol>
    <allowed-ips>0.0.0.0/0</allowed-ips>
    <local_ip>0.0.0.0</local_ip>
  </remote>

  <!-- Recepción de agentes Wazuh desde cualquier IP -->
  <remote>
    <connection>secure</connection>
    <port>1514</port>
    <protocol>tcp</protocol>
    <allowed-ips>0.0.0.0/0</allowed-ips>
  </remote>

</ossec_config>
SYSLOGEOF

  # Reiniciar manager para aplicar cambios
  if systemctl is-active --quiet wazuh-manager; then
    systemctl restart wazuh-manager
    info "wazuh-manager reiniciado con configuración syslog."
  fi
}

# =============================================================================
# PASO 5 — Configurar firewall (ufw)
# =============================================================================
configure_firewall() {
  info "Configurando firewall ufw..."

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow 22/tcp    comment "SSH"
  ufw allow 443/tcp   comment "Wazuh Dashboard (HTTPS)"
  ufw allow 514/udp   comment "Syslog (router Cisco)"
  ufw allow 1514/tcp  comment "Wazuh agentes (secure)"
  ufw allow 1514/udp  comment "Wazuh agentes (syslog)"
  ufw allow 1515/tcp  comment "Wazuh enrollment"
  ufw allow 1516/tcp  comment "Wazuh cluster"
  ufw allow 55000/tcp comment "Wazuh API REST"
  # Puerto 9200 solo local (OpenSearch)
  ufw allow from 127.0.0.1 to any port 9200 comment "OpenSearch (solo local)"

  ufw --force enable
  info "Firewall configurado y habilitado."
}

# =============================================================================
# PASO 6 — Mostrar resumen y credenciales
# =============================================================================
show_summary() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║         WAZUH SIEM — APROVISIONAMIENTO COMPLETADO           ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${YELLOW}Dashboard URL   :${NC} https://${STATIC_IP}"
  echo -e "  ${YELLOW}Usuario         :${NC} admin"
  echo ""
  if [ -s "${WAZUH_PASSWORDS_FILE}" ]; then
    echo -e "  ${YELLOW}Contraseña      :${NC} Ver archivo ${WAZUH_PASSWORDS_FILE}"
    echo ""
    echo "  ── Contenido de ${WAZUH_PASSWORDS_FILE} ──"
    cat "${WAZUH_PASSWORDS_FILE}"
  else
    echo -e "  ${YELLOW}Contraseña      :${NC} Usa el script oficial para obtenerla:"
    echo "    /usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh --api"
  fi
  echo ""
  echo -e "  ${YELLOW}Puertos abiertos:${NC} 22, 443, 514/udp, 1514-1516, 55000"
  echo -e "  ${YELLOW}Logs router     :${NC} UDP 514 (0.0.0.0/0 permitido)"
  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  info "=== Inicio aprovisionamiento Wazuh Server ==="
  configure_network
  install_prerequisites
  install_wazuh
  configure_syslog
  configure_firewall
  show_summary
  info "=== Aprovisionamiento Wazuh completado ==="
}

main "$@"
