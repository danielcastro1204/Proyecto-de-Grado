#!/usr/bin/env bash
# =============================================================================
# conectar_agente_linux.sh — UNIVERSAL para toda VM Linux del laboratorio
# (web-server, dhcpv4-server, dhcpv6-server, dns1-server, dns2-server,
#  smtp-server, ntp-server, linux-01, linux-02, kali)
#
# NO usar en wazuh1 (el propio SIEM): ese host está diseñado a propósito
# para salir a internet por la NAT, y ya tiene las rutas que necesita.
#
# QUÉ CORRIGE (causa raíz de "las VMs agarran la NAT como ruta por defecto"):
#   Vagrant le da a cada VM una interfaz NAT (10.0.2.x) que trae su propia
#   ruta por defecto vía DHCP. La interfaz "puente" (la que de verdad está
#   en la VLAN del laboratorio) muchas veces queda con el MISMO metric (100)
#   que la ruta de la NAT, o en algunos scripts no tiene ruta por defecto
#   propia -- en ambos casos el kernel puede terminar usando la NAT, que NO
#   tiene camino hacia las otras VLAN (192.168.x.0/24), rompiendo la
#   conectividad hacia el SIEM.
#
# CORRECCIÓN:
#   1. Detecta la interfaz NAT (IP 10.0.2.x) y le apaga la ruta por defecto
#      que trae por DHCP (dhcp4-overrides: use-routes: false), dejando la
#      IP intacta (sigue sirviendo para resolver paquetes de Ubuntu).
#   2. Detecta la interfaz puente (la de la VLAN real) y le asegura una
#      ruta por defecto explícita hacia el gateway .1 de su propia subred,
#      con metric bajo (50) para que siempre gane.
#   3. Aplica netplan, verifica que solo quede UNA ruta por defecto y que
#      sea por la interfaz correcta.
#
# Luego de arreglar la red: instala (si falta) y registra el agente Wazuh
# contra el SIEM (192.168.30.10), de forma totalmente idempotente.
#
# USO (desde el host, sin necesidad de carpeta compartida):
#   Get-Content Lab\conectar_agente_linux.sh -Raw | vagrant ssh <vm> -c "sudo bash -s"
# =============================================================================
set -uo pipefail

SIEM_IP="192.168.30.10"
WAZUH_VERSION="4.x"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then err "Ejecutar como root (sudo bash -s)"; exit 1; fi

HOSTNAME_VM=$(hostname)
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Corrigiendo red + conectando agente Wazuh: ${HOSTNAME_VM}"
echo "════════════════════════════════════════════════════════"

# =============================================================================
# PARTE 1 — Corregir la prioridad de rutas (NAT vs. interfaz real)
# =============================================================================

info "Detectando interfaces de red..."

NAT_IFACE=""
BRIDGE_IFACE=""
BRIDGE_IP=""

for iface in $(ls /sys/class/net | grep -v lo); do
    ip4=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [[ -z "$ip4" ]] && continue
    if [[ "$ip4" == 10.0.2.* ]]; then
        NAT_IFACE="$iface"
    else
        BRIDGE_IFACE="$iface"
        BRIDGE_IP="$ip4"
    fi
done

if [[ -z "$NAT_IFACE" ]]; then
    warn "No se detectó interfaz NAT (10.0.2.x). Puede que ya esté corregida, o que esta VM no tenga NAT. Continuando."
fi

if [[ -z "$BRIDGE_IFACE" ]]; then
    err "No se detectó la interfaz puente (la de la VLAN real). Abortando."
    exit 1
fi

GATEWAY="$(echo "$BRIDGE_IP" | cut -d. -f1-3).1"
info "NAT (a desactivar como default)  : ${NAT_IFACE:-ninguna}"
info "Puente (VLAN real)               : ${BRIDGE_IFACE} (${BRIDGE_IP})"
info "Gateway calculado                : ${GATEWAY}"

# ---- 1a. Apagar la ruta por defecto que trae la NAT por DHCP ---------------
if [[ -n "$NAT_IFACE" ]]; then
    cat > /etc/netplan/01-nat-sin-default.yaml << EOF
# Generado por conectar_agente_linux.sh
# Mantiene la IP de la NAT (10.0.2.x) pero le quita el privilegio de ser
# la ruta por defecto, para que SIEMPRE gane la interfaz de la VLAN real.
network:
  version: 2
  ethernets:
    ${NAT_IFACE}:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false
EOF
    chmod 600 /etc/netplan/01-nat-sin-default.yaml
    ok "Ruta por defecto de la NAT (${NAT_IFACE}) deshabilitada en netplan."
fi

# ---- 1b. Asegurar ruta por defecto explícita y de bajo metric en el puente -
cat > /etc/netplan/02-default-route-bridge.yaml << EOF
# Generado por conectar_agente_linux.sh
# Ruta por defecto explícita y prioritaria por la interfaz real del laboratorio.
network:
  version: 2
  ethernets:
    ${BRIDGE_IFACE}:
      routes:
        - to: default
          via: ${GATEWAY}
          metric: 50
