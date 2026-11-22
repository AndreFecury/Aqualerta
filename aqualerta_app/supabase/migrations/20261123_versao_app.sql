-- ============================================================
-- AQUALERTA — Versão do app em uso e limpeza automática do tempo real antigo
--
-- 1. O app (a partir do build 53) chama registrar_versao_app(build) ao abrir
--    com alguém logado. Fica em user_profiles.app_build / app_visto_em.
-- 2. Os apps até o build 50 (4.9.1) ouvem mudanças de alerts e flood_events
--    pela publicação supabase_realtime; do build 51 em diante, o app ouve
--    só o sinal de 1 mensagem/min (20261121b_sinal_dados.sql).
-- 3. Todo dia, realtime_limpar_publicacao_antiga() confere quem usou o app
--    nos últimos 14 dias (sessão renovada em auth.sessions). Quando NINGUÉM
--    ativo estiver num build antigo (ou sem build informado, que é o caso
--    de quem ainda não atualizou), tira alerts e flood_events da publicação
--    e desliga o próprio agendamento. Nada a fazer à mão.
-- ============================================================

ALTER TABLE public.user_profiles
    ADD COLUMN IF NOT EXISTS app_build    integer,
    ADD COLUMN IF NOT EXISTS app_visto_em timestamptz;

CREATE OR REPLACE FUNCTION public.registrar_versao_app(p_build integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    uid uuid := auth.uid();
BEGIN
    IF uid IS NULL OR p_build IS NULL OR p_build NOT BETWEEN 1 AND 100000 THEN
        RETURN;
    END IF;
    INSERT INTO public.user_profiles (id, app_build, app_visto_em)
    VALUES (uid, p_build, now())
    ON CONFLICT (id) DO UPDATE
        SET app_build = excluded.app_build, app_visto_em = excluded.app_visto_em;
END $$;
REVOKE ALL ON FUNCTION public.registrar_versao_app(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_versao_app(integer) TO authenticated;

-- Quem usou o app nos últimos [dias] e em que build está (NULL = não informou,
-- ou seja, build 52 ou anterior). Só para o servidor e para o painel.
CREATE OR REPLACE FUNCTION public.versoes_em_uso(dias integer DEFAULT 14)
RETURNS TABLE (usuario uuid, app_build integer, app_visto_em timestamptz, ultimo_uso timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
    SELECT s.user_id, p.app_build, p.app_visto_em, max(coalesce(s.refreshed_at::timestamptz, s.updated_at, s.created_at))
      FROM auth.sessions s
      LEFT JOIN public.user_profiles p ON p.id = s.user_id
     GROUP BY s.user_id, p.app_build, p.app_visto_em
    HAVING max(coalesce(s.refreshed_at::timestamptz, s.updated_at, s.created_at)) > now() - make_interval(days => dias)
$$;
REVOKE ALL ON FUNCTION public.versoes_em_uso(integer) FROM PUBLIC, anon, authenticated;

-- Build a partir do qual o app não precisa mais das tabelas na publicação.
CREATE OR REPLACE FUNCTION public.realtime_limpar_publicacao_antiga(build_minimo integer DEFAULT 51)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    antigos  integer;
    novos    integer;
    t        text;
    tiradas  text[] := '{}';
BEGIN
    SELECT count(*) FILTER (WHERE v.app_build IS NULL OR v.app_build < build_minimo),
           count(*) FILTER (WHERE v.app_build >= build_minimo)
      INTO antigos, novos
      FROM public.versoes_em_uso(14) v;
    -- Só age depois que algum aparelho provou que o registro de versão funciona.
    IF antigos > 0 OR novos = 0 THEN
        RETURN format('aguardando: %s em versão antiga, %s em versão nova', antigos, novos);
    END IF;
    FOREACH t IN ARRAY ARRAY['alerts', 'flood_events'] LOOP
        IF EXISTS (SELECT 1 FROM pg_publication_tables
                    WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
                      AND tablename = t) THEN
            EXECUTE format('ALTER PUBLICATION supabase_realtime DROP TABLE public.%I', t);
            tiradas := tiradas || t;
        END IF;
    END LOOP;
    PERFORM cron.unschedule('realtime-limpar-antigo');
    RETURN format('feito: %s ativos em versão nova; tiradas da publicação: %s',
                  novos, coalesce(nullif(array_to_string(tiradas, ', '), ''), 'nenhuma'));
END $$;
REVOKE ALL ON FUNCTION public.realtime_limpar_publicacao_antiga(integer) FROM PUBLIC, anon, authenticated;

-- 06:20 UTC = 02:20 em Manaus.
SELECT cron.schedule('realtime-limpar-antigo', '20 6 * * *',
                     'SELECT public.realtime_limpar_publicacao_antiga()');
