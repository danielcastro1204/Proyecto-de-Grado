#!/usr/bin/env bash
# =============================================================================
# smtp-server.sh  |  Servidor de Correo Postfix + Dovecot - Ubuntu 22.04 LTS
# Proyecto SIEM - Integrante B | VLAN 10 (Servidores) | 192.168.10.70
# =============================================================================
# Este script aprovisiona el servidor de correo del laboratorio. Realiza:
#   1. Actualizacion del sistema
#   2. Configuracion de IP fija dual-stack (192.168.10.70/24 + fd00:10::70/64)
#   3. Generacion de certificado TLS autofirmado para el servicio de correo
#   4. Instalacion y configuracion de Postfix (SMTP/Submission/SMTPS)
#   5. Instalacion y configuracion de Dovecot (IMAP/POP3 + SASL para Postfix)
#   6. Creacion de una cuenta de correo de prueba
#   7. Configuracion del firewall UFW (25, 587, 465, 143, 993, 110, 995)
#   8. Instalacion del agente Wazuh
#   9. Configuracion de /etc/hosts y resumen final
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

VM_IP="${VM_IP:-192.168.10.70}"
VM_IP6="${VM_IP6:-fd00:10::70}"
VM_GATEWAY="${VM_GATEWAY:-192.168.10.1}"
VM_GATEWAY6="${VM_GATEWAY6:-fd00:10::1}"
VM_DNS="${VM_DNS:-192.168.10.50}"
SIEM_IP="${SIEM_IP:-192.168.30.10}"
DOMAIN="${DOMAIN:-empresa.local}"

