#!/usr/bin/env bash
# =============================================================================
# kali-attacker.sh — Aprovisionamiento de la Estación Atacante Kali Linux
# Integrante A - VLAN 30 (Gestión) - IP fija: 192.168.30.20/24
#
# Pasos:
#   1. Configurar IP estática (netplan o /etc/network/interfaces según versión)
#   2. Actualizar repositorios
#   3. Instalar / verificar herramientas de pentesting
#   4. Crear usuario 'attacker'
#   5. Mostrar resumen
# =============================================================================

set -euo pipefail

# ── Colores para mensajes ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[KALI-PROV]${NC} $*"; }
warning() { echo -e "${YELLOW}[KALI-WARN]${NC} $*"; }
error()   { echo -e "${RED}[KALI-ERROR]${NC} $*"; exit 1; }

# ── Variables de red ─────────────────────────────────────────────────────────
STATIC_IP="192.168.30.20"
PREFIX="24"
GATEWAY="192.168.30.1"
DNS="${GATEWAY}"
# Segunda NIC de VirtualBox (puente); la primera (eth0/enp0s3) es NAT de Vagrant
# En Kali reciente la interfaz puente suele ser eth1 o enp0s8
IFACE_BRIDGE="eth1"

# ── Usuario atacante ─────────────────────────────────────────────────────────
ATTACKER_USER="attacker"
ATTACKER_PASS="attacker"

# ── Lista de herramientas a asegurar ─────────────────────────────────────────
TOOLS=(
  nmap
  hydra
  sqlmap
  metasploit-framework
  impacket-scripts
  crackmapexec
  gobuster
  nikto
  john
  hashcat
  aircrack-ng
  responder
  evil-winrm
  netcat-traditional
  socat
  smbclient
  enum4linux
  dnsrecon
  whatweb
  wfuzz
  curl
  wget
  python3-pip
  git
)

# =============================================================================
# PASO 1 — Configurar IP estática
# =============================================================================
configure_network() {
  info "Configurando IP estática ${STATIC_IP}/${PREFIX} en ${IFACE_BRIDGE}..."

  # Detectar si Kali usa netplan o interfaces clásico
  if [ -d /etc/netplan ] && command -v netplan &>/dev/null; then
    configure_network_netplan
  else
    configure_network_interfaces
  fi
}

configure_network_netplan() {
  local NETPLAN_FILE="/etc/netplan/60-kali-static.yaml"

  if grep -q "${STATIC_IP}" "${NETPLAN_FILE}" 2>/dev/null; then
    warning "Configuración netplan ya existe en ${NETPLAN_FILE}. Omitiendo."
    return 0
  fi

  cat > "${NETPLAN_FILE}" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE_BRIDGE}:
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
  netplan apply 2>/dev/null || warning "netplan apply retornó error; puede que la interfaz no esté activa aún."
  info "Red configurada vía netplan."
}

configure_network_interfaces() {
  local IFACES_FILE="/etc/network/interfaces"

  if grep -q "${STATIC_IP}" "${IFACES_FILE}" 2>/dev/null; then
    warning "Configuración de red ya existe en ${IFACES_FILE}. Omitiendo."
    return 0
  fi

  # Backup
  cp "${IFACES_FILE}" "${IFACES_FILE}.bak.$(date +%s)" 2>/dev/null || true

  cat >> "${IFACES_FILE}" <<EOF

# Interfaz puente VLAN 30 — configurada por Vagrant provisioner
auto ${IFACE_BRIDGE}
iface ${IFACE_BRIDGE} inet static
    address ${STATIC_IP}
    netmask 255.255.255.0
    gateway ${GATEWAY}
    dns-nameservers ${DNS} 8.8.8.8
EOF

  ifup "${IFACE_BRIDGE}" 2>/dev/null || warning "ifup retornó error; la interfaz puede ya estar activa."
  info "Red configurada vía /etc/network/interfaces."
}

# =============================================================================
# PASO 2 — Actualizar repositorios
# =============================================================================
update_system() {
  info "Actualizando repositorios de Kali Linux..."
  export DEBIAN_FRONTEND=noninteractive

  # En Kali, los repos pueden cambiar; intentar dos veces si falla
  apt-get update -qq || {
    warning "Primer intento de apt-get update falló, reintentando..."
    sleep 5
    apt-get update -qq || error "No se pudo actualizar repositorios. ¿Hay acceso a Internet?"
  }

  info "Repositorios actualizados."
}

