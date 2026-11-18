-- ============================================================
-- AQUALERTA — Push com o app fechado (Firebase Cloud Messaging HTTP v1)
--
-- Fluxo:
--   1. Um alerta ACTIVE é criado ou muda de severidade
--      -> o gatilho põe uma linha em public.push_fila e "cutuca" a Edge
--         Function push-alertas (pg_net, só depois do COMMIT).
--   2. A função chama push_reivindicar(): pega a fila pendente e recebe a
--      lista de aparelhos (token FCM) de quem segue a região, com o aviso
--      ligado e a severidade mínima atendida.
--   3. A função envia pelo FCM e devolve o resultado em push_concluir():
--      grava o resultado, registra a entrega e apaga tokens inválidos.
--
-- A função não recebe dados de quem a chama: só processa a fila. Chamar a
-- função de novo não reenvia nada. A chave da conta de serviço do Firebase
-- fica SÓ no segredo FCM_SERVICE_ACCOUNT da Edge Function.
-- ============================================================

-- Ordem das severidades (para comparar com a mínima escolhida no app).
CREATE OR REPLACE FUNCTION public.severidade_ordem(s text)
RETURNS integer LANGUAGE sql IMMUTABLE
AS $$ SELECT CASE upper(s) WHEN 'LOW' THEN 0 WHEN 'MEDIUM' THEN 1
                           WHEN 'HIGH' THEN 2 WHEN 'CRITICAL' THEN 3 ELSE 1 END $$;

-- ------------------------------------------------------------
-- Fila de envios
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.push_fila (
    id            BIGSERIAL PRIMARY KEY,
    alert_id      UUID NOT NULL REFERENCES public.alerts(id) ON DELETE CASCADE,
    severity      TEXT NOT NULL,
    motivo        TEXT NOT NULL CHECK (motivo IN ('novo','subiu','baixou')),
    criado_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
    processado_em TIMESTAMPTZ,
    tentativas    INTEGER NOT NULL DEFAULT 0,
    resultado     JSONB
);
CREATE INDEX IF NOT EXISTS idx_push_fila_pendente
    ON public.push_fila (id) WHERE resultado IS NULL;
-- Só o servidor mexe na fila (RLS ligado e sem política para o app).
ALTER TABLE public.push_fila ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_fila FROM anon, authenticated;

-- Endereço da Edge Function (não é segredo).
CREATE OR REPLACE FUNCTION public.push_cutucar()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
    PERFORM net.http_post(
        url     := 'https://gayykjlkdtmmzovdbjkb.supabase.co/functions/v1/push-alertas',
        body    := '{}'::jsonb,
        headers := '{"Content-Type": "application/json"}'::jsonb,
        timeout_milliseconds := 30000);
EXCEPTION WHEN OTHERS THEN
    -- Nunca derruba a atualização dos alertas: o cron passa de novo depois.
    RAISE WARNING 'push_cutucar: %', SQLERRM;
END $$;
REVOKE ALL ON FUNCTION public.push_cutucar() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Gatilho: alerta novo ou mudança de severidade
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.alerts_enfileirar_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    m text;
BEGIN
    IF NEW.status <> 'ACTIVE' THEN RETURN NEW; END IF;
    IF TG_OP = 'INSERT' THEN
        m := 'novo';
    ELSIF OLD.severity IS DISTINCT FROM NEW.severity THEN
        m := CASE WHEN public.severidade_ordem(NEW.severity) > public.severidade_ordem(OLD.severity)
                  THEN 'subiu' ELSE 'baixou' END;
    ELSE
        RETURN NEW;
    END IF;
    INSERT INTO public.push_fila (alert_id, severity, motivo) VALUES (NEW.id, NEW.severity, m);
    PERFORM public.push_cutucar();
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_alerts_push ON public.alerts;
CREATE TRIGGER trg_alerts_push
    AFTER INSERT OR UPDATE OF severity ON public.alerts
    FOR EACH ROW EXECUTE FUNCTION public.alerts_enfileirar_push();

-- ------------------------------------------------------------
-- Usado pela Edge Function (service_role)
-- ------------------------------------------------------------
-- Pega até `limite` itens da fila e devolve um destinatário por linha.
-- Itens presos (função caiu no meio) voltam depois de 10 min, até 3 vezes.
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
        RETURNING f.id, f.alert_id, f.severity, f.motivo
    ), destinos AS (
        SELECT DISTINCT ON (pg.id, p.fcm_token)
               pg.id AS fila_id, a.id AS alert_id, p.id AS user_id, p.fcm_token AS token,
               CASE a.severity
                   WHEN 'CRITICAL' THEN 'Saia de áreas de risco: risco crítico'
                   WHEN 'HIGH'     THEN 'Prepare-se: risco alto'
                   WHEN 'MEDIUM'   THEN 'Fique atento: risco médio'
                   ELSE                 'Situação normal: risco baixo' END
               || CASE pg.motivo WHEN 'subiu' THEN ' (subiu)' WHEN 'baixou' THEN ' (baixou)' ELSE '' END
                   AS titulo,
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
         ORDER BY pg.id, p.fcm_token, p.updated_at DESC NULLS LAST
    )
    SELECT d.fila_id, d.alert_id, d.user_id, d.token, d.titulo, d.corpo, d.severity FROM destinos d
    UNION ALL
    -- Itens sem nenhum destinatário também aparecem (token NULL), para a
    -- função fechá-los com o resultado "sem destinatários".
    SELECT pg.id, pg.alert_id, NULL, NULL, NULL, NULL, pg.severity
      FROM pegos pg WHERE NOT EXISTS (SELECT 1 FROM destinos d WHERE d.fila_id = pg.id);
