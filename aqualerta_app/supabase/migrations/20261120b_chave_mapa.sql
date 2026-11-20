-- ============================================================
-- Chave do MapTiler fora da APK
--
-- A APK passa a ser baixável no site (atualização pelo app), então não pode
-- levar a chave do MapTiler. A chave fica no Vault do Supabase com o nome
-- `maptiler_key` (cadastrada pelo dono da conta no painel) e o app a pede
-- depois do login. Sem a chave no Vault, devolve NULL e o app usa os mapas
-- gratuitos. Quem não está logado não recebe nada.
-- Idempotente.
-- ============================================================
CREATE OR REPLACE FUNCTION public.chave_mapa()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    k text;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN NULL;
    END IF;
    BEGIN
        SELECT decrypted_secret INTO k
          FROM vault.decrypted_secrets
         WHERE name = 'maptiler_key'
         LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;
    RETURN nullif(btrim(k), '');
END $$;
REVOKE ALL ON FUNCTION public.chave_mapa() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.chave_mapa() TO authenticated;
