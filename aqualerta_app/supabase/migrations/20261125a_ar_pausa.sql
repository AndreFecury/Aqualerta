-- ============================================================
-- AQUALERTA — Fase 0: avisos de qualidade do ar suspensos
--
-- Até o modelo ser validado contra sensores (fases 1 a 4):
--   1. ar_atualizar_avisos() não cria mais aviso de ar; só encerra o que
--      estiver ativo. A coleta e o ar_resumo continuam (o cartão segue
--      mostrando a estimativa).
--   2. Avisos de ar ativos são encerrados agora.
--   3. Push de ar desligado para TODOS: notification_preferences.ar = false
--      em todos os perfis, e o servidor passa a decidir pelo campo novo
--      "ar_optin" (padrão: desligado). O app atual regrava "ar": true a
--      cada mudança de preferência; como o servidor não lê mais "ar", isso
--      não religa nada. Só um app futuro, com opção explícita, grava
--      "ar_optin".
-- ============================================================

CREATE OR REPLACE FUNCTION public.ar_atualizar_avisos(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    n integer;
BEGIN
    UPDATE public.alerts
       SET status = 'RESOLVED', resolved_at = p_agora, valid_until = p_agora,
           body = body || ' Encerrado: avisos de qualidade do ar suspensos enquanto o modelo é validado com sensores.'
     WHERE status = 'ACTIVE' AND metadata->>'origem' = 'ar-cams';
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.ar_atualizar_avisos(timestamptz) FROM PUBLIC, anon, authenticated;

SELECT public.ar_atualizar_avisos();

UPDATE public.user_profiles
   SET notification_preferences = jsonb_set(coalesce(notification_preferences, '{}'::jsonb), '{ar}', 'false'::jsonb, true)
 WHERE coalesce(notification_preferences->>'ar', 'true') <> 'false';

-- Igual à de 20261123b_push_teste.sql, trocando só a regra do ar:
-- antes  coalesce(ar, true)  ->  agora  coalesce(ar_optin, false).
CREATE OR REPLACE FUNCTION public.push_reivindicar(limite integer DEFAULT 20)
RETURNS TABLE (fila_id bigint, alert_id uuid, user_id uuid, token text,
               titulo text, corpo text, severity text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    WITH pegos AS (
        UPDATE public.push_fila f
           SET processado_em = now(), tentativas = f.tentativas + 1
         WHERE f.id IN (
            SELECT q.id FROM public.push_fila q
             WHERE q.resultado IS NULL
               AND q.tentativas < 3
               AND (q.processado_em IS NULL OR q.processado_em < now() - interval '10 minutes')
             ORDER BY q.id
             LIMIT limite
             FOR UPDATE SKIP LOCKED)
        RETURNING f.id, f.alert_id, f.severity, f.motivo, f.teste_para, f.teste_origem, f.teste_id
    ), destinos AS (
        SELECT DISTINCT ON (pg.id, p.fcm_token)
               pg.id AS fila_id, a.id AS alert_id, p.id AS user_id, p.fcm_token AS token,
               public.push_titulo(a.metadata->>'origem' = 'ar-cams', a.severity, pg.motivo) AS titulo,
               a.title AS corpo,
               a.severity
          FROM pegos pg
          JOIN public.alerts a ON a.id = pg.alert_id
                              AND a.status = 'ACTIVE'
                              AND a.severity = pg.severity   -- mudou de novo? vale o item mais novo
          JOIN public.user_monitored_regions umr ON umr.region_id = a.region_id
                                                AND coalesce(umr.notify, true)
          JOIN public.user_profiles p ON p.id = umr.user_id
         WHERE p.fcm_token IS NOT NULL AND p.fcm_token <> ''
           AND coalesce((p.notification_preferences->>'push')::boolean, true)
           AND public.severidade_ordem(a.severity)
               >= public.severidade_ordem(coalesce(p.notification_preferences->>'min_severity', 'MEDIUM'))
           AND (a.metadata->>'origem' IS DISTINCT FROM 'ar-cams'
                OR coalesce((p.notification_preferences->>'ar_optin')::boolean, false))
         ORDER BY pg.id, p.fcm_token, p.updated_at DESC NULLS LAST
    ), testes AS (
        SELECT pg.id AS fila_id, pg.teste_id AS alert_id, p.id AS user_id, p.fcm_token AS token,
               'TESTE · ' || public.push_titulo(pg.teste_origem = 'ar', pg.severity, pg.motivo) AS titulo,
               'Notificação de teste do AquaAlerta (' ||
                   CASE pg.teste_origem WHEN 'chuva' THEN 'chuva forte'
                                        WHEN 'ar' THEN 'qualidade do ar'
                                        ELSE 'cheia' END
                   || '). Não é um alerta real.' AS corpo,
               pg.severity
          FROM pegos pg
          JOIN public.user_profiles p ON p.id = pg.teste_para
         WHERE pg.alert_id IS NULL
           AND p.fcm_token IS NOT NULL AND p.fcm_token <> ''
    )
    SELECT d.fila_id, d.alert_id, d.user_id, d.token, d.titulo, d.corpo, d.severity FROM destinos d
    UNION ALL
    SELECT t.fila_id, t.alert_id, t.user_id, t.token, t.titulo, t.corpo, t.severity FROM testes t
    UNION ALL
    SELECT pg.id, coalesce(pg.alert_id, pg.teste_id), NULL, NULL, NULL, NULL, pg.severity
      FROM pegos pg
     WHERE NOT EXISTS (SELECT 1 FROM destinos d WHERE d.fila_id = pg.id)
       AND NOT EXISTS (SELECT 1 FROM testes t WHERE t.fila_id = pg.id);
END $$;
REVOKE ALL ON FUNCTION public.push_reivindicar(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_reivindicar(integer) TO service_role;
