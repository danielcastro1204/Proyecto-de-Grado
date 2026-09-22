#!/usr/bin/env bash
# =============================================================================
# linux-desktop.sh — Aprovisionamiento de estaciones Ubuntu 22.04 (VLAN 20)
# =============================================================================
# Variables de entorno esperadas (inyectadas por Vagrant):
#   VM_IP            - IP estática (ej: 192.168.20.40)
#   VM_HOSTNAME      - Nombre del host (ej: linux-01)
#   VM_GW            - Gateway (192.168.20.1)
#   VM_DNS           - DNS / IP del DC (192.168.10.20)
#   WAZUH_MANAGER_IP - IP del manager Wazuh (192.168.30.10)
#   INSTALL_DESKTOP  - "true" si se debe instalar entorno gráfico; "false" si ya viene en la box
# =============================================================================

set -euo pipefail

# ---- Colores para output ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---- Leer variables de entorno con valores por defecto ----
VM_IP="${VM_IP:-192.168.20.40}"
VM_HOSTNAME="${VM_HOSTNAME:-linux-01}"
VM_GW="${VM_GW:-192.168.20.1}"
VM_DNS="${VM_DNS:-192.168.10.20}"
WAZUH_MANAGER_IP="${WAZUH_MANAGER_IP:-192.168.30.10}"
INSTALL_DESKTOP="${INSTALL_DESKTOP:-false}"
WAZUH_VERSION="4.x"

echo "============================================================"
echo " Aprovisionando: $VM_HOSTNAME | IP: $VM_IP"
echo "============================================================"

# ============================================================
# 1. ACTUALIZAR SISTEMA
# ============================================================
log "[1/7] Actualizando lista de paquetes..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Instalar herramientas base
apt-get install -y -qq \
    curl wget gnupg lsb-release apt-transport-https \
    ca-certificates net-tools ufw unzip \
    > /dev/null 2>&1
log "   Paquetes base instalados."

# ============================================================
# 2. CONFIGURAR HOSTNAME
# ============================================================
log "[2/7] Configurando hostname '$VM_HOSTNAME'..."

CURRENT_HOSTNAME=$(hostname)
if [ "$CURRENT_HOSTNAME" != "$VM_HOSTNAME" ]; then
    hostnamectl set-hostname "$VM_HOSTNAME"
    # Actualizar /etc/hosts
    sed -i "s/127.0.1.1.*/127.0.1.1\t$VM_HOSTNAME/" /etc/hosts 2>/dev/null || \
        echo "127.0.1.1	$VM_HOSTNAME" >> /etc/hosts
    log "   Hostname actualizado a '$VM_HOSTNAME'."
else
    log "   Hostname ya es '$VM_HOSTNAME'."
fi

# Agregar entrada del DC al /etc/hosts (por si DNS no resuelve durante boot)
if ! grep -q "empresa.local" /etc/hosts; then
    echo "$VM_DNS	dc01.empresa.local empresa.local" >> /etc/hosts
    log "   Entrada del DC agregada a /etc/hosts."
fi

# ============================================================
# 3. INSTALAR ENTORNO DE ESCRITORIO (OPCIONAL)
# ============================================================
log "[3/7] Verificando entorno de escritorio (INSTALL_DESKTOP=$INSTALL_DESKTOP)..."

if [ "$INSTALL_DESKTOP" = "true" ]; then
    if dpkg -l ubuntu-desktop-minimal > /dev/null 2>&1 || \
       dpkg -l xubuntu-desktop     > /dev/null 2>&1; then
        log "   Entorno de escritorio ya instalado."
    else
        log "   Instalando xubuntu-desktop (más liviano que GNOME)..."
        log "   ADVERTENCIA: Este proceso puede tardar 15-30 minutos según la conexión."
        apt-get install -y --no-install-recommends xubuntu-desktop lightdm \
            > /dev/null 2>&1 || apt-get install -y ubuntu-desktop-minimal > /dev/null 2>&1
        # Configurar LightDM como gestor de pantalla predeterminado
        systemctl enable lightdm 2>/dev/null || true
        log "   Escritorio instalado."
    fi

    # Instalar Firefox si no está presente
    if ! command -v firefox > /dev/null 2>&1; then
        log "   Instalando Firefox..."
        snap install firefox 2>/dev/null || apt-get install -y firefox > /dev/null 2>&1 || true
    fi
