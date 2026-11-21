-- Teste do sinal "dados mudaram" (20261121b_sinal_dados.sql). PostGIS LOCAL
-- apenas: antes da migração, rode stub_base.sql e o trecho "stubs" abaixo
-- (fora da transação), que imita realtime.send e a publicação do Supabase.
--   psql -f stub_base.sql -f sinal_dados_stubs.sql -f ../migrations/20261121b_sinal_dados.sql -f sinal_dados_test.sql
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.envios() RETURNS bigint
LANGUAGE sql AS $$ SELECT count(*) FROM realtime.enviados $$;

-- Estado inicial: tudo já enviado.
DELETE FROM realtime.enviados;
UPDATE public.dados_sinal SET mudou_em = now() - interval '1 hour', enviado_em = now() - interval '30 minutes';

SELECT pg_temp.confere(public.dados_enviar_sinal() = false, 'sem mudança: não envia');
SELECT pg_temp.confere(pg_temp.envios() = 0, 'nenhuma mensagem');

-- 1. Lote de leituras da ANA: um sinal só, não um por linha.
INSERT INTO public.hydro_readings (station_id, water_level_m, recorded_at)
SELECT id, 16 + k / 100.0, now() - make_interval(mins => k * 15)
FROM public.hydro_stations, generate_series(1, 40) k;
SELECT pg_temp.confere(public.dados_enviar_sinal(), 'lote novo: envia');
SELECT pg_temp.confere(pg_temp.envios() = 1, '40 leituras = 1 mensagem');
SELECT pg_temp.confere((SELECT topico = 'dados' AND evento = 'mudou' AND NOT privado
                          AND (payload->>'versao')::int >= 1 FROM realtime.enviados),
                       'canal público "dados", evento "mudou", só a versão');
SELECT pg_temp.confere(public.dados_enviar_sinal() = false, 'no minuto seguinte, sem novidade: não envia');

-- 2. Lote repetido (nada entrou de fato) não é mudança.
UPDATE public.dados_sinal SET enviado_em = now() + interval '1 second';
INSERT INTO public.hydro_readings (station_id, water_level_m, recorded_at)
SELECT id, 1, now() FROM public.hydro_stations WHERE false;
SELECT pg_temp.confere(public.dados_enviar_sinal() = false, 'comando sem linhas: não envia');

-- 3. Alerta: novo conta; só metadata (último gatilho da chuva) não conta.
UPDATE public.dados_sinal SET mudou_em = now() - interval '1 hour', enviado_em = now() - interval '30 minutes';
UPDATE public.alerts SET metadata = metadata || '{"ultimo_gatilho":"2026-11-21T10:00:00Z"}';
SELECT pg_temp.confere(public.dados_enviar_sinal() = false, 'renovar o prazo do aviso: não envia');
UPDATE public.alerts SET severity = 'HIGH';
SELECT pg_temp.confere(public.dados_enviar_sinal(), 'nível do alerta mudou: envia');
UPDATE public.dados_sinal SET mudou_em = now() - interval '1 hour', enviado_em = now() - interval '30 minutes';
INSERT INTO public.alerts (region_id, title, body, severity)
VALUES ('a0000000-0000-0000-0000-000000000001', 't', 'b', 'MEDIUM');
SELECT pg_temp.confere(public.dados_enviar_sinal(), 'alerta novo: envia');

-- 4. Evento de satélite conta.
UPDATE public.dados_sinal SET mudou_em = now() - interval '1 hour', enviado_em = now() - interval '30 minutes';
INSERT INTO public.flood_events (region_id, severity) VALUES ('a0000000-0000-0000-0000-000000000001', 'HIGH');
SELECT pg_temp.confere(public.dados_enviar_sinal(), 'evento novo: envia');

-- 5. Versão sobe a cada envio; cron agendado; leituras fora do tempo real.
SELECT pg_temp.confere((SELECT max((payload->>'versao')::int) - min((payload->>'versao')::int) FROM realtime.enviados) = 3,
                       'versão sobe 1 por envio');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'dados-sinal' AND schedule = '* * * * *'),
                       'cron a cada minuto');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime'
                                     AND tablename = 'hydro_readings'), 'hydro_readings fora da publicação');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime'
                                 AND tablename = 'alerts'), 'alerts segue na publicação (apps antigos)');

-- 6. Quem usa o app não lê nem chama nada disso.
SELECT pg_temp.confere(NOT has_table_privilege('anon', 'public.dados_sinal', 'SELECT')
                   AND NOT has_function_privilege('anon', 'public.dados_enviar_sinal()', 'EXECUTE')
                   AND NOT has_function_privilege('authenticated', 'public.dados_enviar_sinal()', 'EXECUTE'),
                       'sem acesso para anon/authenticated');

ROLLBACK;
