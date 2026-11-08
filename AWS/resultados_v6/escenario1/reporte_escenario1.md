# Reporte Escenario 1 — Linea base de trafico normal

- Ventana analizada: **2026-11-08T17:16:28Z** a **2026-11-08T17:47:44Z** (31 min)
- Total de alertas generadas: **1631** (todas se consideran **falsos positivos**, al no existir actividad maliciosa)
- Tasa de falsos positivos: **3129.9 alertas/hora**
- De esas, con el grupo 'attack' (las mismas reglas que detectan ataques reales): **0**

## Alertas por nivel de severidad

| Nivel | Cantidad |
|---|---|
| 12 | 1 |
| 15 | 3 |
| 3 | 1337 |
| 4 | 164 |
| 5 | 112 |
| 6 | 14 |

## Top reglas disparadas (posibles ajustes de tuning recomendados)

| Regla ID | Descripcion | Cantidad |
|---|---|---|
| 5501 | PAM: Login session opened. | 294 |
| 5502 | PAM: Login session closed. | 252 |
| 60137 | Windows User Logoff | 227 |
| 60106 | Windows Logon Success | 147 |
| 5715 | sshd: authentication success. | 121 |
| 92110 | Detected WinRM activity from 10.0.30.20 to 10.0.20.30 | 117 |
| 60104 | Windows audit failure event | 112 |
| 100030 | Logon de red NTLM tipo 3 (informativo; linea base de autenticacion) | 81 |
| 67027 | A process was created. | 64 |
| 67028 | Special privileges assigned to new logon. | 61 |
| 92106 | Windows System process activity over SMB port - Possible suspicious access to Windows admin shares | 35 |
| 86601 | Suricata: Alert - ET INFO NTLM Session Setup Request - Auth | 33 |
| 60107 | Failed attempt to perform a privileged operation | 32 |
| 92004 | Powershell process spawned Windows command shell instance | 15 |
| 92032 | Suspicious Windows cmd shell execution | 15 |
| 92103 | LDAP activity from Powershell process, possible remote system discovery | 14 |
| 92213 | Executable file dropped in folder commonly used by malware | 3 |
| 92105 | Possible suspicious access to Windows admin shares | 3 |
| 5402 | Successful sudo to ROOT executed. | 2 |
| 591 | Log file rotated. | 2 |
| 92900 | Lsass process was accessed by C:\\ProgramData\\Microsoft\\Windows Defender\\Platform\\4.18.26100.4-0\\MsMpEng.exe with read permissions, possible credential dump | 1 |
