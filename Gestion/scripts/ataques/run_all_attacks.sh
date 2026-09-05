#!/usr/bin/env bash
# Ejecuta los 5 ataques definidos en la metodologia, 5 repeticiones cada uno
# (segun Fase 3 / Escenario 2 del documento), dejando todo registrado en
# log_ataques.csv para la correlacion posterior en Evaluacion/.
#
# Editar las variables de objetivos segun las IPs reales de tu topologia.
set -euo pipefail
cd "$(dirname "$0")"

DC_IP="${DC_IP:-192.168.10.20}"
WEB_URL="${WEB_URL:-http://192.168.10.10/index.php?id=1}"
WIN_WS_IP="${WIN_WS_IP:-192.168.20.30}"
SSH_TARGET="${SSH_TARGET:-192.168.20.40}"
SSH_USER="${SSH_USER:-usuario}"
REPETICIONES="${REPETICIONES:-5}"

echo "=== Escenario 2: Simulacion de ataques controlados (${REPETICIONES}x cada uno) ==="
for i in $(seq 1 "${REPETICIONES}"); do
  echo "--- Repeticion ${i}/${REPETICIONES} ---"
  ./attack1_bruteforce_ssh.sh "${SSH_TARGET}" "${SSH_USER}"      || true
  ./attack2_portscan.sh       "${DC_IP}"                          || true
  ./attack4_sqli.sh           "${WEB_URL}"                        || true
  # Los ataques 3 (Pass-the-Hash) y 5 (payload) requieren credenciales/hash
  # capturados manualmente en el ejercicio; se ejecutan por separado:
  echo "  (Ejecutar manualmente attack3_pass_the_hash.sh y attack5_payload_exec.sh"
  echo "   con las credenciales/hash validos de este intento de laboratorio)"
  sleep 5
done
echo "=== Ataques completados. Revisar $(pwd)/log_ataques.csv (o /home/attacker/log_ataques.csv) ==="
