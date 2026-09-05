#!/usr/bin/env bash
# Libreria comun: registra inicio/fin de cada ataque en un CSV para poder
# correlacionar despues con las alertas generadas por Wazuh (Evaluacion/).
LOG_CSV="/home/attacker/log_ataques.csv"
mkdir -p "$(dirname "$LOG_CSV")" 2>/dev/null || true
[ -f "$LOG_CSV" ] || echo "ataque,mitre_id,target_ip,inicio,fin,intento" > "$LOG_CSV"

log_inicio() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_fin() {
  local ataque="$1" mitre="$2" target="$3" inicio="$4" intento="$5"
  local fin; fin=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "${ataque},${mitre},${target},${inicio},${fin},${intento}" >> "$LOG_CSV"
}
