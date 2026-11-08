# Escenario 3 FINAL post-tuning (mixto)

- Total de ataques ejecutados: **10**
- **Tasa de deteccion ESTRICTA (regla pertinente a la tecnica): 100.0%** (10/10) — metrica rigurosa, criterio del proyecto: >= 80%
- Tasa de deteccion amplia (cualquier alerta correlacionada): 100.0% (10/10)
- Falsos negativos (ataques no detectados, criterio estricto): **0**
- Tiempo medio de deteccion (MTTD estricto): 4.2 s (ver limitaciones: ventanas solapadas)
- Alertas accionables en la ventana: **895** (correctas: 871, falsas alarmas accionables: **24**)
- Precision (alertas accionables correctas): 97.3%
- F1-score: 98.6%

## Desglose por tipo de ataque (deteccion amplia vs estricta)

| ataque            |   intentos |   det_amplia |   det_estricta |   %_amplia |   %_estricta |
|:------------------|-----------:|-------------:|---------------:|-----------:|-------------:|
| pass_the_hash     |          3 |            3 |              3 |        100 |          100 |
| payload_execution |          3 |            3 |              3 |        100 |          100 |
| portscan          |          1 |            1 |              1 |        100 |          100 |
| sql_injection     |          3 |            3 |              3 |        100 |          100 |

## Detalle por intento de ataque

| ataque            | mitre_id   | objetivo   | inicio               | det_amplia   | det_estricta   | reglas_pertinentes              | reglas_disparadas                                                                                              |
|:------------------|:-----------|:-----------|:---------------------|:-------------|:---------------|:--------------------------------|:---------------------------------------------------------------------------------------------------------------|
| pass_the_hash     | T1550.002  | 10.0.10.20 | 2026-11-08T03:18:20Z | Si           | Si             | 92004,92032,92106,92110,92650   | 100030,5501,5502,5715,60106,60107,60137,67027,67028,92004,92032,92106,92110,92650                              |
| sql_injection     | T1190      | 10.0.10.10 | 2026-11-08T03:21:51Z | Si           | Si             | 100040,100041,31106,31171,86601 | 100030,100040,100041,100099,31106,31171,5501,5502,5715,60106,60137,67027,67028,86601,92004,92032,92106,92110   |
| sql_injection     | T1190      | 10.0.10.10 | 2026-11-08T03:26:13Z | Si           | Si             | 100040,100041,31106,31171       | 100030,100040,100041,100099,31106,31171,5501,5502,5715,60106,60137,67027,67028,92103,92106,92110               |
| portscan          | T1046      | 10.0.10.20 | 2026-11-08T03:29:19Z | Si           | Si             | 100022,86601                    | 100022,100030,5501,5502,5715,591,60106,60107,60137,67027,67028,86601,92004,92032,92052,92103,92105,92106,92110 |
| payload_execution | T1059.001  | 10.0.20.30 | 2026-11-08T03:36:59Z | Si           | Si             | 100051,92105,92110,92213        | 100030,100051,5501,5502,5715,60106,60137,67027,67028,91837,92105,92110,92213                                   |
| sql_injection     | T1190      | 10.0.10.10 | 2026-11-08T03:39:57Z | Si           | Si             | 100040,100041,31106,31171       | 100040,100041,100099,31106,31171,5501,5502,5715,60106,60107,60137,92106                                        |
| payload_execution | T1059.001  | 10.0.20.30 | 2026-11-08T03:41:30Z | Si           | Si             | 92105,92110,92213               | 100030,100099,5501,5502,5715,60106,60107,60137,67027,67028,86601,91837,92105,92110,92213                       |
| payload_execution | T1059.001  | 10.0.20.30 | 2026-11-08T03:45:10Z | Si           | Si             | 100051,92105,92110,92213        | 100030,100051,5501,5502,5715,60106,60137,67027,67028,91837,92105,92110,92213                                   |
| pass_the_hash     | T1550.002  | 10.0.10.20 | 2026-11-08T03:48:13Z | Si           | Si             | 92650                           | 100030,5501,5502,5715,60106,60107,60137,67028,92650                                                            |
| pass_the_hash     | T1550.002  | 10.0.10.20 | 2026-11-08T03:52:23Z | Si           | Si             | 92650                           | 100030,5501,5502,5715,591,60106,60107,60137,67028,92650                                                        |

## Matriz de correlacion (tecnica -> reglas Wazuh PERTINENTES disparadas)

| ataque            | reglas_pertinentes                  |
|:------------------|:------------------------------------|
| pass_the_hash     | 92004, 92032, 92106, 92110, 92650   |
| payload_execution | 100051, 92105, 92110, 92213         |
| portscan          | 100022, 86601                       |
| sql_injection     | 100040, 100041, 31106, 31171, 86601 |
