-- Séries do replay de 25-26/11/2026 (Manaus e Porto Velho). Incluído por
-- ar_replay_test.sql e ar_replay_snapshot.sql (\ir). PostGIS LOCAL, depois de
-- stub_base e das migrações (ver o cabeçalho de ar_replay_test.sql).
--
-- ATENÇÃO: isto é uma RECONSTRUÇÃO, não dado real. Ids, nomes de sensor e
-- valores são INVENTADOS a partir dos fatos informados pelo dono:
--   * Manaus: um único sensor, última leitura às 10:00 UTC de 26/11 (a hora das
--     05h às 06h locais), com 180 a 188 µg/m³ nas últimas horas, e o modelo CAMS
--     perto de 45 µg/m³ de manhã, com o cartão "moderada / IQAr 80" às 19:42;
--   * Porto Velho: sensor em dia nos dois instantes (valores de exemplo, de nível
--     "moderada"; o modelo de exemplo diz "boa", como no relatório retro).
-- Para trocar pela série real, ver docs/ar-replay-26-11.md ("Como trocar pelos
-- dados reais"). Sem ids de sensor reais, sem dado pessoal.

INSERT INTO public.monitored_regions (id, name, state_code, monitoring_config) VALUES
 ('a0000000-0000-0000-0000-000000000003', 'Porto Velho', 'RO',
  '{"origem":"ibge","municipio_ibge":"1100205","estacao_ana":"15400000","estacao_lat":-8.7612,"estacao_lng":-63.9004}')
ON CONFLICT DO NOTHING;

INSERT INTO public.openaq_sensores (region_id, sensor_id, location_id, nome, provedor, distancia_m, parametro) VALUES
 ('a0000000-0000-0000-0000-000000000001', 7001, 900001, 'Sensor fictício de Manaus', 'AirGradient', 2026.9, 2),
 ('a0000000-0000-0000-0000-000000000003', 7101, 900101, 'Sensor fictício de Porto Velho', 'AirGradient', 1800, 2);

-- Modelo CAMS (ar_horas): Manaus sobe de 30 para ~50 (IQAr 80 às 19:42); Porto Velho
-- fica em 15 µg/m³ ("boa").
INSERT INTO public.ar_horas (region_id, hora, pm2_5, ingerido_em)
SELECT 'a0000000-0000-0000-0000-000000000001', h,
       CASE WHEN h < '2026-11-26 00:00+00' THEN 30
            WHEN h < '2026-11-26 12:00+00' THEN 40 + 0.75 * extract(hour FROM h)
            ELSE 55 END,
       '2026-11-26 10:05+00'
  FROM generate_series('2026-11-25 00:00+00'::timestamptz, '2026-11-27 12:00+00', interval '1 hour') h;
INSERT INTO public.ar_horas (region_id, hora, pm2_5, ingerido_em)
SELECT 'a0000000-0000-0000-0000-000000000003', h, 15, '2026-11-26 10:05+00'
  FROM generate_series('2026-11-25 00:00+00'::timestamptz, '2026-11-27 12:00+00', interval '1 hour') h;

-- Sensor de Manaus: 24 horas seguidas, de 25/11 10:00 UTC a 26/11 09:00 UTC (a última
-- hora é a das 05h às 06h locais). Depois disso, nada.
INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensores_n, valido)
SELECT 'a0000000-0000-0000-0000-000000000001',
       '2026-11-25 10:00+00'::timestamptz + (i - 1) * interval '1 hour', 'continua',
       (SELECT pm2_5 FROM public.ar_horas a
         WHERE a.region_id = 'a0000000-0000-0000-0000-000000000001'
           AND a.hora = '2026-11-25 10:00+00'::timestamptz + (i - 1) * interval '1 hour'),
       v, 1, true
  FROM unnest(ARRAY[18,20,22,25,24,22,20,24,30,38,46,55,64,75,
                    90,105,120,135,148,160,168,174,180,188]::numeric[]) WITH ORDINALITY t(v, i);

-- Sensor de Porto Velho: em dia até 26/11 22:00 UTC (valores de exemplo, 24 a 34).
INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensores_n, valido)
SELECT 'a0000000-0000-0000-0000-000000000003', h, 'continua', 15,
       24 + ((extract(epoch FROM h - '2026-11-25 10:00+00'::timestamptz)::int / 3600) * 7) % 11, 1, true
  FROM generate_series('2026-11-25 10:00+00'::timestamptz, '2026-11-26 22:00+00', interval '1 hour') h;
