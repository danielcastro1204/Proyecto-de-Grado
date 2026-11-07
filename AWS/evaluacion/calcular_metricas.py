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
from datetime import datetime, timedelta, timezone

import pandas as pd


def parse_ts(ts):
    # Los timestamps de log_ataques.csv son UTC con sufijo "Z"; los de las
    # alertas de Wazuh traen el offset de la zona horaria local del servidor
    # (p.ej. "-0500"). Ambos deben normalizarse a UTC antes de comparar, o
    # cualquier correlación cruzando medianoche local queda mal calculada.
    ts = ts.strip()
    if ts.endswith("Z"):
        ts = ts[:-1] + "+0000"
    try:
        dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S.%f%z")
    except ValueError:
        dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S%z")
    return dt.astimezone(timezone.utc)


def cargar_ataques(path):
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def cargar_alertas(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# -----------------------------------------------------------------------------
# Correlacion a NIVEL DE TECNICA (deteccion estricta).
#
# La deteccion "amplia" cuenta cualquier alerta en la ventana del ataque. Eso
# sobreestima: muchas reglas (logon de Windows, sesion PAM) tambien se disparan
# con actividad normal. La deteccion ESTRICTA solo cuenta como detectado el
# ataque si se disparo una regla PERTINENTE a esa tecnica — se verifica por los
# grupos de la regla de Wazuh (rule.groups) y/o por IDs de regla conocidos.
# Cada entrada: nombre de ataque -> (substrings de grupo, ids de regla).
# -----------------------------------------------------------------------------
TECNICA_RELEVANCIA = {
    "bruteforce_ssh":       (["authentication_fail", "authentication_failures",
                              "invalid_login", "win_authentication_failed", "brute"],
                             ["5551", "5712", "5720", "5716", "5710", "60122", "60204"]),
    "bruteforce_ssh_lento": (["authentication_fail", "authentication_failures",
                              "invalid_login", "brute"],
                             ["5551", "5712", "5720", "5716", "5710"]),
    "portscan":             (["ids", "suricata", "recon", "scan"],
                             ["100020", "100021", "100022"]),
    "portscan_sigiloso":    (["ids", "suricata", "recon", "scan"],
                             ["100020", "100021", "100022"]),
    "sql_injection":        (["sql_injection", "web_scan", "sqli", "web", "ids", "suricata"],
                             ["31103", "31104", "31106", "31105", "31101", "100040", "100041"]),
    "sqli_evasion":         (["sql_injection", "web_scan", "sqli", "web", "ids", "suricata"],
                             ["31103", "31104", "31106", "31105", "31101", "100040", "100041"]),
    # PtH: deteccion fiable por COMPORTAMIENTO de host (92650 servicio creado
    # desde ADMIN$) + Sysmon (100031). 100032 quedo como informativa (no cuenta
    # como deteccion: a nivel de red el PtH no se distingue de la admin legitima).
    "pass_the_hash":        (["lateral_movement", "pth", "sysmon", "mimikatz"],
                             ["100031", "92650", "92652"]),
    "payload_execution":    (["execution", "payload", "sysmon", "windows_powershell",
                              "win_evtchannel", "powershell_script"],
                             ["100050", "100051", "92650", "92652", "92031", "91802", "91803"]),
}

# Grupos que indican una alerta "de ataque" accionable (para el analisis de
# falsos positivos sobre trafico legitimo): si alguno de estos se dispara fuera
# de una ventana de ataque real, es una falsa alarma accionable.
GRUPOS_ACCIONABLES = (
    "authentication_failures", "authentication_failed", "invalid_login",
    "attack", "attacks", "web_scan", "sql_injection", "sqli",
    "recon", "ids", "suricata", "brute", "exploit", "mimikatz", "pass_the_hash",
)


def alerta_relevante(rule, ataque):
    """True si la regla es pertinente a la tecnica del ataque (deteccion estricta)."""
    grupos_rel, ids_rel = TECNICA_RELEVANCIA.get(ataque, ([], []))
    rid = str(rule.get("id", ""))
    if rid in ids_rel:
        return True
    grupos = [g.lower() for g in rule.get("groups", [])]
    for g in grupos:
        for sub in grupos_rel:
            if sub in g:
                return True
    return False


def es_accionable(rule):
    grupos = [g.lower() for g in rule.get("groups", [])]
    return any(any(ga in g for g in grupos) for ga in GRUPOS_ACCIONABLES)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ataques", required=True)
    ap.add_argument("--alertas", required=True)
    ap.add_argument("--margen-seg", type=int, default=30,
                     help="Margen (s) alrededor de [inicio,fin] del ataque para considerar una alerta relacionada")
    ap.add_argument("--escenario", default=None,
                     help="Si se indica, solo se consideran filas de log_ataques.csv con esta columna 'escenario'")
    ap.add_argument("--titulo", default="Reporte de metricas — Validacion SIEM")
    ap.add_argument("--out", default="reporte_metricas.md")
    args = ap.parse_args()

    ataques = cargar_ataques(args.ataques)
    if args.escenario is not None:
        ataques = [a for a in ataques if a.get("escenario", "2") == str(args.escenario)]
    alertas = cargar_alertas(args.alertas)

    filas = []
    total_ataques = len(ataques)
    detectados = 0          # deteccion amplia (cualquier alerta)
    detectados_estrictos = 0  # deteccion estricta (regla pertinente a la tecnica)
    tiempos_deteccion = []  # TTD estricto: inicio ataque -> primera alerta PERTINENTE

    for a in ataques:
        t_ini = parse_ts(a["inicio"]) - timedelta(seconds=args.margen_seg)
        t_fin = parse_ts(a["fin"]) + timedelta(seconds=args.margen_seg)
        matches = []
        matches_estrictos = []
        primera_alerta_estricta = None
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
                if alerta_relevante(rule, a["ataque"]):
                    matches_estrictos.append(rule.get("id", "?"))
                    if primera_alerta_estricta is None or t < primera_alerta_estricta:
                        primera_alerta_estricta = t

        detectado = len(matches) > 0
        detectado_estricto = len(matches_estrictos) > 0
        if detectado:
            detectados += 1
        if detectado_estricto:
            detectados_estrictos += 1
            ttd = (primera_alerta_estricta - parse_ts(a["inicio"])).total_seconds()
            tiempos_deteccion.append(ttd)
        filas.append({
            "ataque": a["ataque"],
            "mitre_id": a["mitre_id"],
            "objetivo": a["target_ip"],
            "inicio": a["inicio"],
            "det_amplia": "Si" if detectado else "No",
            "det_estricta": "Si" if detectado_estricto else "No",
            "reglas_pertinentes": ",".join(sorted(set(matches_estrictos))) if matches_estrictos else "-",
            "reglas_disparadas": ",".join(sorted(set(matches))) if matches else "-",
        })

    df = pd.DataFrame(filas)
    tasa_deteccion = (detectados / total_ataques * 100) if total_ataques else 0.0
    tasa_estricta = (detectados_estrictos / total_ataques * 100) if total_ataques else 0.0
    mttd = (sum(tiempos_deteccion) / len(tiempos_deteccion)) if tiempos_deteccion else None

    # Falsos positivos: alertas de grupo 'attack' que NO caen en ninguna ventana de ataque real
    ventanas = [(parse_ts(a["inicio"]) - timedelta(seconds=args.margen_seg),
                 parse_ts(a["fin"]) + timedelta(seconds=args.margen_seg)) for a in ataques]

    def en_alguna_ventana(t):
        return any(ini <= t <= fin for ini, fin in ventanas)

    # Falsas alarmas ACCIONABLES: alertas con grupos de ataque (no solo el
    # literal 'attack') disparadas FUERA de toda ventana de ataque real. Son
    # las que un analista investigaria como posible incidente => el falso
    # positivo que importa. (Se excluyen los eventos de auditoria rutinarios.)
    total_alertas_accionables = 0
    falsos_positivos = 0
    for al in alertas:
        rule = al.get("rule", {})
        if not es_accionable(rule):
            continue
        ts = al.get("timestamp")
        if not ts:
            continue
        try:
            t = parse_ts(ts)
        except ValueError:
            continue
        total_alertas_accionables += 1
        if not en_alguna_ventana(t):
            falsos_positivos += 1
    alertas_verdaderas = total_alertas_accionables - falsos_positivos

    # Recall = deteccion estricta (la metrica rigurosa); Precision = alertas
    # accionables correctas / total accionables; F1 combina ambas.
    recall = detectados_estrictos / total_ataques if total_ataques else None
    precision = (alertas_verdaderas / total_alertas_accionables) if total_alertas_accionables else None
    f1 = (2 * precision * recall / (precision + recall)) if (precision and recall) else None

    # Desglose por tipo de ataque (amplia y estricta)
    resumen_tipo = df.groupby("ataque").agg(
        intentos=("det_amplia", "count"),
        det_amplia=("det_amplia", lambda s: (s == "Si").sum()),
        det_estricta=("det_estricta", lambda s: (s == "Si").sum()),
    )
    resumen_tipo["%_amplia"] = (resumen_tipo["det_amplia"] / resumen_tipo["intentos"] * 100).round(1)
    resumen_tipo["%_estricta"] = (resumen_tipo["det_estricta"] / resumen_tipo["intentos"] * 100).round(1)

    with open(args.out, "w", encoding="utf-8") as f:
        f.write(f"# {args.titulo}\n\n")
        f.write(f"- Total de ataques ejecutados: **{total_ataques}**\n")
        f.write(f"- **Tasa de deteccion ESTRICTA (regla pertinente a la tecnica): "
                f"{tasa_estricta:.1f}%** ({detectados_estrictos}/{total_ataques}) — "
                f"metrica rigurosa, criterio del proyecto: >= 80%\n")
        f.write(f"- Tasa de deteccion amplia (cualquier alerta correlacionada): "
                f"{tasa_deteccion:.1f}% ({detectados}/{total_ataques})\n")
        f.write(f"- Falsos negativos (ataques no detectados, criterio estricto): "
                f"**{total_ataques - detectados_estrictos}**\n")
        if mttd is not None:
            f.write(f"- Tiempo medio de deteccion (MTTD estricto): {mttd:.1f} s "
                    f"(ver limitaciones: ventanas solapadas)\n")
        f.write(f"- Alertas accionables en la ventana: **{total_alertas_accionables}** "
                f"(correctas: {alertas_verdaderas}, falsas alarmas accionables: **{falsos_positivos}**)\n")
        if precision is not None:
            f.write(f"- Precision (alertas accionables correctas): {precision*100:.1f}%\n")
        if f1 is not None:
            f.write(f"- F1-score: {f1*100:.1f}%\n")
        f.write("\n## Desglose por tipo de ataque (deteccion amplia vs estricta)\n\n")
        f.write(resumen_tipo.to_markdown())
        f.write("\n\n## Detalle por intento de ataque\n\n")
        f.write(df.to_markdown(index=False))
        f.write("\n\n## Matriz de correlacion (tecnica -> reglas Wazuh PERTINENTES disparadas)\n\n")
        matriz = df.groupby("ataque")["reglas_pertinentes"].apply(
            lambda s: ", ".join(sorted(set(",".join(s).split(","))))
        )
        f.write(matriz.to_markdown())
        f.write("\n")

    print(df.to_string(index=False))
    print(f"\nTasa de deteccion ESTRICTA: {tasa_estricta:.1f}% ({detectados_estrictos}/{total_ataques})")
    print(f"Tasa de deteccion amplia:   {tasa_deteccion:.1f}% ({detectados}/{total_ataques})")
    if precision is not None:
        print(f"Precision (accionables): {precision*100:.1f}%")
    if f1 is not None:
        print(f"F1-score: {f1*100:.1f}%")
    print(f"Falsas alarmas accionables: {falsos_positivos} / {total_alertas_accionables}")
    print(f"Reporte completo guardado en {args.out}")


if __name__ == "__main__":
    main()
