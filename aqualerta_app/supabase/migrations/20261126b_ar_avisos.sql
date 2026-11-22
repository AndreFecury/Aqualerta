-- ============================================================
-- AQUALERTA — Fase 3: avisos de qualidade do ar pelo SENSOR, fora de alerts
--
-- Decisões de 22/11/2026:
--   - aviso só onde há sensor saudável, pelo "índice em tempo quase real"
--     (NowCast da EPA, média ponderada de 12 h; NÃO é o IQAr oficial do MMA);
--   - abre com NowCast > 75 µg/m³ por 2 h seguidas; fecha com 3 h seguidas
--     abaixo (histerese); fecha também se o sensor parar de mandar dados;
--   - NowCast > 125 µg/m³ = "Péssima" (CRITICAL); senão "Muito ruim" (HIGH);
--   - só nas regiões com ar_aviso_sensor.ligado = true. HOJE NENHUMA: Manaus é
--     candidata e só liga depois do teste de 2027 (pré-registro v2);
--   - tabela própria (ar_avisos) e push só para quem escolheu (ar_optin), por
--     região seguida; o modelo nunca abre aviso.
-- Série usada: o MP2,5 como a OpenAQ entrega (o teste de out/2026 em Manaus
-- passou nas duas séries; a escolha recebido × corrigido segue em aberto).
-- ============================================================

INSERT INTO public.ar_config (chave, valor, descricao) VALUES
  ('aviso_limite_ugm3',  75, 'Aviso por sensor: NowCast acima disto (µg/m³) abre o aviso'),
  ('aviso_critico_ugm3', 125, 'Aviso por sensor: NowCast acima disto vira "Péssima" (CRITICAL)')
