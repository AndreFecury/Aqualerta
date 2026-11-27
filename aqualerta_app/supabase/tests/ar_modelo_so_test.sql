-- Teste do estado "só modelo" (sensor parado ou ausente) e da regra de que o
-- modelo nunca baixa nem cancela um aviso. PostGIS LOCAL, banco novo:
--   stub_base, ar_stubs, ar_validacao_stubs, push_teste_stubs, sinal_dados_stubs,
--   20261118_push_fcm, 20261121b_sinal_dados, 20261122_ar, 20261123b_push_teste,
--   20261124_openaq, 20261125a_ar_pausa, 20261125b, 20261125c, 20261126a,
--   20261126b, 20261127b, 20261128a, 20261128d, este arquivo
-- Valores inventados. Manaus = a0000000-...-001 (tem sensor), Parintins = ...-002 (não tem).
-- O app (test/ar_sem_medicao_test.dart) decide a manchete "Sem medição agora"
-- a partir de tem_sensor e sensor_situacao = 'parado' vindos de ar_contexto().
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.serie(valores numeric[]) RETURNS void LANGUAGE sql AS $$
    DELETE FROM public.ar_validacao_horas WHERE origem = 'continua';
    INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensores_n, valido)
    SELECT 'a0000000-0000-0000-0000-000000000001', '2026-11-22 00:00+00'::timestamptz + (i - 1) * interval '1 hour',
           'continua', NULL, valores[i], 1, false
      FROM generate_subscripts(valores, 1) i;
$$;
CREATE OR REPLACE FUNCTION pg_temp.agora(horas integer) RETURNS timestamptz LANGUAGE sql AS
$$ SELECT '2026-11-22 00:30+00'::timestamptz + horas * interval '1 hour' $$;
CREATE OR REPLACE FUNCTION pg_temp.modelo(de timestamptz, ate timestamptz, pm numeric) RETURNS void LANGUAGE sql AS $$
    INSERT INTO public.ar_horas (region_id, hora, pm2_5)
    SELECT 'a0000000-0000-0000-0000-000000000001', h, pm
      FROM generate_series(de, ate, interval '1 hour') h
    ON CONFLICT (region_id, hora) DO UPDATE SET pm2_5 = excluded.pm2_5;
$$;

INSERT INTO public.openaq_sensores (region_id, sensor_id, location_id, nome, provedor, distancia_m, parametro) VALUES
 ('a0000000-0000-0000-0000-000000000001', 7001, 900001, 'Manaus', 'AirGradient', 2026.9, 2);

-- 1. As 19:42 de Manaus (23:42 UTC): o modelo diz "moderada"; o sensor perto
--    parou há quase 7 horas (última hora válida 16:00-17:00 UTC).
SELECT pg_temp.modelo('2026-11-21 20:00+00', '2026-11-23 00:00+00', 35);
INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensores_n, valido)
SELECT 'a0000000-0000-0000-0000-000000000001', h, 'continua', 35, 100, 1, true
  FROM generate_series('2026-11-21 17:00+00'::timestamptz, '2026-11-22 16:00+00', interval '1 hour') h;
CREATE TEMP TABLE r AS SELECT * FROM public.ar_resumo('2026-11-22 23:42+00') WHERE region_id = 'a0000000-0000-0000-0000-000000000001';
CREATE TEMP TABLE c AS SELECT * FROM public.ar_contexto('2026-11-22 23:42+00') WHERE region_id = 'a0000000-0000-0000-0000-000000000001';
SELECT pg_temp.confere((SELECT nivel = 'N2' AND iqar BETWEEN 41 AND 80 FROM r), 'o modelo diz "moderada" (IQAr 41 a 80)');
SELECT pg_temp.confere((SELECT tem_sensor AND sensor_situacao = 'parado' AND NOT comparacao_ok FROM c),
                       'o sensor perto está "parado": é isto que faz o app trocar a manchete por "Sem medição agora"');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.ar_agora('2026-11-22 23:42+00') WHERE pm25_3h IS NULL AND sensor_parado),
                       'sem "agora" de 3 h com o sensor parado (nada de número velho)');
SELECT pg_temp.confere((SELECT tem_sensor IS FALSE FROM public.ar_contexto('2026-11-22 23:42+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000002'),
                       'região sem sensor: tem_sensor = false (também "Sem medição agora")');

-- 2. O modelo nunca baixa nem cancela um aviso do sensor.
DELETE FROM public.ar_validacao_horas;
DELETE FROM public.ar_horas;
UPDATE public.ar_aviso_sensor SET ligado = true WHERE region_id = 'a0000000-0000-0000-0000-000000000001';
SELECT pg_temp.serie(ARRAY[20,20,20,20,20,20,20,20,20,20, 200,200,200,200]::numeric[]);
SELECT public.ar_avisos_atualizar(pg_temp.agora(13));
CREATE TEMP TABLE antes AS SELECT id, severity, nowcast_atual, situacao FROM public.ar_avisos;
SELECT pg_temp.confere((SELECT count(*) = 1 AND bool_and(situacao = 'ativo') FROM antes), 'aviso do sensor aberto no pico');

-- modelo dizendo "boa" (5 µg/m³) durante todo o pico
SELECT pg_temp.modelo('2026-11-21 00:00+00', '2026-11-23 00:00+00', 5);
SELECT public.ar_atualizar_avisos(pg_temp.agora(13));
SELECT public.ar_avisos_atualizar(pg_temp.agora(13));
SELECT pg_temp.confere((SELECT a.situacao = 'ativo' AND a.severity = b.severity AND a.nowcast_atual = b.nowcast_atual
                          FROM public.ar_avisos a JOIN antes b USING (id)),
                       'modelo "boa": o aviso do sensor continua igual (não baixa, não encerra)');

-- modelo dizendo "péssima" (500 µg/m³): também não mexe no aviso do sensor
SELECT pg_temp.modelo('2026-11-21 00:00+00', '2026-11-23 00:00+00', 500);
SELECT public.ar_atualizar_avisos(pg_temp.agora(13));
SELECT public.ar_avisos_atualizar(pg_temp.agora(13));
SELECT pg_temp.confere((SELECT a.situacao = 'ativo' AND a.severity = b.severity AND a.nowcast_atual = b.nowcast_atual
                          FROM public.ar_avisos a JOIN antes b USING (id)),
                       'modelo "péssima": o aviso do sensor também não muda (o modelo não abre nem sobe aviso por aqui)');
SELECT pg_temp.confere((SELECT count(*) = 1 FROM public.ar_avisos), 'continua 1 aviso só');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.alerts WHERE metadata->>'origem' = 'ar-cams'),
                       'avisos de ar pelo modelo seguem suspensos (nenhum alerta ar-cams)');
ROLLBACK;