else
    log "   Saltando instalación de escritorio (box ya incluye GUI)."
fi

# ============================================================
# 4. CONFIGURAR IP ESTÁTICA CON NETPLAN
# ============================================================
log "[4/7] Configurando IP estática con Netplan..."

# Detectar la interfaz de red correcta (excluir loopback y la NAT de Vagrant)
NET_IFACE=$(ip -o link show | awk -F': ' '$2 !~ /^lo$|^docker|^veth|^br-/{print $2}' | \
    while read iface; do
        ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        # Excluir interfaz con IP NAT de Vagrant (10.0.2.x)
        if [ -z "$ip" ] || ! echo "$ip" | grep -q "^10\.0\.2\."; then
            echo "$iface"; break
        fi
    done)

# Fallback: usar la segunda interfaz (la primera suele ser NAT)
if [ -z "$NET_IFACE" ]; then
    NET_IFACE=$(ip -o link show | awk -F': ' 'NR==3{print $2}')
fi

if [ -z "$NET_IFACE" ]; then
    err "No se pudo detectar la interfaz de red. Verifica la configuración."
fi

log "   Interfaz seleccionada: $NET_IFACE"

# Crear o sobreescribir configuración de Netplan
NETPLAN_FILE="/etc/netplan/99-vagrant-static.yaml"
cat > "$NETPLAN_FILE" << NETPLAN_EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NET_IFACE}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${VM_IP}/24
      nameservers:
        addresses:
          - ${VM_DNS}
          - 8.8.8.8
        search:
          - empresa.local
NETPLAN_EOF

chmod 600 "$NETPLAN_FILE"

# Aplicar configuración Netplan
netplan apply 2>/dev/null || {
    warn "netplan apply lanzó advertencias (puede ser normal). Continuando..."
}
sleep 3
log "   Netplan aplicado. IP configurada: $VM_IP"

# Verificar conectividad al gateway
if ping -c 2 -W 3 "$VM_GW" > /dev/null 2>&1; then
    log "   Gateway $VM_GW alcanzable."
else
    warn "No se puede alcanzar el gateway $VM_GW. Verifica la conexión puente."
fi

# ============================================================
# 5. INSTALAR AGENTE WAZUH
# ============================================================
log "[5/7] Instalando agente Wazuh..."

# Verificar si ya está instalado
if systemctl is-active --quiet wazuh-agent 2>/dev/null; then
    log "   El agente Wazuh ya está activo."
    # Verificar si la IP del manager es correcta
    if grep -q "<address>$WAZUH_MANAGER_IP</address>" /var/ossec/etc/ossec.conf 2>/dev/null; then
        log "   Manager IP ya configurada correctamente."
    else
        warn "   Actualizando IP del manager en ossec.conf..."
        sed -i "s|<address>[^<]*</address>|<address>${WAZUH_MANAGER_IP}</address>|g" \
            /var/ossec/etc/ossec.conf
        systemctl restart wazuh-agent
    fi
else
    # Agregar repositorio oficial de Wazuh
    log "   Agregando repositorio oficial de Wazuh..."
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
        gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
        --import 2>/dev/null
    chmod 644 /usr/share/keyrings/wazuh.gpg

    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/${WAZUH_VERSION}/apt/ stable main" \
        > /etc/apt/sources.list.d/wazuh.list

    apt-get update -qq

    log "   Instalando paquete wazuh-agent..."
    WAZUH_MANAGER="${WAZUH_MANAGER_IP}" apt-get install -y wazuh-agent > /dev/null 2>&1

    # Configurar ossec.conf con la IP del manager correcta
    if [ -f /var/ossec/etc/ossec.conf ]; then
        sed -i "s|<address>[^<]*</address>|<address>${WAZUH_MANAGER_IP}</address>|g" \
            /var/ossec/etc/ossec.conf

        # Configurar nombre del agente
        if ! grep -q "<agent_name>" /var/ossec/etc/ossec.conf; then
            sed -i "/<server>/a\    <agent_name>${VM_HOSTNAME}</agent_name>" \
                /var/ossec/etc/ossec.conf
        fi
        log "   ossec.conf configurado. Manager: $WAZUH_MANAGER_IP"
    fi

    # Habilitar e iniciar el servicio
    systemctl daemon-reload
    systemctl enable wazuh-agent || true
    systemctl start wazuh-agent || true

    log "   Agente Wazuh instalado."
