# Guía Técnica Reproducible — Plataforma SIEM Open Source para Monitoreo de Eventos de Seguridad

Esta guía consolida el trabajo de las 4 fases descritas en la metodología del proyecto de grado
y sirve como punto de entrada único al repositorio. Está pensada para publicarse en el README
principal de un repositorio de GitHub, junto con todos los scripts y configuraciones.

## 0. Estado de este repositorio y qué falta por hacer en el laboratorio real

Todo lo incluido aquí (Vagrantfiles, scripts de aprovisionamiento, reglas de Wazuh, scripts de
ataque, scripts de escenarios y de evaluación) es **código e infraestructura como código**, listo
para ejecutarse. Lo que **no** puede generarse de antemano —porque depende de hardware físico,
del router Cisco, de licencias de Windows Server y de la ejecución real de los ataques— son:

- Los **resultados numéricos reales** (tasa de detección, falsos positivos, matrices de
  correlación). El script `Evaluacion/calcular_metricas.py` los calcula automáticamente, pero
  necesita que el laboratorio se levante y que los tres escenarios se ejecuten de verdad.
- Las **capturas de pantalla del dashboard de Kibana/Wazuh** que se piden en la sección de
  verificación (deben tomarse tras el despliegue real).
- El **cronograma con fechas ya cumplidas** y las conclusiones del capítulo de resultados, que
  deben redactarse a partir de los datos obtenidos.

Se recomienda ejecutar `./run_lab.sh` como punto de entrada; el menú guía por las 4 fases.

## 1. Requisitos de hardware y software

| Componente | Mínimo recomendado |
|---|---|
| Hipervisor | VirtualBox 7.x + Vagrant 2.4.x |
| Host Gestión (Wazuh + Kali) | 8 GB RAM, 4 vCPU, 100 GB disco |
| Host Servidores (DC + Web) | 8 GB RAM, 4 vCPU, 120 GB disco (Windows Server necesita ISO/licencia propia) |
| Host Workstations | 8 GB RAM, 4 vCPU, 80 GB disco |
| Red física | Switch administrable + router con soporte VLAN (o 3 VLANs simuladas con `private_network` de Vagrant si no hay hardware de red) |

> Nota: si no se cuenta con el router Cisco físico ni con switches administrables, sustituir las
> interfaces `public_network` de los Vagrantfile por `private_network` con las mismas subredes
> (192.168.10.0/24, .20.0/24, .30.0/24) para levantar todo en una sola máquina con VirtualBox.

## 2. Estructura del repositorio

```
Desarrollo/
├── Gestion/            # VM Wazuh (SIEM) + VM Kali (atacante)
│   └── scripts/ataques/  # Los 5 scripts de ataque + orquestador
├── Servidores/         # VM Controlador de Dominio (AD) + VM Web (Apache/NGINX)
├── Workstations/       # VMs Windows 10/11 y Linux con Sysmon/agente Wazuh
├── Suricata/           # Instalación e integración del IDS con Wazuh
├── Deteccion/          # Reglas y decodificadores personalizados de Wazuh (local_rules.xml)
├── Escenarios/         # Escenario 1 (línea base), 2 (ataques) y 3 (mixto)
├── Evaluacion/         # Scripts Python: recolección de alertas y cálculo de métricas
├── run_lab.sh          # Menú maestro de automatización
└── TOPOLOGIA_Y_INTERNET.md
```

## 3. Fase 1 — Diseño de la arquitectura de red simulada

1. Revisar `TOPOLOGIA_Y_INTERNET.md` para las IPs y VLANs asignadas.
2. Levantar en orden (ver también `Servidores/README.md`):
   ```bash
   cd Gestion      && vagrant up      # Wazuh (.30.10) y Kali (.30.20)
   cd ../Servidores && vagrant up      # DC (.10.20) y Web (.10.10)
   cd ../Workstations && vagrant up    # Win10 (.20.30/.31), Linux (.20.40/.41)
   ```
3. Verificar conectividad entre segmentos (`ping` a cada gateway) antes de continuar.

