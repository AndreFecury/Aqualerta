-- ============================================================
-- AquaAlerta: aviso de ar de TESTE visível só para uma conta (Fase D1)
--
-- Para conferir no celular do dono o caminho inteiro do aviso de ar por
-- sensor (seção "Qualidade do ar (sensor)" na aba Alertas, detalhe e push)
-- sem que mais ninguém veja, conte ou receba nada.
--
--   - ar_avisos.teste_para: a conta dona do teste (NULL = aviso real).
--     RLS: cada conta só lê os avisos reais e os próprios testes.
--   - Teste não entra no "1 ativo por região", não é tocado por
--     ar_avisos_atualizar(), não dispara o push dos seguidores nem o sinal de
--     tempo real (o sinal não tem conteúdo, mas faria todo mundo recarregar).
--   - ar_aviso_teste(usuario, regiao): só SQL Editor / service role. O id da
--     conta é passado na hora; não fica gravado no repositório.
--   - Expira em 1 hora (cron a cada 10 min).
--
-- Uso (SQL Editor):  SELECT public.ar_aviso_teste('<uuid da sua conta>');
-- Pode rodar este arquivo mais de uma vez.
-- ============================================================

ALTER TABLE public.ar_avisos
    ADD COLUMN IF NOT EXISTS teste_para uuid REFERENCES auth.users(id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS expira_em  timestamptz;
DO $$ BEGIN
    ALTER TABLE public.ar_avisos ADD CONSTRAINT ar_avisos_teste_expira
        CHECK ((teste_para IS NULL) = (expira_em IS NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 1 aviso REAL ativo por região; 1 teste ativo por conta.
DROP INDEX IF EXISTS public.ar_avisos_um_ativo;
CREATE UNIQUE INDEX ar_avisos_um_ativo ON public.ar_avisos (region_id)
    WHERE situacao = 'ativo' AND teste_para IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ar_avisos_um_teste ON public.ar_avisos (teste_para)
    WHERE situacao = 'ativo' AND teste_para IS NOT NULL;

DROP POLICY IF EXISTS ar_avisos_leitura ON public.ar_avisos;
CREATE POLICY ar_avisos_leitura ON public.ar_avisos FOR SELECT TO authenticated
    USING (teste_para IS NULL OR teste_para = auth.uid());

-- Push dos seguidores: nunca para teste (o teste põe o próprio item na fila).
CREATE OR REPLACE FUNCTION public.ar_avisos_enfileirar_push()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE m text;
BEGIN
    IF NEW.teste_para IS NOT NULL OR NEW.situacao <> 'ativo' THEN RETURN NEW; END IF;
    IF TG_OP = 'INSERT' THEN m := 'novo';
    ELSIF OLD.severity IS DISTINCT FROM NEW.severity THEN
        m := CASE WHEN public.severidade_ordem(NEW.severity) > public.severidade_ordem(OLD.severity) THEN 'subiu' ELSE 'baixou' END;
    ELSE RETURN NEW; END IF;
    INSERT INTO public.push_fila (ar_aviso_id, severity, motivo) VALUES (NEW.id, NEW.severity, m);
    PERFORM public.push_cutucar();
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.ar_avisos_enfileirar_push() FROM PUBLIC, anon, authenticated;

-- Sinal de tempo real: só para avisos reais (um gatilho por linha, com filtro).
DROP TRIGGER IF EXISTS dados_sinal_ar_avisos ON public.ar_avisos;
DROP TRIGGER IF EXISTS dados_sinal_ar_avisos_mudou ON public.ar_avisos;
DROP TRIGGER IF EXISTS dados_sinal_ar_avisos_apagou ON public.ar_avisos;
CREATE TRIGGER dados_sinal_ar_avisos_mudou AFTER INSERT OR UPDATE ON public.ar_avisos
    FOR EACH ROW WHEN (NEW.teste_para IS NULL) EXECUTE FUNCTION public.dados_marcar_mudanca();
CREATE TRIGGER dados_sinal_ar_avisos_apagou AFTER DELETE ON public.ar_avisos
    FOR EACH ROW WHEN (OLD.teste_para IS NULL) EXECUTE FUNCTION public.dados_marcar_mudanca();

-- Igual à de 20261126b_ar_avisos.sql, ignorando os testes.
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
        SELECT * INTO atual FROM public.ar_avisos
         WHERE region_id = reg.id AND situacao = 'ativo' AND teste_para IS NULL;   -- teste não conta

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

-- Texto pronto para itens de teste que precisam de título e corpo próprios.
ALTER TABLE public.push_fila
    ADD COLUMN IF NOT EXISTS titulo_fixo text,
    ADD COLUMN IF NOT EXISTS corpo_fixo  text;

-- Igual à de 20261126b_ar_avisos.sql, mais: o ramo dos seguidores ignora
-- avisos de teste, e o ramo de teste usa titulo_fixo/corpo_fixo quando houver.
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
        RETURNING f.id, f.alert_id, f.ar_aviso_id, f.severity, f.motivo, f.teste_para, f.teste_origem, f.teste_id,
                  f.titulo_fixo, f.corpo_fixo
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
                              AND av.teste_para IS NULL      -- aviso de teste nunca vai para seguidores
          JOIN public.monitored_regions mr ON mr.id = av.region_id
          JOIN public.user_monitored_regions umr ON umr.region_id = av.region_id AND coalesce(umr.notify, true)
          JOIN public.user_profiles p ON p.id = umr.user_id
         WHERE p.fcm_token IS NOT NULL AND p.fcm_token <> ''
           AND coalesce((p.notification_preferences->>'push')::boolean, true)
           AND coalesce((p.notification_preferences->>'ar_optin')::boolean, false)
         ORDER BY pg.id, p.fcm_token, p.updated_at DESC NULLS LAST
    ), testes AS (
        SELECT pg.id AS fila_id, pg.teste_id AS alert_id, p.id AS user_id, p.fcm_token AS token,
               coalesce(pg.titulo_fixo, 'TESTE · ' || public.push_titulo(pg.teste_origem = 'ar', pg.severity, pg.motivo)) AS titulo,
               coalesce(pg.corpo_fixo, 'Notificação de teste do AquaAlerta (' ||
                   CASE pg.teste_origem WHEN 'chuva' THEN 'chuva forte'
                                        WHEN 'ar' THEN 'qualidade do ar'
                                        ELSE 'cheia' END
                   || '). Não é um alerta real.') AS corpo,
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

-- Cria o aviso de teste e põe o push dele na fila, só para `usuario`.
CREATE OR REPLACE FUNCTION public.ar_aviso_teste(usuario uuid,
                                                 regiao uuid DEFAULT NULL,
                                                 p_agora timestamptz DEFAULT now())
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    reg  record;
    novo uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.user_profiles
                    WHERE id = usuario AND fcm_token IS NOT NULL AND fcm_token <> '') THEN
        RAISE EXCEPTION 'usuário sem aparelho registrado para push';
    END IF;
    -- Sem região: a primeira (por nome) com sensor de PM2.5 da OpenAQ.
    SELECT r.id, r.name INTO reg FROM public.monitored_regions r
     WHERE r.id = coalesce(regiao, (SELECT s.region_id FROM public.openaq_sensores s
                                      JOIN public.monitored_regions m ON m.id = s.region_id
                                     WHERE s.parametro = 2 ORDER BY m.name LIMIT 1));
    IF reg.id IS NULL THEN RAISE EXCEPTION 'região não encontrada'; END IF;

    UPDATE public.ar_avisos SET situacao = 'encerrado', fim = p_agora, atualizado_em = p_agora,
           motivo_fim = 'teste substituído por outro'
     WHERE teste_para = usuario AND situacao = 'ativo';

    INSERT INTO public.ar_avisos (region_id, severity, limite_ugm3, nowcast_atual, nowcast_max, inicio,
                                  atualizado_em, teste_para, expira_em)
    VALUES (reg.id, 'HIGH', public.ar_cfg('aviso_limite_ugm3'), NULL, NULL, p_agora,
            p_agora, usuario, p_agora + interval '1 hour')
    RETURNING id INTO novo;

    INSERT INTO public.push_fila (severity, motivo, teste_para, teste_origem, teste_id, titulo_fixo, corpo_fixo)
    VALUES ('HIGH', 'novo', usuario, 'ar', novo,
            'TESTE · Ar muito ruim: proteja-se',
            'TESTE do aviso de ar por sensor em ' || reg.name
                || '. Não é um alerta real; só você vê e some em 1 hora.');
    PERFORM public.push_cutucar();
    RETURN novo;
END $$;
REVOKE ALL ON FUNCTION public.ar_aviso_teste(uuid, uuid, timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ar_avisos_teste_expirar(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE n integer;
BEGIN
    UPDATE public.ar_avisos SET situacao = 'encerrado', fim = p_agora, atualizado_em = p_agora,
           motivo_fim = 'teste encerrado depois de 1 hora'
     WHERE teste_para IS NOT NULL AND situacao = 'ativo' AND expira_em <= p_agora;
    GET DIAGNOSTICS n = ROW_COUNT;
    -- Testes encerrados há mais de 7 dias somem.
    DELETE FROM public.ar_avisos
     WHERE teste_para IS NOT NULL AND situacao = 'encerrado' AND fim < p_agora - interval '7 days';
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.ar_avisos_teste_expirar(timestamptz) FROM PUBLIC, anon, authenticated;
SELECT cron.schedule('ar-aviso-teste-expirar', '*/10 * * * *', 'SELECT public.ar_avisos_teste_expirar()');
