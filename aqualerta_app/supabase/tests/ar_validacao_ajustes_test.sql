-- Teste dos ajustes da Fase 1a (20261125c). PostGIS LOCAL:
--   ... 20261125b_ar_validacao.sql, ../migrations/20261125c_ar_validacao_ajustes.sql, este arquivo
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_config WHERE chave = 'ur_saturada'), 'regra de neblina removida da configuração');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'net-limpar' AND command LIKE '%30 minutes%'), 'limpeza do net a cada 15 min, guarda 30 min');

-- Coleta: com sensor cadastrado, pede também a umidade ambiente.
INSERT INTO vault.decrypted_secrets VALUES ('openaq_key', 'k') ON CONFLICT (name) DO UPDATE SET decrypted_secret = 'k';
INSERT INTO public.openaq_sensores (region_id, sensor_id, location_id, parametro, ultimo_dado) VALUES
 ('a0000000-0000-0000-0000-000000000001', 7001, 900001, 2, '2026-11-22 10:00+00'),
 ('a0000000-0000-0000-0000-000000000001', 7004, 900001, 98, '2026-11-22 10:00+00');
UPDATE public.openaq_estado SET locais_ok_em = '2026-11-22 09:00+00';
DELETE FROM net.chamadas;
SELECT pg_temp.confere(public.openaq_pedir('2026-11-22 12:16+00') = 3, '2 séries de horas + 1 umidade ambiente');
SELECT pg_temp.confere((SELECT count(*) FROM net.chamadas WHERE url = 'https://api.open-meteo.com/v1/forecast'
                          AND params->>'hourly' = 'relative_humidity_2m' AND params->>'latitude' = '-3.1383'
                          AND headers->>'X-API-Key' IS NULL) = 1, 'umidade do Open-Meteo, sem mandar a chave da OpenAQ');
INSERT INTO net._http_response (id, status_code, content)
SELECT p.request_id, 200, CASE p.tipo
    WHEN 'ur_ambiente' THEN '{"hourly": {"time": [1795341600, 1795345200, 1795435200], "relative_humidity_2m": [97, 91, 50]}}'
    ELSE jsonb_build_object('results', jsonb_build_array(jsonb_build_object(
           'value', CASE WHEN p.sensor_id = 7004 THEN 52 ELSE 25 END,
           'period', jsonb_build_object('datetimeFrom', jsonb_build_object('utc', '2026-11-22T10:00:00Z')))))::text END
  FROM public.openaq_pedidos p;
SELECT public.openaq_processar('2026-11-22 12:19+00');
SELECT pg_temp.confere((SELECT array_agg(ur ORDER BY hora) FROM public.ar_ur_ambiente) = ARRAY[97, 91]::numeric[],
                       'umidade ambiente gravada (hora futura da previsão fica fora)');

-- Par: umidade 97% ambiente não descarta a hora; a do sensor vai para a correção.
INSERT INTO public.ar_horas (region_id, hora, pm2_5) VALUES ('a0000000-0000-0000-0000-000000000001', '2026-11-22 10:00+00', 30)
ON CONFLICT (region_id, hora) DO UPDATE SET pm2_5 = 30;
SELECT public.ar_validacao_registrar('2026-11-22 12:30+00');
SELECT pg_temp.confere((SELECT valido AND marcas = '{}' AND ur_modelo = 97 AND ur_sensor = 52
                           AND sensor_pm25_epa = public.ar_correcao_epa(25, 52)
                          FROM public.ar_validacao_horas WHERE hora = '2026-11-22 10:00+00'),
                       'umidade ambiente 97%: hora vale; EPA usa a umidade do sensor');

-- Hora antiga marcada pela regra que saiu volta a valer.
INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensores_n, marcas, valido)
VALUES ('a0000000-0000-0000-0000-000000000001', '2026-08-01 00:00+00', 'retro', 10, 10, 1, '{ur_saturada}', false);
UPDATE public.ar_validacao_horas
   SET marcas = array_remove(marcas, 'ur_saturada'),
       valido = sensores_n > 0 AND modelo_pm25 IS NOT NULL AND sensor_pm25 IS NOT NULL
             AND NOT (array_remove(marcas, 'ur_saturada') && ARRAY['travado', 'salto'])
 WHERE 'ur_saturada' = ANY(marcas);
SELECT pg_temp.confere((SELECT valido AND marcas = '{}' FROM public.ar_validacao_horas WHERE hora = '2026-08-01 00:00+00'),
                       'limpeza da marca antiga');

-- Recortes pela umidade ambiente.
DELETE FROM public.ar_validacao_horas;
INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensor_pm25_epa, sensores_n, ur_sensor, ur_modelo, valido)
SELECT 'a0000000-0000-0000-0000-000000000001', h, 'retro', 30, 20, 14, 1, 45, 90, true
  FROM generate_series('2026-08-10 04:00+00'::timestamptz, '2026-08-11 03:00+00', interval '1 hour') h;
SELECT pg_temp.confere((SELECT ur_ambiente_media = 90 AND ur_sensor_media = 45 FROM public.ar_validacao_dias WHERE fuso = 'local'),
                       'dia guarda as duas umidades');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.ar_validacao_resumo
                                WHERE recorte = 'umidade ambiente (Open-Meteo, grade grosseira) acima de 85'),
                       'recorte pela umidade ambiente');
SELECT pg_temp.confere(NOT has_table_privilege('anon', 'public.ar_validacao_resumo', 'SELECT')
                   AND NOT has_table_privilege('authenticated', 'public.ar_validacao_dias', 'SELECT')
                   AND NOT has_table_privilege('anon', 'public.ar_ur_ambiente', 'SELECT')
                   AND (SELECT reloptions @> ARRAY['security_invoker=true'] FROM pg_class WHERE relname = 'ar_validacao_dias'),
                       'views recriadas continuam fechadas');
ROLLBACK;
