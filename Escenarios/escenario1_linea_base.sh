#!/usr/bin/env bash
# Escenario 1: Linea base de trafico normal (sin actividad maliciosa)
# Ejecutar SIMULTANEAMENTE en las estaciones Linux/Windows del segmento de
# usuarios (VLAN20) durante el tiempo definido en DURACION_MIN.
# Objetivo: medir la tasa de falsos positivos del SIEM.
set -euo pipefail
DURACION_MIN="${1:-30}"
SITIOS=(https://www.icesi.edu.co https://es.wikipedia.org https://www.python.org https://www.debian.org)
SMB_SERVER="${SMB_SERVER:-192.168.10.10}"
SMB_SHARE="${SMB_SHARE:-compartido}"
SMB_USER="${SMB_USER:-usuario}"

FIN=$(( $(date +%s) + DURACION_MIN*60 ))
echo "[+] Iniciando trafico normal por ${DURACION_MIN} min ($(date))"

while [ "$(date +%s)" -lt "$FIN" ]; do
  # 1. Navegacion web a sitios legitimos
  SITE=${SITIOS[$RANDOM % ${#SITIOS[@]}]}
  curl -s -m 5 -o /dev/null "$SITE" && echo "  [web] GET $SITE" || true

  # 2. Acceso SMB a recursos compartidos (si smbclient esta disponible)
  if command -v smbclient &>/dev/null; then
    smbclient -N "//${SMB_SERVER}/${SMB_SHARE}" -c "ls" &>/dev/null \
      && echo "  [smb] Listado de //${SMB_SERVER}/${SMB_SHARE}" || true
  fi

  # 3. Inicio de sesion SSH legitimo (si aplica, con clave/pass correcta)
  if [ -n "${SSH_TEST_HOST:-}" ]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_TEST_HOST}" "echo ok" &>/dev/null \
      && echo "  [ssh] login correcto a ${SSH_TEST_HOST}" || true
  fi

  sleep $(( (RANDOM % 20) + 10 ))
done
echo "[+] Trafico normal finalizado ($(date))."
