#!/usr/bin/env bash
# =============================================================================
# install_suricata.sh — IDS Suricata + integracion con agente Wazuh
# Ejecutar en la VM del servidor web (Ubuntu, VLAN10) o en un sensor dedicado
# escuchando en modo promiscuo la interfaz que ve el trafico a monitorear.
#
# Uso:  sudo ./install_suricata.sh <INTERFAZ_MONITOREO>
#   ej: sudo ./install_suricata.sh eth1
# =============================================================================
set -euo pipefail
IFACE="${1:-eth1}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info(){ echo -e "${GREEN}[SURICATA]${NC} $*"; }
warn(){ echo -e "${YELLOW}[SURICATA-WARN]${NC} $*"; }

info "Instalando Suricata..."
add-apt-repository -y ppa:oisf/suricata-stable 2>/dev/null || true
apt-get update -qq
apt-get install -y -qq suricata jq

info "Descargando reglas Emerging Threats Open..."
suricata-update update-sources 2>/dev/null || true
suricata-update enable-source et/open 2>/dev/null || warn "No se pudo actualizar el set ET (¿sin Internet?). Se usaran las reglas por defecto."
suricata-update 2>/dev/null || warn "suricata-update fallo; revisar conectividad."

info "Configurando interfaz de monitoreo: ${IFACE}"
sed -i "s/^  - interface: .*/  - interface: ${IFACE}/" /etc/suricata/suricata.yaml || true

info "Habilitando salida eve.json (alertas en formato JSON)..."
python3 - "$0" <<'PYEOF'
# Asegura que eve-log este habilitado con tipo alert en /etc/suricata/suricata.yaml
import re
path = "/etc/suricata/suricata.yaml"
with open(path) as f:
    content = f.read()
if "types:\n      - alert" not in content:
    print("Aviso: revisar manualmente la seccion 'outputs > eve-log > types' para asegurar 'alert' habilitado.")
PYEOF

info "Configurando HOME_NET segun topologia del laboratorio (VLAN10/20/30)..."
sed -i 's/HOME_NET: .*/HOME_NET: "[192.168.10.0\/24,192.168.20.0\/24,192.168.30.0\/24]"/' /etc/suricata/suricata.yaml || true

info "Habilitando e iniciando el servicio Suricata en modo IDS (af-packet)..."
systemctl enable suricata
systemctl restart suricata
sleep 3
systemctl is-active --quiet suricata && info "Suricata activo escuchando en ${IFACE}." || warn "Suricata no arranco; revisar 'journalctl -u suricata'."

info "Integrando alertas de Suricata (eve.json) con el agente Wazuh local..."
OSSEC_CONF="/var/ossec/etc/ossec.conf"
if [ -f "${OSSEC_CONF}" ] && ! grep -q "eve.json" "${OSSEC_CONF}"; then
  sed -i 's|</ossec_config>||' "${OSSEC_CONF}"
  cat >> "${OSSEC_CONF}" <<'CONF_EOF'

  <!-- Alertas de Suricata (IDS) en formato JSON -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
  </localfile>

</ossec_config>
CONF_EOF
  systemctl restart wazuh-agent 2>/dev/null || warn "No se pudo reiniciar wazuh-agent (¿esta instalado en este host?)."
  info "Integracion con Wazuh completada."
else
  warn "ossec.conf no encontrado o ya integrado. Verificar manualmente que el agente Wazuh este instalado en este host."
fi

info "=== Suricata instalado y monitoreando ${IFACE} ==="
info "Verificar alertas en vivo con: tail -f /var/log/suricata/eve.json | jq 'select(.event_type==\"alert\")'"
