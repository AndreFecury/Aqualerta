-- Teste de ar_contexto() (20261126a). PostGIS LOCAL:
--   ... 20261125b, 20261125c, ../migrations/20261126a_ar_contexto.sql, este arquivo
-- Valores inventados para exercitar as regras.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
-- Manaus (…01) tem sensor; Parintins (…02) não.
INSERT INTO public.openaq_sensores (region_id, sensor_id, location_id, nome, provedor, distancia_m, parametro) VALUES
 ('a0000000-0000-0000-0000-000000000001', 7001, 900001, 'Manaus', 'AirGradient', 2026.9, 2),
 ('a0000000-0000-0000-0000-000000000001', 7004, 900001, 'Manaus', 'AirGradient', 2026.9, 98);
CREATE TEMP VIEW c AS SELECT * FROM public.ar_contexto('2026-11-22 12:30+00');
-- Pares de hora em hora: f(dia) dá modelo e sensor do dia.
CREATE OR REPLACE FUNCTION pg_temp.pares(de timestamptz, ate timestamptz, modelo numeric, sensor numeric) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensores_n, valido)
    SELECT 'a0000000-0000-0000-0000-000000000001', h, 'continua', modelo, sensor, 1, true
      FROM generate_series(de, ate - interval '1 hour', interval '1 hour') h
    ON CONFLICT (region_id, hora, origem) DO UPDATE SET modelo_pm25 = excluded.modelo_pm25, sensor_pm25 = excluded.sensor_pm25, valido = true
$$;

-- 1. Sensor sem histórico: tem sensor, mas sem comparação.
SELECT pg_temp.confere((SELECT tem_sensor AND sensor_situacao = 'parado' AND NOT comparacao_ok AND sensor_nivel IS NULL
                           AND sensor_nome = 'Manaus' AND sensor_distancia_km = 2
                          FROM c WHERE region_id = 'a0000000-0000-0000-0000-000000000001'), 'sensor sem dados: parado, sem comparação');
SELECT pg_temp.confere((SELECT NOT tem_sensor AND sensor_situacao IS NULL FROM c WHERE region_id = 'a0000000-0000-0000-0000-000000000002'),
                       'região sem sensor');

-- 2. Só 13 dias: ainda sem comparação. Dia local de Manaus = 04:00 UTC a 04:00 UTC.
SELECT pg_temp.pares('2026-11-09 04:00+00', '2026-11-22 04:00+00', 20, 20);
SELECT pg_temp.pares('2026-11-22 04:00+00', '2026-11-22 12:00+00', 20, 20);
SELECT pg_temp.confere((SELECT sensor_situacao = 'saudável' AND NOT comparacao_ok FROM c WHERE region_id = 'a0000000-0000-0000-0000-000000000001'),
                       '13 dias válidos (+ hoje parcial): saudável, mas sem comparação');
-- 3. 14 dias: comparação liberada.
SELECT pg_temp.pares('2026-11-08 04:00+00', '2026-11-09 04:00+00', 20, 20);
SELECT pg_temp.confere((SELECT comparacao_ok AND sensor_pm25_24h = 20 AND sensor_nivel = 'N2' AND modelo_nivel = 'N2'
                           AND NOT sensor_pior AND NOT modelo_pior AND NOT cautela_boa
                          FROM c WHERE region_id = 'a0000000-0000-0000-0000-000000000001'),
                       '14 dias: comparação aparece; sem divergência; sem cautela (há sensor)');

-- 4. Sensor pior em 2 níveis nas últimas 24 h: frase desde o 1º dia.
SELECT pg_temp.pares('2026-11-21 12:00+00', '2026-11-22 12:00+00', 20, 80);
SELECT pg_temp.confere((SELECT sensor_nivel = 'N4' AND modelo_nivel = 'N2' AND sensor_pior AND NOT modelo_pior
                          FROM c WHERE region_id = 'a0000000-0000-0000-0000-000000000001'), 'sensor N4 × modelo N2: sensor pior já no 1º dia');
SELECT pg_temp.pares('2026-11-21 12:00+00', '2026-11-22 12:00+00', 20, 55);
SELECT pg_temp.confere((SELECT NOT sensor_pior FROM c WHERE region_id = 'a0000000-0000-0000-0000-000000000001'), '1 nível de diferença: nada');

