-- Teste da Fase 1a (20261125b_ar_validacao.sql). PostGIS LOCAL:
--   psql -f stub_base.sql -f ar_stubs.sql -f ar_validacao_stubs.sql
--        -f ../migrations/20261118_push_fcm.sql -f ../migrations/20261122_ar.sql
--        -f ../migrations/20261124_openaq.sql -f ../migrations/20261125b_ar_validacao.sql
--        -f ar_validacao_test.sql
-- Valores inventados para exercitar as regras (marcados como tal).
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

-- 1. Correção da EPA (conta à mão: 0,524*20 - 0,0862*80 + 5,75 = 9,334).
SELECT pg_temp.confere(public.ar_correcao_epa(20, 80) = 9.3, 'EPA: 20 µg/m³ a 80% -> 9,3');
SELECT pg_temp.confere(public.ar_correcao_epa(100, 80) = round(0.786 * 100 - 0.0862 * 80 + 5.75, 1), 'EPA: faixa 50-210');
SELECT pg_temp.confere(public.ar_correcao_epa(300, 50) = round(2.966 + 0.69 * 300 + 0.000884 * 300 * 300, 1), 'EPA: acima de 260');
SELECT pg_temp.confere(public.ar_correcao_epa(20, NULL) IS NULL AND public.ar_correcao_epa(1, 99) = 0,
                       'sem umidade: sem correção; nunca negativo');
-- Continuidade nas emendas das faixas.
SELECT pg_temp.confere(abs(public.ar_correcao_epa(29.99, 70) - public.ar_correcao_epa(30, 70)) < 0.2
                   AND abs(public.ar_correcao_epa(49.99, 70) - public.ar_correcao_epa(50, 70)) < 0.2
                   AND abs(public.ar_correcao_epa(209.99, 70) - public.ar_correcao_epa(210, 70)) < 0.5
                   AND abs(public.ar_correcao_epa(259.99, 70) - public.ar_correcao_epa(260, 70)) < 0.5,
                       'EPA contínua nas emendas 30, 50, 210, 260');

-- 2. Coleta de umidade: estação com MP2,5 e umidade.
INSERT INTO vault.decrypted_secrets VALUES ('openaq_key', 'k') ON CONFLICT (name) DO UPDATE SET decrypted_secret = 'k';
SELECT public.openaq_pedir('2026-11-22 10:16+00');
INSERT INTO net._http_response (id, status_code, content)
SELECT p.request_id, 200,
       CASE WHEN p.region_id = 'a0000000-0000-0000-0000-000000000001' THEN $j${"results": [
         {"id": 900001, "name": "Manaus", "isMobile": false, "provider": {"name": "AirGradient"},
          "licenses": [{"name": "CC BY 4.0"}], "coordinates": {"latitude": -3.1, "longitude": -60.0}, "distance": 2000,
          "datetimeLast": {"utc": "2026-11-22T10:00:00Z"},
          "sensors": [{"id": 7001, "parameter": {"id": 2, "name": "pm25"}},
                      {"id": 7004, "parameter": {"id": 98, "name": "relativehumidity"}},
                      {"id": 7005, "parameter": {"id": 100, "name": "temperature"}}]},
         {"id": 900009, "name": "Só umidade", "isMobile": false, "provider": {"name": "X"},
          "coordinates": {"latitude": -3.2, "longitude": -60.1}, "distance": 9000,
          "datetimeLast": {"utc": "2026-11-22T10:00:00Z"},
          "sensors": [{"id": 7009, "parameter": {"id": 98, "name": "relativehumidity"}}]}]}$j$
       ELSE '{"results": []}' END
  FROM public.openaq_pedidos p;
SELECT public.openaq_processar('2026-11-22 10:19+00');
SELECT pg_temp.confere((SELECT array_agg(sensor_id || ':' || parametro ORDER BY sensor_id) FROM public.openaq_sensores)
                       = ARRAY['7001:2', '7004:98'], 'guarda MP2,5 e umidade da mesma estação; ignora temperatura e estação só de umidade');
DELETE FROM net.chamadas;
SELECT pg_temp.confere(public.openaq_pedir('2026-11-22 11:16+00') = 2, 'pede horas de MP2,5 e de umidade');
INSERT INTO net._http_response (id, status_code, content)
SELECT p.request_id, 200, jsonb_build_object('results', jsonb_build_array(
         jsonb_build_object('value', CASE WHEN p.sensor_id = 7004 THEN 82 ELSE 21 END,
             'period', jsonb_build_object('datetimeFrom', jsonb_build_object('utc', '2026-11-22T10:00:00Z')))))::text
  FROM public.openaq_pedidos p;
SELECT public.openaq_processar('2026-11-22 11:19+00');
SELECT pg_temp.confere((SELECT ur FROM public.openaq_ur_horas WHERE sensor_id = 7004) = 82
                   AND (SELECT pm25 FROM public.openaq_horas WHERE sensor_id = 7001) = 21
                   AND NOT EXISTS (SELECT 1 FROM public.openaq_horas WHERE sensor_id = 7004),
                       'umidade vai para openaq_ur_horas, MP2,5 para openaq_horas');
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_local('2026-11-22 12:30+00')) = 0, 'ar_local continua só com MP2,5');

