#!/usr/bin/env bash
# Escenario 2: Simulacion de ataques controlados.
# Se ejecuta en la estacion Kali (Gestion/scripts/ataques/run_all_attacks.sh)
set -euo pipefail
cd "$(dirname "$0")/../Gestion/scripts/ataques" 2>/dev/null || \
  cd "$(dirname "$0")/../../Gestion/scripts/ataques"
./run_all_attacks.sh
