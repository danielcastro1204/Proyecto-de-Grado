#!/usr/bin/env bash
# =============================================================================
# wazuh-server.sh (AWS) — SIEM Wazuh all-in-one  | VLAN30 -> 10.0.30.10
# Migración del script original Gestion/scripts/wazuh-server.sh.
#
# Pasos:
#   1. Prerrequisitos
#   2. Instalación Wazuh all-in-one (manager + indexer + dashboard)  [rama 4.x]
#   3. Recepción de syslog UDP/514 (firewall) + agentes 1514/tcp
#   4. Despliegue de las reglas de correlación del proyecto (local_rules.xml)
#   5. Credenciales del dashboard
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/_common.sh"

WAZUH_VERSION="4.14"
WAZUH_PASSWORDS_FILE="/root/wazuh_passwords.txt"

set_hostname "wazuh-server"
set_timezone
escribir_hosts_lab

# --- 0. Memoria: el sandbox limita a t3.medium (4 GB). Creamos swap para que
#        el indexer (OpenSearch) no muera por OOM durante la instalación. ------
if ! swapon --show | grep -q /swapfile; then
  info "Creando 2 GB de swap (mitiga los 4 GB de RAM del sandbox)..."
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- 1. Prerrequisitos --------------------------------------------------------
info "Instalando prerrequisitos..."
apt-get update -qq
apt-get install -y -qq curl wget gnupg apt-transport-https software-properties-common \
  lsb-release net-tools ca-certificates tar

# --- 2. Wazuh all-in-one ------------------------------------------------------
instalar_wazuh() {
  if systemctl is-active --quiet wazuh-manager 2>/dev/null; then
    warn "Wazuh Manager ya está corriendo. Omitiendo instalación."; return 0
  fi

  # Evitar timeout de systemd en el primer arranque (igual que en el lab físico)
  mkdir -p /etc/systemd/system/wazuh-manager.service.d
  printf '[Service]\nTimeoutStartSec=600\n' > /etc/systemd/system/wazuh-manager.service.d/override.conf
  systemctl daemon-reload

  info "Descargando e instalando Wazuh ${WAZUH_VERSION} all-in-one (15-30 min)..."
  local D=/tmp/wazuh-install; mkdir -p "$D"; cd "$D"
  curl -sO "https://packages.wazuh.com/${WAZUH_VERSION}/wazuh-install.sh" || { err "No se pudo descargar wazuh-install.sh"; exit 1; }
  bash wazuh-install.sh -a -i -o 2>&1 | tee /tmp/wazuh-aio-install.log

  # Limitar el heap del indexer a 1 GB (en 4 GB de RAM el 50% por defecto deja
  # al manager/dashboard sin memoria). Dejamos sitio para el resto del stack.
  if [ -f /etc/wazuh-indexer/jvm.options ]; then
    sed -i 's/^-Xms.*/-Xms1g/; s/^-Xmx.*/-Xmx1g/' /etc/wazuh-indexer/jvm.options
    systemctl restart wazuh-indexer 2>/dev/null || true
    sleep 20
  fi

  # Extraer credenciales
  if [ -f wazuh-install-files.tar ]; then
    tar -O -xf wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt > "${WAZUH_PASSWORDS_FILE}" 2>/dev/null || true
  fi
  grep -E "(User|Password|admin)" /tmp/wazuh-aio-install.log >> "${WAZUH_PASSWORDS_FILE}" 2>/dev/null || true
}
instalar_wazuh

# --- 3. Recepción de syslog (firewall) + agentes -----------------------------
configurar_syslog() {
  local CONF="/var/ossec/etc/ossec.conf"
  [ -f "$CONF" ] || { warn "No existe ossec.conf"; return 0; }
  grep -q "<port>514</port>" "$CONF" 2>/dev/null && { warn "syslog 514 ya configurado"; return 0; }
  # El ossec.conf por defecto de Wazuh ya trae su propio <remote><connection>secure>
  # (puerto 1514) para los agentes, y suele tener más de un bloque <ossec_config>
  # de nivel superior (eso es válido en el formato de Wazuh: el parser OS_XML
  # admite varios bloques <ossec_config> como hermanos en el mismo archivo).
  # Por eso aquí solo quitamos el ÚLTIMO "</ossec_config>" (el cierre real de
  # archivo) y añadimos un bloque NUEVO con solo el <remote> de syslog/514, sin
  # repetir el <remote> secure/1514 que ya existe (Wazuh no admite dos).
  local LAST_CLOSE_LINE
  LAST_CLOSE_LINE="$(grep -n '</ossec_config>' "$CONF" | tail -1 | cut -d: -f1)"
  if [ -n "$LAST_CLOSE_LINE" ]; then
    sed -i "${LAST_CLOSE_LINE}d" "$CONF"
  fi
  cat >> "$CONF" <<'EOF'

<ossec_config>
  <!-- Recepción de syslog del firewall perimetral (fw-gateway / sustituto pfSense) -->
  <remote>
    <connection>syslog</connection>
    <port>514</port>
    <protocol>udp</protocol>
    <allowed-ips>10.0.0.0/16</allowed-ips>
    <local_ip>0.0.0.0</local_ip>
  </remote>
</ossec_config>
EOF
  systemctl restart wazuh-manager 2>/dev/null || true
}
configurar_syslog

# --- 4. Reglas de correlación del proyecto (5 ataques / MITRE ATT&CK) ---------
desplegar_reglas() {
  local SRC="${LAB_DIR}/deteccion/local_rules.xml"
  local DST="/var/ossec/etc/rules/local_rules.xml"
  if [ -f "$SRC" ]; then
    cp "$SRC" "$DST"
    chown wazuh:wazuh "$DST" 2>/dev/null || true
    systemctl restart wazuh-manager 2>/dev/null || true
    log "Reglas de correlación desplegadas desde $SRC"
  else
    warn "No se encontró $SRC (se usarán solo reglas por defecto de Wazuh)."
  fi
}
desplegar_reglas

# --- 5. Resumen ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " WAZUH SIEM LISTO"
echo " Dashboard : https://<IP_PUBLICA>  (usuario: admin)"
echo " Password  : ver ${WAZUH_PASSWORDS_FILE}"
echo " Syslog    : UDP/514 (firewall)   Agentes: TCP/1514"
echo "============================================================"
[ -s "${WAZUH_PASSWORDS_FILE}" ] && cat "${WAZUH_PASSWORDS_FILE}" || true