-- 5. Modelo pior: exige 21 dias válidos na janela e 5 dias seguidos.
SELECT pg_temp.pares('2026-10-31 04:00+00', '2026-11-08 04:00+00', 20, 20);   -- agora 22 dias + hoje
SELECT pg_temp.pares('2026-11-18 04:00+00', '2026-11-22 12:00+00', 60, 20);   -- 4 dias e hoje: modelo pior (N3 × N2, 40 µg/m³)
SELECT pg_temp.confere((SELECT NOT modelo_pior FROM c WHERE region_id = 'a0000000-0000-0000-0000-000000000001'),
                       'hoje (parcial) não conta como dia: 4 dias seguidos, nada');
SELECT pg_temp.pares('2026-11-17 04:00+00', '2026-11-18 04:00+00', 60, 20);
SELECT pg_temp.confere((SELECT modelo_pior AND NOT sensor_pior FROM c WHERE region_id = 'a0000000-0000-0000-0000-000000000001'),
                       '5 dias seguidos com o modelo pior: frase aparece');
-- Um buraco no meio quebra a sequência.
DELETE FROM public.ar_validacao_horas WHERE hora >= '2026-11-19 04:00+00' AND hora < '2026-11-20 04:00+00';
SELECT pg_temp.confere((SELECT NOT modelo_pior FROM c WHERE region_id = 'a0000000-0000-0000-0000-000000000001'),
                       'dia faltando quebra a sequência');

-- 6. Cautela no lugar de "Boa": época (novembro) na região sem sensor.
SELECT pg_temp.confere((SELECT cautela_boa AND epoca_fumaca FROM c WHERE region_id = 'a0000000-0000-0000-0000-000000000002'),
                       'novembro: Parintins (só modelo) com cautela');
SELECT pg_temp.confere((SELECT NOT cautela_boa AND NOT epoca_fumaca FROM public.ar_contexto('2026-12-15 12:00+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000002'), 'dezembro sem focos: sem cautela');
-- Muitos focos polares a 300 km de Parintins (-2.6306, -56.7519) em dezembro: cautela.
INSERT INTO public.ar_focos (lat, lon, satelite, detectado_em)
SELECT -2.6306 + (i / 30) * 0.03, -56.7519 + (i % 30) * 0.03, 'NOAA-20', '2026-12-14 17:00+00'
  FROM generate_series(0, 599) i;
INSERT INTO public.ar_focos (lat, lon, satelite, detectado_em)            -- GOES repetido não conta
SELECT -2.6306, -56.7519 + i * 0.01, 'GOES-19', '2026-12-14 17:00+00' FROM generate_series(0, 99) i;
INSERT INTO public.ar_focos (lat, lon, satelite, detectado_em)            -- mesmo foco em 2 satélites conta 1
VALUES (-2.6306, -56.7519, 'NOAA-21', '2026-12-14 17:10+00');
SELECT pg_temp.confere((SELECT focos_300km_72h = 600 AND cautela_boa FROM public.ar_contexto('2026-12-15 12:00+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000002'), '600 focos polares distintos: cautela fora da época');
SELECT pg_temp.confere((SELECT focos_300km_72h = 0 FROM public.ar_contexto('2026-12-18 12:00+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000002'), 'focos com mais de 72 h não contam');

-- 7. Aviso por sensor: Manaus cadastrada, desligada.
SELECT pg_temp.confere((SELECT bool_and(NOT aviso_sensor_ligado) FROM c), 'aviso por sensor desligado em todas');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.ar_aviso_sensor WHERE region_id = 'a0000000-0000-0000-0000-000000000001' AND NOT ligado),
                       'Manaus cadastrada como candidata, desligada');

-- 8. Permissões.
SELECT pg_temp.confere(has_function_privilege('anon', 'public.ar_contexto(timestamptz)', 'EXECUTE')
                   AND NOT has_table_privilege('anon', 'public.ar_aviso_sensor', 'SELECT')
                   AND NOT has_function_privilege('anon', 'public.ar_focos_regionais(timestamptz)', 'EXECUTE'),
                       'app lê só o contexto pronto');
ROLLBACK;
