#!/usr/bin/env bash
# =============================================================================
# 00_fix_agentes_en_VMs.sh
# EJECUTAR EN CADA VM AGENTE LINUX (web-server, dns1, dns2, dhcpv4, dhcpv6,
# smtp-server, ntp-server, linux-01, linux-02) como root:
#
#   sudo bash /vagrant/Lab/00_fix_agentes_en_VMs.sh
#
# Qué hace:
#   1. Verifica que wazuh-agent esté instalado (si no, lo instala)
#   2. Corrige la IP del manager en ossec.conf (reemplaza placeholder o IP incorrecta)
#   3. Ejecuta el enrollment contra el SIEM (puerto 1515)
#   4. Reinicia el agente y verifica conexión
# =============================================================================
set -euo pipefail

SIEM_IP="192.168.30.10"
WAZUH_VERSION="4.x"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then echo "Ejecutar como root: sudo bash $0"; exit 1; fi

HOSTNAME_VM=$(hostname)
OSSEC_CONF="/var/ossec/etc/ossec.conf"

# ---- 1. Instalar agente si no está ----------------------------------------
if ! command -v wazuh-agent &>/dev/null && ! systemctl list-units --all | grep -q wazuh-agent; then
    info "wazuh-agent no encontrado. Instalando..."
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
        gpg --no-default-keyring \
            --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
            --import 2>/dev/null
    chmod 644 /usr/share/keyrings/wazuh.gpg 2>/dev/null || true
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/${WAZUH_VERSION}/apt/ stable main" \
        > /etc/apt/sources.list.d/wazuh.list
    apt-get update -qq
    WAZUH_MANAGER="${SIEM_IP}" \
    WAZUH_MANAGER_PORT="1514" \
    WAZUH_REGISTRATION_SERVER="${SIEM_IP}" \
    WAZUH_REGISTRATION_PORT="1515" \
    WAZUH_AGENT_NAME="${HOSTNAME_VM}" \
    apt-get install -y -qq wazuh-agent
    ok "wazuh-agent instalado."
else
    ok "wazuh-agent ya está instalado."
fi

# ---- 2. Verificar conectividad al SIEM antes de continuar -----------------
info "Verificando conectividad con SIEM ${SIEM_IP}..."
if ! ping -c 2 -W 2 "${SIEM_IP}" &>/dev/null; then
    err "No hay ping al SIEM (${SIEM_IP}). Verifica que:"
    err "  - El router y los switches estén activos"
    err "  - La VM del SIEM esté levantada (Gestion/vagrant up)"
    err "  - Las rutas entre VLAN10/20 y VLAN30 estén configuradas en el router"
    exit 1
fi
ok "SIEM ${SIEM_IP} responde a ping."

if ! nc -z -w 3 "${SIEM_IP}" 1515 2>/dev/null; then
    err "Puerto 1515 (enrollment) no accesible en ${SIEM_IP}."
    err "Corre primero 00_fix_agentes_wazuh.sh en el SIEM."
    exit 1
fi
ok "Puerto 1515 del SIEM accesible."

# ---- 3. Corregir ossec.conf ------------------------------------------------
if [[ -f "$OSSEC_CONF" ]]; then
    # Reemplazar cualquier placeholder o IP incorrecta en <address>
    sed -i "s|<address>MANAGER_IP</address>|<address>${SIEM_IP}</address>|g" "$OSSEC_CONF"
    sed -i "s|<address>127\.0\.0\.1</address>|<address>${SIEM_IP}</address>|g" "$OSSEC_CONF"
    # Si ya tiene la IP correcta, no hace nada

    # Verificar que quedó bien
    CURRENT_MGR=$(grep -oP '(?<=<address>)[^<]+' "$OSSEC_CONF" | head -1)
    if [[ "$CURRENT_MGR" == "$SIEM_IP" ]]; then
        ok "ossec.conf apunta correctamente al SIEM: ${SIEM_IP}"
    else
        warn "ossec.conf tiene manager: ${CURRENT_MGR}. Forzando corrección..."
        sed -i "s|<address>${CURRENT_MGR}</address>|<address>${SIEM_IP}</address>|g" "$OSSEC_CONF"
    fi
else
    err "No se encontró $OSSEC_CONF. El agente puede no estar instalado correctamente."
    exit 1
fi

# ---- 4. Re-enrollment contra el SIEM (borra clave vieja si existe) ---------
info "Ejecutando enrollment contra ${SIEM_IP}:1515..."

# Detener el agente antes del enrollment
systemctl stop wazuh-agent 2>/dev/null || true
sleep 2

# Borrar clave de registro previa para forzar re-enrollment limpio
rm -f /var/ossec/etc/client.keys

# Ejecutar enrollment
/var/ossec/bin/agent-auth -m "${SIEM_IP}" -p 1515 -A "${HOSTNAME_VM}" 2>&1 | tee /tmp/wazuh_enroll.log

if grep -qi "error\|failed\|refused" /tmp/wazuh_enroll.log; then
    err "Enrollment falló. Contenido del log:"
    cat /tmp/wazuh_enroll.log
    exit 1
fi
ok "Enrollment completado."

# ---- 5. Reiniciar agente y verificar ---------------------------------------
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent
sleep 5

if systemctl is-active --quiet wazuh-agent; then
    ok "wazuh-agent activo y enviando eventos a ${SIEM_IP}."
else
    err "wazuh-agent no arrancó. Revisar: journalctl -u wazuh-agent -n 30"
    journalctl -u wazuh-agent -n 20 --no-pager
    exit 1
fi

# ---- 6. Verificar logs de conexión -----------------------------------------
sleep 3
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  ÚLTIMAS LÍNEAS DEL LOG DEL AGENTE            ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
tail -10 /var/ossec/logs/ossec.log 2>/dev/null || true

echo ""
ok "Agente ${HOSTNAME_VM} registrado. Verifica en el Dashboard del SIEM:"
ok "  https://${SIEM_IP} → Agents → buscar '${HOSTNAME_VM}'"
