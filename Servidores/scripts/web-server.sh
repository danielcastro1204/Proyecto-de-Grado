#!/usr/bin/env bash
# =============================================================================
# web-server.sh  |  Servidor Web Ubuntu 22.04 LTS
# Proyecto SIEM - Integrante B | VLAN 10 | 192.168.10.10
# =============================================================================
# Este script aprovisiona el servidor web del integrante B. Realiza:
#   1. Actualizacion del sistema
#   2. Configuracion de IP fija (192.168.10.10/24) via Netplan
#   3. Instalacion de Apache2 con sitio web del proyecto
#   4. Configuracion de logs detallados de Apache
#   5. Configuracion del firewall UFW
#   6. Instalacion del agente Wazuh (apuntando al SIEM 192.168.30.10)
#   7. Resumen final
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# VARIABLES
# ---------------------------------------------------------------------------
# Las siguientes variables se inyectan desde el Vagrantfile:
#   VM_IP, VM_GATEWAY, VM_DNS, SIEM_IP, DOMAIN
VM_IP="${VM_IP:-192.168.10.10}"
VM_GATEWAY="${VM_GATEWAY:-192.168.10.1}"
VM_DNS="${VM_DNS:-192.168.10.20}"
SIEM_IP="${SIEM_IP:-192.168.30.10}"
DOMAIN="${DOMAIN:-empresa.local}"

WEB_IP="$VM_IP"
WEB_MASK="24"
WEB_GATEWAY="$VM_GATEWAY"
WEB_DNS="$VM_DNS"              # DC como DNS primario (192.168.10.20)
WEB_DNS_FALLBACK="8.8.8.8"     # Fallback: resolver público (requiere internet en router)
WEB_DNS_RETRY_MAX=30            # Reintentos para que el DC esté listo
WEB_DNS_RETRY_DELAY=2           # Segundos entre reintentos
WAZUH_MANAGER="$SIEM_IP"       # SIEM en VLAN 30 (192.168.30.10) - Integrante A
WAZUH_VERSION="4.9.2"

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color

