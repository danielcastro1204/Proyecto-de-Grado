# Reporte Escenario 1 — Linea base de trafico normal

- Ventana analizada: **2026-11-07T21:13:40Z** a **2026-11-07T21:48:20Z** (35 min)
- Total de alertas generadas: **1264** (todas se consideran **falsos positivos**, al no existir actividad maliciosa)
- Tasa de falsos positivos: **2187.7 alertas/hora**
- De esas, con el grupo 'attack' (las mismas reglas que detectan ataques reales): **31**

## Alertas por nivel de severidad

| Nivel | Cantidad |
|---|---|
| 12 | 31 |
| 14 | 31 |
| 3 | 1159 |
| 4 | 39 |
| 5 | 4 |

## Top reglas disparadas (posibles ajustes de tuning recomendados)

| Regla ID | Descripcion | Cantidad |
|---|---|---|
| 5501 | PAM: Login session opened. | 282 |
| 5502 | PAM: Login session closed. | 240 |
| 60137 | Windows User Logoff | 237 |
| 5715 | sshd: authentication success. | 108 |
| 60106 | Windows Logon Success | 93 |
| 67027 | A process was created. | 73 |
| 67028 | Special privileges assigned to new logon. | 64 |
| 60107 | Failed attempt to perform a privileged operation | 38 |
| 100032 | Pass-the-Hash probable: logon NTLM tipo 3 desde el segmento no confiable (10.0.30.0/24) (T1550.002) | 31 |
| 100099 | Multiples familias de ataque detectadas en ventana de 10 min (correlacion escenario mixto) | 31 |
| 86601 | Suricata: Alert - ET INFO NTLM Session Setup Request - Auth | 30 |
| 100030 | Logon de red NTLM tipo 3 (informativo; linea base de autenticacion) | 30 |
| 60104 | Windows audit failure event | 4 |
| 591 | Log file rotated. | 2 |
| 5403 | First time user executed sudo. | 1 |