-- 3. Pares horários com marcas. 26 h, de 21/11 10:00 a 22/11 11:00 UTC.
DELETE FROM public.openaq_horas; DELETE FROM public.openaq_ur_horas;
INSERT INTO public.openaq_horas (sensor_id, hora, pm25)
SELECT 7001, h, CASE
         WHEN h BETWEEN '2026-11-21 14:00+00' AND '2026-11-21 19:00+00' THEN 33   -- 6 h iguais: travado na 6ª
         WHEN h = '2026-11-22 02:00+00' THEN 400                                  -- salto
         ELSE 20 + extract(hour FROM h) / 10 END
  FROM generate_series('2026-11-21 10:00+00'::timestamptz, '2026-11-22 11:00+00', interval '1 hour') h;
INSERT INTO public.openaq_ur_horas (sensor_id, hora, ur)
SELECT 7004, h, CASE WHEN h = '2026-11-22 05:00+00' THEN 97 ELSE 80 END
  FROM generate_series('2026-11-21 10:00+00'::timestamptz, '2026-11-22 11:00+00', interval '1 hour') h
 WHERE h <> '2026-11-22 06:00+00';                                               -- 06:00 sem umidade
INSERT INTO public.ar_horas (region_id, hora, pm2_5)
SELECT 'a0000000-0000-0000-0000-000000000001', h, 30
  FROM generate_series('2026-11-21 10:00+00'::timestamptz, '2026-11-22 11:00+00', interval '1 hour') h
ON CONFLICT (region_id, hora) DO UPDATE SET pm2_5 = 30;

SELECT pg_temp.confere(public.ar_validacao_registrar('2026-11-22 12:30+00') = 26, '26 pares gravados');
SELECT pg_temp.confere((SELECT marcas = '{}' AND valido FROM public.ar_validacao_horas WHERE hora = '2026-11-21 18:00+00'),
                       '5 horas iguais ainda não é travado');
SELECT pg_temp.confere((SELECT marcas = '{travado}' AND NOT valido FROM public.ar_validacao_horas WHERE hora = '2026-11-21 19:00+00'),
                       '6ª hora igual: travado, descartada');
SELECT pg_temp.confere((SELECT 'salto' = ANY(marcas) AND NOT valido FROM public.ar_validacao_horas WHERE hora = '2026-11-22 02:00+00'),
                       'salto de 20 para 400: descartada');
SELECT pg_temp.confere((SELECT 'salto' = ANY(marcas) FROM public.ar_validacao_horas WHERE hora = '2026-11-22 03:00+00'),
                       'a volta de 400 para 20 também é salto');
SELECT pg_temp.confere((SELECT marcas = '{ur_saturada}' AND NOT valido FROM public.ar_validacao_horas WHERE hora = '2026-11-22 05:00+00'),
                       'umidade 97%: descartada');
SELECT pg_temp.confere((SELECT marcas = '{sem_ur}' AND valido AND sensor_pm25_epa IS NULL AND sensor_pm25 IS NOT NULL
                          FROM public.ar_validacao_horas WHERE hora = '2026-11-22 06:00+00'),
                       'sem umidade: vale, mas sem correção da EPA');
SELECT pg_temp.confere((SELECT modelo_pm25 = 30 AND sensor_pm25 = 21 AND sensor_pm25_epa = public.ar_correcao_epa(21, 80)
                          AND ur_sensor = 80 AND sensores_n = 1
                          FROM public.ar_validacao_horas WHERE hora = '2026-11-21 10:00+00'), 'par completo');
SELECT pg_temp.confere(public.ar_validacao_registrar('2026-11-22 12:30+00') = 26, 'regravar não duplica');

-- 4. Cobertura (agora = 22/11 12:30 no teste não vale: a view usa now()).
--    Conferida só a estrutura: a região com sensor aparece com situação.
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_cobertura) = 1
                   AND (SELECT situacao IN ('saudável', 'cobertura baixa', 'parado') FROM public.ar_cobertura),
                       'cobertura lista a região com sensor');

-- 5. Dias: local (UTC-4) e UTC. Dados retroativos inventados.
DELETE FROM public.ar_validacao_horas;
INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensor_pm25_epa, sensores_n, ur_sensor, valido)
SELECT 'a0000000-0000-0000-0000-000000000001', h, 'retro',
       CASE WHEN h < '2026-08-11 04:00+00' THEN 30 ELSE 60 END, 20, 14, 1,
       CASE WHEN h < '2026-08-11 04:00+00' THEN 60 ELSE 90 END, true
  FROM generate_series('2026-08-10 04:00+00'::timestamptz, '2026-08-12 03:00+00', interval '1 hour') h;