fi

# Verificar estado del servicio
sleep 2
if systemctl is-active --quiet wazuh-agent; then
    log "   wazuh-agent: ACTIVO"
else
    warn "wazuh-agent no está activo. Revisa /var/ossec/logs/ossec.log"
fi

# ============================================================
# 6. CONFIGURAR FIREWALL (UFW)
# ============================================================
log "[6/7] Configurando UFW (Uncomplicated Firewall)..."

# Habilitar UFW si no lo está
ufw --force enable > /dev/null 2>&1

# Política por defecto
ufw default deny incoming  > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1

# Permitir SSH (para Vagrant)
ufw allow 22/tcp > /dev/null 2>&1

# Permitir tráfico al SIEM
ufw allow out to "$WAZUH_MANAGER_IP" port 1514 proto tcp > /dev/null 2>&1
ufw allow out to "$WAZUH_MANAGER_IP" port 1514 proto udp > /dev/null 2>&1
ufw allow out to "$WAZUH_MANAGER_IP" port 1515 proto tcp > /dev/null 2>&1

# Permitir tráfico DNS al DC
ufw allow out to "$VM_DNS" port 53 proto udp  > /dev/null 2>&1
ufw allow out to "$VM_DNS" port 53 proto tcp  > /dev/null 2>&1

# Permitir tráfico web
ufw allow out 80/tcp  > /dev/null 2>&1
ufw allow out 443/tcp > /dev/null 2>&1

log "   UFW configurado."

# ============================================================
# 7. CONFIGURAR AUDITORÍA DE SISTEMA (auditd)
# ============================================================
log "[7/7] Configurando auditd para generación de logs..."

apt-get install -y -qq auditd audispd-plugins > /dev/null 2>&1

# Reglas de auditoría básicas para el laboratorio SIEM
cat > /etc/audit/rules.d/99-siem-lab.rules << 'AUDIT_EOF'
# Reglas de auditoría para laboratorio SIEM — Integrante C
# Auditar accesos a archivos de autenticación
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers

# Auditar comandos sudo
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k sudo_commands
-a always,exit -F arch=b32 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k sudo_commands

# Auditar conexiones de red
-a always,exit -F arch=b64 -S connect -k network_connect
-a always,exit -F arch=b32 -S connect -k network_connect

# Auditar creación/eliminación de usuarios
-a always,exit -F arch=b64 -S useradd -k user_mgmt
-a always,exit -F arch=b64 -S userdel -k user_mgmt
-a always,exit -F arch=b64 -S usermod -k user_mgmt

# Auditar cambios de contraseña
-w /usr/bin/passwd -p x -k password_change

# Auditar modificación de cron
-w /etc/cron.d -p wa -k cron
-w /var/spool/cron -p wa -k cron

# Hacer reglas inmutables (comentar durante desarrollo/pruebas)
# -e 2
AUDIT_EOF

# Recargar reglas de auditd
systemctl enable auditd
systemctl restart auditd 2>/dev/null || service auditd restart 2>/dev/null || true

log "   auditd configurado con reglas básicas de monitoreo."

# ============================================================
# RESUMEN FINAL
# ============================================================
echo ""
echo "============================================================"
echo " APROVISIONAMIENTO COMPLETADO — $VM_HOSTNAME"
echo "------------------------------------------------------------"
echo " Hostname    : $(hostname)"
echo " IP          : $(ip -4 addr show $NET_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)/24"
echo " Gateway     : $VM_GW"
echo " DNS         : $VM_DNS"
echo " Wazuh Agent : $(systemctl is-active wazuh-agent 2>/dev/null || echo 'inactivo')"
echo " auditd      : $(systemctl is-active auditd 2>/dev/null || echo 'inactivo')"
echo " UFW         : $(ufw status | head -1)"
echo "============================================================"