ON CONFLICT (chave) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.ar_avisos (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    region_id      uuid NOT NULL REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    severity       text NOT NULL CHECK (severity IN ('HIGH', 'CRITICAL')),
    fonte          text NOT NULL DEFAULT 'sensor' CHECK (fonte = 'sensor'),
    limite_ugm3    numeric NOT NULL,
    nowcast_atual  numeric,
    nowcast_max    numeric,
    inicio         timestamptz NOT NULL,
    fim            timestamptz,
    situacao       text NOT NULL DEFAULT 'ativo' CHECK (situacao IN ('ativo', 'encerrado')),
    motivo_fim     text,
    atualizado_em  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ar_avisos_um_ativo ON public.ar_avisos (region_id) WHERE situacao = 'ativo';
ALTER TABLE public.ar_avisos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ar_avisos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.ar_avisos TO authenticated;
DROP POLICY IF EXISTS ar_avisos_leitura ON public.ar_avisos;
CREATE POLICY ar_avisos_leitura ON public.ar_avisos FOR SELECT TO authenticated USING (true);

-- NowCast da EPA (MP2,5) por região e hora, a partir dos pares válidos.
CREATE OR REPLACE FUNCTION public.ar_nowcast(p_origem text, p_desde timestamptz, p_ate timestamptz)
RETURNS TABLE (region_id uuid, hora timestamptz, nowcast numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH h AS (
        SELECT v.region_id, v.hora, v.sensor_pm25 AS c
          FROM public.ar_validacao_horas v
         -- só o sensor importa aqui (o aviso não depende do modelo); horas travadas
         -- ou com salto já ficam fora de sensor_pm25 (sensores_n = 0).
         WHERE v.origem = p_origem AND v.sensores_n > 0 AND v.sensor_pm25 IS NOT NULL
           AND v.hora >= p_desde - interval '11 hours' AND v.hora < p_ate
    ), janela AS (
        SELECT t.region_id, t.hora, (extract(epoch FROM t.hora - x.hora) / 3600)::int + 1 AS i, x.c
          FROM h t
          JOIN h x ON x.region_id = t.region_id AND x.hora <= t.hora AND x.hora > t.hora - interval '12 hours'
         WHERE t.hora >= p_desde
    ), w AS (
        SELECT j.region_id, j.hora,
               greatest(CASE WHEN max(j.c) > 0 THEN min(j.c) / max(j.c) ELSE 1 END, 0.5) AS w,
               count(*) FILTER (WHERE j.i <= 3) AS recentes
          FROM janela j GROUP BY j.region_id, j.hora
    )
    SELECT j.region_id, j.hora, round(sum(power(w.w, j.i - 1) * j.c) / sum(power(w.w, j.i - 1)), 1)
      FROM janela j JOIN w ON w.region_id = j.region_id AND w.hora = j.hora
     WHERE w.recentes >= 2
     GROUP BY j.region_id, j.hora
$$;
REVOKE ALL ON FUNCTION public.ar_nowcast(text, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;

-- Abre, atualiza e fecha avisos. Recalcula sempre as últimas 48 h (resultado
-- determinístico, mesmo se uma rodada falhar).
CREATE OR REPLACE FUNCTION public.ar_avisos_atualizar(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    reg    record;
    h      record;
    atual  public.ar_avisos;
    limite numeric := public.ar_cfg('aviso_limite_ugm3');
    critico numeric := public.ar_cfg('aviso_critico_ugm3');
    abre   integer := public.ar_cfg('aviso_horas_seguidas');
    fecha  integer := public.ar_cfg('aviso_fim_horas');
    acima integer; abaixo integer; ativo boolean; ant timestamptz;
    v_inicio timestamptz; v_fim timestamptz; maior numeric; ultimo numeric; ultima_hora timestamptz;
    sev text;
    mudancas integer := 0;
BEGIN
    FOR reg IN
        SELECT r.id, coalesce(a.ligado, false) AS ligado
          FROM public.monitored_regions r
          LEFT JOIN public.ar_aviso_sensor a ON a.region_id = r.id
         WHERE r.is_public
    LOOP
        SELECT * INTO atual FROM public.ar_avisos WHERE region_id = reg.id AND situacao = 'ativo';

        IF NOT reg.ligado THEN
            IF atual.id IS NOT NULL THEN
                UPDATE public.ar_avisos SET situacao = 'encerrado', fim = p_agora, atualizado_em = p_agora,
                       motivo_fim = 'avisos de ar desligados nesta região'
                 WHERE id = atual.id;
                mudancas := mudancas + 1;
            END IF;
            CONTINUE;
        END IF;

        acima := 0; abaixo := 0; ativo := false; ant := NULL; v_inicio := NULL; v_fim := NULL;
        maior := 0; ultimo := NULL; ultima_hora := NULL;
        FOR h IN SELECT n.hora, n.nowcast FROM public.ar_nowcast('continua', p_agora - interval '48 hours', p_agora) n
                  WHERE n.region_id = reg.id ORDER BY n.hora LOOP
            IF ant IS NOT NULL AND h.hora - ant > interval '1 hour' THEN acima := 0; abaixo := 0; END IF;
            ant := h.hora; ultimo := h.nowcast; ultima_hora := h.hora;
            IF h.nowcast > limite THEN acima := acima + 1; abaixo := 0; ELSE abaixo := abaixo + 1; acima := 0; END IF;
            IF NOT ativo AND acima >= abre THEN
                ativo := true; v_inicio := h.hora - (abre - 1) * interval '1 hour'; maior := 0; v_fim := NULL;
            ELSIF ativo AND abaixo >= fecha THEN
                ativo := false; v_fim := h.hora + interval '1 hour';
            END IF;
            IF ativo THEN maior := greatest(maior, h.nowcast); END IF;
        END LOOP;

        -- Sensor parado: sem hora válida recente, não mantém aviso aberto.
        IF ultima_hora IS NULL OR ultima_hora + interval '1 hour' < p_agora - public.ar_cfg('sensor_max_atraso_h') * interval '1 hour' THEN
            IF atual.id IS NOT NULL THEN
                UPDATE public.ar_avisos SET situacao = 'encerrado', fim = p_agora, atualizado_em = p_agora,
                       motivo_fim = 'o sensor parou de mandar leituras'
                 WHERE id = atual.id;
                mudancas := mudancas + 1;
            END IF;
            CONTINUE;
        END IF;

        IF ativo THEN
            sev := CASE WHEN ultimo > critico THEN 'CRITICAL' ELSE 'HIGH' END;
            IF atual.id IS NULL THEN
                INSERT INTO public.ar_avisos (region_id, severity, limite_ugm3, nowcast_atual, nowcast_max, inicio, atualizado_em)
                VALUES (reg.id, sev, limite, ultimo, maior, v_inicio, p_agora);
                mudancas := mudancas + 1;
            ELSE
                UPDATE public.ar_avisos
                   SET severity = sev, nowcast_atual = ultimo, nowcast_max = greatest(coalesce(nowcast_max, 0), maior),
                       atualizado_em = p_agora
                 WHERE id = atual.id
                   AND (severity IS DISTINCT FROM sev OR nowcast_atual IS DISTINCT FROM ultimo);
                IF FOUND THEN mudancas := mudancas + 1; END IF;
            END IF;
        ELSIF atual.id IS NOT NULL THEN
            UPDATE public.ar_avisos SET situacao = 'encerrado', fim = coalesce(v_fim, p_agora), atualizado_em = p_agora,
                   nowcast_atual = ultimo,
                   motivo_fim = 'o índice ficou abaixo de ' || limite || ' µg/m³ por ' || fecha || ' h seguidas'
             WHERE id = atual.id;
            mudancas := mudancas + 1;
        END IF;
    END LOOP;
    RETURN mudancas;
END $$;
REVOKE ALL ON FUNCTION public.ar_avisos_atualizar(timestamptz) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Push: aviso novo ou mudança de severidade entra na fila
-- ------------------------------------------------------------
ALTER TABLE public.push_fila ADD COLUMN IF NOT EXISTS ar_aviso_id uuid REFERENCES public.ar_avisos(id) ON DELETE CASCADE;
ALTER TABLE public.push_fila DROP CONSTRAINT IF EXISTS push_fila_alerta_ou_teste;
ALTER TABLE public.push_fila ADD CONSTRAINT push_fila_alerta_ou_teste
    CHECK (alert_id IS NOT NULL OR ar_aviso_id IS NOT NULL
           OR (teste_para IS NOT NULL AND teste_origem IN ('cheia', 'chuva', 'ar')));

CREATE OR REPLACE FUNCTION public.ar_avisos_enfileirar_push()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE m text;
BEGIN
    IF NEW.situacao <> 'ativo' THEN RETURN NEW; END IF;
    IF TG_OP = 'INSERT' THEN m := 'novo';
    ELSIF OLD.severity IS DISTINCT FROM NEW.severity THEN
        m := CASE WHEN public.severidade_ordem(NEW.severity) > public.severidade_ordem(OLD.severity) THEN 'subiu' ELSE 'baixou' END;
    ELSE RETURN NEW; END IF;
    INSERT INTO public.push_fila (ar_aviso_id, severity, motivo) VALUES (NEW.id, NEW.severity, m);
    PERFORM public.push_cutucar();
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.ar_avisos_enfileirar_push() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS ar_avisos_push ON public.ar_avisos;
CREATE TRIGGER ar_avisos_push AFTER INSERT OR UPDATE OF severity ON public.ar_avisos
    FOR EACH ROW EXECUTE FUNCTION public.ar_avisos_enfileirar_push();

-- O app recarrega quando um aviso abre, muda ou fecha.
DROP TRIGGER IF EXISTS dados_sinal_ar_avisos ON public.ar_avisos;
CREATE TRIGGER dados_sinal_ar_avisos AFTER INSERT OR UPDATE OR DELETE ON public.ar_avisos
    FOR EACH STATEMENT EXECUTE FUNCTION public.dados_marcar_mudanca();

-- Igual à de 20261125a_ar_pausa.sql, mais os avisos de ar por sensor.
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
        RETURNING f.id, f.alert_id, f.ar_aviso_id, f.severity, f.motivo, f.teste_para, f.teste_origem, f.teste_id
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
    ), ar AS (
        -- Aviso de ar por sensor: só quem segue a região E escolheu receber.
        SELECT DISTINCT ON (pg.id, p.fcm_token)
               pg.id AS fila_id, av.id AS alert_id, p.id AS user_id, p.fcm_token AS token,
               public.push_titulo(true, av.severity, pg.motivo) AS titulo,
               'O sensor perto de ' || mr.name || ' indica ar '
                   || CASE av.severity WHEN 'CRITICAL' THEN 'péssimo' ELSE 'muito ruim' END
                   || ' agora (índice em tempo quase real, não é o índice oficial).' AS corpo,
               av.severity
          FROM pegos pg
          JOIN public.ar_avisos av ON av.id = pg.ar_aviso_id AND av.situacao = 'ativo' AND av.severity = pg.severity
          JOIN public.monitored_regions mr ON mr.id = av.region_id
          JOIN public.user_monitored_regions umr ON umr.region_id = av.region_id AND coalesce(umr.notify, true)
          JOIN public.user_profiles p ON p.id = umr.user_id
         WHERE p.fcm_token IS NOT NULL AND p.fcm_token <> ''
           AND coalesce((p.notification_preferences->>'push')::boolean, true)
           AND coalesce((p.notification_preferences->>'ar_optin')::boolean, false)
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
         WHERE pg.alert_id IS NULL AND pg.ar_aviso_id IS NULL
           AND p.fcm_token IS NOT NULL AND p.fcm_token <> ''
    )
    SELECT d.fila_id, d.alert_id, d.user_id, d.token, d.titulo, d.corpo, d.severity FROM destinos d
    UNION ALL
    SELECT x.fila_id, x.alert_id, x.user_id, x.token, x.titulo, x.corpo, x.severity FROM ar x
    UNION ALL
    SELECT t.fila_id, t.alert_id, t.user_id, t.token, t.titulo, t.corpo, t.severity FROM testes t
    UNION ALL
    SELECT pg.id, coalesce(pg.alert_id, pg.ar_aviso_id, pg.teste_id), NULL, NULL, NULL, NULL, pg.severity
      FROM pegos pg
     WHERE NOT EXISTS (SELECT 1 FROM destinos d WHERE d.fila_id = pg.id)
       AND NOT EXISTS (SELECT 1 FROM ar x WHERE x.fila_id = pg.id)
       AND NOT EXISTS (SELECT 1 FROM testes t WHERE t.fila_id = pg.id);
END $$;
REVOKE ALL ON FUNCTION public.push_reivindicar(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_reivindicar(integer) TO service_role;

-- Depois da validação (:25).
SELECT cron.schedule('ar-avisos', '27 * * * *', 'SELECT public.ar_avisos_atualizar()');