-- Dia local 10/08 = 10/08 04:00 UTC a 11/08 03:00 UTC (24 h); idem 11/08.
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_validacao_dias WHERE fuso = 'local') = 2
                   AND (SELECT min(horas) FROM public.ar_validacao_dias WHERE fuso = 'local') = 24,
                       'dia local: 2 dias de 24 h');
-- Dia UTC: 10/08 tem 20 h (vale), 11/08 tem 24 h, 12/08 tem 4 h (não vale).
SELECT pg_temp.confere((SELECT array_agg(horas ORDER BY dia) FROM public.ar_validacao_dias WHERE fuso = 'utc') = ARRAY[20, 24],
                       'dia UTC: 20 h e 24 h; o de 4 h fica fora');
SELECT pg_temp.confere((SELECT nivel_modelo = 'N2' AND nivel_sensor = 'N2' FROM public.ar_validacao_dias
                         WHERE fuso = 'local' AND dia = '2026-08-10')
                   AND (SELECT nivel_modelo = 'N3' AND nivel_sensor = 'N2' FROM public.ar_validacao_dias
                         WHERE fuso = 'local' AND dia = '2026-08-11'), 'níveis do IQAr por dia');
INSERT INTO public.ar_fumaca_dias VALUES ('a0000000-0000-0000-0000-000000000001', '2026-08-11', 300, 812, 'muitos'),
                                         ('a0000000-0000-0000-0000-000000000001', '2026-08-11', 500, 2400, 'muitos');
SELECT pg_temp.confere((SELECT dias = 2 AND dif_mediana = 25 AND dif_q1 = 17.5 AND dif_q3 = 32.5
                           AND dif_mediana_epa = 31 AND dias_mesmo_nivel = 1
                          FROM public.ar_validacao_resumo WHERE fuso = 'local' AND recorte = 'todos'),
                       'resumo: mediana da diferença por dia (10 e 40 -> 25), em µg/m³');
SELECT pg_temp.confere((SELECT dias = 1 AND dif_mediana = 40 FROM public.ar_validacao_resumo
                         WHERE fuso = 'local' AND recorte = 'fumaça 300 km: muitos')
                   AND EXISTS (SELECT 1 FROM public.ar_validacao_resumo WHERE recorte = 'fumaça 500 km: muitos'),
                       'recortes de fumaça 300 e 500 km');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.ar_validacao_resumo WHERE recorte = 'umidade abaixo de 70')
                   AND EXISTS (SELECT 1 FROM public.ar_validacao_resumo WHERE recorte = 'umidade acima de 85'),
                       'recortes por umidade');
SELECT pg_temp.confere((SELECT horas = 48 FROM public.ar_validacao_resumo_horario WHERE origem = 'retro'), 'resumo horário de apoio');

-- 6. Fechado: anon e authenticated não leem nada.
SELECT pg_temp.confere(NOT has_table_privilege('anon', 'public.ar_validacao_horas', 'SELECT')
                   AND NOT has_table_privilege('authenticated', 'public.ar_validacao_resumo', 'SELECT')
                   AND NOT has_table_privilege('anon', 'public.ar_validacao_dias', 'SELECT')
                   AND NOT has_table_privilege('anon', 'public.ar_cobertura', 'SELECT')
                   AND NOT has_table_privilege('anon', 'public.ar_config', 'SELECT')
                   AND NOT has_table_privilege('anon', 'public.ar_fumaca_dias', 'SELECT')
                   AND NOT has_table_privilege('anon', 'public.openaq_ur_horas', 'SELECT')
                   AND NOT has_table_privilege('anon', 'net._http_response', 'SELECT')
                   AND NOT has_table_privilege('authenticated', 'net.http_request_queue', 'SELECT'),
                       'sem permissão para anon/authenticated (tabelas, views e net)');
SELECT pg_temp.confere((SELECT reloptions @> ARRAY['security_invoker=true'] FROM pg_class WHERE relname = 'ar_validacao_resumo')
                   AND (SELECT reloptions @> ARRAY['security_invoker=true'] FROM pg_class WHERE relname = 'ar_cobertura'),
                       'views com security_invoker');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ar-validacao' AND schedule = '25 * * * *'), 'agenda :25');
ROLLBACK;

-- Leitura real como anon (fora da transação acima, com os dados de volta).
BEGIN;
INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, valido)
VALUES ('a0000000-0000-0000-0000-000000000001', '2026-08-01 00:00+00', 'retro', 1, 1, true);
SET LOCAL ROLE anon;
DO $$ DECLARE t text; n bigint; BEGIN
  FOREACH t IN ARRAY ARRAY['public.ar_validacao_horas', 'public.ar_validacao_dias', 'public.ar_validacao_resumo',
                           'public.ar_cobertura', 'public.ar_config', 'net._http_response'] LOOP
    BEGIN
      EXECUTE 'SELECT count(*) FROM ' || t INTO n;
      RAISE EXCEPTION 'FALHOU: anon leu % (% linhas)', t, n;
    EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'ok: anon bloqueado em %', t;
    END;
  END LOOP;
END $$;
ROLLBACK;
