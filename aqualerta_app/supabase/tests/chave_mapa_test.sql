-- Teste de chave_mapa() num PostGIS LOCAL (imita auth e vault do Supabase).
\set ON_ERROR_STOP 1
BEGIN;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
CREATE SCHEMA IF NOT EXISTS vault;
CREATE TABLE IF NOT EXISTS vault.decrypted_secrets (name text PRIMARY KEY, decrypted_secret text);
\i /s/migrations/20261120b_chave_mapa.sql
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
DELETE FROM vault.decrypted_secrets WHERE name = 'maptiler_key';

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
SELECT pg_temp.confere(public.chave_mapa() IS NULL, 'sem chave no Vault: NULL (app usa mapas gratuitos)');
INSERT INTO vault.decrypted_secrets VALUES ('maptiler_key', '  ChaveDeTeste123  ');
SELECT pg_temp.confere(public.chave_mapa() = 'ChaveDeTeste123', 'logado recebe a chave (sem espaços)');
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT pg_temp.confere(public.chave_mapa() IS NULL, 'sem login não recebe nada');
SELECT pg_temp.confere(NOT has_function_privilege('anon', 'public.chave_mapa()', 'EXECUTE'), 'anon sem permissão');
SELECT pg_temp.confere(has_function_privilege('authenticated', 'public.chave_mapa()', 'EXECUTE'), 'authenticated pode');
ROLLBACK;
\echo 'chave_mapa_test: TODOS OK'
