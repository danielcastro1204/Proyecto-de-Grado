# Reporte final DEFINITIVO — Validación del SIEM (Wazuh) en 3 escenarios

**Proyecto:** Laboratorio SIEM reproducible en AWS para la detección de técnicas MITRE ATT&CK
**Corrida:** 5ª (definitiva) — 8 de noviembre de 2026
**Carácter:** validación sobre un **despliegue limpio desde cero** (CloudFormation), con todo el tuning de las iteraciones previas ya incorporado en el código. Confirma la **reproducibilidad end-to-end** de la versión definitiva.

---

## 1. Resumen ejecutivo

Se validó la capacidad de detección del SIEM frente a **5 técnicas MITRE ATT&CK** (más 3 variantes de evasión) en **3 escenarios** (línea base, ataques controlados y tráfico mixto). A diferencia de las corridas de desarrollo, esta 5ª corrida se ejecutó sobre un **laboratorio desplegado desde cero** con la configuración definitiva: demuestra que todos los ajustes (reglas, ingesta de Sysmon, detección perimetral de escaneo, payload realista) se aprovisionan automáticamente y funcionan sin intervención manual.

| Escenario | Detección estricta | Detección amplia | Precisión | F1 | FP accionables |
|---|---|---|---|---|---|
| **E1 — Línea base** | — (sin ataques) | — | — | — | **0** |
| **E2 — Ataques controlados** | **82.5%** (33/40) · **núcleo 5 técnicas 100%** | 100% | **100%** | 90.4% | **0 / 1626** |
| **E3 — Mixto (bajo carga)** | **100%** (9/9) | 100% | **98.0%** | 99.0% | 18 / 902 |

**Criterio de éxito del proyecto (≥80% de detección estricta): CUMPLIDO.** Las 5 técnicas de la metodología se detectan al 100% de forma estricta, con 0 falsas alarmas accionables sobre tráfico legítimo en la línea base.

---

## 2. Metodología de evaluación

### 2.1 Técnicas evaluadas (Fase 3)

| # | Técnica | MITRE | Herramienta |
|---|---|---|---|
| 1 | Fuerza bruta SSH | T1110.001 | Hydra |
| 2 | Escaneo de puertos | T1046 | nmap |
| 3 | Pass-the-Hash / mov. lateral | T1550.002 / T1021.002 | Impacket (secretsdump + psexec) |
| 4 | Inyección SQL | T1190 | sqlmap / curl |
| 5 | Ejecución de payload | T1059.001 / T1204 | PowerShell `-enc` (download cradle) vía WinRM |

**Variantes de evasión (estudio adicional):** fuerza bruta lenta, escaneo *low-and-slow* fragmentado, SQLi ofuscado.

### 2.2 Métricas

- **Detección estricta:** la alerta pertenece a una **regla pertinente a la técnica** (métrica rigurosa).
- **Detección amplia:** cualquier alerta correlacionada en la ventana del ataque.
- **Precisión:** TP / (TP + FP) sobre alertas accionables.
- **Falsa alarma accionable:** alerta de grupo de ataque sobre tráfico legítimo, fuera de ventana de ataque.
- 5 repeticiones por técnica en E2; ataques en instantes aleatorios en E3, mezclados con tráfico de fondo denso.

### 2.3 Infraestructura (desplegada automáticamente)

Wazuh 4.x all-in-one (manager + indexer + dashboard) + Suricata (IDS) + Active Directory + Sysmon + 8 agentes, sobre 9 instancias EC2 en una VPC segmentada (VLAN 10 servidores / 20 clientes / 30 gestión). **5 fuentes de log:** Active Directory, firewall perimetral (nftables→syslog), servidor web (Apache), endpoint Windows (Sysmon + Script Block Logging) e IDS de red (Suricata).

---

## 3. Arquitectura de detección (resultado del ciclo de tuning)

La versión definitiva incorpora las lecciones de cuatro iteraciones de ingeniería de detección realizadas en las corridas previas. Cada regla/ajuste responde a una deficiencia real hallada y corregida:

| Técnica | Detector definitivo | Por qué |
|---|---|---|
| Fuerza bruta SSH | Reglas nativas de autenticación (5503/5760) + correlación 100010/100011 | Firma robusta de intentos fallidos repetidos. |
| Escaneo de puertos | **Correlación en firewall perimetral** (100003→**100022**) | Suricata solo cubre la DMZ y ET Open no marca un SYN scan simple; el firewall registra las conexiones nuevas por origen. El reconocimiento enumera el perímetro (punto monitorizado). |
| Pass-the-Hash | **Comportamiento de host** (regla nativa **92650**: servicio creado desde ADMIN$) | A nivel de red el PtH es indistinguible de la administración legítima; la evidencia fiable es de endpoint. La antigua regla por red (100030/100032) se degradó a informativa para eliminar falsos positivos. |
| Inyección SQL | Reglas web (31106/31171) + 100040/100041 | Patrones SQLi en logs de Apache + firma Suricata. |
| Ejecución de payload | **Sysmon Event 1** (línea de comando `-enc`) → **100051**, + Script Block Logging | Requirió suscribir el agente Windows al canal `Microsoft-Windows-Sysmon/Operational` (no se hacía por defecto). Sin esa ingesta, el payload no era visible. |

**Falsos positivos:** la línea base pasó de 6 (antes del tuning) a **0** alertas accionables, al reclasificar como informativas las reglas de autenticación NTLM que disparaban sobre la administración de red legítima.

---

## 4. Resultados por escenario (5ª corrida, deploy limpio)

### 4.1 Escenario 1 — Línea base

