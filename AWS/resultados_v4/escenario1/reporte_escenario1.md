# Reporte Escenario 1 — Linea base de trafico normal

- Ventana analizada: **2026-11-07T21:55:48Z** a **2026-11-07T22:26:14Z** (30 min)
- Total de alertas generadas: **1235** (todas se consideran **falsos positivos**, al no existir actividad maliciosa)
- Tasa de falsos positivos: **2434.8 alertas/hora**
- De esas, con el grupo 'attack' (las mismas reglas que detectan ataques reales): **0**

## Alertas por nivel de severidad

| Nivel | Cantidad |
|---|---|
| 3 | 1197 |
| 4 | 34 |
| 5 | 4 |

## Top reglas disparadas (posibles ajustes de tuning recomendados)

| Regla ID | Descripcion | Cantidad |
|---|---|---|
| 5501 | PAM: Login session opened. | 285 |
| 5502 | PAM: Login session closed. | 244 |
| 60137 | Windows User Logoff | 223 |
| 5715 | sshd: authentication success. | 112 |
| 100030 | Logon de red NTLM tipo 3 (informativo; linea base de autenticacion) | 95 |
| 60106 | Windows Logon Success | 80 |
| 67027 | A process was created. | 69 |
| 67028 | Special privileges assigned to new logon. | 58 |
| 60107 | Failed attempt to perform a privileged operation | 34 |
| 86601 | Suricata: Alert - ET INFO NTLM Session Setup Request - Auth | 30 |
| 60104 | Windows audit failure event | 4 |
| 591 | Log file rotated. | 1 |
