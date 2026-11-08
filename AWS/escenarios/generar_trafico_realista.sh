#!/usr/bin/env bash
# =============================================================================
# generar_trafico_realista.sh — Generador de trafico de red REALISTA y denso.
#
# Reemplaza al generador minimo anterior. Emula el comportamiento continuo de
# una red empresarial real haciendo que CADA host genere, en paralelo y de
# forma concurrente, el trafico propio de su rol, con llegadas aleatorias
# (proceso tipo Poisson) y mucha variedad. El objetivo es:
#   - alimentar las 5 fuentes de logs con actividad legitima densa y diversa,
#   - que la medicion de falsos positivos (Escenario 1) sea significativa
#     (hay mucho trafico diverso que podria confundir a las reglas), y
#   - que el trafico de fondo del Escenario 3 sea indistinguible de una red real.
#
# Uso:  generar_trafico_realista.sh <ROL> <DURACION_MIN> [INTENSIDAD]
#   ROL: cliente-linux | servidor-web | dns | generico
#   INTENSIDAD: 1..5 (nº de "usuarios"/hilos concurrentes; def 3)
#
# Pensado para ejecutarse EN cada instancia (esta en el bundle /opt/lab). El
# orquestador (orquestar_trafico.sh) lo lanza en todas en paralelo.
# =============================================================================
set -uo pipefail

ROL="${1:-generico}"
DURACION_MIN="${2:-30}"
INTENSIDAD="${3:-3}"
FIN=$(( $(date +%s) + DURACION_MIN*60 ))

# --- Objetivos internos del laboratorio (IPs privadas, estables) -------------
DC_IP="${DC_IP:-10.0.10.20}"
WEB_IP="${WEB_IP:-10.0.10.10}"
DNS_IP="${DNS_IP:-10.0.10.50}"
SMTP_IP="${SMTP_IP:-10.0.10.70}"
SMB_SERVER="${SMB_SERVER:-10.0.10.10}"
SMB_SHARE="${SMB_SHARE:-compartido}"
SMB_USER="${SMB_USER:-usuario}"
SMB_PASS="${SMB_PASS:-admin123}"
SSH_USER="${SSH_USER:-usuario}"
SSH_PASS="${SSH_PASS:-admin123}"

# Sitios externos legitimos (navegacion variada de "empleados")
SITIOS_EXT=(
  https://www.icesi.edu.co https://es.wikipedia.org https://www.python.org
  https://www.debian.org https://www.ubuntu.com https://www.google.com
  https://www.github.com https://www.stackoverflow.com https://www.cloudflare.com
  https://www.mozilla.org https://www.kernel.org https://news.ycombinator.com
)
# Dominios para consultas DNS variadas
DOMINIOS=(
  google.com wikipedia.org github.com microsoft.com amazonaws.com
  cloudflare.com debian.org python.org ubuntu.com icesi.edu.co
  outlook.com office365.com windowsupdate.com ntp.org
)
# Rutas de la app web (trafico de usuario legitimo hacia el portal corporativo)
WEB_PATHS=(
  "/" "/index.php?id=1" "/index.php?id=2" "/index.php?id=42"
  "/index.php?id=7" "/" "/index.php?id=100" "/index.php?id=3"
)

# Dual-stack: envuelve una IPv6 entre corchetes para URLs/UNC; IPv4 sin cambios.
brk() { case "$1" in *:*) echo "[$1]";; *) echo "$1";; esac; }
log() { echo "  [$(date -u +%H:%M:%S)][${ROL}] $*"; }
activo() { [ "$(date +%s)" -lt "$FIN" ]; }
espera() { sleep $(( (RANDOM % ${1:-15}) + ${2:-3} )); }

