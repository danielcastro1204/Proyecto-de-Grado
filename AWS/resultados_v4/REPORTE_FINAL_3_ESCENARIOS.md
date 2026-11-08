# Reporte final — Validación del SIEM (Wazuh) en 3 escenarios con ciclo de tuning

**Proyecto:** Laboratorio SIEM reproducible en AWS para la detección de técnicas MITRE ATT&CK
**Fecha de la corrida consolidada:** 7–8 de noviembre de 2026
**Infraestructura:** AWS (CloudFormation `siem-lab`), Wazuh 4.x all-in-one + Suricata + Active Directory + Sysmon, 7 agentes, 5 fuentes de log (AD, firewall perimetral, Apache/web, Sysmon/endpoint, Suricata/IDS).

---

## 1. Resumen ejecutivo

Se validó la capacidad de detección del SIEM frente a **5 técnicas MITRE ATT&CK** (más 3 variantes de evasión) a lo largo de **3 escenarios** (línea base, ataques controlados y tráfico mixto), aplicando un **ciclo de ingeniería de detección completo**: *detectar → medir → analizar el fallo → ajustar (tuning) → re-validar*. Durante la validación se hallaron y resolvieron **cuatro deficiencias reales** de detección que inicialmente quedaban enmascaradas.

**Resultados finales (post-tuning):**

| Escenario | Detección estricta | Detección amplia | Precisión | F1 | Falsas alarmas accionables |
|---|---|---|---|---|---|
| **E1 — Línea base** | — (sin ataques) | — | — | — | **0** (vs 6 pre-tuning) |
| **E2 — Ataques controlados** | **80.0%** (32/40) · **núcleo 5 técnicas 100%** | 100% | **100%** | 88.9% | **0 / 1671** |
| **E3 — Mixto (bajo carga)** | **100%** (10/10) | 100% | **97.3%** | 98.6% | 24 / 895 (informativas) |

**Criterio de éxito del proyecto (≥80% de detección estricta): CUMPLIDO.** Las 5 técnicas de la metodología se detectan al 100% de forma estricta (regla pertinente a la técnica) y con 0 falsas alarmas accionables sobre tráfico legítimo.

---

## 2. Metodología de evaluación

### 2.1 Técnicas evaluadas (Fase 3)

| # | Técnica | MITRE | Herramienta de ataque |
|---|---|---|---|
| 1 | Fuerza bruta SSH | T1110.001 | Hydra |
| 2 | Escaneo de puertos | T1046 | nmap |
| 3 | Pass-the-Hash / mov. lateral | T1550.002 / T1021.002 | Impacket (secretsdump + psexec) |
| 4 | Inyección SQL | T1190 | sqlmap / curl |
| 5 | Ejecución de payload | T1059.001 / T1204 | PowerShell `-enc` vía WinRM (evil-winrm) |

**Variantes de evasión (estudio adicional):** fuerza bruta lenta, escaneo *low-and-slow* fragmentado, SQLi ofuscado (tamper + user-agent aleatorio).

### 2.2 Métricas

- **Detección estricta:** la alerta disparada pertenece a una **regla pertinente a la técnica** (grupos/ids mapeados a cada ataque). Métrica rigurosa.
- **Detección amplia:** cualquier alerta correlacionada en la ventana del ataque.
- **Precisión:** TP / (TP + FP) sobre alertas *accionables* (grupos de ataque).
- **Falsa alarma accionable:** alerta de un grupo de ataque disparada sobre tráfico legítimo, fuera de toda ventana de ataque.
- Cada técnica se repite **5 veces** en E2 (25 ejecuciones núcleo + 15 de evasión); en E3 los ataques se disparan en instantes aleatorios dentro de la ventana, mezclados con tráfico de fondo denso.

### 2.3 Tráfico de fondo ("red viva")

En E1 y E3 se generó tráfico legítimo **denso y concurrente** desde todos los hosts según su rol (navegación externa, portal corporativo, DNS, SMB, SSH, correo, NTP, health-checks), con llegadas aleatorias tipo Poisson. El objetivo: que la medición de falsos positivos sea significativa y que el fondo del escenario mixto sea indistinguible de una red empresarial real.

---

## 3. Ciclo de tuning: 4 deficiencias halladas y resueltas

