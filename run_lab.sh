#!/usr/bin/env bash
# =============================================================================
# run_lab.sh — Menu maestro de automatizacion del laboratorio SIEM
# Orquesta las 4 fases descritas en la metodologia del proyecto de grado.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

show_menu() {
cat <<MENU
=====================================================================
  LABORATORIO SIEM OPEN SOURCE — MENU DE AUTOMATIZACION
=====================================================================
 FASE 1 — Diseño / despliegue de infraestructura (por VM, via Vagrant):
   1) vagrant up   en Gestion/      (Wazuh + Kali)
   2) vagrant up   en Servidores/   (DC + Web)
   3) vagrant up   en Workstations/ (Win10 x2 + Linux x2)

 FASE 2 — Implementacion SIEM:
   4) Instalar Suricata en el servidor web   (Suricata/install_suricata.sh)
   5) Copiar reglas de correlacion a Wazuh   (Deteccion/local_rules.xml)

 FASE 3 — Escenarios de prueba:
   6) Escenario 1: Linea base de trafico normal
   7) Escenario 2: Ataques controlados (5 ataques x5 repeticiones)
   8) Escenario 3: Trafico mixto

 FASE 4 — Evaluacion:
   9) Recolectar alertas de Wazuh para una ventana de tiempo
  10) Calcular metricas y matriz de correlacion

   0) Salir
=====================================================================
MENU
}

deploy_vagrant() {
  local dir="$1"
  echo "[+] Levantando VMs en ${dir} ..."
  (cd "${dir}" && vagrant up)
}

while true; do
  show_menu
  read -rp "Selecciona una opcion: " opt
  case "$opt" in
    1) deploy_vagrant "Gestion" ;;
    2) deploy_vagrant "Servidores" ;;
    3) deploy_vagrant "Workstations" ;;
    4) read -rp "Interfaz de monitoreo (ej eth1): " IF
       echo "[+] Copiar y ejecutar en la VM destino: Suricata/install_suricata.sh ${IF}" ;;
    5) echo "[+] Copiar Deteccion/local_rules.xml a /var/ossec/etc/rules/ en el Wazuh Manager"
       echo "    y reiniciar: systemctl restart wazuh-manager" ;;
    6) read -rp "Duracion en minutos [30]: " M; M=${M:-30}
       echo "[+] Ejecutar en cada estacion de usuario: Escenarios/escenario1_linea_base.sh ${M}" ;;
    7) echo "[+] Ejecutar en Kali: Gestion/scripts/ataques/run_all_attacks.sh" ;;
    8) read -rp "Duracion en minutos [60]: " M; M=${M:-60}
       echo "[+] Ejecutar: Escenarios/escenario3_mixto.sh ${M}" ;;
    9) read -rp "Inicio (ISO8601 UTC): " I; read -rp "Fin (ISO8601 UTC): " F
       python3 Evaluacion/recolectar_alertas.py --inicio "$I" --fin "$F" ;;
    10) python3 Evaluacion/calcular_metricas.py \
          --ataques Gestion/scripts/ataques/log_ataques.csv \
          --alertas alertas_ventana.json ;;
    0) exit 0 ;;
    *) echo "Opcion invalida" ;;
  esac
  echo ""
done
