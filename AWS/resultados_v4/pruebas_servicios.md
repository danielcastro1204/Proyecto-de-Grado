# Pruebas exhaustivas de servicios — verificación pre-escenarios (corrida con tuning)

**Fecha:** 7 de noviembre de 2026
**Objetivo:** verificar que todos los servicios de la red funcionan y que el TUNING de reglas cargó correctamente, antes de ejecutar los 3 escenarios post-tuning.

## Resultado global: ✅ TODOS LOS SERVICIOS OPERATIVOS + TUNING VERIFICADO (7/7 agentes)

| # | Componente / Servicio | Prueba | Resultado |
|---|---|---|---|
| a | web-server — Apache | `systemctl` + HTTP 200 en `/` y `/index.php?id=1` | ✅ OK |
| a | web-server — Suricata (IDS) | activo; `eve.json` creciendo (3.7 MB) | ✅ OK |
| a | web-server — Samba | `smbd` activo | ✅ OK |
| b | dns1 — BIND9 | `dig @localhost google.com` resuelve | ✅ OK |
| c | ntp — chrony | servicio activo | ✅ OK |
| d | firewall — nftables + rsyslog | ambos activos; logs FW-NEW-CONN/FW-SYN reenviados al SIEM | ✅ OK |
| e | atacante — toolkit | evil-winrm, impacket (psexec/secretsdump), hydra, nmap, sqlmap, sshpass, dig, swaks | ✅ OK |
| f | linux-01 — SSH | `PasswordAuthentication yes`; auditd activo | ✅ OK |
| g | Agentes Wazuh | **7/7 Active** (web, fw-gateway, ntp, dns1, linux-01, dc-empresa, win-ws-01) | ✅ OK |
| h | DC / Active Directory | dominio resuelve; `secretsdump` captura el hash NTLM | ✅ OK |
| i | estación Windows — WinRM | `evil-winrm` conecta (`empresa\administrator`) | ✅ OK |
| i | estación Windows — Sysmon | servicio activo y registrando | ✅ OK |

## Verificación del TUNING (nuevo en esta corrida)

| Elemento del tuning | Verificación | Resultado |
|---|---|---|
| Regla 100032 (PtH consciente de segmentación) | presente en `local_rules.xml` del manager | ✅ cargada |
| Regla 100030 degradada a informativa (fuera de `attack`) | nivel 3, grupo `ntlm_logon` | ✅ aplicada |
| Regla 100099 (correlación) umbral 2→3 | presente | ✅ aplicada |
| Detección de escaneo sigiloso (100003 + 100022) | **prueba end-to-end:** 8 conexiones del atacante al perímetro → **regla 100022 disparó** | ✅ FUNCIONA |
| Decoder netfilter nativo | extrae `srcip`/`dstport` de los logs del firewall (regla base 4100) | ✅ OK |

## Nota de infraestructura

- El DC y la estación Windows **se auto-aprovisionaron sin intervención manual por RDP** — el fix de la tarea de reanudación con reintento periódico (commit anterior) funcionó.
- El SIEM (`t3.medium`, 4 GB) requirió un reinicio puntual durante la instalación de Wazuh porque el indexer saturó la memoria y dejó el SSH sin responder (el dashboard en 443 seguía OK); tras reiniciar, todo quedó estable.

## Conclusión

La red está completamente operativa, la cadena de ataque funciona end-to-end, y **el tuning cargó y se verificó** (incluida la nueva detección de escaneo sigiloso). El laboratorio está listo para ejecutar los 3 escenarios post-tuning y comparar contra los resultados pre-tuning.