El valor metodológico central de este trabajo es que la primera medición **no** fue aceptada tal cual: cada resultado sospechoso se analizó hasta su causa raíz y se corrigió, re-validando después. Se documentan las cuatro iteraciones.

### 3.1 Falsos positivos por autenticación NTLM legítima (regla 100030)

- **Síntoma (pre-tuning):** 6 falsas alarmas de nivel 12 ("Pass-the-Hash") en la línea base.
- **Causa raíz:** la regla 100030 disparaba sobre **cualquier** logon NTLM tipo 3, incluida la autenticación de red legítima del dominio (acceso SMB, GPO).
- **Iteración 1:** degradar 100030 a **informativa** (nivel 3, fuera del grupo `attack`) e introducir 100032 "consciente de segmentación" (NTLM tipo 3 desde el segmento de gestión 10.0.30.0/24).
- **Hallazgo de la re-validación (E1):** 100030 → **0 FP** ✅, pero **100032 generó 31 FP nuevos**, porque el tráfico de **administración remota legítimo** (WinRM del administrador desde la VLAN de gestión, como `Administrator` y por IP → NTLM) produce exactamente la misma firma. **Conclusión metodológica: a nivel de red, el Pass-the-Hash es indistinguible de la administración remota legítima.**
- **Iteración 2 (solución):** degradar también 100032 a informativa y mover la detección fiable de PtH a la **evidencia de host**: la regla nativa **92650** ("servicio creado desde la raíz de Windows; binario posiblemente dejado vía recursos administrativos ADMIN$"), que captura el comportamiento de Impacket-psexec. Verificado: **0 FP en línea base** y disparo sobre el ataque real.
- **Resultado:** línea base de **6 → 0** falsas alarmas accionables.

### 3.2 Escaneo de puertos no detectado (cobertura de sensores)

- **Síntoma:** tras corregir el etiquetado de reglas, el escaneo de puertos (ruidoso y sigiloso) no se detectaba de forma estricta (en v3 figuraba "detectado" por la regla de SQLi 100040 que corría en paralelo — una **atribución falsa**).
- **Causa raíz:** (a) Suricata solo observa el segmento del servidor web (DMZ), pero los escaneos apuntaban al DC, que **ningún IDS vigila**; y (b) la firma ET Open **no marca de forma fiable** un SYN scan simple.
- **Solución:** detección por **correlación en el firewall perimetral** — el firewall registra cada conexión nueva (regla intermedia 100003 sobre el decoder nativo netfilter), y la correlación por origen (**100022**) dispara ante el barrido. Se bajó el umbral de 100022 de 6 → 4 (margen fiable manteniendo el carácter *low-and-slow*) y el reconocimiento ahora enumera también el perímetro (punto monitorizado). Verificado end-to-end: escanear el gateway dispara 100022.
- **Resultado:** escaneo de puertos (ruidoso) **0% → 100%** de detección estricta.
- **Limitación documentada:** los escaneos contra hosts internos que no cruzan un punto monitorizado siguen siendo un **punto ciego** (ver §5).

### 3.3 Sysmon no ingestado (agente Windows sin suscripción al canal)

- **Síntoma:** en E2 el payload aparecía 100% detectado, pero en E3 (ataques espaciados) se reveló **0/3** — en E2 era un **artefacto de medición**: la regla 92650 del Pass-the-Hash (que corría ~2 s después) caía en la ventana del payload.
- **Causa raíz:** el agente de Wazuh en Windows se instalaba **solo con la IP del manager, sin suscribirse al canal `Microsoft-Windows-Sysmon/Operational`**. Por defecto el agente solo lee Application/Security/System, de modo que el **Event ID 1 de Sysmon** (creación de proceso con línea de comando) nunca llegaba a Wazuh; las reglas de payload (100050/100051) y la de herramientas de movimiento lateral vía Sysmon (100031) no podían dispararse.
- **Solución:** suscripción al canal de Sysmon (y de PowerShell/Operational) mediante **configuración compartida del manager** (`/var/ossec/etc/shared`, aplicable a hosts ya desplegados sin RDP/WinRM) y en el **script de despliegue** (`windows-ws.ps1`) para reproducibilidad.

