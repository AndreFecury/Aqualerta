-- ============================================================
-- Avisos de chuva forte (risco de alagamento) com os pluviômetros do CEMADEN
--
-- A Edge Function chuva-cemaden lê, a cada 5 min, a chuva hora a hora de
-- cada estação do CEMADEN nos municípios monitorados e grava aqui. Depois
-- chuva_atualizar_avisos() cria, sobe ou encerra um alerta por município na
-- tabela alerts (metadata.origem = 'chuva-cemaden'). O gatilho de push que
-- já existe em alerts avisa quem segue a região.
--
-- Limites: critérios de "chuvas intensas" do INMET (20/30/60 mm em 1 h;
-- 50/100 mm em 24 h). São o ponto de partida; calibrar com os alagamentos
-- reais de Manaus na estação chuvosa.
--
-- Dado velho nunca vira aviso: só conta leitura atualizada nos últimos
-- 40 min. Valores impossíveis (> 150 mm numa hora) são ignorados.
--
-- Idempotente: pode rodar de novo sem efeito colateral.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Estações, leituras e estado da coleta
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.chuva_estacoes (
    id            integer PRIMARY KEY,           -- idestacao do CEMADEN
    codigo        text NOT NULL,                 -- codestacao (ex. 130260310A)
    nome          text NOT NULL,
    tipo          text NOT NULL,                 -- Pluviométrica | Hidrológica
    region_id     uuid NOT NULL REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    lat           float8 NOT NULL,
    lng           float8 NOT NULL,
    ativa         boolean NOT NULL DEFAULT true,
    atualizado_em timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS chuva_estacoes_regiao_idx ON public.chuva_estacoes (region_id);

CREATE TABLE IF NOT EXISTS public.chuva_leituras (
    estacao_id integer NOT NULL REFERENCES public.chuva_estacoes(id) ON DELETE CASCADE,
    hora       timestamptz NOT NULL,             -- início da hora (UTC)
    mm         numeric NOT NULL CHECK (mm >= 0),
    lido_em    timestamptz NOT NULL DEFAULT now(),  -- última vez que o CEMADEN confirmou o valor
    PRIMARY KEY (estacao_id, hora)
);
CREATE INDEX IF NOT EXISTS chuva_leituras_hora_idx ON public.chuva_leituras (hora DESC);

CREATE TABLE IF NOT EXISTS public.chuva_estado (
    id                     integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    ultima_coleta          timestamptz,
    ultima_coleta_ok       timestamptz,
    estacoes_lidas         integer,
    estacoes_com_falha     integer,
    ultimo_erro            text,
    estacoes_atualizadas_em timestamptz
);
INSERT INTO public.chuva_estado (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Leitura pública das estações e do estado (transparência); escrita só pelo servidor.
ALTER TABLE public.chuva_estacoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chuva_leituras ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chuva_estado   ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.chuva_estacoes, public.chuva_leituras, public.chuva_estado FROM anon, authenticated;
GRANT SELECT ON public.chuva_estacoes, public.chuva_leituras, public.chuva_estado TO anon, authenticated;
DROP POLICY IF EXISTS chuva_estacoes_leitura ON public.chuva_estacoes;
CREATE POLICY chuva_estacoes_leitura ON public.chuva_estacoes FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS chuva_leituras_leitura ON public.chuva_leituras;
CREATE POLICY chuva_leituras_leitura ON public.chuva_leituras FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS chuva_estado_leitura ON public.chuva_estado;
CREATE POLICY chuva_estado_leitura ON public.chuva_estado FOR SELECT TO anon, authenticated USING (true);

-- ------------------------------------------------------------
-- 2. Regra (uma função só, usada pelos avisos e pela view)
-- ------------------------------------------------------------
-- Milímetros no formato brasileiro, sem zeros à toa: 25 → "25"; 34.5 → "34,5".
CREATE OR REPLACE FUNCTION public.chuva_mm_br(v numeric)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(rtrim(rtrim(to_char(round(v, 1), 'FM999990.0'), '0'), '.'), '.', ',');
$$;

CREATE OR REPLACE FUNCTION public.chuva_rank(sev text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE sev WHEN 'CRITICAL' THEN 3 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 1 ELSE 0 END;
$$;

-- Chuva por estação no instante p_agora:
--   mm_1h  = maior valor entre a hora corrente e a anterior (os dados vêm em
--            baldes de hora cheia; assim uma chuva das 14h50 às 15h10 conta)
--   mm_24h = soma das últimas 24 horas
-- Só leituras confirmadas nos últimos 40 min e com valor plausível.
CREATE OR REPLACE FUNCTION public.chuva_avaliar(p_agora timestamptz DEFAULT now())
RETURNS TABLE (estacao_id integer, region_id uuid, nome text,
               mm_1h numeric, mm_24h numeric, lido_em timestamptz, severidade text)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    WITH v AS (
        SELECT e.id, e.region_id, e.nome,
               max(l.mm) FILTER (WHERE l.hora >= date_trunc('hour', p_agora) - interval '1 hour') AS h1,
               sum(l.mm) FILTER (WHERE l.hora > p_agora - interval '24 hours') AS d24,
               max(l.lido_em) AS lido
        FROM public.chuva_estacoes e
        JOIN public.chuva_leituras l ON l.estacao_id = e.id
        WHERE e.ativa
          AND l.hora > p_agora - interval '25 hours'
          AND l.hora <= p_agora
          AND l.mm <= 150
        GROUP BY e.id, e.region_id, e.nome
        HAVING max(l.lido_em) > p_agora - interval '40 minutes'
    )
    SELECT id, region_id, nome, coalesce(h1, 0), coalesce(d24, 0), lido,
           CASE
             WHEN coalesce(h1, 0) > 60 OR coalesce(d24, 0) > 100 THEN 'CRITICAL'
             WHEN coalesce(h1, 0) >= 30 OR coalesce(d24, 0) >= 50 THEN 'HIGH'
             WHEN coalesce(h1, 0) >= 20 THEN 'MEDIUM'
             ELSE 'LOW' END
    FROM v;
$$;

-- Para o app (e para conferência): chuva agora em cada estação.
CREATE OR REPLACE VIEW public.v_chuva_agora
WITH (security_invoker = on) AS
SELECT e.id, e.nome, e.tipo, e.region_id, e.lat, e.lng,
       a.mm_1h, a.mm_24h, a.lido_em, a.severidade
FROM public.chuva_estacoes e
LEFT JOIN public.chuva_avaliar() a ON a.estacao_id = e.id
WHERE e.ativa;
GRANT SELECT ON public.v_chuva_agora TO anon, authenticated;

-- ------------------------------------------------------------
-- 3. Avisos (um por município, na tabela alerts)
-- ------------------------------------------------------------
-- Dentro de um mesmo episódio o nível só sobe (não fica subindo e descendo
-- a cada 5 min, o que viraria spam de push). Encerra 2 h depois da última
-- vez que alguma estação passou do limite: a água demora a escoar.
CREATE OR REPLACE FUNCTION public.chuva_atualizar_avisos(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    r        record;
    pior     record;
    atual    record;
    fuso     text;
    titulo   text;
    texto    text;
    mudancas integer := 0;
BEGIN
    FOR r IN
        SELECT mr.id, mr.name, mr.state_code FROM public.monitored_regions mr
        WHERE EXISTS (SELECT 1 FROM public.chuva_estacoes e WHERE e.region_id = mr.id AND e.ativa)
    LOOP
        fuso := CASE r.state_code WHEN 'AC' THEN 'America/Rio_Branco' ELSE 'America/Manaus' END;

        SELECT * INTO pior FROM public.chuva_avaliar(p_agora) a
        WHERE a.region_id = r.id
        ORDER BY public.chuva_rank(a.severidade) DESC, a.mm_1h DESC, a.mm_24h DESC
        LIMIT 1;

        SELECT * INTO atual FROM public.alerts al
        WHERE al.region_id = r.id AND al.status = 'ACTIVE'
          AND al.metadata->>'origem' = 'chuva-cemaden'
        ORDER BY al.issued_at DESC LIMIT 1;

        IF pior.estacao_id IS NOT NULL AND pior.severidade <> 'LOW' THEN
            titulo := CASE pior.severidade
                WHEN 'CRITICAL' THEN 'Chuva extrema em ' || r.name || ': risco de grandes alagamentos'
                WHEN 'HIGH'     THEN 'Chuva muito forte em ' || r.name || ': alagamentos prováveis'
                ELSE                 'Chuva forte em ' || r.name || ': risco de alagamento' END;
            texto := 'O pluviômetro ' || pior.nome || ' (CEMADEN) registrou '
                  || public.chuva_mm_br(pior.mm_1h) || ' mm na última hora e '
                  || public.chuva_mm_br(pior.mm_24h) || ' mm em 24 h (leitura das '
                  || to_char(pior.lido_em AT TIME ZONE fuso, 'HH24:MI') || '). '
                  || 'Ruas e igarapés podem alagar em minutos: evite áreas alagadas, não atravesse '
                  || 'correnteza e fique longe de encostas. '
                  || 'Aviso automático do AquaAlerta com dados do CEMADEN e critérios de chuva '
                  || 'intensa do INMET; não substitui a Defesa Civil. Emergência: 199 (Defesa Civil) '
                  || 'ou 193 (Bombeiros).';

            IF atual.id IS NULL THEN
                INSERT INTO public.alerts
                    (region_id, title, body, severity, status, valid_from, issued_at, metadata)
                VALUES (r.id, titulo, texto, pior.severidade, 'ACTIVE', pior.lido_em, p_agora,
                        jsonb_build_object('origem', 'chuva-cemaden', 'estacao_cemaden', pior.estacao_id,
                                           'mm_1h', pior.mm_1h, 'mm_24h', pior.mm_24h,
                                           'ultimo_gatilho', p_agora));
                mudancas := mudancas + 1;
            ELSIF public.chuva_rank(pior.severidade) > public.chuva_rank(atual.severity) THEN
                UPDATE public.alerts
                   SET severity = pior.severidade, title = titulo, body = texto,
                       metadata = metadata || jsonb_build_object('estacao_cemaden', pior.estacao_id,
                                  'mm_1h', pior.mm_1h, 'mm_24h', pior.mm_24h, 'ultimo_gatilho', p_agora)
                 WHERE id = atual.id;
                mudancas := mudancas + 1;
            ELSE
                -- Mesmo nível ou menor: só renova o prazo (sem push).
                UPDATE public.alerts
                   SET metadata = metadata || jsonb_build_object('ultimo_gatilho', p_agora)
                 WHERE id = atual.id;
            END IF;

        ELSIF atual.id IS NOT NULL
              AND coalesce((atual.metadata->>'ultimo_gatilho')::timestamptz, atual.issued_at)
                  < p_agora - interval '2 hours' THEN
            UPDATE public.alerts
               SET status = 'RESOLVED', resolved_at = p_agora, valid_until = p_agora,
                   body = body || ' Encerrado às ' || to_char(p_agora AT TIME ZONE fuso, 'HH24:MI')
                          || ': 2 h sem chuva forte nos pluviômetros do município.'
             WHERE id = atual.id;
            mudancas := mudancas + 1;
        END IF;
    END LOOP;
    RETURN mudancas;
END $$;
REVOKE ALL ON FUNCTION public.chuva_atualizar_avisos(timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chuva_atualizar_avisos(timestamptz) TO service_role;

-- ------------------------------------------------------------
-- 4. Escrita pela Edge Function (service role apenas)
-- ------------------------------------------------------------

-- O que a coleta precisa saber: estações conhecidas e os municípios (IBGE).
CREATE OR REPLACE FUNCTION public.chuva_plano()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT jsonb_build_object(
        'municipios', coalesce((SELECT jsonb_agg(jsonb_build_object(
                          'region_id', mr.id, 'ibge', (mr.monitoring_config->>'municipio_ibge')::int))
                       FROM public.monitored_regions mr
                       WHERE mr.is_public AND mr.monitoring_config ? 'municipio_ibge'), '[]'::jsonb),
        'estacoes', coalesce((SELECT jsonb_agg(e.id ORDER BY e.id)
                     FROM public.chuva_estacoes e WHERE e.ativa), '[]'::jsonb),
        'estacoes_atualizadas_em', (SELECT estacoes_atualizadas_em FROM public.chuva_estado WHERE id = 1));
$$;
REVOKE ALL ON FUNCTION public.chuva_plano() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chuva_plano() TO service_role;

-- Lista de estações vinda do CEMADEN (as que sumirem da lista ficam inativas).
CREATE OR REPLACE FUNCTION public.chuva_registrar_estacoes(p jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE n integer;
BEGIN
    INSERT INTO public.chuva_estacoes AS e (id, codigo, nome, tipo, region_id, lat, lng, ativa, atualizado_em)
    SELECT (x->>'id')::int, x->>'codigo', x->>'nome', x->>'tipo', (x->>'region_id')::uuid,
           (x->>'lat')::float8, (x->>'lng')::float8, true, now()
    FROM jsonb_array_elements(p) x
    ON CONFLICT (id) DO UPDATE SET codigo = EXCLUDED.codigo, nome = EXCLUDED.nome, tipo = EXCLUDED.tipo,
        region_id = EXCLUDED.region_id, lat = EXCLUDED.lat, lng = EXCLUDED.lng,
        ativa = true, atualizado_em = now();
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE public.chuva_estacoes SET ativa = false
     WHERE id NOT IN (SELECT (x->>'id')::int FROM jsonb_array_elements(p) x);
    UPDATE public.chuva_estado SET estacoes_atualizadas_em = now() WHERE id = 1;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.chuva_registrar_estacoes(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chuva_registrar_estacoes(jsonb) TO service_role;

-- Leituras de uma coleta: [{estacao, hora, mm}], mais o resumo da coleta.
CREATE OR REPLACE FUNCTION public.chuva_registrar_leituras(p jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE n integer;
BEGIN
    INSERT INTO public.chuva_leituras AS l (estacao_id, hora, mm, lido_em)
    SELECT (x->>'estacao')::int, (x->>'hora')::timestamptz, (x->>'mm')::numeric, now()
    FROM jsonb_array_elements(coalesce(p->'linhas', '[]'::jsonb)) x
    WHERE (x->>'mm')::numeric >= 0
      AND EXISTS (SELECT 1 FROM public.chuva_estacoes e WHERE e.id = (x->>'estacao')::int)
    ON CONFLICT (estacao_id, hora) DO UPDATE SET mm = EXCLUDED.mm, lido_em = now();
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE public.chuva_estado
       SET ultima_coleta = now(),
           ultima_coleta_ok = CASE WHEN (p->>'lidas')::int > 0 THEN now() ELSE ultima_coleta_ok END,
           estacoes_lidas = (p->>'lidas')::int,
           estacoes_com_falha = (p->>'falhas')::int,
           ultimo_erro = p->>'erro'
     WHERE id = 1;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.chuva_registrar_leituras(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chuva_registrar_leituras(jsonb) TO service_role;

-- ------------------------------------------------------------
-- 5. Correção em ana_atualizar_alertas(): só mexe nos alertas do rio.
--    Antes ela pegava QUALQUER alerta ativo da região e o encerrava quando o
--    rio estava baixo, o que fecharia um aviso de chuva. Única mudança: o
--    filtro de origem no LEFT JOIN (alertas antigos sem origem continuam dela).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ana_atualizar_alertas()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    x        record;
    sev      text;
    titulo   text;
    texto    text;
    evento   uuid;
    mudancas integer := 0;
BEGIN
    FOR x IN
        SELECT r.id AS region_id, r.name AS municipio, s.ana_code, s.river,
               s.alert_level_m, s.flood_level_m, s.emergency_level_m,
               ult.water_level_m AS nivel, ult.recorded_at,
               COALESCE((r.monitoring_config->>'estacao_lat')::float8, ST_Y(ST_Centroid(r.geometry))) AS lat,
               COALESCE((r.monitoring_config->>'estacao_lng')::float8, ST_X(ST_Centroid(r.geometry))) AS lng,
               a.id AS alerta_id, a.severity AS sev_atual, a.flood_event_id
        FROM public.monitored_regions r
        JOIN public.hydro_stations s ON s.ana_code = r.monitoring_config->>'estacao_ana' AND s.is_active
        JOIN LATERAL (
            SELECT hr.water_level_m, hr.recorded_at FROM public.hydro_readings hr
            WHERE hr.station_id = s.id AND hr.water_level_m IS NOT NULL
            ORDER BY hr.recorded_at DESC LIMIT 1
        ) ult ON ult.recorded_at > now() - interval '48 hours'
        LEFT JOIN public.alerts a ON a.region_id = r.id AND a.status = 'ACTIVE'
             AND coalesce(a.metadata->>'origem', 'telemetria-ana') = 'telemetria-ana'
        WHERE s.alert_level_m IS NOT NULL
    LOOP
        sev := CASE
            WHEN x.emergency_level_m IS NOT NULL AND x.nivel >= x.emergency_level_m THEN 'CRITICAL'
            WHEN x.flood_level_m IS NOT NULL AND x.nivel >= x.flood_level_m THEN 'HIGH'
            WHEN x.nivel >= x.alert_level_m THEN 'MEDIUM'
            ELSE 'LOW' END;

        IF sev = 'LOW' THEN
            IF x.alerta_id IS NOT NULL THEN
                UPDATE public.alerts
                   SET status = 'RESOLVED', resolved_at = now(), valid_until = now(),
                       body = body || ' Encerrado: o rio voltou para baixo da cota de alerta ('
                              || public.metros_br(x.nivel) || ' m em ' || to_char(x.recorded_at AT TIME ZONE 'America/Manaus', 'DD/MM HH24:MI') || ').'
                 WHERE id = x.alerta_id;
                mudancas := mudancas + 1;
            END IF;
            CONTINUE;
        END IF;

        IF x.sev_atual = sev THEN CONTINUE; END IF;

        titulo := x.river || ' ' || CASE sev
            WHEN 'CRITICAL' THEN 'acima da cota de inundação severa'
            WHEN 'HIGH'     THEN 'acima da cota de inundação'
            ELSE                 'acima da cota de alerta' END || ' em ' || x.municipio;
        texto := 'O ' || x.river || ' marcou ' || public.metros_br(x.nivel) || ' m na estação '
              || x.ana_code || ' da ANA (' || to_char(x.recorded_at AT TIME ZONE 'America/Manaus', 'DD/MM HH24:MI')
              || '). Cotas do SGB: alerta ' || public.metros_br(x.alert_level_m) || ' m'
              || coalesce(', inundação ' || public.metros_br(x.flood_level_m) || ' m', '')
              || coalesce(', inundação severa ' || public.metros_br(x.emergency_level_m) || ' m', '') || '.';

        IF x.alerta_id IS NULL THEN
            INSERT INTO public.flood_events
                (region_id, detected_at, severity, center_lat, center_lng, processing_metadata)
            VALUES (x.region_id, x.recorded_at, sev, x.lat, x.lng,
                    jsonb_build_object('origem', 'telemetria-ana', 'estacao_ana', x.ana_code, 'nivel_m', x.nivel))
            RETURNING id INTO evento;
            INSERT INTO public.alerts
                (flood_event_id, region_id, title, body, severity, status, valid_from, issued_at, metadata)
            VALUES (evento, x.region_id, titulo, texto, sev, 'ACTIVE', x.recorded_at, now(),
                    jsonb_build_object('origem', 'telemetria-ana', 'estacao_ana', x.ana_code, 'nivel_m', x.nivel));
        ELSE
            UPDATE public.alerts
               SET severity = sev, title = titulo, body = texto,
                   metadata = metadata || jsonb_build_object('nivel_m', x.nivel)
             WHERE id = x.alerta_id;
            UPDATE public.flood_events SET severity = sev WHERE id = x.flood_event_id;
        END IF;
        mudancas := mudancas + 1;
    END LOOP;
    RETURN mudancas;
END $$;
REVOKE ALL ON FUNCTION public.ana_atualizar_alertas() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 6. Agendamento: a cada 5 min (o CEMADEN atualiza de 10 em 10 min
--    durante a chuva; 5 min corta o atraso médio pela metade).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chuva_cutucar()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
    PERFORM net.http_post(
        url     := 'https://gayykjlkdtmmzovdbjkb.supabase.co/functions/v1/chuva-cemaden',
        body    := '{}'::jsonb,
        headers := '{"Content-Type": "application/json"}'::jsonb,
        timeout_milliseconds := 60000);
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'chuva_cutucar: %', SQLERRM;
END $$;
REVOKE ALL ON FUNCTION public.chuva_cutucar() FROM PUBLIC, anon, authenticated;

SELECT cron.schedule('chuva-cemaden', '*/5 * * * *', 'SELECT public.chuva_cutucar()');
