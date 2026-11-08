#!/usr/bin/env bash
# Ataque 2b (SIGILOSO): Escaneo de puertos evasivo (MITRE T1046)
# A diferencia del escaneo ruidoso (-sS -T4 -p- a todos los puertos rapido),
# aqui se usa timing muy lento (-T1 paranoico), fragmentacion de paquetes (-f),
# senuelos (-D) y un conjunto reducido de puertos, para evadir la deteccion de
# escaneos por umbral de Suricata/Wazuh. Tecnica de evasion real documentada.
# Uso: ./attack2b_portscan_sigiloso.sh <IP>
set -uo pipefail
source "$(dirname "$0")/../_lib_log_ataque.sh"
TARGET="${1:?Uso: $0 <IP_OBJETIVO>}"

FW_IP="${FW_IP:-10.0.30.30}"
INICIO=$(log_inicio)
echo "[+] Escaneo SIGILOSO del perimetro ${FW_IP} y de ${TARGET} (-T1 paranoico, fragmentado)..."
# -T1: timing muy lento; -f: fragmenta; --scan-delay: separa los paquetes.
# Evade la deteccion POR FIRMA (umbral de Suricata). Se escanea PRIMERO el
# firewall perimetral (${FW_IP}): aunque la firma se evada, la correlacion de
# conexiones nuevas registradas por el firewall (regla 100022, defensa en
# profundidad) detecta el patron low-and-slow por volumen/origen. Se escanea el
# perimetro primero y con un conjunto amplio de puertos (>= umbral de 100022)
# para que la deteccion por correlacion sea fiable aun siendo sigilosa.
# (Se omiten los senuelos -D para no fragmentar la correlacion por IP origen.)
sudo nmap $(fam6 "$FW_IP") -sS -T1 -f --scan-delay 1s -p 22,23,25,135,139,445,1433,3306,3389,5985 \
  "${FW_IP}" -oN "/tmp/nmap_sigiloso_fw_$(date +%s).log" &>/dev/null || true
# Escaneo del host interno (punto ciego: no cruza un sensor) — se mantiene para
# documentar la limitacion de cobertura frente al barrido sigiloso.
sudo nmap $(fam6 "$TARGET") -sS -T1 -f --scan-delay 2s -p 22,80,135,139,389,443,445,3389,5985 \
  "${TARGET}" -oN "/tmp/nmap_sigiloso_$(date +%s).log" &>/dev/null || true
log_fin "portscan_sigiloso" "T1046" "${TARGET}" "${INICIO}" "1"
echo "[+] Ataque sigiloso registrado en log_ataques.csv"
