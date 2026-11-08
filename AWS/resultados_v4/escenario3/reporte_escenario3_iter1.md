# Escenario 3 post-tuning (mixto: trafico + ataques)

- Total de ataques ejecutados: **8**
- **Tasa de deteccion ESTRICTA (regla pertinente a la tecnica): 62.5%** (5/8) — metrica rigurosa, criterio del proyecto: >= 80%
- Tasa de deteccion amplia (cualquier alerta correlacionada): 100.0% (8/8)
- Falsos negativos (ataques no detectados, criterio estricto): **3**
- Tiempo medio de deteccion (MTTD estricto): 52.0 s (ver limitaciones: ventanas solapadas)
- Alertas accionables en la ventana: **340** (correctas: 322, falsas alarmas accionables: **18**)
- Precision (alertas accionables correctas): 94.7%
- F1-score: 75.3%

## Desglose por tipo de ataque (deteccion amplia vs estricta)

| ataque            |   intentos |   det_amplia |   det_estricta |   %_amplia |   %_estricta |
|:------------------|-----------:|-------------:|---------------:|-----------:|-------------:|
| pass_the_hash     |          2 |            2 |              2 |        100 |          100 |
| payload_execution |          3 |            3 |              0 |        100 |            0 |
| portscan          |          2 |            2 |              2 |        100 |          100 |
| sql_injection     |          1 |            1 |              1 |        100 |          100 |

## Detalle por intento de ataque

| ataque            | mitre_id   | objetivo   | inicio               | det_amplia   | det_estricta   | reglas_pertinentes        | reglas_disparadas                                                       |
|:------------------|:-----------|:-----------|:---------------------|:-------------|:---------------|:--------------------------|:------------------------------------------------------------------------|
| payload_execution | T1059.001  | 10.0.20.30 | 2026-11-08T00:52:31Z | Si           | No             | -                         | 100030,5501,5502,5715,60106,60107,60137,67027,67028                     |
| pass_the_hash     | T1550.002  | 10.0.10.20 | 2026-11-08T00:57:11Z | Si           | Si             | 92650                     | 100030,5501,5502,5715,60106,60107,60137,67027,67028,92650               |
| portscan          | T1046      | 10.0.10.20 | 2026-11-08T01:02:14Z | Si           | Si             | 100022,86601              | 100022,100030,5501,5502,5715,591,60106,60107,60137,67027,67028,86601    |
| portscan          | T1046      | 10.0.10.20 | 2026-11-08T01:12:09Z | Si           | Si             | 100022,86601              | 100022,5501,5502,5715,60106,60107,60137,67028,86601                     |
| pass_the_hash     | T1550.002  | 10.0.10.20 | 2026-11-08T01:19:53Z | Si           | Si             | 92650                     | 100030,5501,5502,5715,60106,60107,60137,67028,92650                     |
| payload_execution | T1059.001  | 10.0.20.30 | 2026-11-08T01:22:05Z | Si           | No             | -                         | 100030,5501,5502,5715,591,60106,60107,60137,67027,67028,86601           |
| sql_injection     | T1190      | 10.0.10.10 | 2026-11-08T01:26:42Z | Si           | Si             | 100040,100041,31106,31171 | 100040,100041,100099,31106,31171,5501,5502,5715,60106,60107,60137,67027 |
| payload_execution | T1059.001  | 10.0.20.30 | 2026-11-08T01:30:09Z | Si           | No             | -                         | 100030,5501,5502,5715,60106,60137,67027,67028                           |

## Matriz de correlacion (tecnica -> reglas Wazuh PERTINENTES disparadas)

| ataque            | reglas_pertinentes           |
|:------------------|:-----------------------------|
| pass_the_hash     | 92650                        |
| payload_execution | -                            |
| portscan          | 100022, 86601                |
| sql_injection     | 100040, 100041, 31106, 31171 |
