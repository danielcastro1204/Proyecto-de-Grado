#!/usr/bin/env bash
# =============================================================================
# dns1-server.sh  |  Servidor DNS Primario/Maestro (BIND9) - Ubuntu 22.04 LTS
# Proyecto SIEM - Integrante B | VLAN 10 (Servidores) | 192.168.10.50
# =============================================================================
# Este script aprovisiona el servidor DNS1 (maestro) del laboratorio. Realiza:
#   1. Actualizacion del sistema
#   2. Configuracion de IP fija dual-stack (192.168.10.50/24 + fd00:10::50/64)
#   3. Instalacion de BIND9
#   4. Generacion de la clave TSIG compartida con DNS2 (transferencia segura)
#   5. Creacion de la zona directa "empresa.local" y las zonas inversas
#      IPv4 (10.168.192.in-addr.arpa) e IPv6 (fd00:10::/64)
#   6. Configuracion del firewall UFW (puerto 53 tcp/udp)
#   7. Instalacion del agente Wazuh
#   8. Configuracion de /etc/hosts y resumen final
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

VM_IP="${VM_IP:-192.168.10.50}"
VM_IP6="${VM_IP6:-fd00:10::50}"
VM_GATEWAY="${VM_GATEWAY:-192.168.10.1}"
VM_GATEWAY6="${VM_GATEWAY6:-fd00:10::1}"
SIEM_IP="${SIEM_IP:-192.168.30.10}"
DOMAIN="${DOMAIN:-empresa.local}"
DNS2_IP="${DNS2_IP:-192.168.10.60}"
DNS2_IP6="${DNS2_IP6:-fd00:10::60}"
TSIG_SECRET="${TSIG_SECRET:?ERROR: TSIG_SECRET no fue inyectado desde el Vagrantfile}"

SRV_IP="$VM_IP"; SRV_MASK="24"; SRV_IP6="$VM_IP6"; SRV_PREFIX6="64"
WAZUH_MANAGER="$SIEM_IP"
WAZUH_VERSION="4.9.2"
TSIG_KEY_NAME="tsig-ns."
ZONE_FILE="/etc/bind/zones/db.${DOMAIN}"
REV4_ZONE_FILE="/etc/bind/zones/db.192.168.10"
REV6_ZONE_FILE="/etc/bind/zones/db.fd00-10"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Aprovisionamiento: Servidor DNS1 - Maestro (BIND9)${NC}"
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
apt-get install -y -qq curl wget gnupg lsb-release ca-certificates apt-transport-https net-tools htop vim ufw dnsutils
log "Paquetes base instalados."

# ===========================================================================
# PASO 3: IP fija dual-stack via Netplan (DNS1 se apunta a si mismo)
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
          - 127.0.0.1
          - ${DNS2_IP}
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

# ===========================================================================
# PASO 4: Instalar BIND9
# ===========================================================================
info "PASO 4: Instalando BIND9..."
apt-get install -y -qq bind9 bind9utils bind9-dnsutils
mkdir -p /etc/bind/zones /etc/bind/keys
log "Paquete bind9 instalado."

# ===========================================================================
# PASO 5: Escribir la clave TSIG compartida con DNS2
# El secreto viaja fijo desde el Vagrantfile (TSIG_SECRET) para que DNS1 y
# DNS2 queden sincronizados automaticamente, sin pasos manuales de copiado.
# ===========================================================================
info "PASO 5: Configurando clave TSIG para transferencia segura con DNS2..."
TSIG_KEYFILE="/etc/bind/keys/tsig-ns.key"
cat > "$TSIG_KEYFILE" << EOF
key "${TSIG_KEY_NAME}" {
    algorithm hmac-sha256;
    secret "${TSIG_SECRET}";
};
EOF
chmod 640 "$TSIG_KEYFILE"
chown root:bind "$TSIG_KEYFILE"
log "Clave TSIG configurada en ${TSIG_KEYFILE} (compartida con DNS2)."

