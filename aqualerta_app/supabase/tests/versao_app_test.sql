-- Teste da versão em uso e da limpeza automática (20261123_versao_app.sql).
-- PostGIS LOCAL apenas:
--   psql -f stub_base.sql -f ar_stubs.sql -f sinal_dados_stubs.sql
--        -f versao_app_stubs.sql -f ../migrations/20261123_versao_app.sql
--        -f versao_app_test.sql
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.publicadas() RETURNS text LANGUAGE sql AS
$$ SELECT string_agg(tablename, ',' ORDER BY tablename) FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' $$;
CREATE OR REPLACE FUNCTION pg_temp.como(u text) RETURNS void LANGUAGE sql AS
$$ SELECT set_config('request.jwt.claim.sub', u, true) $$;

SELECT pg_temp.confere(pg_temp.publicadas() = 'alerts,flood_events,hydro_readings', 'publicação antes: as três tabelas');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'realtime-limpar-antigo'
                                  AND command LIKE '%realtime_limpar_publicacao_antiga%'), 'agendamento diário criado');

-- A: usa o app novo. B: usa 4.9.1 (nunca informa). C: sumiu há 30 dias.
INSERT INTO public.user_profiles (id, fcm_token) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'tok-a'),
  ('00000000-0000-0000-0000-0000000000b1', 'tok-b');
INSERT INTO auth.sessions (user_id, created_at, updated_at, refreshed_at) VALUES
  ('00000000-0000-0000-0000-0000000000a1', now() - interval '20 days', now() - interval '20 days', (now() - interval '1 hour')::timestamp),
  ('00000000-0000-0000-0000-0000000000b1', now() - interval '3 days', now() - interval '2 days', NULL),
  ('00000000-0000-0000-0000-0000000000c1', now() - interval '40 days', now() - interval '30 days', (now() - interval '30 days')::timestamp);

-- Registro: sem login não faz nada; valores absurdos são ignorados.
SELECT pg_temp.como('');
SELECT public.registrar_versao_app(53);
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE app_build IS NOT NULL), 'sem login: nada gravado');
SELECT pg_temp.como('00000000-0000-0000-0000-0000000000a1');
SELECT public.registrar_versao_app(-5);
SELECT public.registrar_versao_app(NULL);
SELECT pg_temp.confere((SELECT app_build FROM public.user_profiles WHERE id = '00000000-0000-0000-0000-0000000000a1') IS NULL,
                       'build negativo ou nulo é ignorado');

-- Nenhum aparelho informou ainda: não mexe (prova de que o registro funciona).
SELECT pg_temp.como('');
SELECT pg_temp.confere(public.realtime_limpar_publicacao_antiga() = 'aguardando: 2 em versão antiga, 0 em versão nova',
                       'sem nenhum build novo informado, espera');

SELECT pg_temp.como('00000000-0000-0000-0000-0000000000a1');
SELECT public.registrar_versao_app(53);
SELECT pg_temp.confere((SELECT app_build = 53 AND app_visto_em > now() - interval '1 minute' AND fcm_token = 'tok-a'
                          FROM public.user_profiles WHERE id = '00000000-0000-0000-0000-0000000000a1'),
                       'A gravado com build 53, token intacto');
SELECT pg_temp.confere((SELECT count(*) FROM public.versoes_em_uso(14)) = 2, 'ativos em 14 dias: A e B (C sumiu)');

-- B ainda em versão antiga: espera e mantém tudo.
SELECT pg_temp.como('');
SELECT pg_temp.confere(public.realtime_limpar_publicacao_antiga() = 'aguardando: 1 em versão antiga, 1 em versão nova',
                       'B sem build informado segura a limpeza');
SELECT pg_temp.confere(pg_temp.publicadas() = 'alerts,flood_events,hydro_readings', 'publicação intacta');

-- B informa o build 50 (ainda antigo), depois atualiza para o 53; D é um
-- usuário novo, sem perfil e sem sessão, que também registra.
SELECT pg_temp.como('00000000-0000-0000-0000-0000000000b1');
SELECT public.registrar_versao_app(50);
SELECT pg_temp.como('');
SELECT pg_temp.confere(public.realtime_limpar_publicacao_antiga() LIKE 'aguardando: 1 em versão antiga%',
                       'build 50 ainda conta como antigo');
SELECT pg_temp.como('00000000-0000-0000-0000-0000000000b1');
SELECT public.registrar_versao_app(53);
SELECT pg_temp.como('00000000-0000-0000-0000-0000000000d1');
SELECT public.registrar_versao_app(53);
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.user_profiles WHERE id = '00000000-0000-0000-0000-0000000000d1' AND app_build = 53),
                       'perfil criado para quem ainda não tinha');

-- Todos os ativos no novo: tira alerts e flood_events e desliga o agendamento.
SELECT pg_temp.como('');
SELECT pg_temp.confere(public.realtime_limpar_publicacao_antiga() = 'feito: 2 ativos em versão nova; tiradas da publicação: alerts, flood_events',
                       'limpeza feita');
SELECT pg_temp.confere(pg_temp.publicadas() = 'hydro_readings', 'só sobrou o que já estava (hydro_readings sai pela 20261121b)');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'realtime-limpar-antigo'), 'agendamento desligado');

-- Permissões: o app só registra; o resto é do servidor.
SELECT pg_temp.confere(has_function_privilege('authenticated', 'public.registrar_versao_app(integer)', 'EXECUTE')
                   AND NOT has_function_privilege('anon', 'public.registrar_versao_app(integer)', 'EXECUTE')
                   AND NOT has_function_privilege('authenticated', 'public.versoes_em_uso(integer)', 'EXECUTE')
                   AND NOT has_function_privilege('authenticated', 'public.realtime_limpar_publicacao_antiga(integer)', 'EXECUTE'),
                       'permissões: só registrar_versao_app para quem está logado');
ROLLBACK;
