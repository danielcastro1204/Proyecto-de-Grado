#!/usr/bin/env bash
# Libreria comun: registra inicio/fin de cada ataque en un CSV para poder
# correlacionar despues con las alertas generadas por Wazuh (Evaluacion/).
LOG_CSV="${LOG_CSV:-/home/attacker/log_ataques.csv}"
mkdir -p "$(dirname "$LOG_CSV")" 2>/dev/null || true
[ -f "$LOG_CSV" ] || echo "ataque,mitre_id,target_ip,inicio,fin,intento,escenario" > "$LOG_CSV"

# --- DUAL-STACK: ayudas para objetivos IPv6 -------------------------------
# Un objetivo IPv6 se reconoce porque contiene ':'. Estas funciones dan el
# flag de familia (-6 para nmap/hydra) y el formato con corchetes [..] para
# URLs y cadenas user@host.
es_ipv6()    { case "$1" in *:*) return 0;; *) return 1;; esac; }
fam6()       { es_ipv6 "$1" && echo "-6" || true; }   # flag -6 si es IPv6
brk()        { if es_ipv6 "$1"; then echo "[$1]"; else echo "$1"; fi; }  # [ipv6] o host

log_inicio() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_fin() {
  local ataque="$1" mitre="$2" target="$3" inicio="$4" intento="$5"
  local fin; fin=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local escenario="${ESCENARIO:-2}"
  echo "${ataque},${mitre},${target},${inicio},${fin},${intento},${escenario}" >> "$LOG_CSV"
}