log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Aprovisionamiento: Servidor Web Ubuntu 22.04${NC}"
echo -e "${CYAN} IP: ${WEB_IP}/${WEB_MASK} | Gateway: ${WEB_GATEWAY}${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ===========================================================================
# Identificar el adaptador puente ANTES de usarlo en cualquier paso.
# El adaptador puente en Ubuntu suele llamarse enp0s8 o enp0s3 segun el orden.
# Vagrant usa enp0s3 para NAT y enp0s8 para redes adicionales.
# Identificamos el adaptador puente (el que no es el de NAT 10.0.2.x).
# ===========================================================================
BRIDGE_IFACE=""
for iface in $(ls /sys/class/net | grep -v lo); do
    iface_ip=$(ip addr show "$iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || true)
    if [[ -n "$iface_ip" && "$iface_ip" != "10.0.2"* ]]; then
        BRIDGE_IFACE="$iface"
        break
    fi
    # Si el adaptador no tiene IP aun, puede ser el puente
    if [[ -z "$iface_ip" && "$iface" != "lo" ]]; then
        BRIDGE_IFACE="$iface"
    fi
done

# Fallback: usar enp0s8 que es el nombre comun del segundo adaptador en VirtualBox
if [[ -z "$BRIDGE_IFACE" ]]; then
    BRIDGE_IFACE="enp0s8"
    warn "No se identifico el adaptador puente automaticamente. Usando $BRIDGE_IFACE."
fi

info "Adaptador puente detectado: $BRIDGE_IFACE"


# ===========================================================================
# PASO 0: Esperar a que el DNS esté disponible (DC puede tardar en levantarse)
# ===========================================================================
info "PASO 0: Activando el adaptador puente..."

# En las cajas Vagrant de Ubuntu, la segunda interfaz (adaptador puente) viene
# administrativamente apagada hasta que algo la activa. La configuracion real
# de IP ocurre en el PASO 3 (netplan); aqui solo la encendemos y seguimos.
ip link set dev "$BRIDGE_IFACE" up 2>/dev/null || warn "No se pudo forzar 'up' en $BRIDGE_IFACE (puede requerir netplan)."
sleep 2
LINK_STATE=$(cat "/sys/class/net/${BRIDGE_IFACE}/operstate" 2>/dev/null || echo "unknown")
info "Estado de $BRIDGE_IFACE tras activarla: $LINK_STATE (se confirmara despues de configurar la IP en el PASO 3)."


# ===========================================================================
# PASO 1: Actualizar el sistema
# ===========================================================================
info "PASO 1: Actualizando paquetes del sistema..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
log "Sistema actualizado."


# ===========================================================================
# PASO 2: Instalar paquetes base
# ===========================================================================
info "PASO 2: Instalando paquetes base..."
apt-get install -y -qq \
    curl \
    wget \
    gnupg \
    lsb-release \
    ca-certificates \
    apt-transport-https \
    net-tools \
    htop \
    vim \
    ufw
log "Paquetes base instalados."


# ===========================================================================
# PASO 3: Configurar IP fija via Netplan
# El adaptador puente en Ubuntu suele llamarse enp0s8 o enp0s3 segun el orden.
# Vagrant usa enp0s3 para NAT y enp0s8 para redes adicionales.
# Identificamos el adaptador puente (el que no es el de NAT 10.0.2.x).
# ===========================================================================
info "PASO 3: Configurando IP fija ${WEB_IP}/${WEB_MASK}..."

# Verificar si la IP ya esta configurada
CURRENT_IP=$(ip addr show "$BRIDGE_IFACE" 2>/dev/null | grep "inet ${WEB_IP}" | awk '{print $2}' | cut -d/ -f1 || true)

if [[ "$CURRENT_IP" == "$WEB_IP" ]]; then
    warn "IP ${WEB_IP} ya esta configurada en $BRIDGE_IFACE. Saltando."
else
    # Crear archivo de configuracion Netplan
    NETPLAN_FILE="/etc/netplan/99-siem-static.yaml"

    cat > "$NETPLAN_FILE" << EOF
# Configuracion de red estatica para VLAN 10 - Proyecto SIEM
# Generado por Vagrant/web-server.sh
network:
  version: 2
  renderer: networkd
  ethernets:
    ${BRIDGE_IFACE}:
      dhcp4: no
      dhcp6: no
      addresses:
        - ${WEB_IP}/${WEB_MASK}
      routes:
        - to: default
          via: ${WEB_GATEWAY}
          metric: 100
      nameservers:
        addresses:
          - ${WEB_DNS}
          - ${WEB_DNS_FALLBACK}
        search:
          - ${DOMAIN}
EOF

    # Establecer permisos correctos (Netplan lo requiere)
    chmod 600 "$NETPLAN_FILE"
    log "Archivo Netplan creado: $NETPLAN_FILE"

    # Aplicar configuracion
    netplan generate 2>/dev/null || warn "netplan generate produjo advertencias."
    netplan apply 2>/dev/null || warn "netplan apply produjo advertencias."

    # Esperar un momento para que la interfaz obtenga la IP
    sleep 3

    # Verificar asignacion
    NEW_IP=$(ip addr show "$BRIDGE_IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || true)
    if [[ "$NEW_IP" == "$WEB_IP" ]]; then
        log "IP estatica ${WEB_IP}/${WEB_MASK} configurada correctamente en $BRIDGE_IFACE."
    else
        warn "IP aun no visible en la interfaz (puede tardar unos segundos). IP actual: ${NEW_IP:-'(ninguna)'}"
    fi
fi

# Ahora que la IP esta configurada, intentar alcanzar el gateway (router Cisco)
RETRY_COUNT=0
while [ $RETRY_COUNT -lt 10 ]; do
    if ping -c 1 -W 1 "$WEB_GATEWAY" &>/dev/null; then
        log "Gateway $WEB_GATEWAY está accesible."
        break
    fi
    info "Gateway $WEB_GATEWAY no accesible. Reintentando... ($RETRY_COUNT/10)"
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ $RETRY_COUNT -eq 10 ]; then
    warn "⚠️  ADVERTENCIA: Gateway $WEB_GATEWAY no está accesible tras 10 intentos."
    warn "Si el adaptador puente no esta bien conectado a una red con salida, NO habrá internet."
    warn "El aprovisionamiento continuará; verifica manualmente la conectividad si algo falla más adelante."
fi


# ===========================================================================
# PASO 4: Instalar Apache2 y configurar el sitio web
# ===========================================================================
info "PASO 4: Instalando Apache2..."
apt-get install -y -qq apache2
systemctl enable apache2
systemctl start apache2
log "Apache2 instalado e iniciado."

# ---- Configurar LogFormat detallado ---
APACHE_CONF="/etc/apache2/conf-available/siem-logging.conf"
cat > "$APACHE_CONF" << 'EOF'
# Configuracion de logging detallado para proyecto SIEM
# Formatos adicionales con informacion de autenticacion y tiempos

# Formato extendido con tiempo de respuesta (microsegundos) y User-Agent completo
LogFormat "%h %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\" %D" combined_extended
LogFormat "%{%Y-%m-%dT%H:%M:%S%z}t %h \"%r\" %>s %b" json_like

# Aumentar nivel de log para capturar mas eventos
LogLevel info

EOF
a2enconf siem-logging 2>/dev/null
log "Configuracion de logging detallado creada."

# ---- Crear sitio web del proyecto ---
WEBROOT="/var/www/html"

# Pagina principal
cat > "${WEBROOT}/index.html" << EOF
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Servidor Web - Proyecto SIEM | empresa.local</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Segoe UI', Arial, sans-serif;
            background: #0d1117;
            color: #c9d1d9;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
        }
        .container {
            max-width: 760px;
            width: 90%;
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 12px;
            padding: 48px 40px;
            box-shadow: 0 8px 32px rgba(0,0,0,0.4);
        }
        .badge {
            display: inline-block;
            background: #238636;
            color: #fff;
            font-size: 12px;
            padding: 3px 10px;
            border-radius: 20px;
            margin-bottom: 16px;
            letter-spacing: 0.5px;
        }
        h1 { font-size: 28px; color: #f0f6fc; margin-bottom: 8px; }
        .subtitle { color: #8b949e; font-size: 15px; margin-bottom: 32px; }
        .grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 16px;
            margin-bottom: 28px;
        }
        .card {
            background: #0d1117;
            border: 1px solid #21262d;
            border-radius: 8px;
            padding: 18px;
        }
        .card-label { color: #8b949e; font-size: 11px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 6px; }
        .card-value { color: #58a6ff; font-size: 15px; font-weight: 600; font-family: monospace; }
        .info-row { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #21262d; font-size: 14px; }
        .info-row:last-child { border-bottom: none; }
        .info-key { color: #8b949e; }
        .info-val { color: #e6edf3; font-family: monospace; }
        .log-note {
            background: #1c2128;
            border-left: 3px solid #f78166;
            padding: 12px 16px;
            border-radius: 4px;
            font-size: 13px;
            color: #8b949e;
            margin-top: 24px;
        }
        .log-note code { color: #f78166; font-size: 12px; }
        footer { margin-top: 32px; font-size: 12px; color: #484f58; text-align: center; }
    </style>
</head>
<body>
<div class="container">
    <div class="badge">SIEM LAB · ACTIVO</div>
    <h1>Servidor Web · empresa.local</h1>
    <p class="subtitle">Laboratorio de Ciberseguridad — Proyecto SIEM con Wazuh &amp; Active Directory</p>

    <div class="grid">
        <div class="card">
            <div class="card-label">Dirección IP</div>
            <div class="card-value">192.168.10.10</div>
        </div>
        <div class="card">
            <div class="card-label">VLAN</div>
            <div class="card-value">VLAN 10 · Servidores</div>
        </div>
        <div class="card">
            <div class="card-label">Dominio</div>
            <div class="card-value">empresa.local</div>
        </div>
        <div class="card">
            <div class="card-label">Servidor Web</div>
            <div class="card-value">Apache 2.4 · Ubuntu 22.04</div>
        </div>
    </div>

    <div class="info-row">
        <span class="info-key">Controlador de Dominio</span>
        <span class="info-val">192.168.10.20 (dc-empresa.empresa.local)</span>
    </div>
    <div class="info-row">
        <span class="info-key">SIEM (Wazuh Manager)</span>
        <span class="info-val">192.168.30.10 (VLAN 30 · Gestión)</span>
    </div>
    <div class="info-row">
        <span class="info-key">Gateway</span>
        <span class="info-val">192.168.10.1 (Cisco ISR4321)</span>
    </div>
    <div class="info-row">
        <span class="info-key">Estado del agente Wazuh</span>
        <span class="info-val" id="wazuh-status">Ver systemctl status wazuh-agent</span>
    </div>

    <div class="log-note">
        📋 Los logs de acceso a esta página se envían al SIEM en tiempo real.<br>
        Rutas: <code>/var/log/apache2/access.log</code> · <code>/var/log/apache2/error.log</code>
    </div>
</div>
<footer>Proyecto Final · Ciberseguridad · VLAN 10 · web-server · Apache/Ubuntu 22.04</footer>
</body>
</html>
EOF

# Pagina de login simulada (genera eventos de autenticacion en logs)
cat > "${WEBROOT}/login.html" << 'EOF'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>Portal Corporativo - empresa.local</title>
    <style>
        body { font-family: Arial, sans-serif; background: #f0f2f5; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }
        .login-box { background: #fff; padding: 40px; border-radius: 8px; box-shadow: 0 2px 16px rgba(0,0,0,0.1); width: 320px; }
        h2 { text-align: center; color: #1a1a2e; margin-bottom: 24px; }
        input { width: 100%; padding: 10px; margin: 8px 0; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; }
        button { width: 100%; padding: 12px; background: #0066cc; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 15px; margin-top: 8px; }
        button:hover { background: #0055aa; }
        .note { font-size: 11px; color: #999; text-align: center; margin-top: 16px; }
    </style>
</head>
<body>
<div class="login-box">
    <h2>Portal empresa.local</h2>
    <input type="text" placeholder="Usuario (ej: user1)" />
    <input type="password" placeholder="Contraseña" />
    <button onclick="alert('Autenticacion registrada en logs de Apache y Wazuh.')">Iniciar sesión</button>
    <p class="note">Entorno de laboratorio SIEM — Accesos auditados</p>
</div>
</body>
</html>
EOF

# Configurar VirtualHost con logging extendido
cat > "/etc/apache2/sites-available/empresa-siem.conf" << EOF
<VirtualHost *:80>
    ServerName web-server.empresa.local
    ServerAlias ${WEB_IP}
    DocumentRoot /var/www/html
    ServerAdmin admin@empresa.local

    # Logs detallados para el SIEM
    ErrorLog  \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined_extended
    LogLevel info

    <Directory /var/www/html>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    # Cabeceras de seguridad basicas
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
</VirtualHost>
EOF

a2enmod headers 2>/dev/null
a2ensite empresa-siem 2>/dev/null
a2dissite 000-default 2>/dev/null || true
systemctl restart apache2
log "Sitio web configurado en /var/www/html. Logs en /var/log/apache2/"


# ===========================================================================
# PASO 5: Configurar firewall UFW
# ===========================================================================
info "PASO 5: Configurando firewall UFW..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Servicios entrantes permitidos
ufw allow 22/tcp   comment 'SSH - Acceso de gestion'
ufw allow 80/tcp   comment 'HTTP - Servidor Web'
ufw allow 443/tcp  comment 'HTTPS - Servidor Web'

# Trafico saliente al SIEM (Wazuh Manager)
ufw allow out to "${WAZUH_MANAGER}" port 1514 proto tcp comment 'Wazuh logs'
ufw allow out to "${WAZUH_MANAGER}" port 1515 proto tcp comment 'Wazuh registro'
ufw allow out to "${WAZUH_MANAGER}" port 1516 proto tcp comment 'Wazuh control'

# Trafico saliente al DC (DNS y dominio)
ufw allow out to "${WEB_DNS}" port 53 comment 'DNS al DC'
ufw allow out to "${WEB_DNS}" port 389 comment 'LDAP al DC'
ufw allow out to "${WEB_DNS}" port 636 comment 'LDAPS al DC'

ufw --force enable
log "Firewall UFW configurado."
ufw status verbose


# ===========================================================================
# PASO 6: Instalar agente Wazuh para Linux (Ubuntu)
# Sigue el proceso oficial: agregar repositorio, instalar, configurar, iniciar.
# ===========================================================================
info "PASO 6: Instalando agente Wazuh (manager: ${WAZUH_MANAGER})..."

# Verificar si ya esta instalado
if systemctl is-active --quiet wazuh-agent 2>/dev/null; then
    warn "El agente Wazuh ya esta activo. Saltando instalacion."
else
    # Agregar la clave GPG oficial de Wazuh
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
        gpg --no-default-keyring \
            --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
            --import
    chmod 644 /usr/share/keyrings/wazuh.gpg

    # Agregar el repositorio de Wazuh (CORRECCIÓN: Usar 4.x)
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
        | tee /etc/apt/sources.list.d/wazuh.list

    # Instalar el paquete del agente
    apt-get update -qq
    WAZUH_MANAGER="${WAZUH_MANAGER}" \
    WAZUH_MANAGER_PORT="1514" \
    WAZUH_REGISTRATION_SERVER="${WAZUH_MANAGER}" \
    WAZUH_REGISTRATION_PORT="1515" \
    WAZUH_AGENT_NAME="web-server" \
    apt-get install -y -qq wazuh-agent

    log "Paquete wazuh-agent instalado."

    # Verificar y ajustar la configuracion del manager en ossec.conf
    OSSEC_CONF="/var/ossec/etc/ossec.conf"
    if [[ -f "$OSSEC_CONF" ]]; then
        # Asegurar que la IP del manager es correcta
        if grep -q "<address>MANAGER_IP</address>" "$OSSEC_CONF"; then
            sed -i "s|<address>MANAGER_IP</address>|<address>${WAZUH_MANAGER}</address>|g" "$OSSEC_CONF"
            log "IP del manager actualizada en ossec.conf: ${WAZUH_MANAGER}"
        fi

        # Agregar monitoreo de logs de Apache
        if ! grep -q "apache2" "$OSSEC_CONF"; then
            # Insertar configuracion de localfile antes de </ossec_config>
            sed -i 's|</ossec_config>|  <localfile>\n    <log_format>apache</log_format>\n    <location>/var/log/apache2/access.log</location>\n  </localfile>\n\n  <localfile>\n    <log_format>apache</log_format>\n    <location>/var/log/apache2/error.log</location>\n  </localfile>\n\n</ossec_config>|' "$OSSEC_CONF"
            log "Monitoreo de logs Apache agregado a ossec.conf."
        fi
    else
        warn "No se encontro $OSSEC_CONF. Wazuh puede requerir configuracion manual."
    fi

    # Habilitar e iniciar el servicio
    systemctl daemon-reload
    systemctl enable wazuh-agent
    systemctl start wazuh-agent

    # Verificar estado
    sleep 3
    if systemctl is-active --quiet wazuh-agent; then
        log "Servicio wazuh-agent activo y en ejecucion."
    else
        warn "El servicio wazuh-agent no esta activo. Revisar: journalctl -u wazuh-agent"
    fi
fi


# ===========================================================================
# PASO 7: Configurar NTP / sincronizacion horaria
# ===========================================================================
info "PASO 7: Configurando sincronizacion de tiempo..."
timedatectl set-timezone "America/Bogota"
timedatectl set-ntp true
log "Zona horaria: America/Bogota (UTC-5). NTP habilitado."


# ===========================================================================
# PASO 8: Configuracion de /etc/hosts para resolucion local
# ===========================================================================
info "PASO 8: Actualizando /etc/hosts..."

declare -A HOSTS=(
    ["192.168.10.10"]="web-server web-server.empresa.local"
    ["192.168.10.20"]="dc-empresa dc-empresa.empresa.local"
    ["192.168.10.1"]="gateway-vlan10"
    ["192.168.30.10"]="siem-wazuh siem-wazuh.empresa.local"
)

for ip in "${!HOSTS[@]}"; do
    hostname="${HOSTS[$ip]}"
    if ! grep -q "$ip" /etc/hosts; then
        echo "$ip    $hostname" >> /etc/hosts
        log "Agregado a /etc/hosts: $ip -> $hostname"
    fi
done


# ===========================================================================
# RESUMEN FINAL
# ===========================================================================
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} RESUMEN FINAL - Servidor Web${NC}"
echo -e "${CYAN}============================================================${NC}"

echo ""
echo -e " ${GREEN}Servicio Apache2:${NC}"
systemctl is-active apache2 && echo "   Estado: ACTIVO" || echo "   Estado: INACTIVO"
echo "   Sitio web : http://${WEB_IP}/"
echo "   Login     : http://${WEB_IP}/login.html"
echo "   Logs      : /var/log/apache2/access.log"
echo "               /var/log/apache2/error.log"

echo ""
echo -e " ${GREEN}Agente Wazuh:${NC}"
systemctl is-active wazuh-agent && echo "   Estado: ACTIVO" || echo "   Estado: INACTIVO (verificar manualmente)"
echo "   Manager   : ${WAZUH_MANAGER}:1514"
echo "   Config    : /var/ossec/etc/ossec.conf"

echo ""
echo -e " ${GREEN}Red:${NC}"
echo "   IP        : ${WEB_IP}/${WEB_MASK}"
echo "   Gateway   : ${WEB_GATEWAY}"
echo "   DNS (DC)  : ${WEB_DNS}"

echo ""
echo -e " ${YELLOW}Comandos utiles:${NC}"
echo "   curl http://${WEB_IP}/            # Probar sitio web"
echo "   ping ${WEB_GATEWAY}               # Probar gateway"
echo "   ping ${WEB_DNS}                   # Probar DC/DNS"
echo "   ping ${WAZUH_MANAGER}             # Probar SIEM"
echo "   tail -f /var/log/apache2/access.log"
echo "   systemctl status wazuh-agent"
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN} APROVISIONAMIENTO COMPLETADO - web-server listo${NC}"
echo -e "${CYAN}============================================================${NC}"