-- Teste da Fase 0 (20261125a_ar_pausa.sql). PostGIS LOCAL:
--   psql -f stub_base.sql -f ar_stubs.sql -f push_teste_stubs.sql
--        -f ../migrations/20261118_push_fcm.sql -f ../migrations/20261122_ar.sql
--        -f ../migrations/20261123b_push_teste.sql -f ar_pausa_pre.sql
--        -f ../migrations/20261125a_ar_pausa.sql -f ar_pausa_test.sql
-- ar_pausa_pre.sql cria, ANTES da migração, um aviso de ar ativo e perfis
-- com o ar ligado, como em produção.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.alerts WHERE status = 'ACTIVE' AND metadata->>'origem' = 'ar-cams'),
                       'aviso de ar ativo foi encerrado pela migração');
SELECT pg_temp.confere((SELECT body LIKE '%suspensos enquanto o modelo é validado%' FROM public.alerts
                         WHERE metadata->>'origem' = 'ar-cams'), 'texto do encerramento');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.alerts WHERE status = 'ACTIVE' AND metadata->>'origem' = 'telemetria-ana'),
                       'aviso de rio continua ativo');
SELECT pg_temp.confere((SELECT bool_and(notification_preferences->>'ar' = 'false') FROM public.user_profiles),
                       'ar = false em TODOS os perfis (inclusive quem não tinha a chave)');
SELECT pg_temp.confere((SELECT notification_preferences->>'min_severity' FROM public.user_profiles
                         WHERE id = '00000000-0000-0000-0000-0000000000a1') = 'HIGH', 'outras preferências preservadas');

-- Mesmo com dado acima de 120 por várias coletas, nenhum aviso novo.
UPDATE public.ar_regiao SET acima = 5;
SELECT pg_temp.confere(public.ar_atualizar_avisos(now()) = 0, 'nenhum aviso criado');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.alerts WHERE status = 'ACTIVE' AND metadata->>'origem' = 'ar-cams'),
                       'continua sem aviso de ar ativo');

-- App antigo regrava "ar": true. Mesmo assim um aviso de ar (simulado) não vai por push.
UPDATE public.user_profiles SET notification_preferences = notification_preferences || '{"ar": true}';
INSERT INTO public.alerts (region_id, title, body, severity, metadata)
VALUES ('a0000000-0000-0000-0000-000000000001', 'Ar simulado', 'x', 'CRITICAL', '{"origem":"ar-cams"}');
CREATE TEMP TABLE r AS SELECT * FROM public.push_reivindicar(20);
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM r WHERE token IS NOT NULL), 'ar: true do app antigo não religa o push');
-- Só quem tiver ar_optin explícito (app futuro) receberia.
UPDATE public.push_fila SET resultado = NULL, tentativas = 0, processado_em = NULL;
UPDATE public.user_profiles SET notification_preferences = notification_preferences || '{"ar_optin": true}'
 WHERE id = '00000000-0000-0000-0000-0000000000b1';
DROP TABLE r;
CREATE TEMP TABLE r AS SELECT * FROM public.push_reivindicar(20);
SELECT pg_temp.confere((SELECT count(*) FROM r WHERE token IS NOT NULL) = 1, 'ar_optin = true recebe');
-- Rio continua indo para todos.
INSERT INTO public.alerts (region_id, title, body, severity, metadata)
VALUES ('a0000000-0000-0000-0000-000000000001', 'Rio subindo', 'x', 'CRITICAL', '{"origem":"telemetria-ana"}');
DROP TABLE r;
CREATE TEMP TABLE r AS SELECT * FROM public.push_reivindicar(20);
SELECT pg_temp.confere((SELECT count(*) FROM r WHERE corpo = 'Rio subindo' AND token IS NOT NULL) = 2, 'push de rio inalterado');
ROLLBACK;
