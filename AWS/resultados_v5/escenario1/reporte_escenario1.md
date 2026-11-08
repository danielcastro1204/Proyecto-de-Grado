# Reporte Escenario 1 — Linea base de trafico normal

- Ventana analizada: **2026-11-08T13:26:11Z** a **2026-11-08T13:57:23Z** (31 min)
- Total de alertas generadas: **1410** (todas se consideran **falsos positivos**, al no existir actividad maliciosa)
- Tasa de falsos positivos: **2711.5 alertas/hora**
- De esas, con el grupo 'attack' (las mismas reglas que detectan ataques reales): **0**

## Alertas por nivel de severidad

| Nivel | Cantidad |
|---|---|
| 12 | 2 |
| 15 | 3 |
| 3 | 1194 |
| 4 | 174 |
| 5 | 15 |
| 6 | 20 |
| 8 | 2 |

## Top reglas disparadas (posibles ajustes de tuning recomendados)

| Regla ID | Descripcion | Cantidad |
|---|---|---|
| 5501 | PAM: Login session opened. | 246 |
| 60137 | Windows User Logoff | 233 |
| 5502 | PAM: Login session closed. | 229 |
| 92110 | Detected WinRM activity from 10.0.30.20 to 10.0.20.30 | 123 |
| 5715 | sshd: authentication success. | 98 |
| 100030 | Logon de red NTLM tipo 3 (informativo; linea base de autenticacion) | 93 |
| 60106 | Windows Logon Success | 86 |
| 67028 | Special privileges assigned to new logon. | 64 |
| 67027 | A process was created. | 61 |
| 92106 | Windows System process activity over SMB port - Possible suspicious access to Windows admin shares | 38 |
| 60107 | Failed attempt to perform a privileged operation | 36 |
| 86601 | Suricata: Alert - ET INFO NTLMv1 Session Setup Response - Challenge | 30 |
| 92103 | LDAP activity from Powershell process, possible remote system discovery | 20 |
| 92004 | Powershell process spawned Windows command shell instance | 11 |
| 92032 | Suspicious Windows cmd shell execution | 11 |
| 60147 | Security Enabled Local Group Changed | 6 |
| 60148 | Security Enabled Global Group Changed | 4 |
| 60104 | Windows audit failure event | 4 |
| 92213 | Executable file dropped in folder commonly used by malware | 3 |
| 92105 | Possible suspicious access to Windows admin shares | 3 |
| 60110 | User account changed | 2 |
| 591 | Log file rotated. | 2 |
| 5403 | First time user executed sudo. | 1 |
| 91815 | Powershell executing process discovery | 1 |
| 92052 | Windows command prompt started by an abnormal process | 1 |
