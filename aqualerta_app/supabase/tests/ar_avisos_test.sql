-- Teste da Fase 3 (20261126b_ar_avisos.sql). PostGIS LOCAL:
--   stub_base, ar_stubs, ar_validacao_stubs, push_teste_stubs, 20261118_push_fcm,
--   20261122_ar, 20261123b_push_teste, 20261124_openaq, 20261125a_ar_pausa,
--   20261125b, 20261125c, 20261126a, 20261126b, este arquivo
-- Valores inventados para exercitar as regras.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
-- Série do sensor de Manaus (…01), hora a hora, a partir de 22/11 00:00 UTC.
CREATE OR REPLACE FUNCTION pg_temp.serie(valores numeric[]) RETURNS void LANGUAGE sql AS $$
    DELETE FROM public.ar_validacao_horas WHERE origem = 'continua';
    INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensores_n, valido)
    SELECT 'a0000000-0000-0000-0000-000000000001', '2026-11-22 00:00+00'::timestamptz + (i - 1) * interval '1 hour',
           'continua', NULL, valores[i], 1, false          -- sem modelo: o aviso não depende dele
      FROM generate_subscripts(valores, 1) i;
$$;
CREATE OR REPLACE FUNCTION pg_temp.agora(horas integer) RETURNS timestamptz LANGUAGE sql AS
$$ SELECT '2026-11-22 00:30+00'::timestamptz + horas * interval '1 hour' $$;

-- A segue Manaus e escolheu avisos de ar; B segue e não escolheu; C não segue.
INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b1'),
                                   ('00000000-0000-0000-0000-0000000000c1') ON CONFLICT DO NOTHING;
INSERT INTO public.user_profiles (id, fcm_token, notification_preferences) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'tok-a-0123456789abcdef', '{"ar_optin": true, "ar": true}'),
  ('00000000-0000-0000-0000-0000000000b1', 'tok-b-0123456789abcdef', '{"ar": true}'),
  ('00000000-0000-0000-0000-0000000000c1', 'tok-c-0123456789abcdef', '{"ar_optin": true}')
ON CONFLICT (id) DO UPDATE SET fcm_token = excluded.fcm_token, notification_preferences = excluded.notification_preferences;
INSERT INTO public.user_monitored_regions (user_id, region_id) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'a0000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-0000000000b1', 'a0000000-0000-0000-0000-000000000001') ON CONFLICT DO NOTHING;
DELETE FROM public.push_fila;

-- 10 h limpas, 4 h de pico (200 µg/m³), 8 h limpas.
SELECT pg_temp.serie(ARRAY[20,20,20,20,20,20,20,20,20,20, 200,200,200,200, 10,10,10,10,10,10,10,10]::numeric[]);

-- 1. Desligado (padrão em Manaus): nada abre.
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.ar_aviso_sensor WHERE region_id = 'a0000000-0000-0000-0000-000000000001' AND NOT ligado),
                       'Manaus candidata, desligada');
SELECT public.ar_avisos_atualizar(pg_temp.agora(13));
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_avisos), 'desligado: nenhum aviso, mesmo com pico');

-- 2. Ligado: abre na 2ª hora acima do limite.
UPDATE public.ar_aviso_sensor SET ligado = true WHERE region_id = 'a0000000-0000-0000-0000-000000000001';
SELECT pg_temp.confere((SELECT nowcast > 75 FROM public.ar_nowcast('continua', '2026-11-22 10:00+00', '2026-11-22 11:00+00')),
                       '1ª hora do pico: NowCast já acima de 75');
SELECT public.ar_avisos_atualizar(pg_temp.agora(10));   -- só a 1ª hora de pico fechada
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_avisos), '1 hora acima: ainda não abre');
SELECT public.ar_avisos_atualizar(pg_temp.agora(11));
SELECT pg_temp.confere((SELECT count(*) = 1 AND bool_and(situacao = 'ativo' AND inicio = '2026-11-22 10:00+00' AND limite_ugm3 = 75)
                          FROM public.ar_avisos), '2 horas seguidas acima: abre, com início na 1ª hora');
SELECT pg_temp.confere((SELECT severity FROM public.ar_avisos) =
                       CASE WHEN (SELECT nowcast FROM public.ar_nowcast('continua', '2026-11-22 11:00+00', '2026-11-22 12:00+00')) > 125
                            THEN 'CRITICAL' ELSE 'HIGH' END, 'severidade pelo NowCast atual (> 125 = péssima)');

