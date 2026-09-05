#!/usr/bin/env bash
# Escenario 3: Eventos mixtos — trafico normal + ataques en momentos aleatorios.
# Ejecutar escenario1 en background en las estaciones de usuario, y disparar
# los ataques (Kali) en instantes aleatorios dentro de la misma ventana.
set -euo pipefail
DURACION_MIN="${1:-60}"
KALI_ATTACK_DIR="${KALI_ATTACK_DIR:-../Gestion/scripts/ataques}"

echo "[+] Lanzando trafico normal de fondo por ${DURACION_MIN} min..."
"$(dirname "$0")/escenario1_linea_base.sh" "${DURACION_MIN}" &
BG_PID=$!

FIN=$(( $(date +%s) + DURACION_MIN*60 ))
while [ "$(date +%s)" -lt "$FIN" ]; do
  sleep $(( (RANDOM % 300) + 60 ))  # espera aleatoria entre 1 y 6 min
  [ "$(date +%s)" -ge "$FIN" ] && break
  echo "[+] Disparando ataque aleatorio ($(date))..."
  ATTACKS=(attack1_bruteforce_ssh.sh attack2_portscan.sh attack4_sqli.sh)
  SEL=${ATTACKS[$RANDOM % ${#ATTACKS[@]}]}
  echo "    -> ${SEL} (ejecutar manualmente con los parametros correctos de IP objetivo)"
done

wait "${BG_PID}" 2>/dev/null || true
echo "[+] Escenario mixto finalizado."
