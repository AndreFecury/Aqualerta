-- Teste da Fase D1 (20261127b_ar_aviso_teste.sql). PostGIS LOCAL, banco novo:
--   stub_base, ar_stubs, ar_validacao_stubs, push_teste_stubs, sinal_dados_stubs,
--   20261118_push_fcm, 20261122_ar, 20261123b_push_teste, 20261124_openaq,
--   20261125a_ar_pausa, 20261125b, 20261125c, 20261126a, 20261126b, 20261127b,
--   este arquivo
-- Valores inventados. A = dono do teste, B = outra conta que segue Manaus.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b1')
ON CONFLICT DO NOTHING;
INSERT INTO public.user_profiles (id, fcm_token, notification_preferences) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'tok-a-0123456789abcdef', '{}'),
  ('00000000-0000-0000-0000-0000000000b1', 'tok-b-0123456789abcdef', '{"ar_optin": true, "ar": true}')
ON CONFLICT (id) DO UPDATE SET fcm_token = excluded.fcm_token, notification_preferences = excluded.notification_preferences;
INSERT INTO public.user_monitored_regions (user_id, region_id) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'a0000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-0000000000b1', 'a0000000-0000-0000-0000-000000000001') ON CONFLICT DO NOTHING;
INSERT INTO public.openaq_sensores (region_id, sensor_id, location_id, nome, parametro)
VALUES ('a0000000-0000-0000-0000-000000000001', 13574643, 5040030, 'Manaus', 2) ON CONFLICT DO NOTHING;
DELETE FROM public.push_fila; DELETE FROM public.ar_avisos;
UPDATE public.dados_sinal SET mudou_em = '2000-01-01' WHERE id = 1;

-- 1. Só o SQL Editor / service role cria o teste.
SELECT pg_temp.confere(NOT has_function_privilege('authenticated', 'public.ar_aviso_teste(uuid,uuid,timestamptz)', 'EXECUTE')
                   AND NOT has_function_privilege('anon', 'public.ar_aviso_teste(uuid,uuid,timestamptz)', 'EXECUTE'),
                       'app não cria aviso de teste');
DO $$ BEGIN
    PERFORM public.ar_aviso_teste('00000000-0000-0000-0000-0000000000c1');
    RAISE EXCEPTION 'devia recusar';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'usuário sem aparelho registrado para push' THEN RAISE; END IF;
END $$;
SELECT pg_temp.confere(true, 'conta sem aparelho: recusa');

CREATE TEMP TABLE t AS SELECT public.ar_aviso_teste('00000000-0000-0000-0000-0000000000a1', NULL, '2026-11-23 12:00+00') AS id;
GRANT SELECT ON t TO authenticated;
SELECT pg_temp.confere((SELECT count(*) = 1 AND bool_and(situacao = 'ativo' AND region_id = 'a0000000-0000-0000-0000-000000000001'
                           AND expira_em = '2026-11-23 13:00+00' AND nowcast_atual IS NULL)
                          FROM public.ar_avisos), 'teste criado em Manaus, expira em 1 h, sem número inventado');
SELECT pg_temp.confere((SELECT mudou_em FROM public.dados_sinal WHERE id = 1) = '2000-01-01', 'teste não dispara o sinal de tempo real');

-- 2. RLS: A vê, B não vê; anon não lê nada.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_avisos WHERE situacao = 'ativo') = 1, 'A vê o próprio teste (conta nos ativos dele)');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', true);
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_avisos) = 0, 'B não vê o teste de A');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_avisos WHERE id = (SELECT id FROM t)), 'B não acha nem pelo id');
RESET ROLE;
SELECT pg_temp.confere(NOT has_table_privilege('anon', 'public.ar_avisos', 'SELECT'), 'anon não lê ar_avisos');

-- 3. Push: um item, só para A, com TESTE no título e no corpo, id do aviso junto.
CREATE TEMP TABLE r AS SELECT * FROM public.push_reivindicar(20);
SELECT pg_temp.confere((SELECT array_agg(token) FROM r WHERE token IS NOT NULL) = ARRAY['tok-a-0123456789abcdef'],
                       'push só para A (B segue Manaus e escolheu ar, e não recebe)');
