#!/usr/bin/env python3
"""
calcular_metricas.py — Calcula tasa de deteccion, falsos positivos y matriz de
correlacion cruzando log_ataques.csv (Gestion/scripts/ataques/) con las alertas
reales exportadas por recolectar_alertas.py.

IMPORTANTE: este script NO inventa resultados. Debe ejecutarse sobre datos reales
obtenidos tras correr los escenarios 1, 2 y 3 en el laboratorio.

Uso:
  python3 calcular_metricas.py --ataques log_ataques.csv --alertas alertas_ventana.json \
      --margen-seg 30 --out reporte_metricas.md
"""
import argparse
import csv
import json
from datetime import datetime, timedelta

import pandas as pd


def parse_ts(ts):
    return datetime.strptime(ts.split(".")[0].replace("Z", ""), "%Y-%m-%dT%H:%M:%S")


def cargar_ataques(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def cargar_alertas(path):
    with open(path) as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ataques", required=True)
    ap.add_argument("--alertas", required=True)
    ap.add_argument("--margen-seg", type=int, default=30,
                     help="Margen (s) alrededor de [inicio,fin] del ataque para considerar una alerta relacionada")
    ap.add_argument("--out", default="reporte_metricas.md")
    args = ap.parse_args()

    ataques = cargar_ataques(args.ataques)
    alertas = cargar_alertas(args.alertas)

    filas = []
    total_ataques = len(ataques)
    detectados = 0

    for a in ataques:
        t_ini = parse_ts(a["inicio"]) - timedelta(seconds=args.margen_seg)
        t_fin = parse_ts(a["fin"]) + timedelta(seconds=args.margen_seg)
        matches = []
        for al in alertas:
            ts = al.get("timestamp")
            if not ts:
                continue
            try:
                t = parse_ts(ts)
            except ValueError:
                continue
            if t_ini <= t <= t_fin:
                rule = al.get("rule", {})
                matches.append(rule.get("id", "?"))

        detectado = len(matches) > 0
        if detectado:
            detectados += 1
        filas.append({
            "ataque": a["ataque"],
            "mitre_id": a["mitre_id"],
            "objetivo": a["target_ip"],
            "inicio": a["inicio"],
            "detectado": "Si" if detectado else "No",
            "reglas_disparadas": ",".join(sorted(set(matches))) if matches else "-",
        })

    df = pd.DataFrame(filas)
    tasa_deteccion = (detectados / total_ataques * 100) if total_ataques else 0.0

    # Falsos positivos: alertas de grupo 'attack' que NO caen en ninguna ventana de ataque real
    ventanas = [(parse_ts(a["inicio"]) - timedelta(seconds=args.margen_seg),
                 parse_ts(a["fin"]) + timedelta(seconds=args.margen_seg)) for a in ataques]

    def en_alguna_ventana(t):
        return any(ini <= t <= fin for ini, fin in ventanas)

    falsos_positivos = 0
    for al in alertas:
        rule = al.get("rule", {})
        if "attack" not in rule.get("groups", []):
            continue
        ts = al.get("timestamp")
        if not ts:
            continue
        try:
            t = parse_ts(ts)
        except ValueError:
            continue
        if not en_alguna_ventana(t):
            falsos_positivos += 1

    with open(args.out, "w") as f:
        f.write("# Reporte de metricas — Validacion SIEM\n\n")
        f.write(f"- Total de ataques ejecutados: **{total_ataques}**\n")
        f.write(f"- Ataques detectados: **{detectados}**\n")
        f.write(f"- **Tasa de deteccion: {tasa_deteccion:.1f}%** "
                f"(criterio de exito del proyecto: >= 80%)\n")
        f.write(f"- Alertas de grupo 'attack' fuera de ventanas de ataque real "
                f"(posibles falsos positivos): **{falsos_positivos}**\n\n")
        f.write("## Detalle por intento de ataque\n\n")
        f.write(df.to_markdown(index=False))
        f.write("\n\n## Matriz de correlacion (tipo de ataque -> reglas Wazuh disparadas)\n\n")
        matriz = df.groupby("ataque")["reglas_disparadas"].apply(
            lambda s: ", ".join(sorted(set(",".join(s).split(","))))
        )
        f.write(matriz.to_markdown())
        f.write("\n")

    print(df.to_string(index=False))
    print(f"\nTasa de deteccion: {tasa_deteccion:.1f}%")
    print(f"Posibles falsos positivos: {falsos_positivos}")
    print(f"Reporte completo guardado en {args.out}")


if __name__ == "__main__":
    main()