SRV_IP="$VM_IP"; SRV_MASK="24"; SRV_IP6="$VM_IP6"; SRV_PREFIX6="64"
WAZUH_MANAGER="$SIEM_IP"
WAZUH_VERSION="4.9.2"
MAIL_HOSTNAME="smtp.${DOMAIN}"
TEST_USER="correo1"
TEST_PASS="Correo123!"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Aprovisionamiento: Servidor SMTP (Postfix + Dovecot)${NC}"
echo -e "${CYAN} IP: ${SRV_IP}/${SRV_MASK}  |  ${SRV_IP6}/${SRV_PREFIX6}${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ===========================================================================
# Detectar el adaptador puente
# ===========================================================================
BRIDGE_IFACE=""
for iface in $(ls /sys/class/net | grep -v lo); do
    iface_ip=$(ip addr show "$iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || true)
    if [[ -n "$iface_ip" && "$iface_ip" != "10.0.2"* ]]; then
        BRIDGE_IFACE="$iface"; break
    fi
    if [[ -z "$iface_ip" && "$iface" != "lo" ]]; then
        BRIDGE_IFACE="$iface"
    fi
done
[[ -z "$BRIDGE_IFACE" ]] && BRIDGE_IFACE="enp0s8" && warn "No se identifico el adaptador puente. Usando $BRIDGE_IFACE."
info "Adaptador puente detectado: $BRIDGE_IFACE"
ip link set dev "$BRIDGE_IFACE" up 2>/dev/null || true
sleep 2

# ===========================================================================
# PASO 1: Actualizar el sistema
# ===========================================================================
info "PASO 1: Actualizando paquetes del sistema..."
export DEBIAN_FRONTEND=noninteractive
rm -f /etc/apt/sources.list.d/wazuh.list
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
log "Sistema actualizado."

# ===========================================================================
# PASO 2: Paquetes base
# ===========================================================================
info "PASO 2: Instalando paquetes base..."
apt-get install -y -qq curl wget gnupg lsb-release ca-certificates apt-transport-https net-tools htop vim ufw openssl
log "Paquetes base instalados."

# ===========================================================================
# PASO 3: IP fija dual-stack via Netplan
# ===========================================================================
info "PASO 3: Configurando IP fija ${SRV_IP}/${SRV_MASK} y ${SRV_IP6}/${SRV_PREFIX6}..."
NETPLAN_FILE="/etc/netplan/99-siem-static.yaml"
cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${BRIDGE_IFACE}:
      dhcp4: no
      dhcp6: no
      addresses:
        - ${SRV_IP}/${SRV_MASK}
        - ${SRV_IP6}/${SRV_PREFIX6}
      routes:
        - to: default
          via: ${VM_GATEWAY}
          metric: 100
        - to: ::/0
          via: ${VM_GATEWAY6}
          metric: 100
      nameservers:
        addresses:
          - ${VM_DNS}
        search:
          - ${DOMAIN}
EOF
chmod 600 "$NETPLAN_FILE"
netplan generate 2>/dev/null || warn "netplan generate produjo advertencias."
netplan apply 2>/dev/null || warn "netplan apply produjo advertencias."
sleep 3
log "Red dual-stack configurada en $BRIDGE_IFACE."

RETRY_COUNT=0
while [ $RETRY_COUNT -lt 10 ]; do
    if ping -c 1 -W 1 "$VM_GATEWAY" &>/dev/null; then log "Gateway $VM_GATEWAY accesible."; break; fi
    info "Gateway $VM_GATEWAY no accesible. Reintentando... ($RETRY_COUNT/10)"
    sleep 2; RETRY_COUNT=$((RETRY_COUNT + 1))
done

hostnamectl set-hostname "smtp-server"

# ===========================================================================
# PASO 4: Certificado TLS autofirmado para el correo
# ===========================================================================
info "PASO 4: Generando certificado TLS autofirmado para ${MAIL_HOSTNAME}..."
mkdir -p /etc/ssl/mail
if [[ -f /etc/ssl/mail/mail.cert.pem ]]; then
    warn "El certificado ya existe. Se conserva el existente."
else
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
        -keyout /etc/ssl/mail/mail.key.pem \
        -out /etc/ssl/mail/mail.cert.pem \
        -subj "/C=CO/ST=Valle del Cauca/L=Cali/O=Proyecto SIEM/CN=${MAIL_HOSTNAME}" \
        -addext "subjectAltName=DNS:${MAIL_HOSTNAME},IP:${SRV_IP}" 2>/dev/null
    chmod 640 /etc/ssl/mail/mail.key.pem
    chmod 644 /etc/ssl/mail/mail.cert.pem
    log "Certificado generado en /etc/ssl/mail/."
fi

# ===========================================================================
# PASO 5: Instalar y configurar Postfix
# ===========================================================================
info "PASO 5: Instalando Postfix (modo no interactivo)..."
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
echo "postfix postfix/mailname string ${MAIL_HOSTNAME}" | debconf-set-selections
apt-get install -y -qq postfix
log "Paquete postfix instalado."

info "Configurando Postfix para el dominio ${DOMAIN}..."
cat > /etc/postfix/main.cf << EOF
# ==== Identidad del servidor ====
myhostname = ${MAIL_HOSTNAME}
mydomain = ${DOMAIN}
myorigin = \$mydomain

# ==== Interfaces de red ====
inet_interfaces = all
inet_protocols = all

# ==== Destinos locales (correo para el propio dominio) ====
mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain

# ==== Redes de confianza (permitidas para enviar sin autenticacion) ====
mynetworks = 127.0.0.0/8, 192.168.10.0/24, 192.168.20.0/24, 192.168.30.0/24, fd00:10::/64, fd00:20::/64, fd00:30::/64

# ==== Almacenamiento del correo (Maildir por usuario) ====
home_mailbox = Maildir/

# ==== Configuracion TLS/SSL (cifrado del correo) ====
smtpd_tls_cert_file = /etc/ssl/mail/mail.cert.pem
smtpd_tls_key_file = /etc/ssl/mail/mail.key.pem
smtpd_use_tls = yes
smtpd_tls_security_level = may
smtp_tls_security_level = may
smtpd_tls_auth_only = yes
smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache

# ==== Autenticacion SASL usando Dovecot ====
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes

# ==== Politicas de recepcion (quien puede enviar) ====
smtpd_recipient_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination

# ==== Limite de tamano de mensaje (25 MB) ====
message_size_limit = 26214400

# ==== Banner y ajustes basicos ====
smtpd_banner = \$myhostname ESMTP
biff = no
EOF

cat > /etc/postfix/master.cf << 'EOF'
# ==== Servicio SMTP estandar (puerto 25) ====
smtp      inet  n       -       y       -       -       smtpd

# ==== Recoleccion y limpieza de correo local ====
pickup    unix  n       -       y       60      1       pickup
cleanup   unix  n       -       y       -       0       cleanup

# ==== Gestion de colas y entrega ====
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       y       1000?   1       tlsmgr

# ==== Reescritura y manejo interno de mensajes ====
rewrite   unix  -       -       y       -       -       trivial-rewrite
bounce    unix  -       -       y       -       0       bounce
defer     unix  -       -       y       -       0       bounce
trace     unix  -       -       y       -       0       bounce
verify    unix  -       -       y       -       1       verify
flush     unix  -       -       y       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxymap

# ==== Transporte SMTP saliente y relay ====
smtp      unix  -       -       y       -       -       smtp
relay     unix  -       -       y       -       -       smtp
        -o syslog_name=postfix/$service_name

# ==== Entrega local y virtual ====
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       y       -       -       lmtp

# ==== Servicios auxiliares ====
anvil     unix  -       -       y       -       1       anvil
scache    unix  -       -       y       -       1       scache
postlog   unix-dgram n  -       n       -       1       postlogd

# ==== Soporte UUCP (no suele usarse, pero inofensivo) ====
uucp      unix  -       n       n       -       -       pipe
  flags=Fqhu user=uucp argv=uux -r -n -z -a$sender - $nexthop!rmail ($recipient)

# ==== Servicio Submission (puerto 587, STARTTLS) ====
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject

# ==== Servicio SMTPS (puerto 465, TLS directo) ====
smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
EOF
log "Postfix configurado (main.cf / master.cf)."

# ===========================================================================
# PASO 6: Instalar y configurar Dovecot
# ===========================================================================
info "PASO 6: Instalando Dovecot (IMAP/POP3 + SASL para Postfix)..."
apt-get install -y -qq dovecot-core dovecot-imapd dovecot-pop3d
log "Paquetes dovecot instalados."

cat > /etc/dovecot/dovecot.conf << 'EOF'
# ==== Protocolos habilitados ====
protocols = imap pop3

# ==== Interfaces de red habilitadas (IPv4 e IPv6 en todas las IP) ====
listen = *, ::

# ==== Inclusion de configuraciones modulares de Dovecot ====
!include_try /usr/share/dovecot/protocols.d/*.protocol
!include conf.d/*.conf
!include_try local.conf

# ==== Diccionario interno (usado por plugins, opcional) ====
dict {
}
EOF

cat > /etc/dovecot/conf.d/10-mail.conf << 'EOF'
# ==== Ubicacion del buzon de correo ====
mail_location = maildir:~/Maildir

# ==== Definicion del namespace principal ====
namespace inbox {
  inbox = yes
}

# ==== Grupo privilegiado para acceso al correo ====
mail_privileged_group = mail
EOF

cat > /etc/dovecot/conf.d/10-auth.conf << 'EOF'
# ==== Configuracion de autenticacion principal ====
disable_plaintext_auth = no

# ==== Mecanismos de autenticacion permitidos ====
auth_mechanisms = plain login

# ==== Fuente de autenticacion (cuentas locales del sistema) ====
!include auth-system.conf.ext
EOF

cat > /etc/dovecot/conf.d/10-master.conf << 'EOF'
# ==== Servicio de autenticacion Dovecot (para Postfix) ====
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
EOF

cat > /etc/dovecot/conf.d/10-ssl.conf << 'EOF'
# ==== Activar SSL/TLS para IMAP y POP3 ====
ssl = yes

# ==== Certificado y clave del servidor de correo ====
ssl_cert = </etc/ssl/mail/mail.cert.pem
ssl_key = </etc/ssl/mail/mail.key.pem

# ==== Protocolos y compatibilidad TLS (CORREGIDO A TLSv1.0) ====
ssl_min_protocol = TLSv1.0

# ==== Permitir certificados autofirmados (CA local) ====
ssl_client_ca_dir = /etc/ssl/certs
ssl_verify_client_cert = no

# ==== Usar el campo CommonName del certificado como nombre de usuario ====
ssl_cert_username_field = commonName

# ==== Parametros Diffie-Hellman para intercambio seguro de claves ====
ssl_dh = </usr/share/dovecot/dh.pem
EOF

if [[ ! -f /usr/share/dovecot/dh.pem ]]; then
    info "Generando parametros Diffie-Hellman para Dovecot (puede tardar unos segundos)..."
    openssl dhparam -out /usr/share/dovecot/dh.pem 2048 2>/dev/null
fi

usermod -aG mail postfix 2>/dev/null || true
log "Dovecot configurado (dovecot.conf y conf.d/*.conf)."

# ===========================================================================
# PASO 7: Cuenta de correo de prueba
# ===========================================================================
info "PASO 7: Creando cuenta de correo de prueba (${TEST_USER})..."
if id "${TEST_USER}" &>/dev/null; then
    warn "El usuario ${TEST_USER} ya existe. Saltando creacion."
else
    useradd -m -s /usr/sbin/nologin "${TEST_USER}"
    echo "${TEST_USER}:${TEST_PASS}" | chpasswd
    mkdir -p "/home/${TEST_USER}/Maildir"
    chown -R "${TEST_USER}:${TEST_USER}" "/home/${TEST_USER}/Maildir"
    log "Usuario ${TEST_USER} creado con buzon Maildir."
fi

systemctl daemon-reload
systemctl enable postfix dovecot
systemctl restart postfix
systemctl restart dovecot
sleep 3
systemctl is-active --quiet postfix && log "Servicio postfix activo." || warn "postfix no esta activo. Revisar: journalctl -u postfix"
systemctl is-active --quiet dovecot && log "Servicio dovecot activo." || warn "dovecot no esta activo. Revisar: journalctl -u dovecot"

# ===========================================================================
# PASO 8: Firewall UFW
# ===========================================================================
info "PASO 8: Configurando firewall UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment 'SSH - Acceso de gestion'
ufw allow 25/tcp    comment 'SMTP'
ufw allow 587/tcp   comment 'Submission (STARTTLS)'
ufw allow 465/tcp   comment 'SMTPS'
ufw allow 143/tcp   comment 'IMAP'
ufw allow 993/tcp   comment 'IMAPS'
ufw allow 110/tcp   comment 'POP3'
ufw allow 995/tcp   comment 'POP3S'
ufw allow out to "${SIEM_IP}" port 1514 proto tcp comment 'Wazuh logs'
ufw allow out to "${SIEM_IP}" port 1515 proto tcp comment 'Wazuh registro'
ufw --force enable
log "Firewall UFW configurado."
ufw status verbose

# ===========================================================================
# PASO 9: Agente Wazuh
# ===========================================================================
info "PASO 9: Instalando agente Wazuh (manager: ${WAZUH_MANAGER})..."
if systemctl is-active --quiet wazuh-agent 2>/dev/null; then
    warn "El agente Wazuh ya esta activo. Saltando instalacion."
else
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
        gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
    chmod 644 /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
        | tee /etc/apt/sources.list.d/wazuh.list
    apt-get update -qq
    WAZUH_MANAGER="${WAZUH_MANAGER}" WAZUH_MANAGER_PORT="1514" \
    WAZUH_REGISTRATION_SERVER="${WAZUH_MANAGER}" WAZUH_REGISTRATION_PORT="1515" \
    WAZUH_AGENT_NAME="smtp-server" \
    apt-get install -y -qq wazuh-agent
    log "Paquete wazuh-agent instalado."

    OSSEC_CONF="/var/ossec/etc/ossec.conf"
    if [[ -f "$OSSEC_CONF" ]]; then
        grep -q "<address>MANAGER_IP</address>" "$OSSEC_CONF" && \
            sed -i "s|<address>MANAGER_IP</address>|<address>${WAZUH_MANAGER}</address>|g" "$OSSEC_CONF"
        if ! grep -q "mail.log" "$OSSEC_CONF"; then
            sed -i 's|</ossec_config>|  <localfile>\n    <log_format>syslog</log_format>\n    <location>/var/log/mail.log</location>\n  </localfile>\n\n</ossec_config>|' "$OSSEC_CONF"
            log "Monitoreo de logs de correo agregado a ossec.conf."
        fi
    fi
    systemctl daemon-reload
    systemctl enable wazuh-agent
    systemctl start wazuh-agent
    sleep 3
    systemctl is-active --quiet wazuh-agent && log "Servicio wazuh-agent activo." || warn "wazuh-agent no esta activo."
fi

# ===========================================================================
# PASO 10: Zona horaria
# ===========================================================================
info "PASO 10: Configurando sincronizacion de tiempo..."
timedatectl set-timezone "America/Bogota"
timedatectl set-ntp true
log "Zona horaria: America/Bogota (UTC-5)."

# ===========================================================================
# PASO 11: /etc/hosts
# ===========================================================================
info "PASO 11: Actualizando /etc/hosts..."
declare -A HOSTS=(
    ["192.168.10.10"]="web-server web-server.${DOMAIN}"
    ["192.168.10.20"]="dc-empresa dc-empresa.${DOMAIN}"
    ["192.168.10.30"]="dhcpv4-server dhcpv4-server.${DOMAIN}"
    ["192.168.10.40"]="dhcpv6-server dhcpv6-server.${DOMAIN}"
    ["192.168.10.50"]="dns1-server dns1-server.${DOMAIN}"
    ["192.168.10.60"]="dns2-server dns2-server.${DOMAIN}"
    ["192.168.10.70"]="smtp-server smtp-server.${DOMAIN} smtp.${DOMAIN}"
    ["192.168.10.80"]="ntp-server ntp-server.${DOMAIN}"
    ["192.168.10.1"]="gateway-vlan10"
    ["192.168.30.10"]="siem-wazuh siem-wazuh.${DOMAIN}"
)
for ip in "${!HOSTS[@]}"; do
    hostname="${HOSTS[$ip]}"
    grep -q "$ip" /etc/hosts || echo "$ip    $hostname" >> /etc/hosts
done
log "/etc/hosts actualizado."

# ===========================================================================
# RESUMEN FINAL
# ===========================================================================
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} RESUMEN FINAL - Servidor SMTP (Postfix + Dovecot)${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e " ${GREEN}Servicio Postfix:${NC}"
systemctl is-active postfix && echo "   Estado: ACTIVO" || echo "   Estado: INACTIVO"
echo "   Dominio   : ${DOMAIN}  |  Hostname: ${MAIL_HOSTNAME}"
echo "   Puertos   : 25 (SMTP), 587 (Submission), 465 (SMTPS)"
echo ""
echo -e " ${GREEN}Servicio Dovecot:${NC}"
systemctl is-active dovecot && echo "   Estado: ACTIVO" || echo "   Estado: INACTIVO"
echo "   Puertos   : 143 (IMAP), 993 (IMAPS), 110 (POP3), 995 (POP3S)"
echo ""
echo -e " ${GREEN}Cuenta de prueba:${NC}"
echo "   Usuario   : ${TEST_USER}@${DOMAIN}"
echo "   Password  : ${TEST_PASS}"
echo ""
echo -e " ${YELLOW}Comandos utiles:${NC}"
echo "   echo 'Prueba' | mail -s 'Test' ${TEST_USER}@${DOMAIN}"
echo "   tail -f /var/log/mail.log"
echo ""
echo -e " ${GREEN}Red:${NC}"
echo "   IPv4 : ${SRV_IP}/${SRV_MASK}   Gateway: ${VM_GATEWAY}"
echo "   IPv6 : ${SRV_IP6}/${SRV_PREFIX6}   Gateway: ${VM_GATEWAY6}"
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN} APROVISIONAMIENTO COMPLETADO - smtp-server listo${NC}"
echo -e "${CYAN}============================================================${NC}"