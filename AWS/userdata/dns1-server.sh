#!/usr/bin/env bash
# =============================================================================
# dns1-server.sh (AWS) — DNS primario BIND9 | VLAN10 -> 10.0.10.50
# Migración de Servidores/scripts/dns1-server.sh (adaptado a 10.0.x.y).
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/_common.sh"
DOMAIN="${DOMAIN:-empresa.local}"
SELF_IP="${VM_IP:-10.0.10.50}"; DNS2_IP="10.0.10.60"

set_hostname "dns1-server"; set_timezone; escribir_hosts_lab
apt-get update -qq
apt-get install -y -qq bind9 bind9utils dnsutils

mkdir -p /etc/bind/zones
cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";
    recursion yes;
    allow-query { any; };
    forwarders { 169.254.169.253; };   # Resolver de la VPC (salida a Internet)
    dnssec-validation no;
    listen-on { any; };
    listen-on-v6 { any; };   # DUAL-STACK: servir DNS tambien por IPv6
};
EOF

cat > /etc/bind/named.conf.local <<EOF
zone "${DOMAIN}" {
    type master;
    file "/etc/bind/zones/db.${DOMAIN}";
    allow-transfer { ${DNS2_IP}; };
    also-notify { ${DNS2_IP}; };
};
zone "10.0.10.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.10.0.10";
    allow-transfer { ${DNS2_IP}; };
};
EOF

cat > /etc/bind/zones/db.${DOMAIN} <<EOF
\$TTL 604800
@   IN SOA dns1-server.${DOMAIN}. admin.${DOMAIN}. ( 3 604800 86400 2419200 604800 )
@       IN NS dns1-server.${DOMAIN}.
@       IN NS dns2-server.${DOMAIN}.
dns1-server IN A 10.0.10.50
dns2-server IN A 10.0.10.60
dc-empresa  IN A 10.0.10.20
web-server  IN A 10.0.10.10
smtp        IN A 10.0.10.70
ntp-server  IN A 10.0.10.80
EOF

cat > /etc/bind/zones/db.10.0.10 <<EOF
\$TTL 604800
@   IN SOA dns1-server.${DOMAIN}. admin.${DOMAIN}. ( 3 604800 86400 2419200 604800 )
@       IN NS dns1-server.${DOMAIN}.
10      IN PTR web-server.${DOMAIN}.
20      IN PTR dc-empresa.${DOMAIN}.
50      IN PTR dns1-server.${DOMAIN}.
60      IN PTR dns2-server.${DOMAIN}.
EOF

named-checkconf && named-checkzone "${DOMAIN}" /etc/bind/zones/db.${DOMAIN} || warn "Revisar zonas BIND."
systemctl enable named 2>/dev/null || systemctl enable bind9 2>/dev/null || true
systemctl restart named 2>/dev/null || systemctl restart bind9 2>/dev/null || true
instalar_agente_wazuh "dns1-server"
log "DNS1 (BIND9 maestro) listo en ${SELF_IP}."
