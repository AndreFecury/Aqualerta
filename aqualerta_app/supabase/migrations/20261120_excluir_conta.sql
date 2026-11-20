-- ============================================================
-- Excluir a própria conta (LGPD art. 18, VI; exigência da Play Store)
--
-- O app chama `excluir_minha_conta()` depois de a pessoa confirmar. Apaga o
-- usuário em auth.users; o resto vai junto por ON DELETE CASCADE:
--   user_profiles (nome, token de notificação, preferências)
--   user_monitored_regions (regiões seguidas)
-- (A fila de push é por alerta, não por pessoa: sem o token, nada mais é
-- enviado a este aparelho.) Nada disso tem volta.
-- Idempotente.
-- ============================================================
CREATE OR REPLACE FUNCTION public.excluir_minha_conta()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    uid uuid := auth.uid();
BEGIN
    IF uid IS NULL THEN
        RAISE EXCEPTION 'sem sessão' USING ERRCODE = '42501';
    END IF;
    DELETE FROM auth.users WHERE id = uid;
END $$;
REVOKE ALL ON FUNCTION public.excluir_minha_conta() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.excluir_minha_conta() TO authenticated;