EOF
chmod 600 /etc/netplan/02-default-route-bridge.yaml
ok "Ruta por defecto explícita agregada en ${BRIDGE_IFACE} vía ${GATEWAY} (metric 50)."

info "Aplicando netplan..."
netplan generate 2>/dev/null || warn "netplan generate con advertencias."
netplan apply 2>/dev/null || warn "netplan apply con advertencias."
sleep 3

# Forzar la eliminación inmediata de la ruta NAT en la tabla de rutas en vivo
# (por si netplan apply no la retiró al instante)
if [[ -n "$NAT_IFACE" ]]; then
    ip route del default dev "$NAT_IFACE" 2>/dev/null || true
fi

# ---- 1c. Verificar ---------------------------------------------------------
echo ""
info "Rutas por defecto actuales:"
ip route show default | sed 's/^/    /'

NUM_DEFAULT=$(ip route show default | wc -l)
DEFAULT_IFACE=$(ip route show default | head -1 | grep -oP '(?<=dev )\S+')

if [[ "$NUM_DEFAULT" -eq 1 && "$DEFAULT_IFACE" == "$BRIDGE_IFACE" ]]; then
    ok "Ruta por defecto correcta: una sola, por ${BRIDGE_IFACE}."
else
    warn "Revisar manualmente: hay ${NUM_DEFAULT} ruta(s) por defecto, activa por '${DEFAULT_IFACE}'."
fi

# ---- 1d. Probar conectividad real hacia el SIEM ----------------------------
if ping -c 2 -W 2 "${SIEM_IP}" &>/dev/null; then
    ok "Ping a SIEM (${SIEM_IP}) exitoso."
else
    err "Sin ping al SIEM (${SIEM_IP}) incluso después de corregir rutas."
    err "Verifica el router, los switches y que la VM del SIEM esté levantada."
    exit 1
fi

# =============================================================================
# PARTE 2 — Instalar / conectar el agente Wazuh
# =============================================================================
echo ""
info "Configurando agente Wazuh..."

OSSEC_CONF="/var/ossec/etc/ossec.conf"

if ! command -v /var/ossec/bin/wazuh-control &>/dev/null; then
    info "wazuh-agent no está instalado. Instalando..."
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
        gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import 2>/dev/null
    chmod 644 /usr/share/keyrings/wazuh.gpg 2>/dev/null || true
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/${WAZUH_VERSION}/apt/ stable main" \
        > /etc/apt/sources.list.d/wazuh.list
    apt-get update -qq
    WAZUH_MANAGER="${SIEM_IP}" WAZUH_MANAGER_PORT="1514" \
    WAZUH_REGISTRATION_SERVER="${SIEM_IP}" WAZUH_REGISTRATION_PORT="1515" \
    WAZUH_AGENT_NAME="${HOSTNAME_VM}" \
    apt-get install -y -qq wazuh-agent
    ok "wazuh-agent instalado."
else
    ok "wazuh-agent ya estaba instalado."
fi

if ! nc -z -w 3 "${SIEM_IP}" 1515 2>/dev/null; then
    err "Puerto 1515 (enrollment) no accesible en ${SIEM_IP}."
    err "Corre primero el fix del lado del SIEM: 00_fix_agentes_wazuh.sh"
    exit 1
fi

# Corregir manager en ossec.conf (placeholder o IP vieja)
sed -i "s|<address>MANAGER_IP</address>|<address>${SIEM_IP}</address>|g" "$OSSEC_CONF" 2>/dev/null
sed -i "s|<address>127\.0\.0\.1</address>|<address>${SIEM_IP}</address>|g" "$OSSEC_CONF" 2>/dev/null
CURRENT_MGR=$(grep -oP '(?<=<address>)[^<]+' "$OSSEC_CONF" 2>/dev/null | head -1)
if [[ "$CURRENT_MGR" != "$SIEM_IP" ]]; then
    sed -i "s|<address>${CURRENT_MGR}</address>|<address>${SIEM_IP}</address>|g" "$OSSEC_CONF" 2>/dev/null
fi
ok "ossec.conf apunta a ${SIEM_IP}."

info "Re-enrollment (clave limpia) contra ${SIEM_IP}:1515..."
systemctl stop wazuh-agent 2>/dev/null || true
sleep 1
rm -f /var/ossec/etc/client.keys
/var/ossec/bin/agent-auth -m "${SIEM_IP}" -p 1515 -A "${HOSTNAME_VM}" > /tmp/wazuh_enroll.log 2>&1

if grep -qi "error\|failed\|refused" /tmp/wazuh_enroll.log; then
    err "Enrollment falló:"
    cat /tmp/wazuh_enroll.log
    exit 1
fi
ok "Enrollment completado."

systemctl daemon-reload
systemctl enable wazuh-agent --now 2>/dev/null
sleep 4

if systemctl is-active --quiet wazuh-agent; then
    ok "wazuh-agent ACTIVO en ${HOSTNAME_VM}."
else
    err "wazuh-agent no arrancó. journalctl -u wazuh-agent -n 20:"
    journalctl -u wazuh-agent -n 20 --no-pager
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════"
ok "${HOSTNAME_VM}: red corregida y agente Wazuh conectado."
echo "════════════════════════════════════════════════════════"
