#!/usr/bin/env bash
# =============================================================================
# orquestar_trafico.sh — Lanza trafico de red realista en TODAS las instancias
# del laboratorio EN PARALELO, para emular una red empresarial que "respira".
#
# Se ejecuta desde la maquina de administracion (la IP que el security group
# autoriza para SSH/RDP), no desde el atacante. Lanza:
#   - cliente-linux en linux-01 y linux-ws (navegacion, DNS, SMB, SSH, correo)
#   - servidor-web  en web-server (health checks, DNS, NTP, correo saliente)
#   - dns           en dns1 (consultas continuas)
#   - trafico Windows en win-ws-01 via WinRM (navegacion, SMB, Kerberos/LDAP)
#
# Todas las fuentes corren concurrentemente durante DURACION_MIN, generando
# un fondo de trafico legitimo denso y diverso. El trafico de los clientes
# ademas golpea a los servidores (web, DNS, SMB, SMTP, DC), de modo que esos
# servidores tambien registran actividad entrante legitima.
#
# Uso:  ./orquestar_trafico.sh <DURACION_MIN> <PEM> [INTENSIDAD]
#   (requiere exportar las IPs PUBLICAS: LINUX01_PUB, LINUXWS_PUB, WEB_PUB,
#    DNS_PUB, WINWS_IP_PRIV, ATACANTE_PUB — ver variables abajo)
# =============================================================================
set -uo pipefail

DURACION_MIN="${1:-30}"
PEM="${2:?Uso: $0 <DURACION_MIN> <PEM> [INTENSIDAD]}"
INTENSIDAD="${3:-3}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=90"

# IPs PUBLICAS de cada instancia (exportar antes de llamar, o editar aqui)
LINUX01_PUB="${LINUX01_PUB:?Falta LINUX01_PUB}"
LINUXWS_PUB="${LINUXWS_PUB:-}"
WEB_PUB="${WEB_PUB:?Falta WEB_PUB}"
DNS_PUB="${DNS_PUB:-}"
WINWS_IP_PRIV="${WINWS_IP_PRIV:-10.0.20.30}"
ATACANTE_PUB="${ATACANTE_PUB:-}"      # desde el atacante se lanza el WinRM a win-ws
GEN="/opt/lab/escenarios/generar_trafico_realista.sh"

echo "============================================================"
echo " Orquestando trafico realista en toda la red (${DURACION_MIN} min)"
echo "============================================================"
PIDS=()

lanzar() {  # <ip_publica> <rol>
  local ip="$1" rol="$2"
  [ -n "$ip" ] || return 0
  echo ">> ${rol} en ${ip}"
  nohup ssh $SSH_OPTS -i "$PEM" "ubuntu@${ip}" \
    "sudo DC_IP=${TGT_DC:-10.0.10.20} WEB_IP=${TGT_WEB:-10.0.10.10} DNS_IP=${TGT_DNS:-10.0.10.50} SMTP_IP=${TGT_SMTP:-10.0.10.70} bash ${GEN} ${rol} ${DURACION_MIN} ${INTENSIDAD} > /tmp/trafico_${rol}.log 2>&1" &
  PIDS+=($!)
}

lanzar "$LINUX01_PUB" "cliente-linux"
lanzar "$LINUXWS_PUB" "cliente-linux"
lanzar "$WEB_PUB"     "servidor-web"
lanzar "$DNS_PUB"     "dns"

# Trafico Windows: se dispara via WinRM desde el atacante (que alcanza la IP
# privada de win-ws dentro de la VPC). Requiere evil-winrm y el .ps1 en el bundle.
if [ -n "$ATACANTE_PUB" ]; then
  echo ">> trafico Windows en ${WINWS_IP_PRIV} (via WinRM desde atacante)"
  nohup ssh $SSH_OPTS -i "$PEM" "ubuntu@${ATACANTE_PUB}" \
    "sudo -u attacker bash -lc 'source ~/lab.env 2>/dev/null; { echo \"EMPRESA\\\\Administrator\"; echo \"P@ssw0rd\"; echo \"powershell -ExecutionPolicy Bypass -File C:\\\\lab\\\\escenarios\\\\generar_trafico_windows.ps1 ${DURACION_MIN}\"; echo exit; } | evil-winrm -i ${WINWS_IP_PRIV} -u EMPRESA\\\\Administrator -p P@ssw0rd > /tmp/trafico_windows.log 2>&1'" &
  PIDS+=($!)
fi

echo ">> ${#PIDS[@]} generadores de trafico lanzados. Esperando ${DURACION_MIN} min..."
for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
echo ">> Trafico realista de toda la red finalizado."