# ===========================================================================
# PASO 6: Zona directa "empresa.local"
# ===========================================================================
info "PASO 6: Creando zona directa ${DOMAIN}..."
SERIAL=$(date +%Y%m%d01)
cat > "$ZONE_FILE" << EOF
\$TTL 3600
@   IN  SOA ns1.${DOMAIN}. admin.${DOMAIN}. (
        ${SERIAL} ; serial: YYYYMMDDnn
        86400      ; refresh (1 dia)
        7200       ; retry (2 horas)
        604800     ; expire (1 semana)
        3600       ; minimum (1 hora)
)

; Servidores autoritativos
    IN  NS  ns1.${DOMAIN}.
    IN  NS  ns2.${DOMAIN}.

; Servidor web y controlador de dominio
web-server   IN  A     192.168.10.10
web-server   IN  AAAA  fd00:10::10
dc-empresa   IN  A     192.168.10.20
dc-empresa   IN  AAAA  fd00:10::20

; Servidores DHCP
dhcpv4-server   IN  A     192.168.10.30
dhcpv4-server   IN  AAAA  fd00:10::30
dhcpv6-server   IN  A     192.168.10.40
dhcpv6-server   IN  AAAA  fd00:10::40

; Servidores DNS
ns1   IN  A     192.168.10.50
ns1   IN  AAAA  fd00:10::50
ns2   IN  A     192.168.10.60
ns2   IN  AAAA  fd00:10::60

; Servidor de correo
smtp   IN  A     192.168.10.70
smtp   IN  AAAA  fd00:10::70

; Servidor NTP
ntp   IN  A     192.168.10.80
ntp   IN  AAAA  fd00:10::80

; VLAN gestion
siem      IN  A  192.168.30.10
siem      IN  AAAA  fd00:30::10
kali      IN  A  192.168.30.20
kali      IN  AAAA  fd00:30::20
pfsense   IN  A  192.168.30.30
pfsense   IN  AAAA  fd00:30::30

; Registros de correo y politicas de envio
${DOMAIN}.   IN  MX   10 smtp.${DOMAIN}.
${DOMAIN}.   IN  TXT  "v=spf1 mx -all"
EOF

# ===========================================================================
# PASO 7: Zona inversa IPv4 (10.168.192.in-addr.arpa)
# ===========================================================================
info "PASO 7: Creando zona inversa IPv4 (192.168.10.0/24)..."
cat > "$REV4_ZONE_FILE" << EOF
\$TTL 3600
@ IN SOA ns1.${DOMAIN}. admin.${DOMAIN}. (
    ${SERIAL} ; serial
    86400
    7200
    604800
    3600
)
    IN NS ns1.${DOMAIN}.
    IN NS ns2.${DOMAIN}.

10 IN PTR web-server.${DOMAIN}.
20 IN PTR dc-empresa.${DOMAIN}.
30 IN PTR dhcpv4-server.${DOMAIN}.
40 IN PTR dhcpv6-server.${DOMAIN}.
50 IN PTR ns1.${DOMAIN}.
60 IN PTR ns2.${DOMAIN}.
70 IN PTR smtp.${DOMAIN}.
80 IN PTR ntp.${DOMAIN}.
EOF

# ===========================================================================
# PASO 8: Zona inversa IPv6 (fd00:10::/64 -> 0.0.0.0.0.0.0.0.0.1.0.0.0.0.d.f.ip6.arpa)
# ===========================================================================
info "PASO 8: Creando zona inversa IPv6 (fd00:10::/64)..."
cat > "$REV6_ZONE_FILE" << EOF
\$TTL 3600
@ IN SOA ns1.${DOMAIN}. admin.${DOMAIN}. (
    ${SERIAL} ; serial
    86400
    7200
    604800
    3600
)
    IN NS ns1.${DOMAIN}.
    IN NS ns2.${DOMAIN}.

