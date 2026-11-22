-- Teste do push de teste (20261123b_push_teste.sql). PostGIS LOCAL apenas:
--   psql -f stub_base.sql -f ar_stubs.sql -f push_teste_stubs.sql
--        -f ../migrations/20261118_push_fcm.sql -f ../migrations/20261122_ar.sql
--        -f ../migrations/20261123b_push_teste.sql -f push_teste_test.sql
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

-- A segue Manaus (aparelho A). B também segue Manaus (aparelho B).
INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b1');
INSERT INTO public.user_profiles (id, fcm_token, notification_preferences) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'tok-a-0123456789abcdef', '{"min_severity":"HIGH","ar":false}'),
  ('00000000-0000-0000-0000-0000000000b1', 'tok-b-0123456789abcdef', '{}');
INSERT INTO public.user_monitored_regions (user_id, region_id) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'a0000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-0000000000b1', 'a0000000-0000-0000-0000-000000000001');
DELETE FROM public.push_fila;
DELETE FROM net.chamadas;

-- Títulos reais não mudaram.
SELECT pg_temp.confere(public.push_titulo(false, 'HIGH', 'subiu') = 'Prepare-se: risco alto (subiu)'
                   AND public.push_titulo(false, 'LOW', 'baixou') = 'Situação normal: risco baixo (baixou)'
                   AND public.push_titulo(true, 'CRITICAL', 'novo') = 'Ar péssimo: evite sair de casa'
                   AND public.push_titulo(true, 'HIGH', 'novo') = 'Ar muito ruim: proteja-se', 'títulos iguais aos de antes');

-- Teste para quem não tem aparelho: erro claro.
DO $$ BEGIN
    PERFORM public.push_teste('00000000-0000-0000-0000-0000000000c1');
    RAISE EXCEPTION 'devia ter falhado';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'usuário sem aparelho%' THEN RAISE; END IF;
END $$;

SELECT pg_temp.confere(public.push_teste('00000000-0000-0000-0000-0000000000a1') = 7, '7 avisos de teste na fila');
SELECT pg_temp.confere((SELECT count(*) FROM net.chamadas WHERE url LIKE '%/functions/v1/push-alertas') = 1, 'Edge Function cutucada');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.alerts WHERE title LIKE '%TESTE%'), 'nenhum alerta criado');

CREATE TEMP TABLE r AS SELECT * FROM public.push_reivindicar(20);
SELECT pg_temp.confere((SELECT count(*) FROM r) = 7, 'um destino por item');
SELECT pg_temp.confere((SELECT bool_and(token = 'tok-a-0123456789abcdef') FROM r), 'só o aparelho de A (B não recebe)');
SELECT pg_temp.confere((SELECT count(DISTINCT alert_id) FROM r) = 7, 'id próprio por aviso (não se substituem)');
SELECT pg_temp.confere((SELECT bool_and(titulo LIKE 'TESTE · %' AND corpo LIKE 'Notificação de teste%Não é um alerta real.') FROM r),
                       'título e texto marcados como teste');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM r WHERE titulo = 'TESTE · Fique atento: risco médio')
                   AND EXISTS (SELECT 1 FROM r WHERE titulo = 'TESTE · Situação normal: risco baixo (baixou)')
                   AND EXISTS (SELECT 1 FROM r WHERE titulo = 'TESTE · Ar péssimo: evite sair de casa (subiu)')
                   AND EXISTS (SELECT 1 FROM r WHERE corpo LIKE '%(chuva forte)%'),
                       'ignora as preferências de A (mínimo HIGH, ar desligado): é teste');

-- Conclusão: resultado gravado, sem entrega de alerta (o id não existe em alerts).
SELECT public.push_concluir((SELECT jsonb_agg(jsonb_build_object('fila_id', fila_id, 'alert_id', alert_id,
                              'user_id', user_id, 'token', token, 'ok', true)) FROM r));
SELECT pg_temp.confere((SELECT count(*) FROM public.push_fila WHERE resultado->>'enviados' = '1') = 7, 'resultado gravado nos 7');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.alert_deliveries), 'nenhuma entrega registrada');

-- Alerta real continua igual: vai para A e B conforme as preferências.
INSERT INTO public.alerts (region_id, title, body, severity, metadata)
VALUES ('a0000000-0000-0000-0000-000000000001', 'Rio Negro subindo', 'real', 'HIGH', '{"origem":"telemetria-ana"}');
DROP TABLE r;
CREATE TEMP TABLE r AS SELECT * FROM public.push_reivindicar(20);
SELECT pg_temp.confere((SELECT count(*) FROM r) = 2 AND (SELECT bool_and(titulo = 'Prepare-se: risco alto' AND corpo = 'Rio Negro subindo') FROM r),
                       'alerta real: A e B, título de sempre');
SELECT public.push_concluir((SELECT jsonb_agg(jsonb_build_object('fila_id', fila_id, 'alert_id', alert_id,
                              'user_id', user_id, 'token', token, 'ok', true)) FROM r));
SELECT pg_temp.confere((SELECT count(*) FROM public.alert_deliveries) = 2, 'entregas do alerta real registradas');
-- MEDIUM real não chega a A (mínimo HIGH), chega a B.
INSERT INTO public.alerts (region_id, title, body, severity, metadata)
VALUES ('a0000000-0000-0000-0000-000000000001', 'Chuva moderada', 'real', 'MEDIUM', '{"origem":"chuva-cemaden"}');
DROP TABLE r;
CREATE TEMP TABLE r AS SELECT * FROM public.push_reivindicar(20);
SELECT pg_temp.confere((SELECT count(*) FROM r) = 1 AND (SELECT token FROM r) = 'tok-b-0123456789abcdef',
                       'preferências valem para alerta real');

-- Fila não aceita item sem alerta e sem destino de teste.
DO $$ BEGIN
    INSERT INTO public.push_fila (alert_id, severity, motivo) VALUES (NULL, 'HIGH', 'novo');
    RAISE EXCEPTION 'devia ter falhado';
EXCEPTION WHEN check_violation THEN NULL; END $$;
SELECT pg_temp.confere(NOT has_function_privilege('authenticated', 'public.push_teste(uuid)', 'EXECUTE')
                   AND NOT has_function_privilege('anon', 'public.push_teste(uuid)', 'EXECUTE'), 'push_teste só pelo servidor');
ROLLBACK;
