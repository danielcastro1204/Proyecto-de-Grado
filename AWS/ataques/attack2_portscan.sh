#!/usr/bin/env bash
# Ataque 2: Escaneo de puertos (MITRE T1046)
# Uso: ./attack2_portscan.sh <IP_OBJETIVO|RANGO>
set -euo pipefail
source "$(dirname "$0")/_lib_log_ataque.sh"
TARGET="${1:?Uso: $0 <IP_OBJETIVO_o_RANGO>}"
FW_IP="${FW_IP:-10.0.30.30}"

INICIO=$(log_inicio)
echo "[+] Escaneando puertos de ${TARGET}..."
# -sS (SYN scan) requiere privilegios de root (crea paquetes raw); el usuario
# 'attacker' del laboratorio tiene sudo NOPASSWD para esto.
# --max-retries/--host-timeout acotan el peor caso ante puertos filtrados
# (sin esto, un escaneo de los 65535 puertos puede tardar mucho más de lo
# esperado si hay descartes silenciosos, y sin generar ninguna salida visible
# mientras tanto).
sudo nmap -sS -sV -T4 -p- --max-retries 1 --host-timeout 5m "${TARGET}" -oN "/tmp/nmap_$(date +%s).log" || true
# Reconocimiento del PERIMETRO: el atacante tambien enumera el gateway/firewall.
# Este es el punto de deteccion fiable: el firewall registra cada conexion nueva
# (regla 100003) y la correlacion por origen (100022) dispara ante el barrido.
# Los escaneos contra hosts internos (DC) no cruzan un punto monitorizado -> se
# documentan como punto ciego de cobertura de sensores (ver reporte).
echo "[+] Enumerando el perimetro ${FW_IP}..."
sudo nmap -sS -T4 -p 22,23,25,80,135,139,445,1433,3306,3389,5985,8080 \
  --max-retries 1 "${FW_IP}" -oN "/tmp/nmap_fw_$(date +%s).log" &>/dev/null || true
log_fin "portscan" "T1046" "${TARGET}" "${INICIO}" "1"
echo "[+] Ataque registrado en log_ataques.csv"