; Los nombres de host son relativos al origen de la zona
; (0.0.0.0.0.0.0.0.0.1.0.0.0.0.d.f.ip6.arpa, definido en named.conf.local),
; es decir, cada linea representa los 16 nibbles del identificador de host
; para las direcciones fd00:10::10, ::20, ::30 ... ::80.
0.1.0.0.0.0.0.0.0.0.0.0.0.0.0.0 IN PTR web-server.${DOMAIN}.
0.2.0.0.0.0.0.0.0.0.0.0.0.0.0.0 IN PTR dc-empresa.${DOMAIN}.
0.3.0.0.0.0.0.0.0.0.0.0.0.0.0.0 IN PTR dhcpv4-server.${DOMAIN}.
0.4.0.0.0.0.0.0.0.0.0.0.0.0.0.0 IN PTR dhcpv6-server.${DOMAIN}.
0.5.0.0.0.0.0.0.0.0.0.0.0.0.0.0 IN PTR ns1.${DOMAIN}.
0.6.0.0.0.0.0.0.0.0.0.0.0.0.0.0 IN PTR ns2.${DOMAIN}.
0.7.0.0.0.0.0.0.0.0.0.0.0.0.0.0 IN PTR smtp.${DOMAIN}.
0.8.0.0.0.0.0.0.0.0.0.0.0.0.0.0 IN PTR ntp.${DOMAIN}.
EOF
warn "Nota: los registros PTR IPv6 corresponden a fd00:10::10, ::20 ... ::80; verifica con 'dig -x' tras el aprovisionamiento."

chown -R bind:bind /etc/bind/zones

# ===========================================================================
# PASO 9: named.conf.local y named.conf.options
# ===========================================================================
info "PASO 9: Configurando named.conf.local y named.conf.options..."
cat > /etc/bind/named.conf.local << EOF
// Clave TSIG compartida con el servidor secundario (DNS2)
include "/etc/bind/keys/tsig-ns.key";

// Zona directa principal del dominio
zone "${DOMAIN}" {
    type master;
    file "${ZONE_FILE}";
    allow-transfer { key "${TSIG_KEY_NAME}"; ${DNS2_IP}; ${DNS2_IP6}; };
    also-notify { ${DNS2_IP}; ${DNS2_IP6}; };
};

// Zona inversa IPv4
zone "10.168.192.in-addr.arpa" {
    type master;
    file "${REV4_ZONE_FILE}";
    allow-transfer { key "${TSIG_KEY_NAME}"; ${DNS2_IP}; ${DNS2_IP6}; };
    also-notify { ${DNS2_IP}; ${DNS2_IP6}; };
};

// Zona inversa IPv6
zone "0.0.0.0.0.0.0.0.0.1.0.0.0.0.d.f.ip6.arpa" {
    type master;
    file "${REV6_ZONE_FILE}";
    allow-transfer { key "${TSIG_KEY_NAME}"; ${DNS2_IP}; ${DNS2_IP6}; };
    also-notify { ${DNS2_IP}; ${DNS2_IP6}; };
};
EOF

cat > /etc/bind/named.conf.options << EOF
acl "trusted-hosts" {
    localhost;
    localnets;
    192.168.10.0/24;
    192.168.20.0/24;
    192.168.30.0/24;
    fd00:10::/64;
    fd00:20::/64;
    fd00:30::/64;
};

options {
    directory "/var/cache/bind";

    recursion yes;
    allow-recursion { trusted-hosts; };

    dnssec-validation auto;

    listen-on port 53 { 127.0.0.1; ${SRV_IP}; };
    listen-on-v6 port 53 { ::1; ${SRV_IP6}; };

    forwarders { 8.8.8.8; 8.8.4.4; };

    allow-query { trusted-hosts; };

    auth-nxdomain no;
};
EOF

named-checkconf && log "Sintaxis de named.conf validada." || warn "named.conf presenta advertencias de sintaxis."
named-checkzone "${DOMAIN}" "$ZONE_FILE" || warn "Zona directa presenta advertencias."
named-checkzone "10.168.192.in-addr.arpa" "$REV4_ZONE_FILE" || warn "Zona inversa IPv4 presenta advertencias."

systemctl daemon-reload
systemctl enable named
systemctl restart named
sleep 2
systemctl is-active --quiet named && log "Servicio BIND9 (named) activo." || warn "named no esta activo. Revisar: journalctl -u named"

# ===========================================================================
# PASO 10: Firewall UFW
# ===========================================================================
info "PASO 10: Configurando firewall UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment 'SSH - Acceso de gestion'
ufw allow 53/tcp   comment 'DNS TCP (transferencias de zona)'
ufw allow 53/udp   comment 'DNS UDP (consultas)'
ufw allow out to "${SIEM_IP}" port 1514 proto tcp comment 'Wazuh logs'
ufw allow out to "${SIEM_IP}" port 1515 proto tcp comment 'Wazuh registro'
ufw --force enable
log "Firewall UFW configurado."
ufw status verbose

