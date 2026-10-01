#!/usr/bin/env bash
# =============================================================================
# calcular_metricas.sh — Recolecta alertas del SIEM y calcula métricas
#
# EJECUTAR EN EL SIEM (192.168.30.10):
#   sudo bash /vagrant/Lab/calcular_metricas.sh \
#       /tmp/log_ataques.csv "2026-09-06T14:00:00Z" "2026-09-06T18:00:00Z"
#
# O sin ventana de tiempo (usa todas las alertas de hoy):
#   sudo bash /vagrant/Lab/calcular_metricas.sh /tmp/log_ataques.csv
#
# Genera:
#   /tmp/alertas_wazuh.json   — alertas extraídas del SIEM
#   /tmp/reporte_metricas.md  — reporte final con tasa de detección
# =============================================================================
set -euo pipefail

LOG_CSV="${1:-/tmp/log_ataques.csv}"
INICIO_VENTANA="${2:-}"
FIN_VENTANA="${3:-}"
ALERTS_JSON="/tmp/alertas_wazuh.json"
ALERTS_FILE="/var/ossec/logs/alerts/alerts.json"
REPORTE="/tmp/reporte_metricas.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then echo "Ejecutar como root: sudo bash $0"; exit 1; fi

# ---- 1. Verificar archivos de entrada --------------------------------------
if [[ ! -f "$LOG_CSV" ]]; then
    echo -e "${RED}[ERROR]${NC} No se encontró el CSV de ataques: ${LOG_CSV}"
    echo "Cópialo desde Kali: scp vagrant@192.168.30.20:/tmp/log_ataques.csv /tmp/"
    exit 1
fi

if [[ ! -f "$ALERTS_FILE" ]]; then
    echo -e "${RED}[ERROR]${NC} No se encontró ${ALERTS_FILE}"
    echo "¿Está corriendo wazuh-manager? systemctl status wazuh-manager"
    exit 1
fi

LINEAS_CSV=$(wc -l < "$LOG_CSV")
info "CSV de ataques: ${LOG_CSV} (${LINEAS_CSV} líneas incluyendo cabecera)"
info "Alertas Wazuh: ${ALERTS_FILE} ($(wc -l < "$ALERTS_FILE") alertas totales)"

# ---- 2. Determinar ventana de tiempo ---------------------------------------
if [[ -z "$INICIO_VENTANA" ]]; then
    # Usar la fecha de hoy completa
    INICIO_VENTANA="$(date -u +%Y-%m-%d)T00:00:00Z"
    FIN_VENTANA="$(date -u +%Y-%m-%d)T23:59:59Z"
    warn "Sin ventana especificada. Usando hoy: ${INICIO_VENTANA} → ${FIN_VENTANA}"
fi

info "Ventana de análisis: ${INICIO_VENTANA} → ${FIN_VENTANA}"

# ---- 3. Instalar dependencias Python si faltan -----------------------------
if ! python3 -c "import pandas, tabulate" &>/dev/null 2>&1; then
    info "Instalando dependencias Python (pandas, tabulate)..."
    pip3 install --quiet --break-system-packages pandas tabulate 2>/dev/null || \
    pip3 install --quiet pandas tabulate 2>/dev/null || true
fi

# ---- 4. Extraer alertas de la ventana de tiempo ----------------------------
info "Extrayendo alertas de la ventana de tiempo..."

python3 << PYEOF
import json, sys
from datetime import datetime

def parse_ts(ts):
    for fmt in ["%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S"]:
        try:
            return datetime.strptime(ts[:26].replace("Z",""), fmt.replace("Z",""))
        except:
            continue
    return None

t_ini = parse_ts("${INICIO_VENTANA}")
t_fin = parse_ts("${FIN_VENTANA}")
encontradas = []

with open("${ALERTS_FILE}", "r", errors="ignore") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            alert = json.loads(line)
        except:
            continue
        ts = alert.get("timestamp","")
        t = parse_ts(ts)
        if t and t_ini <= t <= t_fin:
            encontradas.append(alert)

with open("${ALERTS_JSON}", "w") as f:
    json.dump(encontradas, f, indent=2)

print(f"[OK] {len(encontradas)} alertas en la ventana → ${ALERTS_JSON}")
PYEOF

TOTAL_ALERTAS=$(python3 -c "import json; d=json.load(open('${ALERTS_JSON}')); print(len(d))")
ok "${TOTAL_ALERTAS} alertas extraídas."

# ---- 5. Calcular métricas --------------------------------------------------
info "Calculando métricas de detección..."

python3 << PYEOF
import json, csv, sys
from datetime import datetime, timedelta

MARGEN = 30  # segundos de margen alrededor de cada ataque

