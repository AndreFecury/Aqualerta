-- Teste de excluir_minha_conta() num PostGIS LOCAL (imita auth do Supabase).
\set ON_ERROR_STOP 1
BEGIN;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY, email text);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
CREATE TABLE IF NOT EXISTS public.user_profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE, display_name text, fcm_token text);
CREATE TABLE IF NOT EXISTS public.user_monitored_regions (
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE, region_id uuid);
\i /s/migrations/20261120_excluir_conta.sql
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-0000000000a1', 'a@x.org'),
                              ('00000000-0000-0000-0000-0000000000b2', 'b@x.org');
INSERT INTO public.user_profiles VALUES ('00000000-0000-0000-0000-0000000000a1', 'A', 'tok-a'),
                                        ('00000000-0000-0000-0000-0000000000b2', 'B', 'tok-b');
INSERT INTO public.user_monitored_regions VALUES ('00000000-0000-0000-0000-0000000000a1', gen_random_uuid()),
                                                 ('00000000-0000-0000-0000-0000000000b2', gen_random_uuid());

-- Sem sessão: recusa e não apaga nada.
DO $$ BEGIN
  PERFORM public.excluir_minha_conta();
  RAISE EXCEPTION 'FALHOU: deveria recusar sem sessão';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'ok: sem sessão é recusado';
END $$;
SELECT pg_temp.confere((SELECT count(*) FROM auth.users) = 2, 'ninguém apagado sem sessão');

-- Logado como A: apaga só A, com perfil, token e regiões.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
SELECT public.excluir_minha_conta();
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM auth.users WHERE email = 'a@x.org'), 'conta de A apagada');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE fcm_token = 'tok-a'), 'perfil e token de A apagados');
SELECT pg_temp.confere((SELECT count(*) FROM public.user_monitored_regions) = 1, 'regiões de A apagadas');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.user_profiles WHERE fcm_token = 'tok-b'), 'B intacto');
-- Chamar de novo (sessão já sem usuário) não quebra.
SELECT public.excluir_minha_conta();
SELECT pg_temp.confere((SELECT count(*) FROM auth.users) = 1, 'segunda chamada não apaga mais ninguém');

-- anon não pode executar.
SELECT pg_temp.confere(NOT has_function_privilege('anon', 'public.excluir_minha_conta()', 'EXECUTE'), 'anon sem permissão');
SELECT pg_temp.confere(has_function_privilege('authenticated', 'public.excluir_minha_conta()', 'EXECUTE'), 'authenticated pode');
ROLLBACK;
\echo 'excluir_conta_test: TODOS OK'
