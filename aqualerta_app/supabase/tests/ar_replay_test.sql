-- Replay de 25-26/11/2026 no servidor: o que ar_resumo(), ar_contexto() e ar_agora()
-- devolvem às 06:00 locais (10:00 UTC) e às 19:42 locais (23:42 UTC) de 26/11, em
-- Manaus (sensor calado desde 10:00 UTC) e em Porto Velho (sensor em dia).
-- PostGIS LOCAL, banco novo:
--   stub_base, ar_stubs, ar_validacao_stubs, push_teste_stubs, sinal_dados_stubs,
--   20261118_push_fcm, 20261121b_sinal_dados, 20261122_ar, 20261123b_push_teste,
--   20261124_openaq, 20261125a_ar_pausa, 20261125b, 20261125c, 20261126a,
--   20261126b, 20261127b, 20261128a, 20261128b, 20261128c, 20261128d, 20261128e,
--   este arquivo
-- A série é uma RECONSTRUÇÃO (ver fixtures/ar_replay_serie.sql), não dado real.
-- O app (test/ar_replay_test.dart) lê o JSON gerado por fixtures/ar_replay_snapshot.sql
-- a partir destas mesmas séries.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
\ir fixtures/ar_replay_serie.sql

-- Manaus às 06:00 locais: o sensor acabou de mandar a última hora.
CREATE TEMP TABLE m6a AS SELECT * FROM public.ar_agora('2026-11-26 10:00+00') WHERE region_id = 'a0000000-0000-0000-0000-000000000001';
CREATE TEMP TABLE m6r AS SELECT * FROM public.ar_resumo('2026-11-26 10:00+00') WHERE region_id = 'a0000000-0000-0000-0000-000000000001';
SELECT pg_temp.confere((SELECT NOT sensor_parado AND pm25_3h = 180.7 AND nivel_3h = 'N5'
                          AND pm25_24h_sensor = 81.3 AND nivel_24h_sensor = 'N4' AND NOT piorou FROM m6a),
                       'Manaus 06:00: sensor em dia, 3 h = 180,7 µg/m³ (péssima), 24 h = 81,3 (muito ruim)');
SELECT pg_temp.confere((SELECT nivel = 'N2' AND iqar BETWEEN 41 AND 80 FROM m6r),
                       'Manaus 06:00: o modelo diz "moderada" (o cartão antigo mostraria isto)');
SELECT pg_temp.confere((SELECT sensor_situacao = 'saudável' FROM public.ar_contexto('2026-11-26 10:00+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000001'), 'Manaus 06:00: contexto "saudável"');

-- Manaus às 19:42 locais: 13 h sem leitura.
CREATE TEMP TABLE m19a AS SELECT * FROM public.ar_agora('2026-11-26 23:42+00') WHERE region_id = 'a0000000-0000-0000-0000-000000000001';
SELECT pg_temp.confere((SELECT sensor_parado AND sem_dados_h = 13 AND pm25_3h IS NULL AND ultima_leitura = '2026-11-26 10:00+00' FROM m19a),
                       'Manaus 19:42: sensor parado, sem dados há 13 h, sem número de "agora"');
SELECT pg_temp.confere((SELECT nivel = 'N2' AND iqar BETWEEN 76 AND 80 FROM public.ar_resumo('2026-11-26 23:42+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000001'),
                       'Manaus 19:42: o modelo diz "moderada", IQAr perto de 80 (o que o cartão antigo mostrou)');
SELECT pg_temp.confere((SELECT sensor_situacao = 'parado' FROM public.ar_contexto('2026-11-26 23:42+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000001'), 'Manaus 19:42: contexto "parado"');

-- Porto Velho: sensor em dia nos dois instantes; modelo "boa", sensor "moderada".
SELECT pg_temp.confere((SELECT bool_and(NOT sensor_parado AND nivel_3h = 'N2' AND nivel_24h_sensor = 'N2')
                          FROM (SELECT * FROM public.ar_agora('2026-11-26 10:00+00')
                                UNION ALL SELECT * FROM public.ar_agora('2026-11-26 23:42+00')) x
                         WHERE x.region_id = 'a0000000-0000-0000-0000-000000000003'),
                       'Porto Velho: sensor em dia nos dois instantes, faixa "moderada" (3 h e 24 h)');
SELECT pg_temp.confere((SELECT bool_and(nivel = 'N1')
                          FROM (SELECT * FROM public.ar_resumo('2026-11-26 10:00+00')
                                UNION ALL SELECT * FROM public.ar_resumo('2026-11-26 23:42+00')) x
                         WHERE x.region_id = 'a0000000-0000-0000-0000-000000000003'),
                       'Porto Velho: o modelo diz "boa" (falsa tranquilidade, como no relatório retro)');
SELECT pg_temp.confere((SELECT sensor_situacao = 'saudável' AND cautela_boa FROM public.ar_contexto('2026-11-26 23:42+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000003'),
                       'Porto Velho: "saudável"; a cautela do "Boa" ainda existia no cartão antigo');

-- Avisos por sensor seguem desligados e nada abre.
SELECT public.ar_avisos_atualizar('2026-11-26 10:00+00');
SELECT public.ar_avisos_atualizar('2026-11-26 23:42+00');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_aviso_sensor WHERE ligado) AND NOT EXISTS (SELECT 1 FROM public.ar_avisos),
                       'avisos por sensor desligados: o replay não abre aviso algum');
ROLLBACK;