def parse_ts(ts):
    for fmt in ["%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S"]:
        try:
            return datetime.strptime(ts[:19], fmt[:19])
        except:
            continue
    return None

# Cargar ataques
ataques = []
with open("${LOG_CSV}") as f:
    for row in csv.DictReader(f):
        ataques.append(row)

# Cargar alertas
with open("${ALERTS_JSON}") as f:
    alertas = json.load(f)

# Correlacionar cada ataque con alertas en su ventana
total = len(ataques)
detectados = 0
filas = []

for a in ataques:
    t_ini = parse_ts(a["inicio"])
    t_fin = parse_ts(a["fin"])
    if not t_ini or not t_fin:
        continue
    t_ini -= timedelta(seconds=MARGEN)
    t_fin += timedelta(seconds=MARGEN)

    matches = []
    for al in alertas:
        t = parse_ts(al.get("timestamp",""))
        if t and t_ini <= t <= t_fin:
            rule = al.get("rule", {})
            rid  = rule.get("id","?")
            rdesc = rule.get("description","")[:60]
            matches.append(f"{rid}:{rdesc}")

    det = len(matches) > 0
    if det:
        detectados += 1

    filas.append({
        "Ataque"        : a["ataque"],
        "MITRE"         : a["mitre_id"],
        "Objetivo"      : a["target_ip"],
        "Rep"           : a.get("repeticion","1"),
        "Detectado"     : "✓ SÍ" if det else "✗ NO",
        "Reglas (id:desc)": " | ".join(sorted(set(matches))[:3]) if matches else "—",
    })

tasa = (detectados / total * 100) if total else 0.0

# Falsos positivos: alertas con nivel >= 8 fuera de cualquier ventana de ataque
ventanas = []
for a in ataques:
    ti = parse_ts(a["inicio"])
    tf = parse_ts(a["fin"])
    if ti and tf:
        ventanas.append((ti - timedelta(seconds=MARGEN), tf + timedelta(seconds=MARGEN)))

fp = 0
for al in alertas:
    nivel = int(al.get("rule", {}).get("level", 0))
    if nivel < 8:
        continue
    t = parse_ts(al.get("timestamp",""))
    if not t:
        continue
    if not any(ini <= t <= fin for ini, fin in ventanas):
        fp += 1

# Escribir reporte Markdown
lines = []
lines.append("# Reporte de Métricas — Validación SIEM\n")
lines.append(f"**Ventana:** {ataques[0]['inicio'] if ataques else '?'} → {ataques[-1]['fin'] if ataques else '?'}\n")
lines.append(f"- Total ataques registrados : **{total}**")
lines.append(f"- Ataques detectados        : **{detectados}**")
lines.append(f"- **Tasa de detección       : {tasa:.1f}%** (objetivo ≥ 80%)")
lines.append(f"- Alertas fuera de ventana de ataque (nivel ≥ 8): **{fp}** (falsos positivos candidatos)\n")

# Tabla de detalle
lines.append("## Detalle por ataque\n")
header = "| Ataque | MITRE | Objetivo | Rep | Detectado | Reglas disparadas |"
sep    = "|--------|-------|----------|-----|-----------|-------------------|"
lines.append(header)
lines.append(sep)
for f in filas:
    lines.append(f"| {f['Ataque']} | {f['MITRE']} | {f['Objetivo']} | {f['Rep']} | {f['Detectado']} | {f['Reglas (id:desc)']} |")

# Resumen por tipo de ataque
lines.append("\n## Resumen por tipo de ataque\n")
from collections import defaultdict
por_tipo = defaultdict(lambda: {"total":0,"detectados":0})
for f in filas:
    k = f["Ataque"]
    por_tipo[k]["total"] += 1
    if "SÍ" in f["Detectado"]:
        por_tipo[k]["detectados"] += 1

lines.append("| Tipo de ataque | Total intentos | Detectados | Tasa |")
lines.append("|----------------|---------------|------------|------|")
for tipo, d in sorted(por_tipo.items()):
    t_tipo = (d["detectados"] / d["total"] * 100) if d["total"] else 0
    lines.append(f"| {tipo} | {d['total']} | {d['detectados']} | {t_tipo:.0f}% |")

with open("${REPORTE}", "w") as f:
    f.write("\n".join(lines) + "\n")

# Imprimir en pantalla también
print("\n" + "="*60)
print("  RESULTADO FINAL")
print("="*60)
print(f"  Total ataques    : {total}")
print(f"  Detectados       : {detectados}")
print(f"  Tasa detección   : {tasa:.1f}%")
print(f"  Falsos positivos : {fp}")
print("="*60)
print(f"\nReporte guardado en: ${REPORTE}")
PYEOF

echo ""
ok "Análisis completado."
echo ""
echo "  Reporte: ${REPORTE}"
echo ""
cat "$REPORTE"