# --- Acciones atomicas de trafico -------------------------------------------
navegar_externo() {
  local s=${SITIOS_EXT[$RANDOM % ${#SITIOS_EXT[@]}]}
  curl -s -m 8 -A "Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/120.0" -o /dev/null "$s" && log "web ext $s"
}
navegar_portal() {
  local p=${WEB_PATHS[$RANDOM % ${#WEB_PATHS[@]}]}
  curl -s -g -m 5 -o /dev/null "http://$(brk "${WEB_IP}")${p}" && log "portal corp ${p}"
}
consulta_dns() {
  local d=${DOMINIOS[$RANDOM % ${#DOMINIOS[@]}]}
  if command -v dig &>/dev/null; then dig +short +time=3 "@${DNS_IP}" "$d" &>/dev/null; else nslookup "$d" "${DNS_IP}" &>/dev/null; fi
  log "dns ${d}"
}
transferir_smb() {
  command -v smbclient &>/dev/null || return 0
  local f="/tmp/doc_$$_$RANDOM.txt"; head -c $(( (RANDOM%4096)+256 )) /dev/urandom | base64 > "$f"
  smbclient "//${SMB_SERVER}/${SMB_SHARE}" "${SMB_PASS}" -U "${SMB_USER}" \
    -c "ls; put ${f} informe_$$_$RANDOM.docx; get informe_$$_$RANDOM.docx /tmp/g_$$.tmp 2>/dev/null; rm informe_$$_$RANDOM.docx" &>/dev/null && log "smb transfer"
  rm -f "$f" /tmp/g_$$.tmp
}
sesion_ssh() {
  command -v sshpass &>/dev/null || return 0
  local destinos=("${WEB_IP}") ; local d=${destinos[$RANDOM % ${#destinos[@]}]}
  sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    "${SSH_USER}@${d}" "hostname; ls -la /srv/compartido 2>/dev/null; uptime; whoami" &>/dev/null && log "ssh sesion ${d}"
}
enviar_correo() {
  command -v swaks &>/dev/null || return 0
  swaks --server "${SMTP_IP}" --to "empleado$((RANDOM%20))@empresa.local" \
    --from "sistema@empresa.local" --header "Subject: Reporte automatico $RANDOM" \
    --body "Mensaje de prueba de trafico normal." --timeout 8 &>/dev/null && log "smtp correo"
}
sync_ntp() {
  command -v ntpdate &>/dev/null && ntpdate -q "${DC_IP}" &>/dev/null && log "ntp query"
}

# --- Bucle de un "usuario" segun rol ----------------------------------------
usuario_cliente() {
  while activo; do
    case $(( RANDOM % 10 )) in
      0|1|2) navegar_externo ;;      # 30% navegacion externa
      3|4)   navegar_portal ;;       # 20% portal corporativo
      5)     consulta_dns ;;         # 10% DNS
      6)     transferir_smb ;;       # 10% SMB
      7)     sesion_ssh ;;           # 10% SSH
      8)     enviar_correo ;;        # 10% correo
      9)     consulta_dns; navegar_portal ;;  # 10% combinado
    esac
    espera 8 2    # red mas viva: acciones cada 2-10 s por usuario
  done
}
usuario_servidor() {
  # Un servidor tambien hace consultas salientes (updates, DNS, NTP, health checks)
  while activo; do
    case $(( RANDOM % 6 )) in
      0|1) consulta_dns ;;
      2)   navegar_externo ;;
      3)   sync_ntp ;;
      4)   curl -s -g -m5 -o /dev/null "http://$(brk "${WEB_IP}")/" && log "health-check web" ;;
      5)   enviar_correo ;;
    esac
    espera 12 4
  done
}
usuario_dns() {
  while activo; do consulta_dns; espera 5 1; done
}

log "Inicio trafico realista (${DURACION_MIN} min, intensidad ${INTENSIDAD})"
PIDS=()
for _ in $(seq 1 "${INTENSIDAD}"); do
  case "$ROL" in
    cliente-linux) usuario_cliente & ;;
    servidor-web)  usuario_servidor & ;;
    dns)           usuario_dns & ;;
    *)             usuario_cliente & ;;
  esac
  PIDS+=($!)
  sleep 1
done
for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
log "Trafico realista finalizado."