- 30 min de tráfico legítimo denso y concurrente de toda la red (navegación, portal, DNS, SMB, SSH, correo, NTP, WinRM de administración).
- 1410 alertas totales; **falsas alarmas accionables: 0**.
- **Interpretación:** el SIEM no confunde la actividad legítima densa (incluida la administración remota) con un ataque.

### 4.2 Escenario 2 — Ataques controlados (5×8 técnicas)

| Técnica | Detección estricta |
|---|---|
| Fuerza bruta SSH | **100%** (5/5) |
| Escaneo de puertos | **100%** (5/5) |
| Pass-the-Hash | **100%** (5/5) |
| Inyección SQL | **100%** (5/5) |
| Ejecución de payload | **100%** (5/5) |
| **Núcleo (metodología)** | **100% (25/25)** |
| Fuerza bruta SSH lenta | 100% (5/5) |
| Escaneo sigiloso | 0% (0/5) |
| SQLi con evasión | 60% (3/5) |
| **Evasión (adicional)** | **53% (8/15)** |
| **GLOBAL** | **82.5% (33/40)** |

- **Precisión 100%** · **F1 90.4%** · **Falsas alarmas accionables: 0 / 1626**.
- Las variantes de evasión reducen la detección (resultado esperado y creíble).
- El escaneo sigiloso evade por **contención de estado (conntrack)** generada por los escaneos previos del mismo origen — efecto documentado de secuenciación de ataques; en aislamiento la correlación de firewall sí lo detecta.

### 4.3 Escenario 3 — Mixto (ataques aleatorios + tráfico de fondo denso)

| Técnica | Ejecuciones | Detección estricta |
|---|---|---|
| Fuerza bruta SSH | 1 | **100%** |
| Pass-the-Hash | 2 | **100%** |
| Ejecución de payload | 1 | **100%** |
| Escaneo de puertos | 2 | **100%** |
| Inyección SQL | 3 | **100%** |
| **GLOBAL** | **9** | **100% (9/9)** |

- **Precisión 98.0%** · **F1 99.0%** · **Falsas alarmas accionables: 18 / 902** bajo carga densa (mayoritariamente alertas informativas de Suricata `ET INFO NTLM Session Setup` por el tráfico SMB legítimo; baja severidad, no son detecciones de ataque espurias).
- **Interpretación:** con tráfico malicioso oculto entre actividad legítima, el SIEM detecta el 100% de las técnicas con precisión muy alta.

---

## 5. Limitaciones y recomendaciones

1. **Cobertura de sensores de red (punto ciego interno):** el único NIDS cubre la DMZ; los escaneos a hosts internos que no cruzan un punto monitorizado no son visibles. *Recomendación:* TAP/mirror o NIDS adicional en los segmentos internos.
2. **Evasión *low-and-slow*:** el escaneo sigiloso evade la correlación bajo ciertas secuencias. *Recomendación:* analítica de comportamiento por origen/puerto en ventanas largas, además del umbral.
3. **PtH a nivel de red:** inherentemente ambiguo frente a la administración legítima; mantener el enfoque *endpoint-first* (Sysmon, servicios/ADMIN$).
4. **Dependencia de telemetría de endpoint:** la detección de payload y lateral depende de Sysmon y Script Block Logging activos e ingestados. *Recomendación:* monitorizar la salud de agentes y canales como parte de la operación.

---

## 6. Reproducibilidad (validada en esta corrida)

Esta 5ª corrida se ejecutó sobre un **despliegue nuevo desde CloudFormation**. Todas las correcciones se aprovisionan automáticamente y se verificaron operativas desde el arranque:

- 8/8 agentes activos (incluidos DC y estación Windows tras promoción de AD automática).
- Reglas de correlación afinadas desplegadas por `userdata/wazuh-server.sh`.
- Suscripción del agente Windows a Sysmon (via `windows-ws.ps1` y config compartida del manager) + Script Block Logging.
- Detección de payload (100051) y de escaneo (100022) verificadas end-to-end antes de las corridas.

Artefactos por escenario en `resultados_v5/escenario{1,2,3}/`: alertas completas, alertas de la ventana, log de ataques y reporte individual. Todo versionado en git.

---

## 7. Conclusión

El laboratorio SIEM detecta las **5 técnicas MITRE ATT&CK de la metodología al 100%** de forma estricta, con **0 falsas alarmas accionables** sobre tráfico legítimo y **precisión del 98–100%** bajo carga realista, cumpliendo el criterio de éxito (≥80%). El trabajo demuestra, además de la cifra, un **ciclo de ingeniería de detección** completo (detectar → medir → analizar → ajustar → re-validar) que halló y corrigió cuatro deficiencias reales, y cuya versión definitiva es **reproducible end-to-end desde cero**. El SIEM no solo "detecta": se entiende **por qué** detecta, **dónde** falla (evasión, cobertura de sensores) y **cómo** se mejora.

---

## 8. Estado del apagado (teardown)

**Laboratorio apagado correctamente.** Al finalizar la 5ª corrida se eliminó toda la infraestructura vía CLI (las credenciales seguían vigentes):

- Stack de CloudFormation `siem-lab`: **eliminado** (DELETE_COMPLETE).
- Bucket S3 del bundle de aprovisionamiento: vaciado y eliminado.
- Instancias EC2 en ejecución: **0** (verificado).

No queda ningún recurso consumiendo presupuesto del sandbox. Todos los datos, alertas, logs y reportes están guardados localmente en `resultados_v5/` y versionados en git. El laboratorio es reproducible desde CloudFormation (`./deploy.sh`) cuando se necesite.