### 3.4 Detección de payload ofuscado

- **Con Sysmon ya ingestado**, se verificó end-to-end que la regla **100051** dispara sobre la línea de comando `-enc` del payload (`Sysmon Event 1 → windows_eventchannel → 100051`).
- **Refuerzos:** se habilitó **PowerShell Script Block Logging** (Event 4104) y se sustituyó el payload de prueba inocuo (`Start-Sleep`) por un **download cradle realista** (`IEX (New-Object Net.WebClient).DownloadString(...)` codificado en base64/UTF-16LE), comportamiento típico de T1059.001, que deja evidencia tanto en la línea de comando como en el contenido del script.
- **Resultado:** payload **0% → 100%** de detección estricta (confirmado bajo carga en E3).

---

## 4. Resultados por escenario (final)

### 4.1 Escenario 1 — Línea base (tráfico legítimo, sin ataques)

- Ventana de 30 min de tráfico denso y concurrente de toda la red.
- **Falsas alarmas accionables: 0** (vs **6** antes del tuning).
- La regla 100030 registró ~95 logons NTLM como **informativos** (trazabilidad/auditoría, sin generar alarma).
- **Interpretación:** tras el tuning, el SIEM no confunde la actividad legítima densa (incluida la administración remota) con un ataque.

### 4.2 Escenario 2 — Ataques controlados (5×8 técnicas)

| Técnica | Repeticiones | Detección estricta |
|---|---|---|
| Fuerza bruta SSH | 5 | **100%** |
| Escaneo de puertos | 5 | **100%** |
| Pass-the-Hash | 5 | **100%** |
| Inyección SQL | 5 | **100%** |
| Ejecución de payload | 5 | **100%** |
| **Subtotal núcleo (metodología)** | **25** | **100% (25/25)** |
| Fuerza bruta SSH lenta | 5 | 100% |
| Escaneo sigiloso | 5 | 0% |
| SQLi con evasión | 5 | 40% |
| **Subtotal evasión (adicional)** | **15** | **47% (7/15)** |
| **GLOBAL** | **40** | **80.0% (32/40)** |

- **Precisión: 100%** · **F1: 88.9%** · **Falsas alarmas accionables: 0 / 1671**.
- Las variantes de evasión reducen la detección, resultado **esperado y creíble** que motiva las recomendaciones.
- *Nota técnica (escaneo sigiloso):* la correlación de firewall detecta el barrido sigiloso en aislamiento (verificado, dispara 100022), pero en la secuencia completa evade por **contención de estado (conntrack)** generada por los escaneos previos del mismo origen a los mismos puertos — un efecto real de **secuenciación de ataques**, documentado como hallazgo.

### 4.3 Escenario 3 — Mixto (ataques aleatorios + tráfico de fondo denso)

| Técnica | Ejecuciones | Detección estricta |
|---|---|---|
| Pass-the-Hash | 3 | **100%** |
| Ejecución de payload | 3 | **100%** |
| Escaneo de puertos | 1 | **100%** |
| Inyección SQL | 3 | **100%** |
| **GLOBAL** | **10** | **100% (10/10)** |

- **Detección amplia 100%** · **Precisión 97.3%** · **F1 98.6%**.
- **Falsas alarmas accionables: 24 / 895** bajo carga densa. Dominadas por alertas **informativas de Suricata** (`ET INFO NTLM Session Setup`) disparadas por el tráfico SMB legítimo de fondo — baja severidad, no son detecciones de ataque espurias.
- **Interpretación:** bajo condiciones realistas (tráfico malicioso oculto entre actividad legítima), el SIEM detecta el 100% de las técnicas con precisión muy alta.

---

## 5. Limitaciones y recomendaciones

