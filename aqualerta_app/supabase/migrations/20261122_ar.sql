-- ============================================================
-- Qualidade do ar por região (plano: docs/plano-qualidade-do-ar.md)
--
-- Fontes (sem conta):
--   * Open-Meteo Air Quality (modelo CAMS/Copernicus, CC BY 4.0): MP2,5,
--     MP10, O3, NO2 e CO de hora em hora, ontem + 5 dias, das 6 regiões
--     numa requisição só. É ESTIMATIVA DE MODELO (~0,4°), não medição local.
--   * INPE Queimadas: arquivos de focos de 10 min (lat, lon, satélite, hora).
--
-- Coleta pelo banco (pg_net), como a chuva:
--   ar_pedir()      :11 de cada hora: 1 pedido ao Open-Meteo + os arquivos
--                   de focos de 10 min ainda não lidos (até 8).
--   ar_processar()  :14 de cada hora: grava, recalcula o índice e os avisos.
--   ar_podar()      domingo: apaga horas > 30 dias e focos > 7 dias.
--
-- Índice: IQAr do MMA, Orientação Técnica de 10/01/2025 (Res. CONAMA
-- 506/2024), Quadro 1 e Equação 1; vale o maior índice entre os poluentes.
-- Avisos (decisão do dono, 21/11/2026): alerta com push só a partir de
-- N4 - Muito ruim (IQAr > 120) em 2 coletas seguidas; N5 (> 200) = CRITICAL.
-- metadata.origem = 'ar-cams'. O ar NUNCA muda o risco de cheia: o app
-- ignora esses alertas na severidade da região, e quem quiser desliga o push
-- de ar no Perfil (notification_preferences.ar = false).
--
-- Idempotente. Depende de 20261118_push_fcm.sql (push_reivindicar).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Tabelas
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ar_horas (
    region_id   uuid NOT NULL REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    hora        timestamptz NOT NULL,           -- início da hora, UTC
    pm2_5       numeric,                        -- µg/m³
    pm10        numeric,                        -- µg/m³
    o3          numeric,                        -- µg/m³
    no2         numeric,                        -- µg/m³
    co          numeric,                        -- µg/m³ (vira ppm no índice)
    fonte       text NOT NULL DEFAULT 'open-meteo-cams',
    ingerido_em timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (region_id, hora)
);

CREATE TABLE IF NOT EXISTS public.ar_focos (
    lat          numeric(8,5) NOT NULL,
    lon          numeric(8,5) NOT NULL,
    satelite     text NOT NULL,
    detectado_em timestamptz NOT NULL,
    PRIMARY KEY (lat, lon, satelite, detectado_em)
);
CREATE INDEX IF NOT EXISTS ar_focos_data_idx ON public.ar_focos (detectado_em);

-- Arquivos de 10 min já lidos (para não pedir de novo).
CREATE TABLE IF NOT EXISTS public.ar_focos_arquivos (
    nome    text PRIMARY KEY,                   -- AAAAMMDD_HHMI (UTC)
    lido_em timestamptz NOT NULL DEFAULT now(),
    focos   integer
);

