#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Despliegue de un comando del laboratorio SIEM en AWS.
#
# Qué hace:
#   1. Empaqueta los scripts de aprovisionamiento (userdata/, deteccion/,
#      config/, ataques/, escenarios/, evaluacion/) en un .tgz y lo sube a S3.
#   2. Genera una URL PREFIRMADA de ese .tgz: así las instancias lo descargan
#      sin necesitar rol IAM (en este sandbox IAM es de solo lectura).
#   3. Despliega el stack de CloudFormation cloudformation/siem-lab.yaml.
#   4. Muestra las salidas (URL del dashboard, IPs, etc.).
#
# Ajustado a las restricciones de "AWS Academy Cloud Architecting - Sandbox":
#   - Key pair preexistente 'vockey' (descarga labsuser.pem desde AWS Details).
#   - Tipos de instancia hasta t3.medium, discos gp2 <= 35 GB, MÁX. 9 instancias.
#   - Sin creación de IAM (entrega de scripts por URL prefirmada).
#
# Uso (desde CloudShell, WSL, Linux o macOS):
#   ./deploy.sh [-k vockey] [-p completa] [-c TU_IP/32] [-r us-east-1] [-s siem-lab]
#     -k  key pair EC2 (def: vockey)
#     -p  perfil: minima (7) | completa (9)   (def: completa)
#     -c  CIDR de administración SSH/RDP/dashboard (def: 0.0.0.0/0; mejor TU_IP/32)
#     -r  región (def: us-east-1)       -s  nombre del stack (def: siem-lab)
#     -b  bucket S3 (def: siem-lab-<accountid>-<region>)
#     -i  perfil de instancia preexistente (def: vacío = usar URL prefirmada)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"; SCRIPT_DIR="$(pwd)"

PERFIL="completa"; ADMIN_CIDR="0.0.0.0/0"; REGION="us-east-1"
STACK="siem-lab"; KEYNAME="vockey"; BUCKET=""; PROFILE_NAME=""

while getopts "k:p:c:r:s:b:i:h" opt; do
  case "$opt" in
    k) KEYNAME="$OPTARG" ;;
    p) PERFIL="$OPTARG" ;;
    c) ADMIN_CIDR="$OPTARG" ;;
    r) REGION="$OPTARG" ;;
    s) STACK="$OPTARG" ;;
    b) BUCKET="$OPTARG" ;;
    i) PROFILE_NAME="$OPTARG" ;;
    h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opción inválida. Usa -h."; exit 1 ;;
  esac
done

command -v aws >/dev/null || { echo "ERROR: falta la AWS CLI."; exit 1; }

echo ">> Verificando credenciales AWS..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || { echo "ERROR: credenciales no válidas. Pega las de 'AWS Details' del lab."; exit 1; }
echo "   Cuenta: $ACCOUNT_ID  Región: $REGION"

[ -n "$BUCKET" ] || BUCKET="siem-lab-${ACCOUNT_ID}-${REGION}"

echo ">> Asegurando bucket S3: s3://${BUCKET}"
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

echo ">> Empaquetando scripts de aprovisionamiento..."
BUNDLE="/tmp/lab-bundle.$$.tgz"
tar -czf "$BUNDLE" -C "$SCRIPT_DIR" userdata deteccion config ataques escenarios evaluacion
aws s3 cp "$BUNDLE" "s3://${BUCKET}/lab-bundle.tgz" --region "$REGION"

echo ">> Generando URL prefirmada (las instancias la usan para descargar)..."
SCRIPTS_URL="$(aws s3 presign "s3://${BUCKET}/lab-bundle.tgz" --region "$REGION" --expires-in 43200)"
rm -f "$BUNDLE"

echo ">> Desplegando stack '${STACK}' (perfil: ${PERFIL})..."
# NOTA (compatibilidad Windows): la AWS CLI v2 en Windows abre el YAML local
# con la codificación ANSI del sistema y falla ('charmap' codec can't decode)
# si el archivo trae tildes/ñ en comentarios o Description. Si hay `iconv`
# disponible, se usa una copia transliterada a ASCII solo para esta llamada
# (no modifica el archivo original ni cambia la lógica de la plantilla).
TEMPLATE_FILE="${SCRIPT_DIR}/cloudformation/siem-lab.yaml"
if command -v iconv >/dev/null 2>&1; then
  TEMPLATE_ASCII="$(mktemp)"
  if iconv -f UTF-8 -t ASCII//TRANSLIT "$TEMPLATE_FILE" > "$TEMPLATE_ASCII" 2>/dev/null; then
    TEMPLATE_FILE="$TEMPLATE_ASCII"
  else
    rm -f "$TEMPLATE_ASCII"
  fi
fi
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK" \
  --template-file "$TEMPLATE_FILE" \
  --s3-bucket "$BUCKET" \
  --parameter-overrides \
      KeyName="$KEYNAME" \
      ScriptsBaseUrl="$SCRIPTS_URL" \
      InstanceProfileName="$PROFILE_NAME" \
      AdminIngressCidr="$ADMIN_CIDR" \
      Perfil="$PERFIL" \
  --no-fail-on-empty-changeset

echo ""
echo ">> Salidas del stack:"
aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" --output table

cat <<EOF

============================================================
 El aprovisionamiento continúa DENTRO de las instancias (user-data):
   - Wazuh all-in-one: 15-30 min hasta que el dashboard responda.
   - DC Windows: 2-3 reinicios automáticos (AD DS). 15-25 min.
   - Estaciones: esperan al DC, se unen al dominio y reinician.
 Progreso:  Linux -> /var/log/siem-bootstrap.log | Windows -> C:\\siem-bootstrap.log
 NOTA: la URL prefirmada caduca con tu sesión del lab; las instancias la usan al
 arrancar (primeros minutos). Si recreas una instancia mucho después, re-despliega.
============================================================
EOF
