#!/bin/sh
# =============================================================================
# pfsense-config.sh — Configuración de pfSense para VLAN 30 (Gestión)
# Integrante A - Firewall perimetral / fuente de logs para el SIEM
#
# Qué hace:
#   1. Asigna IP estática 192.168.30.30/24 a la interfaz LAN
#   2. Configura envío de logs por syslog al servidor Wazuh (192.168.30.10:514)
#
# IMPORTANTE: este script asume que ya completaste la asignación de
# interfaces (WAN/LAN) en el menú de consola de pfSense la primera vez
# que arrancó (ver guía PASO A PASO). Sin eso, "lan" puede no existir
# todavía y el script no tendrá efecto.
# =============================================================================

WAZUH_IP="192.168.30.10"
WAZUH_PORT="514"
LAN_IP="192.168.30.30"
LAN_SUBNET="24"

echo "[PFSENSE-CONF] Configurando IP estática ${LAN_IP}/${LAN_SUBNET} en LAN..."
echo "[PFSENSE-CONF] Configurando envío de syslog a ${WAZUH_IP}:${WAZUH_PORT}..."

# En vez de depender de pfSsh.php (cuya carpeta de "playback scripts"
# varía según versión/empaquetado), ejecutamos el PHP directamente con
# el intérprete de pfSense — así es como corren internamente sus
# propios scripts (rc.reload_all, cron, etc.), así que es más confiable.
PHP_BIN=$(command -v php || find / -xdev -type f -name "php" 2>/dev/null | head -n1)

if [ -z "${PHP_BIN}" ]; then
  echo "[PFSENSE-CONF] No se encontró el intérprete de PHP."
  echo "[PFSENSE-CONF] Aplica la configuración manualmente desde la web GUI (ver GUIA-pfsense.md)."
else
  echo "[PFSENSE-CONF] Intérprete PHP detectado: ${PHP_BIN}"

  cat > /tmp/wazuhconfig.php <<'PHPEOF'
<?php
require_once("config.inc");
require_once("functions.inc");
require_once("interfaces.inc");

global $config;

// --- IP estática en LAN ---
$config['interfaces']['lan']['ipaddr'] = '192.168.30.30';
$config['interfaces']['lan']['subnet'] = '24';
$config['interfaces']['lan']['enable'] = true;

// --- Envío de logs (syslog) al SIEM Wazuh ---
$config['syslog']['remoteserver']  = '192.168.30.10:514';
$config['syslog']['sourceip']      = 'lan';
$config['syslog']['filter']        = true;
$config['syslog']['everything']    = true;

write_config("Configurado automáticamente: IP LAN + syslog remoto a Wazuh");
interface_configure("lan", $config['interfaces']['lan']);
system_syslogd_start();

echo "Configuración aplicada correctamente.\n";
PHPEOF

  "${PHP_BIN}" -f /tmp/wazuhconfig.php
  rm -f /tmp/wazuhconfig.php
fi

echo "[PFSENSE-CONF] Listo. Verifica en la web GUI (https://192.168.30.30):"
echo "  - Interfaces > LAN            -> IP 192.168.30.30/24"
echo "  - Status > System Logs > Settings -> Remote server 192.168.30.10:514"