# =============================================================================
# PASO 3 — Instalar herramientas de pentesting
# =============================================================================
install_tools() {
  info "Verificando e instalando herramientas de pentesting..."

  local MISSING=()
  for tool in "${TOOLS[@]}"; do
    if ! dpkg -l "${tool}" &>/dev/null; then
      MISSING+=("${tool}")
    else
      info "  ✓ ${tool} ya instalado"
    fi
  done

  if [ ${#MISSING[@]} -eq 0 ]; then
    info "Todas las herramientas ya están instaladas."
    return 0
  fi

  info "Instalando: ${MISSING[*]}"
  apt-get install -y -qq "${MISSING[@]}" || {
    warning "Algunos paquetes no se instalaron. Intentando uno por uno..."
    for pkg in "${MISSING[@]}"; do
      apt-get install -y -qq "${pkg}" 2>/dev/null \
        && info "  ✓ ${pkg} instalado" \
        || warning "  ✗ ${pkg} no disponible en repos (puede que ya venga incluido en Kali)"
    done
  }

  # Asegurar que Metasploit DB esté inicializada
  if command -v msfdb &>/dev/null; then
    info "Inicializando base de datos de Metasploit..."
    msfdb init 2>/dev/null || warning "msfdb init falló o ya estaba inicializado."
  fi

  info "Herramientas de pentesting listas."
}

# =============================================================================
# PASO 4 — Crear usuario 'attacker'
# =============================================================================
create_attacker_user() {
  info "Configurando usuario '${ATTACKER_USER}'..."

  if id "${ATTACKER_USER}" &>/dev/null; then
    warning "El usuario '${ATTACKER_USER}' ya existe. Omitiendo creación."
  else
    useradd -m -s /bin/bash "${ATTACKER_USER}"
    echo "${ATTACKER_USER}:${ATTACKER_PASS}" | chpasswd
    usermod -aG sudo "${ATTACKER_USER}"
    info "Usuario '${ATTACKER_USER}' creado."
  fi

  # Asegurar que tenga sudo sin contraseña (igual que vagrant)
  local SUDOERS_FILE="/etc/sudoers.d/${ATTACKER_USER}"
  if [ ! -f "${SUDOERS_FILE}" ]; then
    echo "${ATTACKER_USER} ALL=(ALL) NOPASSWD:ALL" > "${SUDOERS_FILE}"
    chmod 440 "${SUDOERS_FILE}"
    info "sudo sin contraseña configurado para '${ATTACKER_USER}'."
  fi

  # Copiar configuración de bash básica
  if [ ! -f "/home/${ATTACKER_USER}/.bashrc" ]; then
    cp /etc/skel/.bashrc "/home/${ATTACKER_USER}/.bashrc" 2>/dev/null || true
    chown "${ATTACKER_USER}:${ATTACKER_USER}" "/home/${ATTACKER_USER}/.bashrc"
  fi

  # Banner de bienvenida para el usuario attacker
  cat > "/home/${ATTACKER_USER}/.profile_lab" <<'PROFILEEOF'
# ═══════════════════════════════════════════════════
#  Laboratorio de Ciberseguridad - VLAN 30 (Gestión)
#  Kali Linux - Estación Atacante
#  IP: 192.168.30.20 | GW: 192.168.30.1
# ───────────────────────────────────────────────────
#  Objetivos disponibles:
#    VLAN 10 (Servidores):  192.168.10.0/24
#      - DC Windows Server: 192.168.10.20
#      - Web Ubuntu:        192.168.10.10
#    VLAN 20 (Usuarios):    192.168.20.0/24
#      - Windows 10/11:     192.168.20.30, .31
#      - Ubuntu Desktop:    192.168.20.40, .41
#    VLAN 30 (Gestión):     192.168.30.0/24
#      - SIEM Wazuh:        192.168.30.10
# ═══════════════════════════════════════════════════
PROFILEEOF
  chown "${ATTACKER_USER}:${ATTACKER_USER}" "/home/${ATTACKER_USER}/.profile_lab"
}

# =============================================================================
# PASO 5 — Resumen final
# =============================================================================
show_summary() {
  echo ""
  echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║      KALI LINUX — APROVISIONAMIENTO COMPLETADO              ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${YELLOW}Hostname      :${NC} kali-attacker"
  echo -e "  ${YELLOW}IP estática   :${NC} ${STATIC_IP}/${PREFIX}"
  echo -e "  ${YELLOW}Gateway       :${NC} ${GATEWAY}"
  echo ""
  echo -e "  ${YELLOW}Usuarios:${NC}"
  echo    "    vagrant  / vagrant     (usuario base Vagrant - sudo sin pass)"
  echo    "    attacker / attacker    (usuario pentesting   - sudo sin pass)"
  echo ""
  echo -e "  ${YELLOW}Herramientas instaladas:${NC}"
  echo    "    nmap, hydra, sqlmap, metasploit-framework,"
  echo    "    impacket-scripts, crackmapexec, gobuster, nikto,"
  echo    "    john, hashcat, aircrack-ng, responder, evil-winrm"
  echo ""
  echo -e "  ${YELLOW}Targets en la red:${NC}"
  echo    "    VLAN 10 Servidores → 192.168.10.0/24"
  echo    "    VLAN 20 Usuarios   → 192.168.20.0/24"
  echo    "    SIEM Wazuh         → 192.168.30.10"
  echo ""
  echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  info "=== Inicio aprovisionamiento Kali Attacker ==="
  configure_network
  update_system
  install_tools
  create_attacker_user
  show_summary
  info "=== Aprovisionamiento Kali completado ==="
}

main "$@"
