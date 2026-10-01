#!/usr/bin/env bash
# =============================================================================
# escenario1_linea_base.sh — ESCENARIO 1: Tráfico normal (línea base)
#
# DÓNDE EJECUTAR: en el HOST DE SERVIDORES (192.168.10.x) o en el
#                 HOST DE WORKSTATIONS (192.168.20.x), en cualquier VM Linux.
#                 NO en la Kali ni en el SIEM.
#
# QUÉ MIDE: la tasa de falsos positivos del SIEM cuando NO hay ataques.
#           Si el SIEM genera alertas de nivel "attack" durante este periodo,
#           son falsos positivos.
#
# DURACIÓN: 30 minutos por defecto (configurable como primer argumento)
#
# USO:
#   bash escenario1_linea_base.sh          # 30 min
#   bash escenario1_linea_base.sh 15       # 15 min
# =============================================================================

DURACION_MIN="${1:-30}"
WEB_IP="192.168.10.10"
SIEM_IP="192.168.30.10"
DC_IP="192.168.10.20"
GW_IP="192.168.10.1"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }

FIN=$(( $(date +%s) + DURACION_MIN * 60 ))
INICIO_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo ""
echo "════════════════════════════════════════════════════"
echo "  ESCENARIO 1 — Línea base (tráfico normal)"
echo "  Inicio : $(date)"
echo "  Fin    : $(date -d "+${DURACION_MIN} minutes" 2>/dev/null || date -v +${DURACION_MIN}M)"
echo "  Guarda: /tmp/escenario1_ventana.txt"
echo "════════════════════════════════════════════════════"
echo ""

# Guardar ventana de tiempo para correlación posterior
echo "inicio=${INICIO_ISO}" > /tmp/escenario1_ventana.txt

ITER=0
while [ "$(date +%s)" -lt "$FIN" ]; do
    ITER=$((ITER + 1))
    info "Iteración ${ITER} — $(( (FIN - $(date +%s)) / 60 )) min restantes"

    # 1. Petición HTTP al servidor web (tráfico legítimo)
    curl -s -m 5 -o /dev/null -w "HTTP %{http_code}" "http://${WEB_IP}/" && echo "" || true
    sleep 1

    # 2. Petición a la página de login (genera logs de acceso normales)
    curl -s -m 5 -o /dev/null "http://${WEB_IP}/login.html" || true
    sleep 1

    # 3. Ping al gateway (tráfico de red normal)
    ping -c 2 -W 1 "${GW_IP}" &>/dev/null && info "Ping gateway OK" || info "Ping gateway sin respuesta"

    # 4. Ping al DC (tráfico normal entre VLANs)
    ping -c 1 -W 2 "${DC_IP}" &>/dev/null && info "Ping DC OK" || true

    # 5. Resolución DNS (consulta normal)
    if command -v dig &>/dev/null; then
        dig +short +time=2 "empresa.local" "@${DC_IP}" &>/dev/null || true
        info "Consulta DNS OK"
    elif command -v nslookup &>/dev/null; then
        nslookup empresa.local "${DC_IP}" &>/dev/null || true
    fi

    # 6. Escritura de log local (genera eventos normales de filesystem)
    echo "$(date) - acceso normal usuario" >> /tmp/trafico_normal.log

    # Espera aleatoria entre 15 y 45 segundos
    sleep $(( (RANDOM % 30) + 15 ))
done

FIN_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "fin=${FIN_ISO}" >> /tmp/escenario1_ventana.txt

echo ""
echo "════════════════════════════════════════════════════"
ok "ESCENARIO 1 completado."
echo "  Ventana registrada en /tmp/escenario1_ventana.txt"
echo "  inicio=${INICIO_ISO}"
echo "  fin=${FIN_ISO}"
echo ""
echo "  → En el SIEM, verifica que NO haya alertas de"
echo "    nivel >= 10 con grupo 'attack' en esta ventana."
echo "════════════════════════════════════════════════════"