-- Push: só A (segue e escolheu). B segue sem escolher; C escolheu mas não segue.
SELECT pg_temp.confere((SELECT count(*) FROM public.push_fila WHERE ar_aviso_id IS NOT NULL AND motivo = 'novo') = 1, 'aviso novo na fila');
CREATE TEMP TABLE r AS SELECT * FROM public.push_reivindicar(20);
SELECT pg_temp.confere((SELECT array_agg(token) FROM r WHERE token IS NOT NULL) = ARRAY['tok-a-0123456789abcdef'],
                       'push só para quem segue a região E escolheu avisos de ar');
SELECT pg_temp.confere((SELECT bool_and(corpo LIKE 'O sensor perto de Manaus indica ar %não é o índice oficial).'
                                  AND titulo LIKE 'Ar %' AND alert_id = (SELECT id FROM public.ar_avisos)) FROM r WHERE token IS NOT NULL),
                       'texto do push diz que é sensor e que não é o índice oficial; id do aviso vai junto');
SELECT public.push_concluir((SELECT jsonb_agg(jsonb_build_object('fila_id', fila_id, 'alert_id', alert_id, 'user_id', user_id,
                                                                  'token', token, 'ok', true)) FROM r));
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.alert_deliveries), 'aviso de ar não vira entrega de alerta');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.alerts WHERE metadata->>'origem' LIKE 'ar%'), 'nada em alerts');

-- 3. Rodar de novo sem mudança: nada novo na fila.
SELECT public.ar_avisos_atualizar(pg_temp.agora(11));
SELECT pg_temp.confere((SELECT count(*) FROM public.push_fila) = 1, 'sem mudança, sem push repetido');

-- 4. Fecha com 3 horas seguidas abaixo do limite.
SELECT public.ar_avisos_atualizar(pg_temp.agora(16));
SELECT pg_temp.confere((SELECT situacao FROM public.ar_avisos) = 'ativo'
                    OR (SELECT situacao FROM public.ar_avisos) = 'encerrado', 'estado coerente durante a queda');
CREATE TEMP TABLE antes AS SELECT count(*) AS n FROM public.push_fila;
SELECT public.ar_avisos_atualizar(pg_temp.agora(21));
SELECT pg_temp.confere((SELECT situacao = 'encerrado' AND motivo_fim LIKE 'o índice ficou abaixo de 75 µg/m³ por 3 h seguidas'
                           AND fim IS NOT NULL AND nowcast_max >= 75 FROM public.ar_avisos), 'fecha por histerese (3 h abaixo)');
SELECT pg_temp.confere((SELECT count(*) FROM public.push_fila) = (SELECT n FROM antes), 'encerramento não manda push');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.push_fila WHERE motivo NOT IN ('novo', 'subiu', 'baixou')), 'só novo, subiu ou baixou');

-- 5. Sensor parado com aviso aberto: fecha.
DELETE FROM public.ar_avisos;
SELECT pg_temp.serie(ARRAY[20,20,20,20,20,20,20,20,20,20, 200,200,200,200]::numeric[]);
SELECT public.ar_avisos_atualizar(pg_temp.agora(13));
SELECT pg_temp.confere((SELECT situacao FROM public.ar_avisos) = 'ativo', 'aberto no pico');
SELECT public.ar_avisos_atualizar(pg_temp.agora(20));   -- 6 h sem nenhuma leitura
SELECT pg_temp.confere((SELECT situacao = 'encerrado' AND motivo_fim = 'o sensor parou de mandar leituras' FROM public.ar_avisos),
                       'sensor parado fecha o aviso');

-- 6. Desligar a região fecha o que estiver aberto.
DELETE FROM public.ar_avisos;
SELECT public.ar_avisos_atualizar(pg_temp.agora(13));
UPDATE public.ar_aviso_sensor SET ligado = false;
SELECT public.ar_avisos_atualizar(pg_temp.agora(13));
SELECT pg_temp.confere((SELECT situacao = 'encerrado' AND motivo_fim = 'avisos de ar desligados nesta região' FROM public.ar_avisos),
                       'desligar fecha o aviso aberto');

-- 7. Um ativo por região; permissões; agenda.
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'ar_avisos_um_ativo'), 'no máximo 1 aviso ativo por região');
SELECT pg_temp.confere(has_table_privilege('authenticated', 'public.ar_avisos', 'SELECT')
                   AND NOT has_table_privilege('anon', 'public.ar_avisos', 'SELECT')
                   AND NOT has_table_privilege('authenticated', 'public.ar_avisos', 'INSERT')
                   AND NOT has_function_privilege('authenticated', 'public.ar_avisos_atualizar(timestamptz)', 'EXECUTE'),
                       'usuário logado só lê; o servidor decide');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ar-avisos' AND schedule = '27 * * * *'), 'agenda :27');
ROLLBACK;
