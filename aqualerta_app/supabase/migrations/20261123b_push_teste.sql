-- ============================================================
-- AQUALERTA — Push de teste só para um usuário
--
-- push_teste(usuario) põe na fila um aviso de cada tipo (cheia em cada
-- severidade, subiu/baixou, chuva, ar), com o título começando por
-- "TESTE · ". Vai SÓ para o aparelho desse usuário, ignorando as
-- preferências (é teste), e não cria nenhum alerta: ninguém mais vê nada
-- no app e nenhum outro aparelho recebe push.
--
-- A Edge Function push-alertas não muda: o item de teste chega a ela como
-- qualquer outro, com um id próprio no lugar do id do alerta.
-- Uso (SQL Editor do painel):  SELECT public.push_teste('<uuid do usuário>');
-- ============================================================

ALTER TABLE public.push_fila ALTER COLUMN alert_id DROP NOT NULL;
ALTER TABLE public.push_fila
    ADD COLUMN IF NOT EXISTS teste_para   uuid REFERENCES auth.users(id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS teste_origem text,
    ADD COLUMN IF NOT EXISTS teste_id     uuid NOT NULL DEFAULT gen_random_uuid();
DO $$ BEGIN
    ALTER TABLE public.push_fila ADD CONSTRAINT push_fila_alerta_ou_teste
        CHECK (alert_id IS NOT NULL OR (teste_para IS NOT NULL AND teste_origem IN ('cheia', 'chuva', 'ar')));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Título do push, igual para avisos reais e de teste.
CREATE OR REPLACE FUNCTION public.push_titulo(ar boolean, severidade text, motivo text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE WHEN ar THEN
               CASE severidade WHEN 'CRITICAL' THEN 'Ar péssimo: evite sair de casa'
                               ELSE 'Ar muito ruim: proteja-se' END
           ELSE
               CASE severidade
                   WHEN 'CRITICAL' THEN 'Saia de áreas de risco: risco crítico'
                   WHEN 'HIGH'     THEN 'Prepare-se: risco alto'
                   WHEN 'MEDIUM'   THEN 'Fique atento: risco médio'
                   ELSE                 'Situação normal: risco baixo' END
           END
           || CASE motivo WHEN 'subiu' THEN ' (subiu)' WHEN 'baixou' THEN ' (baixou)' ELSE '' END
$$;

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
                OR coalesce((p.notification_preferences->>'ar')::boolean, true))
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

-- Igual à de 20261118_push_fcm.sql, mas só registra entrega de alerta real
-- (o id de um teste não existe em alerts).
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
       AND EXISTS (SELECT 1 FROM public.alerts a WHERE a.id = (e->>'alert_id')::uuid)
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

-- Um aviso de cada tipo para [usuario]. Só o servidor/painel chama.
CREATE OR REPLACE FUNCTION public.push_teste(usuario uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    n integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.user_profiles
                    WHERE id = usuario AND fcm_token IS NOT NULL AND fcm_token <> '') THEN
        RAISE EXCEPTION 'usuário sem aparelho registrado para push';
    END IF;
    INSERT INTO public.push_fila (alert_id, severity, motivo, teste_para, teste_origem)
    VALUES (NULL, 'MEDIUM',   'novo',   usuario, 'cheia'),
           (NULL, 'HIGH',     'subiu',  usuario, 'cheia'),
           (NULL, 'CRITICAL', 'subiu',  usuario, 'cheia'),
           (NULL, 'LOW',      'baixou', usuario, 'cheia'),
           (NULL, 'HIGH',     'novo',   usuario, 'chuva'),
           (NULL, 'HIGH',     'novo',   usuario, 'ar'),
           (NULL, 'CRITICAL', 'subiu',  usuario, 'ar');
    GET DIAGNOSTICS n = ROW_COUNT;
    PERFORM public.push_cutucar();
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.push_teste(uuid) FROM PUBLIC, anon, authenticated;