END $$;
REVOKE ALL ON FUNCTION public.push_reivindicar(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_reivindicar(integer) TO service_role;

-- Recebe [{fila_id, alert_id, user_id, token, ok, erro, invalido}] e fecha os itens.
CREATE OR REPLACE FUNCTION public.push_concluir(envios jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    n integer;
BEGIN
    -- Entregas aceitas pelo FCM
    INSERT INTO public.alert_deliveries (alert_id, user_id, delivered_via, delivered_at)
    SELECT DISTINCT (e->>'alert_id')::uuid, (e->>'user_id')::uuid, 'FCM', now()
      FROM jsonb_array_elements(envios) e
     WHERE (e->>'ok')::boolean AND e->>'user_id' IS NOT NULL
    ON CONFLICT (alert_id, user_id, delivered_via) DO UPDATE SET delivered_at = excluded.delivered_at;

    -- Tokens que o FCM disse que não existem mais
    UPDATE public.user_profiles p SET fcm_token = NULL
     WHERE p.fcm_token IN (SELECT e->>'token' FROM jsonb_array_elements(envios) e
                            WHERE coalesce((e->>'invalido')::boolean, false));

    -- Resultado por item da fila (sem os tokens)
    UPDATE public.push_fila f
       SET resultado = r.res
      FROM (SELECT (e->>'fila_id')::bigint AS id,
                   jsonb_build_object(
                       'enviados', count(*) FILTER (WHERE (e->>'ok')::boolean),
                       'falhas',   count(*) FILTER (WHERE NOT (e->>'ok')::boolean AND e->>'token' IS NOT NULL),
                       'invalidos', count(*) FILTER (WHERE coalesce((e->>'invalido')::boolean, false)),
                       'erros', coalesce(jsonb_agg(DISTINCT e->>'erro') FILTER (WHERE e->>'erro' IS NOT NULL), '[]'::jsonb)
                   ) AS res
              FROM jsonb_array_elements(envios) e
             GROUP BY 1) r
     WHERE f.id = r.id;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.push_concluir(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_concluir(jsonb) TO service_role;

-- ------------------------------------------------------------
-- Usado pelo app (usuário logado)
-- ------------------------------------------------------------
-- Guarda o token deste aparelho no perfil de quem está logado e tira o
-- mesmo token de qualquer outro perfil (aparelho que trocou de conta).
CREATE OR REPLACE FUNCTION public.registrar_token_push(p_token text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    uid uuid := auth.uid();
BEGIN
    IF uid IS NULL OR p_token IS NULL OR length(p_token) NOT BETWEEN 20 AND 4096 THEN
        RETURN;
    END IF;
    UPDATE public.user_profiles SET fcm_token = NULL, updated_at = now()
     WHERE fcm_token = p_token AND id <> uid;
    INSERT INTO public.user_profiles (id, fcm_token) VALUES (uid, p_token)
    ON CONFLICT (id) DO UPDATE SET fcm_token = excluded.fcm_token, updated_at = now();
END $$;
REVOKE ALL ON FUNCTION public.registrar_token_push(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_token_push(text) TO authenticated;

-- Chamado antes de sair da conta: este aparelho para de receber os avisos dela.
CREATE OR REPLACE FUNCTION public.remover_token_push(p_token text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
    UPDATE public.user_profiles SET fcm_token = NULL, updated_at = now()
     WHERE id = auth.uid() AND (p_token IS NULL OR fcm_token = p_token);
$$;
REVOKE ALL ON FUNCTION public.remover_token_push(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remover_token_push(text) TO authenticated;

-- ------------------------------------------------------------
-- Rede de segurança: passa na fila 2 min depois de cada atualização dos
-- alertas (que roda às :07 e :37), caso a cutucada do gatilho tenha falhado.
-- ------------------------------------------------------------
SELECT cron.schedule('push-alertas', '9,39 * * * *',
    $c$ SELECT public.push_cutucar() WHERE EXISTS (
          SELECT 1 FROM public.push_fila WHERE resultado IS NULL AND tentativas < 3) $c$);