SELECT pg_temp.confere((SELECT bool_and(titulo = 'TESTE · Ar muito ruim: proteja-se' AND corpo LIKE 'TESTE do aviso de ar por sensor em Manaus.%'
                                        AND alert_id = (SELECT id FROM t)) FROM r WHERE token IS NOT NULL),
                       'push marcado TESTE; toque abre o detalhe do aviso');
SELECT public.push_concluir((SELECT jsonb_agg(jsonb_build_object('fila_id', fila_id, 'alert_id', alert_id, 'user_id', user_id,
                                                                  'token', token, 'ok', true)) FROM r));
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.push_fila WHERE ar_aviso_id IS NOT NULL), 'seguidores: nenhum item na fila');

-- 4. Aviso real convive: o teste não ocupa o "1 ativo por região" nem é fechado pela regra do sensor.
UPDATE public.ar_aviso_sensor SET ligado = true WHERE region_id = 'a0000000-0000-0000-0000-000000000001';
INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensores_n, valido)
SELECT 'a0000000-0000-0000-0000-000000000001', '2026-11-23 00:00+00'::timestamptz + g * interval '1 hour',
       'continua', NULL, CASE WHEN g >= 9 THEN 200 ELSE 20 END, 1, false FROM generate_series(0, 11) g;
SELECT public.ar_avisos_atualizar('2026-11-23 12:30+00');
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_avisos WHERE situacao = 'ativo' AND teste_para IS NULL) = 1
                   AND (SELECT situacao FROM public.ar_avisos WHERE id = (SELECT id FROM t)) = 'ativo',
                       'aviso real abre na mesma região; teste continua');
SELECT pg_temp.confere((SELECT count(*) FROM public.push_fila WHERE ar_aviso_id IS NOT NULL AND resultado IS NULL) = 1,
                       'aviso real vai para a fila dos seguidores');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', true);
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_avisos) = 1 AND (SELECT teste_para FROM public.ar_avisos) IS NULL,
                       'B vê só o aviso real');
RESET ROLE;
-- Sensor para: fecha o real; o teste fica.
SELECT public.ar_avisos_atualizar('2026-11-23 18:30+00');
SELECT pg_temp.confere((SELECT situacao FROM public.ar_avisos WHERE teste_para IS NULL) = 'encerrado'
                   AND (SELECT situacao FROM public.ar_avisos WHERE id = (SELECT id FROM t)) = 'ativo',
                       'regra do sensor fecha o real e não toca no teste');

-- 5. Expira em 1 hora.
SELECT pg_temp.confere(public.ar_avisos_teste_expirar('2026-11-23 12:59+00') = 0, 'antes de 1 h: continua');
SELECT pg_temp.confere(public.ar_avisos_teste_expirar('2026-11-23 13:00+00') = 1, 'com 1 h: um teste encerrado');
SELECT pg_temp.confere((SELECT situacao = 'encerrado' AND motivo_fim = 'teste encerrado depois de 1 hora'
                          FROM public.ar_avisos WHERE id = (SELECT id FROM t)), 'com 1 h: vai para Encerrados');
SELECT public.ar_avisos_teste_expirar('2026-12-01 13:00+00');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_avisos WHERE id = (SELECT id FROM t)), 'teste velho some depois de 7 dias');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.ar_avisos WHERE teste_para IS NULL), 'aviso real não é apagado');

-- 6. Um teste ativo por conta: o segundo substitui o primeiro.
CREATE TEMP TABLE t2 AS SELECT public.ar_aviso_teste('00000000-0000-0000-0000-0000000000a1') AS id;
CREATE TEMP TABLE t3 AS SELECT public.ar_aviso_teste('00000000-0000-0000-0000-0000000000a1') AS id;
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_avisos WHERE teste_para IS NOT NULL AND situacao = 'ativo') = 1
                   AND (SELECT motivo_fim FROM public.ar_avisos WHERE id = (SELECT id FROM t2)) = 'teste substituído por outro',
                       'um teste ativo por conta');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ar-aviso-teste-expirar' AND schedule = '*/10 * * * *'),
                       'agenda a cada 10 min');
ROLLBACK;
