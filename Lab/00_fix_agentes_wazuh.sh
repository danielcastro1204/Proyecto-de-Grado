#!/usr/bin/env bash
# =============================================================================
# 00_fix_agentes_wazuh.sh
# EJECUTAR EN EL SIEM (192.168.30.10) como root:
#   sudo bash /vagrant/Lab/00_fix_agentes_wazuh.sh
#
# Qué hace:
#   1. Corrige ossec.conf para aceptar conexiones de agentes desde cualquier IP
#   2. Habilita auto-enrollment (los agentes se registran solos al arrancar)
#   3. Copia las reglas de correlacion del proyecto a la carpeta correcta
#   4. Reinicia el manager para aplicar todo
#   5. Muestra el estado de agentes conectados al final
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then echo "Ejecutar como root: sudo bash $0"; exit 1; fi

OSSEC_CONF="/var/ossec/etc/ossec.conf"
RULES_DIR="/var/ossec/etc/rules"

# ---- 1. Verificar que Wazuh Manager está instalado -------------------------
if ! systemctl is-active --quiet wazuh-manager 2>/dev/null; then
    echo -e "${RED}[ERROR]${NC} wazuh-manager no está corriendo. Revisar la VM del SIEM."
    exit 1
fi
ok "wazuh-manager está activo."

# ---- 2. Backup del ossec.conf original -------------------------------------
cp "$OSSEC_CONF" "${OSSEC_CONF}.bak_$(date +%Y%m%d_%H%M%S)"
ok "Backup de ossec.conf creado."

# ---- 3. Asegurar bloque <remote> para agentes (puerto 1514 TCP) ------------
# Wazuh 4.x ya viene con esto, pero lo verificamos/corregimos explícitamente.
if ! grep -q "<connection>secure</connection>" "$OSSEC_CONF"; then
    warn "No hay bloque <remote> secure. Agregando..."
    sed -i 's|</ossec_config>||' "$OSSEC_CONF"
    cat >> "$OSSEC_CONF" << 'REMOTEEOF'

  <!-- Recepción de agentes Wazuh (protocolo seguro) -->
  <remote>
    <connection>secure</connection>
    <port>1514</port>
    <protocol>tcp</protocol>
    <allowed-ips>0.0.0.0/0</allowed-ips>
  </remote>

</ossec_config>
REMOTEEOF
    ok "Bloque <remote> secure agregado."
else
    ok "Bloque <remote> secure ya existe."
fi

# ---- 4. Habilitar auto-enrollment en authd ---------------------------------
# Wazuh 4.x usa wazuh-authd para el enrollment automático en puerto 1515.
# Por defecto viene activo, pero validamos que la configuración no lo bloquee.
if grep -q "<disabled>yes</disabled>" "$OSSEC_CONF" 2>/dev/null; then
    sed -i 's|<disabled>yes</disabled>|<disabled>no</disabled>|g' "$OSSEC_CONF"
    warn "Se encontró <disabled>yes</disabled> en ossec.conf — corregido a no."
fi

# Asegurar que el bloque <auth> exista y esté habilitado
if ! grep -q "<auth>" "$OSSEC_CONF"; then
    sed -i 's|</ossec_config>||' "$OSSEC_CONF"
    cat >> "$OSSEC_CONF" << 'AUTHEOF'

  <!-- Enrollment automático de agentes (puerto 1515) -->
  <auth>
    <disabled>no</disabled>
    <port>1515</port>
    <use_source_ip>yes</use_source_ip>
    <purge>yes</purge>
    <use_password>no</use_password>
    <crt_manager>
      <verify_manager_cert>no</verify_manager_cert>
    </crt_manager>
    <ssl_agent_ca></ssl_agent_ca>
    <ssl_verify_host>no</ssl_verify_host>
    <ssl_manager_cert>/var/ossec/etc/sslmanager.cert</ssl_manager_cert>
    <ssl_manager_key>/var/ossec/etc/sslmanager.key</ssl_manager_key>
    <ssl_auto_negotiate>no</ssl_auto_negotiate>
  </auth>

</ossec_config>
AUTHEOF
    ok "Bloque <auth> agregado para enrollment automático."
else
    ok "Bloque <auth> ya existe en ossec.conf."
fi

# ---- 5. Copiar reglas de correlación del proyecto --------------------------
LOCAL_RULES_SRC="$(dirname "$0")/../Deteccion/local_rules.xml"
if [[ -f "$LOCAL_RULES_SRC" ]]; then
    cp "$LOCAL_RULES_SRC" "${RULES_DIR}/local_rules.xml"
    ok "Reglas de correlación copiadas a ${RULES_DIR}/local_rules.xml"
else
    warn "No se encontró Deteccion/local_rules.xml. Verifica la ruta del repositorio."
fi

# ---- 6. Reiniciar manager --------------------------------------------------
info "Reiniciando wazuh-manager..."
systemctl restart wazuh-manager
sleep 10

systemctl is-active --quiet wazuh-manager && ok "wazuh-manager reiniciado correctamente." \
    || { echo -e "${RED}[ERROR]${NC} wazuh-manager no arrancó. Ver: journalctl -u wazuh-manager -n 50"; exit 1; }

# ---- 7. Mostrar agentes registrados ----------------------------------------
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  AGENTES REGISTRADOS EN EL SIEM                   ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
/var/ossec/bin/agent_control -lc 2>/dev/null || /var/ossec/bin/wazuh-control list 2>/dev/null || \
    echo "(usar Dashboard en https://192.168.30.10 para ver agentes)"

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  PUERTOS ESCUCHANDO                               ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
ss -tlnp | grep -E "1514|1515|1516|55000|9200|443" || netstat -tlnp | grep -E "1514|1515"

echo ""
ok "Script completado. Ahora corre 00_fix_agentes_en_VMs.sh en cada VM agente."