# ===========================================================================
# PASO 11: Agente Wazuh
# ===========================================================================
info "PASO 11: Instalando agente Wazuh (manager: ${WAZUH_MANAGER})..."
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
    WAZUH_AGENT_NAME="dns1-server" \
    apt-get install -y -qq wazuh-agent
    log "Paquete wazuh-agent instalado."

    OSSEC_CONF="/var/ossec/etc/ossec.conf"
    if [[ -f "$OSSEC_CONF" ]]; then
        grep -q "<address>MANAGER_IP</address>" "$OSSEC_CONF" && \
            sed -i "s|<address>MANAGER_IP</address>|<address>${WAZUH_MANAGER}</address>|g" "$OSSEC_CONF"
        if ! grep -q "named/security" "$OSSEC_CONF"; then
            sed -i 's|</ossec_config>|  <localfile>\n    <log_format>syslog</log_format>\n    <location>/var/log/syslog</location>\n  </localfile>\n\n</ossec_config>|' "$OSSEC_CONF"
            log "Monitoreo de logs de BIND9 agregado a ossec.conf."
        fi
    fi
    systemctl daemon-reload
    systemctl enable wazuh-agent
    systemctl start wazuh-agent
    sleep 3
    systemctl is-active --quiet wazuh-agent && log "Servicio wazuh-agent activo." || warn "wazuh-agent no esta activo."
fi

# ===========================================================================
# PASO 12: Zona horaria
# ===========================================================================
info "PASO 12: Configurando sincronizacion de tiempo..."
timedatectl set-timezone "America/Bogota"
timedatectl set-ntp true
log "Zona horaria: America/Bogota (UTC-5)."

# ===========================================================================
# PASO 13: /etc/hosts
# ===========================================================================
info "PASO 13: Actualizando /etc/hosts..."
declare -A HOSTS=(
    ["192.168.10.10"]="web-server web-server.${DOMAIN}"
    ["192.168.10.20"]="dc-empresa dc-empresa.${DOMAIN}"
    ["192.168.10.30"]="dhcpv4-server dhcpv4-server.${DOMAIN}"
    ["192.168.10.40"]="dhcpv6-server dhcpv6-server.${DOMAIN}"
    ["192.168.10.50"]="dns1-server dns1-server.${DOMAIN}"
    ["192.168.10.60"]="dns2-server dns2-server.${DOMAIN}"
    ["192.168.10.70"]="smtp-server smtp-server.${DOMAIN}"
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
echo -e "${CYAN} RESUMEN FINAL - Servidor DNS1 (Maestro)${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e " ${GREEN}Servicio BIND9 (named):${NC}"
systemctl is-active named && echo "   Estado: ACTIVO" || echo "   Estado: INACTIVO"
echo "   Zona directa    : ${DOMAIN} -> ${ZONE_FILE}"
echo "   Zona inversa v4 : 10.168.192.in-addr.arpa -> ${REV4_ZONE_FILE}"
echo "   Zona inversa v6 : fd00:10::/64 -> ${REV6_ZONE_FILE}"
echo "   Transferencias  : autenticadas con TSIG (${TSIG_KEYFILE}) hacia DNS2 (${DNS2_IP})"
echo ""
echo -e " ${YELLOW}Comandos utiles:${NC}"
echo "   dig @${SRV_IP} web-server.${DOMAIN}"
echo "   dig @${SRV_IP} AAAA web-server.${DOMAIN}"
echo "   rndc notify ${DOMAIN}"
echo ""
echo -e " ${GREEN}Red:${NC}"
echo "   IPv4 : ${SRV_IP}/${SRV_MASK}   Gateway: ${VM_GATEWAY}"
echo "   IPv6 : ${SRV_IP6}/${SRV_PREFIX6}   Gateway: ${VM_GATEWAY6}"
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN} APROVISIONAMIENTO COMPLETADO - dns1-server listo${NC}"
echo -e "${CYAN}============================================================${NC}"