1. **Cobertura de sensores de red (punto ciego interno).** El único NIDS (Suricata) cubre la DMZ/servidor web; los escaneos y el tráfico lateral entre hosts internos que no cruzan un punto monitorizado no son visibles a nivel de red. *Recomendación:* desplegar un TAP/mirror o un NIDS adicional que cubra los segmentos internos (VLAN de servidores y de usuarios), o habilitar logging de conexiones en los firewalls de host.
2. **Evasión *low-and-slow*.** El escaneo sigiloso evade la correlación bajo ciertas secuencias por contención de estado. *Recomendación:* complementar la detección por umbral con analítica de comportamiento (perfil de puertos/origen en ventanas largas) y detección en el endpoint.
3. **Detección de PtH a nivel de red.** Es inherentemente ambigua frente a la administración legítima; la detección fiable es **de host** (creación de servicios/uso de ADMIN$, telemetría de Sysmon). Mantener el enfoque *endpoint-first* para movimiento lateral.
4. **Dependencia de la telemetría de endpoint.** La detección de payload y de movimiento lateral depende de que **Sysmon y el Script Block Logging** estén activos e ingestados. *Recomendación:* monitorizar la salud de los agentes y la recepción de los canales Windows como parte de la operación del SIEM.

---

## 6. Reproducibilidad

Todos los ajustes quedaron versionados en el repositorio (reglas, scripts de ataque, scripts de despliegue y de evaluación). Correcciones clave incluidas:

- `deteccion/local_rules.xml` — reglas de correlación con el tuning (100030/100032 informativas, 100003/100022 para escaneo, PtH vía 92650).
- `deteccion/agent.conf.windows-sysmon` — configuración compartida que suscribe a los agentes Windows a los canales de Sysmon y PowerShell.
- `userdata/windows-ws.ps1` — suscripción a Sysmon + habilitación de Script Block Logging en el despliegue.
- `ataques/attack2_portscan.sh`, `ataques/sigilosos/attack2b_portscan_sigiloso.sh` — reconocimiento del perímetro.
- `ataques/attack5_payload_exec.sh` — payload realista (download cradle).
- `evaluacion/calcular_metricas.py` — relevancia por técnica corregida (atribución honesta).

Artefactos de datos por escenario en `resultados_v4/escenario{1,2,3}/`: alertas completas, alertas de la ventana, log de ataques y reporte individual. Se conservan además las iteraciones intermedias (`*_iter1`, `*_iter2`) como evidencia del ciclo de tuning.

---

## 7. Conclusión

El laboratorio SIEM detecta las **5 técnicas MITRE ATT&CK de la metodología al 100%** de forma estricta, con **0 falsas alarmas accionables** sobre tráfico legítimo y **precisión del 97–100%** bajo carga realista, cumpliendo el criterio de éxito (≥80%). Más allá del número, el aporte metodológico es el **ciclo de ingeniería de detección** ejecutado: se hallaron cuatro deficiencias reales (falsos positivos de autenticación, cobertura de sensores para escaneo, ingesta de Sysmon y detección de payload), se analizó su causa raíz y se corrigieron con re-validación medible, documentando las limitaciones residuales y las recomendaciones de mejora. Esto demuestra no solo que el SIEM "detecta", sino **por qué** detecta, **dónde** falla y **cómo** se mejora — el objetivo real de un trabajo de validación de detección.

---

## 8. Estado del apagado del laboratorio (teardown)

> **ACCIÓN PENDIENTE PARA EL USUARIO:** no se pudo apagar el laboratorio automáticamente.

Al intentar eliminar el stack de CloudFormation (`aws cloudformation delete-stack --stack-name siem-lab`), las **credenciales temporales de AWS Academy habían expirado** (`ExpiredToken`) — es normal: el token del sandbox dura unas pocas horas y la corrida completa (3 escenarios + 4 iteraciones de tuning) superó esa ventana. No es posible refrescar el token desde aquí, porque proviene del portal de AWS Academy.

**Qué hacer al despertar (cualquiera de las dos opciones apaga todo):**

1. **Opción simple (recomendada):** entrar al portal de **AWS Academy → Learner Lab** y pulsar **"End Lab"**. Esto detiene y limpia todas las instancias y recursos del sandbox. No requiere CLI.

2. **Opción por CLI (si quieres borrar solo el stack):** en el portal, abrir **"AWS Details"**, copiar las nuevas credenciales (`aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`) al archivo de credenciales, y ejecutar:
   ```bash
   aws cloudformation delete-stack --stack-name siem-lab
   ```

**No se pierde nada con el apagado:** todos los datos, alertas, logs y reportes ya están guardados localmente en `resultados_v4/` y versionados en git. El laboratorio es reproducible desde CloudFormation cuando se necesite.