CREATE TABLE IF NOT EXISTS public.ar_pedidos (
    request_id bigint PRIMARY KEY,
    tipo       text NOT NULL CHECK (tipo IN ('modelo', 'focos')),
    regioes    uuid[],                          -- ordem das coordenadas no pedido
    arquivo    text,
    criado_em  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.ar_estado (
    id            integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    modelo_ok_em  timestamptz,
    focos_ok_em   timestamptz,
    erro          text,
    erro_em       timestamptz
);
INSERT INTO public.ar_estado (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Contagem de coletas seguidas acima/abaixo do limite do aviso.
CREATE TABLE IF NOT EXISTS public.ar_regiao (
    region_id   uuid PRIMARY KEY REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    iqar        integer,
    acima       integer NOT NULL DEFAULT 0,
    abaixo      integer NOT NULL DEFAULT 0,
    avaliado_em timestamptz
);

-- Leitura pública só do que o app mostra; o resto é do servidor.
ALTER TABLE public.ar_horas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_focos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_estado ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_focos_arquivos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_pedidos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_regiao ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ar_horas, public.ar_focos, public.ar_estado, public.ar_focos_arquivos,
              public.ar_pedidos, public.ar_regiao FROM anon, authenticated;
GRANT SELECT ON public.ar_horas, public.ar_focos, public.ar_estado TO anon, authenticated;
DROP POLICY IF EXISTS ar_horas_leitura ON public.ar_horas;
CREATE POLICY ar_horas_leitura ON public.ar_horas FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS ar_focos_leitura ON public.ar_focos;
CREATE POLICY ar_focos_leitura ON public.ar_focos FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS ar_estado_leitura ON public.ar_estado;
CREATE POLICY ar_estado_leitura ON public.ar_estado FOR SELECT TO anon, authenticated USING (true);

-- ------------------------------------------------------------
-- 2. IQAr (MMA, Quadro 1 + Equação 1)
-- ------------------------------------------------------------
-- Arredondamento do MMA: inteiro mais próximo; X,5 vai para o par.
CREATE OR REPLACE FUNCTION public.ar_arredondar(v numeric, casas integer DEFAULT 0)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN v IS NULL THEN NULL
        WHEN abs(v * 10 ^ casas - trunc(v * 10 ^ casas)) = 0.5
            THEN (trunc(v * 10 ^ casas) + CASE WHEN trunc(v * 10 ^ casas)::bigint % 2 = 0 THEN 0
                                                 ELSE sign(v) END) / 10 ^ casas
        ELSE round(v, casas) END
$$;

-- poluente: pm2_5 | pm10 | o3 | no2 | co (ppm) | so2. Concentração já na
-- média certa (24 h para MP e SO2, 8 h para O3 e CO, 1 h para NO2).
CREATE OR REPLACE FUNCTION public.ar_iqar(poluente text, conc numeric)
RETURNS integer LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    fins numeric[] := CASE poluente
        WHEN 'pm2_5' THEN ARRAY[15, 50, 75, 125, 300]
        WHEN 'pm10'  THEN ARRAY[45, 100, 150, 250, 600]
        WHEN 'o3'    THEN ARRAY[100, 130, 160, 200, 800]
        WHEN 'no2'   THEN ARRAY[200, 240, 320, 1130, 3750]
        WHEN 'co'    THEN ARRAY[9, 11, 13, 15, 50]
        WHEN 'so2'   THEN ARRAY[40, 50, 125, 800, 2620] END;
    passo numeric := CASE poluente WHEN 'co' THEN 0.1 ELSE 1 END;
    ii    integer[] := ARRAY[0, 41, 81, 121, 201];
    ifin  integer[] := ARRAY[40, 80, 120, 200, 400];
    c     numeric;
    ci    numeric;
BEGIN
    IF conc IS NULL OR fins IS NULL THEN RETURN NULL; END IF;
    c := public.ar_arredondar(greatest(conc, 0), CASE poluente WHEN 'co' THEN 1 ELSE 0 END);
    FOR k IN 1..5 LOOP
        IF c <= fins[k] THEN
            ci := CASE WHEN k = 1 THEN 0 ELSE fins[k - 1] + passo END;
            RETURN public.ar_arredondar(ii[k] + (ifin[k] - ii[k]) / (fins[k] - ci) * (c - ci))::integer;
        END IF;
    END LOOP;
    RETURN 400;   -- acima da escala
END $$;

-- Índice hora a hora (passado e previsão) com as médias móveis do MMA.
-- Média de 24 h só vale com pelo menos 18 horas de dados.
CREATE OR REPLACE VIEW public.v_ar_indice_horas
WITH (security_invoker = on) AS
WITH m AS (
    SELECT h.region_id, h.hora, h.no2,
           avg(h.pm2_5) OVER w24 AS pm2_5_24, count(h.pm2_5) OVER w24 AS n24,
           avg(h.pm10)  OVER w24 AS pm10_24,
           avg(h.o3)    OVER w8  AS o3_8,
           avg(h.co)    OVER w8  AS co_8,
           count(h.o3)  OVER w8  AS n8
    FROM public.ar_horas h
    WINDOW w24 AS (PARTITION BY h.region_id ORDER BY h.hora
                   RANGE BETWEEN interval '23 hours' PRECEDING AND CURRENT ROW),
           w8  AS (PARTITION BY h.region_id ORDER BY h.hora
                   RANGE BETWEEN interval '7 hours' PRECEDING AND CURRENT ROW)
), i AS (
    SELECT m.*,
           CASE WHEN n24 >= 18 THEN public.ar_iqar('pm2_5', pm2_5_24) END AS i_pm2_5,
           CASE WHEN n24 >= 18 THEN public.ar_iqar('pm10', pm10_24) END   AS i_pm10,
           CASE WHEN n8 >= 6 THEN public.ar_iqar('o3', o3_8) END          AS i_o3,
           public.ar_iqar('no2', no2)                                     AS i_no2,
           CASE WHEN n8 >= 6 THEN public.ar_iqar('co', co_8 / 1145) END   AS i_co
    FROM m
)
SELECT region_id, hora, pm2_5_24, pm10_24, o3_8, no2, co_8,
       greatest(i_pm2_5, i_pm10, i_o3, i_no2, i_co) AS iqar,
       CASE greatest(i_pm2_5, i_pm10, i_o3, i_no2, i_co)
           WHEN i_pm2_5 THEN 'pm2_5' WHEN i_pm10 THEN 'pm10' WHEN i_o3 THEN 'o3'
           WHEN i_no2 THEN 'no2' WHEN i_co THEN 'co' END AS poluente
FROM i;

-- Nível do IQAr (N1..N5) e severidade do alerta.
CREATE OR REPLACE FUNCTION public.ar_nivel(iqar integer)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN iqar IS NULL THEN NULL WHEN iqar <= 40 THEN 'N1' WHEN iqar <= 80 THEN 'N2'
                WHEN iqar <= 120 THEN 'N3' WHEN iqar <= 200 THEN 'N4' ELSE 'N5' END
$$;

-- Resumo por região para o app: agora, previsão de 48 h, tendência, focos.
CREATE OR REPLACE FUNCTION public.ar_resumo(p_agora timestamptz DEFAULT now())
RETURNS TABLE (region_id uuid, hora timestamptz, iqar integer, nivel text, poluente text,
               pm2_5_24 numeric, iqar_previsto_48h integer, hora_pior_prevista timestamptz,
               tendencia text, focos_24h integer, fumaca_provavel boolean,
               atualizado_em timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
    WITH agora AS (
        SELECT DISTINCT ON (v.region_id) v.*
        FROM public.v_ar_indice_horas v
        WHERE v.hora <= p_agora AND v.hora > p_agora - interval '6 hours' AND v.iqar IS NOT NULL
        ORDER BY v.region_id, v.hora DESC
    ), ontem AS (
        SELECT DISTINCT ON (v.region_id) v.region_id, v.pm2_5_24
        FROM public.v_ar_indice_horas v
        WHERE v.hora <= p_agora - interval '24 hours' AND v.hora > p_agora - interval '27 hours'
        ORDER BY v.region_id, v.hora DESC
    ), prev AS (
        SELECT DISTINCT ON (v.region_id) v.region_id, v.iqar, v.hora
        FROM public.v_ar_indice_horas v
        WHERE v.hora > p_agora AND v.hora <= p_agora + interval '48 hours' AND v.iqar IS NOT NULL
        ORDER BY v.region_id, v.iqar DESC, v.hora
    ), centro AS (
        SELECT r.id,
               ST_SetSRID(ST_MakePoint((r.monitoring_config->>'estacao_lng')::float8,
                                       (r.monitoring_config->>'estacao_lat')::float8), 4326)::geography AS g
        FROM public.monitored_regions r
        WHERE r.is_public AND r.monitoring_config ? 'estacao_lat'
    ), focos AS (
        -- Só satélites de órbita polar (VIIRS/MODIS): o GOES repete o mesmo
        -- fogo a cada 10 min. Mesmo fogo em satélites diferentes conta 1
        -- (células de ~1 km).
        SELECT c.id, count(DISTINCT (round(f.lat, 2), round(f.lon, 2)))::integer AS n
        FROM centro c
        JOIN public.ar_focos f
          ON f.detectado_em > p_agora - interval '24 hours'
         AND f.satelite IN ('AQUA_M-T', 'AQUA_M-M', 'TERRA_M-T', 'TERRA_M-M', 'NPP-375', 'NOAA-20', 'NOAA-21')
         AND ST_DWithin(c.g, ST_SetSRID(ST_MakePoint(f.lon, f.lat), 4326)::geography, 100000)
        GROUP BY c.id
    )
    SELECT c.id, a.hora, a.iqar, public.ar_nivel(a.iqar), a.poluente,
           round(a.pm2_5_24, 1), p.iqar, p.hora,
           CASE WHEN a.pm2_5_24 IS NULL OR o.pm2_5_24 IS NULL THEN NULL
                WHEN a.pm2_5_24 - o.pm2_5_24 >= greatest(2, o.pm2_5_24 * 0.15) THEN 'sobe'
                WHEN o.pm2_5_24 - a.pm2_5_24 >= greatest(2, o.pm2_5_24 * 0.15) THEN 'desce'
                ELSE 'estavel' END,
           coalesce(fo.n, 0),
           coalesce(fo.n, 0) >= 10 AND a.pm2_5_24 > 15
               AND (a.pm2_5_24 >= 25 OR a.pm2_5_24 - coalesce(o.pm2_5_24, a.pm2_5_24) >= 2),
           (SELECT max(h.ingerido_em) FROM public.ar_horas h WHERE h.region_id = c.id)
    FROM centro c
    LEFT JOIN agora a ON a.region_id = c.id
    LEFT JOIN ontem o ON o.region_id = c.id
    LEFT JOIN prev p ON p.region_id = c.id
    LEFT JOIN focos fo ON fo.id = c.id;
$$;
REVOKE ALL ON FUNCTION public.ar_resumo(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ar_resumo(timestamptz) TO anon, authenticated, service_role;

-- ------------------------------------------------------------
-- 3. Coleta
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ar_pedir(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    ids  uuid[];
    lats text;
    lons text;
    rid  bigint;
    n    integer := 0;
    base timestamp := date_trunc('hour', p_agora AT TIME ZONE 'UTC')
                      + floor(extract(minute FROM p_agora AT TIME ZONE 'UTC') / 10) * interval '10 minutes';
    arq  text;
BEGIN
    -- Pedidos sem resposta há mais de 30 min: desiste (o próximo ciclo pede de novo).
    DELETE FROM public.ar_pedidos WHERE criado_em < p_agora - interval '30 minutes';

    SELECT array_agg(r.id ORDER BY r.id),
           string_agg(r.monitoring_config->>'estacao_lat', ',' ORDER BY r.id),
           string_agg(r.monitoring_config->>'estacao_lng', ',' ORDER BY r.id)
      INTO ids, lats, lons
      FROM public.monitored_regions r
     WHERE r.is_public AND r.monitoring_config ? 'estacao_lat';

    IF ids IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.ar_pedidos WHERE tipo = 'modelo') THEN
        rid := net.http_get(
            url := 'https://air-quality-api.open-meteo.com/v1/air-quality',
            params := jsonb_build_object(
                'latitude', lats, 'longitude', lons,
                'hourly', 'pm2_5,pm10,ozone,nitrogen_dioxide,carbon_monoxide',
                'past_days', '1', 'forecast_days', '3',
                'timezone', 'GMT', 'timeformat', 'unixtime'),
            timeout_milliseconds := 30000);
        INSERT INTO public.ar_pedidos (request_id, tipo, regioes) VALUES (rid, 'modelo', ids);
        n := n + 1;
    END IF;

    -- Arquivos de focos de 10 min: de 20 a 90 min atrás (o INPE publica com
    -- atraso), os que ainda não foram lidos nem pedidos.
    FOR k IN 2..9 LOOP
        arq := to_char(base - k * interval '10 minutes', 'YYYYMMDD_HH24MI');
        CONTINUE WHEN EXISTS (SELECT 1 FROM public.ar_focos_arquivos fa WHERE fa.nome = arq)
                   OR EXISTS (SELECT 1 FROM public.ar_pedidos p WHERE p.arquivo = arq);
        rid := net.http_get(
            url := 'https://dataserver-coids.inpe.br/queimadas/queimadas/focos/csv/10min/focos_10min_'
                   || arq || '.csv',
            timeout_milliseconds := 30000);
        INSERT INTO public.ar_pedidos (request_id, tipo, arquivo) VALUES (rid, 'focos', arq);
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.ar_pedir(timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ar_processar(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    p       record;
    j       jsonb;
    loc     jsonb;
    k       integer;
    gravadas integer := 0;
    modelo_novo boolean := false;
    n       integer;
BEGIN
    FOR p IN
        SELECT ap.*, r.status_code, r.timed_out, r.error_msg, r.content
        FROM public.ar_pedidos ap
        JOIN net._http_response r ON r.id = ap.request_id
    LOOP
        BEGIN
            IF p.tipo = 'modelo' THEN
                IF p.status_code IS DISTINCT FROM 200 THEN
                    RAISE EXCEPTION 'modelo: %', coalesce(p.error_msg, 'HTTP ' || coalesce(p.status_code::text, '?'));
                END IF;
                j := p.content::jsonb;
                IF jsonb_typeof(j) = 'object' THEN j := jsonb_build_array(j); END IF;
                FOR k IN 1..coalesce(array_length(p.regioes, 1), 0) LOOP
                    loc := j -> (k - 1);
                    CONTINUE WHEN loc IS NULL OR loc->'hourly' IS NULL;
                    INSERT INTO public.ar_horas AS h (region_id, hora, pm2_5, pm10, o3, no2, co, ingerido_em)
                    SELECT p.regioes[k], to_timestamp(t::bigint),
                           nullif(loc->'hourly'->'pm2_5'->>(i::int - 1), '')::numeric,
                           nullif(loc->'hourly'->'pm10'->>(i::int - 1), '')::numeric,
                           nullif(loc->'hourly'->'ozone'->>(i::int - 1), '')::numeric,
                           nullif(loc->'hourly'->'nitrogen_dioxide'->>(i::int - 1), '')::numeric,
                           nullif(loc->'hourly'->'carbon_monoxide'->>(i::int - 1), '')::numeric,
                           p_agora
                    FROM jsonb_array_elements_text(loc->'hourly'->'time') WITH ORDINALITY AS x(t, i)
                    ON CONFLICT (region_id, hora) DO UPDATE
                       SET pm2_5 = EXCLUDED.pm2_5, pm10 = EXCLUDED.pm10, o3 = EXCLUDED.o3,
                           no2 = EXCLUDED.no2, co = EXCLUDED.co, ingerido_em = EXCLUDED.ingerido_em;
                    GET DIAGNOSTICS n = ROW_COUNT;
                    gravadas := gravadas + n;
                END LOOP;
                modelo_novo := true;
                UPDATE public.ar_estado SET modelo_ok_em = p_agora, erro = NULL, erro_em = NULL WHERE id = 1;

            ELSE  -- focos
                IF p.status_code = 404 THEN
                    -- Ainda não publicado: tenta de novo no próximo ciclo; depois
                    -- de 3 h, desiste (o INPE às vezes pula um intervalo).
                    IF to_timestamp(p.arquivo, 'YYYYMMDD_HH24MI')::timestamp AT TIME ZONE 'UTC' < p_agora - interval '3 hours' THEN
                        INSERT INTO public.ar_focos_arquivos (nome, focos) VALUES (p.arquivo, NULL)
                        ON CONFLICT (nome) DO NOTHING;
                    END IF;
                ELSIF p.status_code IS DISTINCT FROM 200 THEN
                    RAISE EXCEPTION 'focos %: %', p.arquivo, coalesce(p.error_msg, 'HTTP ' || coalesce(p.status_code::text, '?'));
                ELSE
                    INSERT INTO public.ar_focos (lat, lon, satelite, detectado_em)
                    SELECT trim(split_part(l, ',', 1))::numeric, trim(split_part(l, ',', 2))::numeric,
                           trim(split_part(l, ',', 3)),
                           trim(split_part(l, ',', 4))::timestamp AT TIME ZONE 'UTC'
                    FROM regexp_split_to_table(coalesce(p.content, ''), E'\r?\n') AS l
                    WHERE l ~ '^\s*-?[0-9.]'              -- pula o cabeçalho e linhas vazias (o INPE escreve -.0828)
                    ON CONFLICT DO NOTHING;
                    GET DIAGNOSTICS n = ROW_COUNT;
                    INSERT INTO public.ar_focos_arquivos (nome, focos) VALUES (p.arquivo, n)
                    ON CONFLICT (nome) DO UPDATE SET focos = EXCLUDED.focos, lido_em = now();
                    UPDATE public.ar_estado SET focos_ok_em = p_agora WHERE id = 1;
                END IF;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Um pedido com problema não derruba os outros.
            UPDATE public.ar_estado SET erro = left(SQLERRM, 300), erro_em = p_agora WHERE id = 1;
        END;
        DELETE FROM public.ar_pedidos WHERE request_id = p.request_id;
        DELETE FROM net._http_response WHERE id = p.request_id;
    END LOOP;

    IF modelo_novo THEN
        PERFORM public.ar_atualizar_avisos(p_agora);
    END IF;
    RETURN gravadas;
END $$;
REVOKE ALL ON FUNCTION public.ar_processar(timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ar_podar(p_agora timestamptz DEFAULT now())
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    DELETE FROM public.ar_horas WHERE hora < p_agora - interval '30 days';
    DELETE FROM public.ar_focos WHERE detectado_em < p_agora - interval '7 days';
    DELETE FROM public.ar_focos_arquivos WHERE lido_em < p_agora - interval '2 days';
$$;
REVOKE ALL ON FUNCTION public.ar_podar(timestamptz) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 4. Avisos (alerts, origem 'ar-cams')
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ar_atualizar_avisos(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    r        record;
    atual    record;
    est      public.ar_regiao;
    sev      text;
    titulo   text;
    texto    text;
    mudancas integer := 0;
    rank_novo integer;
    rank_atual integer;
BEGIN
    FOR r IN
        SELECT s.*, mr.name FROM public.ar_resumo(p_agora) s
        JOIN public.monitored_regions mr ON mr.id = s.region_id
    LOOP
        INSERT INTO public.ar_regiao (region_id) VALUES (r.region_id) ON CONFLICT DO NOTHING;
        UPDATE public.ar_regiao
           SET iqar = r.iqar, avaliado_em = p_agora,
               acima  = CASE WHEN r.iqar > 120 THEN acima + 1 ELSE 0 END,
               abaixo = CASE WHEN r.iqar IS NOT NULL AND r.iqar <= 120 THEN abaixo + 1 ELSE 0 END
         WHERE region_id = r.region_id
        RETURNING * INTO est;

        SELECT * INTO atual FROM public.alerts al
         WHERE al.region_id = r.region_id AND al.status = 'ACTIVE'
           AND al.metadata->>'origem' = 'ar-cams'
         ORDER BY al.issued_at DESC LIMIT 1;

        IF est.acima >= 2 THEN
            sev := CASE WHEN r.iqar > 200 THEN 'CRITICAL' ELSE 'HIGH' END;
            titulo := CASE sev WHEN 'CRITICAL' THEN 'Qualidade do ar péssima em ' ELSE 'Qualidade do ar muito ruim em ' END
                      || r.name;
            texto := 'O modelo CAMS (Copernicus) estima IQAr ' || r.iqar || ' na região, puxado por '
                  || CASE r.poluente WHEN 'pm2_5' THEN 'partículas finas (MP2,5)' WHEN 'pm10' THEN 'partículas (MP10)'
                                     WHEN 'o3' THEN 'ozônio' WHEN 'no2' THEN 'dióxido de nitrogênio'
                                     ELSE 'monóxido de carbono' END
                  || CASE WHEN r.fumaca_provavel THEN ', com focos de queimada por perto (fumaça provável)' ELSE '' END
                  || '. '
                  || CASE sev WHEN 'CRITICAL'
                        THEN 'Toda a população pode ter sérios riscos de doenças respiratórias e cardiovasculares. '
                        ELSE 'Toda a população pode ter tosse, cansaço, ardor nos olhos, nariz e garganta e falta de ar; '
                             || 'crianças, idosos e pessoas com doenças respiratórias ou cardíacas, efeitos mais graves. ' END
                  || 'Evite esforço ao ar livre, mantenha portas e janelas fechadas nas horas de mais fumaça e '
                  || 'procure atendimento se tiver falta de ar. '
                  || 'Estimativa de modelo, não medição local (Open-Meteo/CAMS; focos: INPE). '
                  || 'Índice do MMA (Res. Conama 506/2024). Emergência: 192 (SAMU).';
            rank_novo := CASE sev WHEN 'CRITICAL' THEN 4 ELSE 3 END;
            IF atual.id IS NULL THEN
                INSERT INTO public.alerts (region_id, title, body, severity, status, valid_from, issued_at, metadata)
                VALUES (r.region_id, titulo, texto, sev, 'ACTIVE', p_agora, p_agora,
                        jsonb_build_object('origem', 'ar-cams', 'iqar', r.iqar, 'poluente', r.poluente,
                                           'fumaca_provavel', r.fumaca_provavel, 'ultimo_gatilho', p_agora));
                mudancas := mudancas + 1;
            ELSE
                rank_atual := CASE atual.severity WHEN 'CRITICAL' THEN 4 WHEN 'HIGH' THEN 3 ELSE 2 END;
                IF rank_novo > rank_atual THEN
                    UPDATE public.alerts SET severity = sev, title = titulo, body = texto,
                           metadata = metadata || jsonb_build_object('iqar', r.iqar, 'poluente', r.poluente,
                                                                     'ultimo_gatilho', p_agora)
                     WHERE id = atual.id;
                    mudancas := mudancas + 1;
                ELSE
                    UPDATE public.alerts
                       SET metadata = metadata || jsonb_build_object('iqar', r.iqar, 'ultimo_gatilho', p_agora)
                     WHERE id = atual.id;
                END IF;
            END IF;

        ELSIF atual.id IS NOT NULL AND (est.abaixo >= 2 OR r.iqar IS NULL) THEN
            UPDATE public.alerts
               SET status = 'RESOLVED', resolved_at = p_agora, valid_until = p_agora,
                   body = body || CASE WHEN r.iqar IS NULL
                                       THEN ' Encerrado: sem estimativa recente do modelo.'
                                       ELSE ' Encerrado: o índice voltou para ' || r.iqar || '.' END
             WHERE id = atual.id;
            mudancas := mudancas + 1;
        END IF;
    END LOOP;
    RETURN mudancas;
END $$;
REVOKE ALL ON FUNCTION public.ar_atualizar_avisos(timestamptz) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 5. Push: título próprio para o ar e opção de desligar
--    (mesmo corpo de 20261118_push_fcm.sql com esses dois ajustes)
-- ------------------------------------------------------------
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
               CASE WHEN a.metadata->>'origem' = 'ar-cams' THEN
                   CASE a.severity WHEN 'CRITICAL' THEN 'Ar péssimo: evite sair de casa'
                                   ELSE 'Ar muito ruim: proteja-se' END
               ELSE
                   CASE a.severity
                       WHEN 'CRITICAL' THEN 'Saia de áreas de risco: risco crítico'
                       WHEN 'HIGH'     THEN 'Prepare-se: risco alto'
                       WHEN 'MEDIUM'   THEN 'Fique atento: risco médio'
                       ELSE                 'Situação normal: risco baixo' END
               END
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
           AND (a.metadata->>'origem' IS DISTINCT FROM 'ar-cams'
                OR coalesce((p.notification_preferences->>'ar')::boolean, true))
         ORDER BY pg.id, p.fcm_token, p.updated_at DESC NULLS LAST
    )
    SELECT d.fila_id, d.alert_id, d.user_id, d.token, d.titulo, d.corpo, d.severity FROM destinos d
    UNION ALL
    SELECT pg.id, pg.alert_id, NULL, NULL, NULL, NULL, pg.severity
      FROM pegos pg WHERE NOT EXISTS (SELECT 1 FROM destinos d WHERE d.fila_id = pg.id);
END $$;
REVOKE ALL ON FUNCTION public.push_reivindicar(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_reivindicar(integer) TO service_role;

-- ------------------------------------------------------------
-- 6. Agenda
-- ------------------------------------------------------------
SELECT cron.schedule('ar-pedir', '11 * * * *', 'SELECT public.ar_pedir()');
SELECT cron.schedule('ar-processar', '14 * * * *', 'SELECT public.ar_processar()');
SELECT cron.schedule('ar-podar', '41 4 * * 0', 'SELECT public.ar_podar()');