## 4. Fase 2 — Implementación de la plataforma SIEM

1. **Servidor Wazuh**: aprovisionado automáticamente por `Gestion/scripts/wazuh-server.sh`
   (stack completo: manager + indexer + dashboard, además de recepción de syslog en UDP/514).
2. **Agentes**: instalados por los scripts de cada VM (`web-server.sh`, `windows-dc.ps1`,
   `windows-ws.ps1`, `linux-desktop.sh`), que registran el agente contra `192.168.30.10`.
3. **Sysmon en Windows**: configurado con `Workstations/scripts/sysmonconfig.xml`.
4. **Suricata (IDS)**: ejecutar en el servidor web o en un sensor dedicado:
   ```bash
   sudo ./Suricata/install_suricata.sh eth1
   ```
5. **Reglas de correlación personalizadas**: copiar `Deteccion/local_rules.xml` a
   `/var/ossec/etc/rules/` en el Wazuh Manager y reiniciar:
   ```bash
   systemctl restart wazuh-manager
   ```
   Estas reglas cubren los 5 tipos de eventos objetivo, cada una mapeada a su técnica MITRE
   ATT&CK (T1110.001, T1046, T1550.002/T1021.002, T1190, T1059.001/T1204.002).

## 5. Fase 3 — Generación de escenarios de prueba

| Escenario | Script | Qué mide |
|---|---|---|
| 1. Línea base | `Escenarios/escenario1_linea_base.sh <min>` | Falsos positivos en ausencia de ataques |
| 2. Ataques controlados | `Gestion/scripts/ataques/run_all_attacks.sh` | Tasa de detección por tipo de ataque (5 repeticiones c/u) |
| 3. Mixto | `Escenarios/escenario3_mixto.sh <min>` | Detección con tráfico legítimo de fondo |

Cada ataque individual también puede ejecutarse por separado desde
`Gestion/scripts/ataques/attackN_*.sh`; todos registran automáticamente
`ataque, mitre_id, ip_objetivo, inicio, fin` en `log_ataques.csv` para la correlación posterior.

## 6. Fase 4 — Recolección de datos y evaluación de resultados

```bash
# En el Wazuh Manager (o copiando alerts.json localmente):
python3 Evaluacion/recolectar_alertas.py \
  --inicio 2026-06-01T14:00:00Z --fin 2026-06-01T18:00:00Z \
  --out alertas_ventana.json

python3 Evaluacion/calcular_metricas.py \
  --ataques Gestion/scripts/ataques/log_ataques.csv \
  --alertas alertas_ventana.json \
  --out reporte_metricas.md
```

`reporte_metricas.md` incluye: tasa de detección global, conteo de posibles falsos positivos,
detalle por intento de ataque y la matriz de correlación (tipo de ataque → reglas Wazuh
disparadas). El criterio de éxito del proyecto es una tasa de detección **≥ 80 %**.

## 7. Verificación y solución de problemas comunes

- **Un agente no aparece "Active" en el dashboard**: revisar `/var/ossec/logs/ossec.log` en el
  agente y confirmar que el puerto 1514/TCP hacia `192.168.30.10` no está bloqueado.
- **Suricata no genera alertas**: confirmar que la interfaz configurada en
  `/etc/suricata/suricata.yaml` es la que realmente ve el tráfico (modo promiscuo/SPAN o bridge).
- **Sin acceso a internet en las VMs**: ver la sección de diagnóstico en
  `TOPOLOGIA_Y_INTERNET.md` (dependencia del router Cisco / gateway).
- **`calcular_metricas.py` no encuentra coincidencias**: verificar que los relojes de todas las
  VMs estén sincronizados por NTP (supuesto metodológico del proyecto); un desfase horario
  invalida la correlación por ventana de tiempo.

## 8. Publicación

Se recomienda publicar este directorio completo (excluyendo carpetas `.vagrant/` y credenciales)
en un repositorio público de GitHub, con este archivo como `README.md` principal, tal como
especifica la sección "Formato y disponibilidad" del documento del proyecto.
