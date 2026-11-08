# Escenario 3 (5a corrida, deploy limpio): mixto

- Total de ataques ejecutados: **9**
- **Tasa de deteccion ESTRICTA (regla pertinente a la tecnica): 100.0%** (9/9) — metrica rigurosa, criterio del proyecto: >= 80%
- Tasa de deteccion amplia (cualquier alerta correlacionada): 100.0% (9/9)
- Falsos negativos (ataques no detectados, criterio estricto): **0**
- Tiempo medio de deteccion (MTTD estricto): 15.8 s (ver limitaciones: ventanas solapadas)
- Alertas accionables en la ventana: **902** (correctas: 884, falsas alarmas accionables: **18**)
- Precision (alertas accionables correctas): 98.0%
- F1-score: 99.0%

## Desglose por tipo de ataque (deteccion amplia vs estricta)

| ataque            |   intentos |   det_amplia |   det_estricta |   %_amplia |   %_estricta |
|:------------------|-----------:|-------------:|---------------:|-----------:|-------------:|
| bruteforce_ssh    |          1 |            1 |              1 |        100 |          100 |
| pass_the_hash     |          2 |            2 |              2 |        100 |          100 |
| payload_execution |          1 |            1 |              1 |        100 |          100 |
| portscan          |          2 |            2 |              2 |        100 |          100 |
| sql_injection     |          3 |            3 |              3 |        100 |          100 |

## Detalle por intento de ataque

| ataque            | mitre_id   | objetivo   | inicio               | det_amplia   | det_estricta   | reglas_pertinentes             | reglas_disparadas                                                                            |
|:------------------|:-----------|:-----------|:---------------------|:-------------|:---------------|:-------------------------------|:---------------------------------------------------------------------------------------------|
| sql_injection     | T1190      | 10.0.10.10 | 2026-11-08T15:01:39Z | Si           | Si             | 100040,100041,31106,31171      | 100030,100040,100041,100099,31106,31171,5501,5502,5715,60106,60107,60137,67028,92110         |
| bruteforce_ssh    | T1110.001  | 10.0.20.40 | 2026-11-08T15:04:35Z | Si           | Si             | 5503,5760                      | 100030,5501,5502,5503,5715,5760,60106,60107,60137,67027,67028,86601,92004,92032,92106,92110  |
| sql_injection     | T1190      | 10.0.10.10 | 2026-11-08T15:09:20Z | Si           | Si             | 100040,100041,31106,31171      | 100030,100040,100041,100099,31106,31171,5501,5502,5715,60106,60137,67027,67028,92106,92110   |
| pass_the_hash     | T1550.002  | 10.0.10.20 | 2026-11-08T15:12:47Z | Si           | Si             | 92004,92032,92110,92650        | 100030,5501,5502,5715,60106,60137,67027,67028,92004,92032,92110,92650                        |
| portscan          | T1046      | 10.0.10.20 | 2026-11-08T15:15:43Z | Si           | Si             | 100022,86601                   | 100022,100030,5501,5502,5715,60106,60107,60137,67027,67028,86601,92103,92106,92110           |
| sql_injection     | T1190      | 10.0.10.10 | 2026-11-08T15:23:46Z | Si           | Si             | 100040,100041,31106,31171      | 100040,100041,100099,31106,31171,5501,5502,5715,60106,60137,67027                            |
| payload_execution | T1059.001  | 10.0.20.30 | 2026-11-08T15:26:34Z | Si           | Si             | 100051,92052,92105,92110,92213 | 100030,100051,5501,5502,5715,591,60106,60107,60137,67027,67028,91837,92052,92105,92110,92213 |
| pass_the_hash     | T1550.002  | 10.0.10.20 | 2026-11-08T15:29:51Z | Si           | Si             | 92650                          | 100030,5501,5502,5715,60106,60107,60137,67028,86601,92650                                    |
| portscan          | T1046      | 10.0.10.20 | 2026-11-08T15:33:35Z | Si           | Si             | 100022,86601                   | 100022,5501,5502,5715,60106,60107,60137,86601,92106                                          |

## Matriz de correlacion (tecnica -> reglas Wazuh PERTINENTES disparadas)

| ataque            | reglas_pertinentes                 |
|:------------------|:-----------------------------------|
| bruteforce_ssh    | 5503, 5760                         |
| pass_the_hash     | 92004, 92032, 92110, 92650         |
| payload_execution | 100051, 92052, 92105, 92110, 92213 |
| portscan          | 100022, 86601                      |
| sql_injection     | 100040, 100041, 31106, 31171       |
