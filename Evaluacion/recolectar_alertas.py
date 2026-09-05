#!/usr/bin/env python3
"""
recolectar_alertas.py — Extrae alertas del Wazuh Manager para una ventana de tiempo.

Ejecutar EN el servidor Wazuh (lee directamente /var/ossec/logs/alerts/alerts.json)
o copiar ese archivo localmente y pasar su ruta con --alerts-file.

Uso:
  python3 recolectar_alertas.py --inicio 2026-06-01T00:00:00Z --fin 2026-06-01T23:59:59Z \
      --alerts-file /var/ossec/logs/alerts/alerts.json --out alertas_ventana.json
"""
import argparse
import json
import sys
from datetime import datetime


def parse_ts(ts):
    return datetime.strptime(ts.split(".")[0].replace("Z", ""), "%Y-%m-%dT%H:%M:%S")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--alerts-file", default="/var/ossec/logs/alerts/alerts.json")
    ap.add_argument("--inicio", required=True, help="ISO8601 UTC, ej 2026-06-01T00:00:00Z")
    ap.add_argument("--fin", required=True, help="ISO8601 UTC")
    ap.add_argument("--out", default="alertas_ventana.json")
    args = ap.parse_args()

    t_ini, t_fin = parse_ts(args.inicio), parse_ts(args.fin)
    encontradas = []

    try:
        with open(args.alerts_file, "r", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    alert = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = alert.get("timestamp")
                if not ts:
                    continue
                try:
                    t = parse_ts(ts)
                except ValueError:
                    continue
                if t_ini <= t <= t_fin:
                    encontradas.append(alert)
    except FileNotFoundError:
        print(f"ERROR: no se encontro {args.alerts_file}. Ejecuta este script en el "
              f"Wazuh Manager o copia el archivo alerts.json localmente.", file=sys.stderr)
        sys.exit(1)

    with open(args.out, "w") as f:
        json.dump(encontradas, f, indent=2)

    print(f"[+] {len(encontradas)} alertas encontradas entre {args.inicio} y {args.fin}")
    print(f"[+] Guardadas en {args.out}")


if __name__ == "__main__":
    main()
