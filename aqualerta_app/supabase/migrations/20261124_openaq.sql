-- ============================================================
-- AQUALERTA — Medição local de MP2,5 pela OpenAQ (sensores de verdade)
--
-- Fica PARADO até existir o segredo "openaq_key" no Vault (chave gratuita
-- criada em https://explore.openaq.org/register). Com a chave:
--   - openaq_pedir() (:16 de toda hora)
--       * 1 vez por dia: procura estações com MP2,5 (parâmetro 2) num raio
--         de 25 km de cada região  -> GET /v3/locations
--       * toda hora: médias horárias das últimas 26 h de cada sensor
--         achado (até 40)           -> GET /v3/sensors/{id}/hours
--     Fica abaixo do limite gratuito (60/min, 2.000/h).
--   - openaq_processar() (:19) lê as respostas (pg_net).
--   - ar_local() (RPC do app): média de 24 h por região, só com sensores
--     que têm ao menos 18 das 24 horas, e o IQAr do MMA dessa média.
-- Atribuição: OpenAQ + provedor de cada estação (termos da OpenAQ).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.openaq_sensores (
    region_id     uuid NOT NULL REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    sensor_id     bigint NOT NULL,
    location_id   bigint NOT NULL,
    nome          text,
    provedor      text,
    licenca       text,
    lat           double precision,
    lon           double precision,
    distancia_m   double precision,
    ultimo_dado   timestamptz,
    visto_em      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (region_id, sensor_id)
);

CREATE TABLE IF NOT EXISTS public.openaq_horas (
    sensor_id  bigint NOT NULL,
    hora       timestamptz NOT NULL,          -- início da hora (UTC)
    pm25       numeric NOT NULL,
    PRIMARY KEY (sensor_id, hora)
);

CREATE TABLE IF NOT EXISTS public.openaq_pedidos (
    request_id bigint PRIMARY KEY,
    tipo       text NOT NULL CHECK (tipo IN ('locais', 'horas')),
    region_id  uuid,
    sensor_id  bigint,
    criado_em  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.openaq_estado (
    id            integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    tem_chave     boolean NOT NULL DEFAULT false,
    locais_ok_em  timestamptz,
    horas_ok_em   timestamptz,
    erro          text,
    erro_em       timestamptz
);
INSERT INTO public.openaq_estado (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.openaq_sensores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.openaq_horas    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.openaq_pedidos  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.openaq_estado   ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.openaq_sensores, public.openaq_horas, public.openaq_pedidos,
              public.openaq_estado FROM anon, authenticated;
GRANT SELECT ON public.openaq_estado TO anon, authenticated;
DROP POLICY IF EXISTS openaq_estado_leitura ON public.openaq_estado;
CREATE POLICY openaq_estado_leitura ON public.openaq_estado FOR SELECT TO anon, authenticated USING (true);

CREATE OR REPLACE FUNCTION public.openaq_chave()
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
    SELECT nullif(btrim(decrypted_secret), '') FROM vault.decrypted_secrets
     WHERE name = 'openaq_key' LIMIT 1
$$;
REVOKE ALL ON FUNCTION public.openaq_chave() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.openaq_pedir(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    chave text := public.openaq_chave();
    cab   jsonb;
    r     record;
    rid   bigint;
    n     integer := 0;
    est   public.openaq_estado;
BEGIN
    UPDATE public.openaq_estado SET tem_chave = (chave IS NOT NULL) WHERE id = 1 RETURNING * INTO est;
    IF chave IS NULL THEN
        RETURN 0;
    END IF;
    cab := jsonb_build_object('X-API-Key', chave, 'Accept', 'application/json');
    DELETE FROM public.openaq_pedidos WHERE criado_em < p_agora - interval '30 minutes';

    -- Estações perto de cada região, 1 vez por dia.
    IF (est.locais_ok_em IS NULL OR est.locais_ok_em < p_agora - interval '23 hours')
       AND NOT EXISTS (SELECT 1 FROM public.openaq_pedidos WHERE tipo = 'locais') THEN
        FOR r IN
            SELECT id, round((monitoring_config->>'estacao_lat')::numeric, 4) AS lat,
                       round((monitoring_config->>'estacao_lng')::numeric, 4) AS lon
              FROM public.monitored_regions
             WHERE is_public AND monitoring_config ? 'estacao_lat'
             ORDER BY id
        LOOP
            rid := net.http_get(
                url := 'https://api.openaq.org/v3/locations',
                params := jsonb_build_object('coordinates', r.lat || ',' || r.lon, 'radius', '25000',
                                             'parameters_id', '2', 'limit', '50'),
                headers := cab,
                timeout_milliseconds := 30000);
            INSERT INTO public.openaq_pedidos (request_id, tipo, region_id, criado_em) VALUES (rid, 'locais', r.id, p_agora);
            n := n + 1;
        END LOOP;
    END IF;

    -- Médias horárias das últimas 26 h dos sensores ativos na última semana.
    FOR r IN
        SELECT DISTINCT sensor_id FROM public.openaq_sensores s
         WHERE s.ultimo_dado > p_agora - interval '7 days'
           AND NOT EXISTS (SELECT 1 FROM public.openaq_pedidos p WHERE p.sensor_id = s.sensor_id)
         ORDER BY sensor_id
         LIMIT 40
    LOOP
        rid := net.http_get(
            url := 'https://api.openaq.org/v3/sensors/' || r.sensor_id || '/hours',
            params := jsonb_build_object(
                'datetime_from', to_char((p_agora - interval '26 hours') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:00:00"Z"'),
                'limit', '48'),
            headers := cab,
            timeout_milliseconds := 30000);
        INSERT INTO public.openaq_pedidos (request_id, tipo, sensor_id, criado_em) VALUES (rid, 'horas', r.sensor_id, p_agora);
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.openaq_pedir(timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.openaq_processar(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    p   record;
    j   jsonb;
    n   integer := 0;
    k   integer;
    locais_ok boolean := false;
    horas_ok  boolean := false;
BEGIN
    FOR p IN
        SELECT op.*, r.status_code, r.error_msg, r.content
          FROM public.openaq_pedidos op
          JOIN net._http_response r ON r.id = op.request_id
         ORDER BY op.request_id
    LOOP
        BEGIN
            IF p.status_code IN (401, 403) THEN
                RAISE EXCEPTION 'chave recusada pela OpenAQ (HTTP %)', p.status_code;
            ELSIF p.status_code = 429 THEN
                RAISE EXCEPTION 'limite de pedidos da OpenAQ atingido (HTTP 429)';
            ELSIF p.status_code IS DISTINCT FROM 200 THEN
                RAISE EXCEPTION '%: %', p.tipo, coalesce(p.error_msg, 'HTTP ' || coalesce(p.status_code::text, '?'));
            END IF;
            j := p.content::jsonb;

            IF p.tipo = 'locais' THEN
                DELETE FROM public.openaq_sensores WHERE region_id = p.region_id;
                INSERT INTO public.openaq_sensores AS s
                       (region_id, sensor_id, location_id, nome, provedor, licenca, lat, lon,
                        distancia_m, ultimo_dado, visto_em)
                SELECT DISTINCT ON (sen->>'id')
                       p.region_id, (sen->>'id')::bigint, (loc->>'id')::bigint, loc->>'name',
                       loc->'provider'->>'name', loc->'licenses'->0->>'name',
                       (loc->'coordinates'->>'latitude')::double precision,
                       (loc->'coordinates'->>'longitude')::double precision,
                       (loc->>'distance')::double precision,
                       (loc->'datetimeLast'->>'utc')::timestamptz, p_agora
                  FROM jsonb_array_elements(coalesce(j->'results', '[]')) loc,
                       jsonb_array_elements(coalesce(loc->'sensors', '[]')) sen
                 WHERE (sen->'parameter'->>'id')::int = 2
                   AND coalesce(loc->>'isMobile', 'false') = 'false'
                 ORDER BY sen->>'id';
                locais_ok := true;

            ELSE -- horas
                INSERT INTO public.openaq_horas AS h (sensor_id, hora, pm25)
                SELECT p.sensor_id,
                       coalesce(x->'period'->'datetimeFrom'->>'utc', x->'datetimeFrom'->>'utc')::timestamptz,
                       (x->>'value')::numeric
                  FROM jsonb_array_elements(coalesce(j->'results', '[]')) x
                 WHERE coalesce(x->'period'->'datetimeFrom'->>'utc', x->'datetimeFrom'->>'utc') IS NOT NULL
                   AND (x->>'value') IS NOT NULL
                   AND (x->>'value')::numeric BETWEEN 0 AND 1000   -- descarta leitura impossível
                ON CONFLICT (sensor_id, hora) DO UPDATE SET pm25 = excluded.pm25;
                GET DIAGNOSTICS k = ROW_COUNT;
                IF k > 0 THEN
                    UPDATE public.openaq_sensores SET ultimo_dado = greatest(ultimo_dado,
                           (SELECT max(hora) + interval '1 hour' FROM public.openaq_horas WHERE sensor_id = p.sensor_id))
                     WHERE sensor_id = p.sensor_id;
                END IF;
                horas_ok := true;
            END IF;
            n := n + 1;
        EXCEPTION WHEN OTHERS THEN
            UPDATE public.openaq_estado SET erro = left(SQLERRM, 300), erro_em = p_agora WHERE id = 1;
        END;
        DELETE FROM public.openaq_pedidos WHERE request_id = p.request_id;
        DELETE FROM net._http_response WHERE id = p.request_id;
    END LOOP;

    UPDATE public.openaq_estado
       SET locais_ok_em = CASE WHEN locais_ok THEN p_agora ELSE locais_ok_em END,
           horas_ok_em  = CASE WHEN horas_ok  THEN p_agora ELSE horas_ok_em END
     WHERE id = 1;
    DELETE FROM public.openaq_horas WHERE hora < p_agora - interval '3 days';
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.openaq_processar(timestamptz) FROM PUBLIC, anon, authenticated;

-- Média de 24 h por região (MMA: o IQAr do MP2,5 é sobre a média de 24 h).
CREATE OR REPLACE FUNCTION public.ar_local(p_agora timestamptz DEFAULT now())
RETURNS TABLE (region_id uuid, pm25_24h numeric, iqar integer, sensores integer,
               distancia_km numeric, fontes text, atualizado_em timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
    WITH por_sensor AS (
        SELECT s.region_id, s.sensor_id, s.distancia_m, s.provedor,
               avg(h.pm25) AS media, count(*) AS horas, max(h.hora) + interval '1 hour' AS ultima
          FROM public.openaq_sensores s
          JOIN public.openaq_horas h ON h.sensor_id = s.sensor_id
                                    AND h.hora >= date_trunc('hour', p_agora) - interval '24 hours'
                                    AND h.hora <  date_trunc('hour', p_agora)
         GROUP BY s.region_id, s.sensor_id, s.distancia_m, s.provedor
        HAVING count(*) >= 18          -- 75% das horas, senão a média não vale
    )
    SELECT ps.region_id,
           round(avg(ps.media), 1),
           public.ar_iqar('pm2_5', round(avg(ps.media), 1)),
           count(*)::integer,
           round((max(ps.distancia_m) / 1000)::numeric, 0),
           'OpenAQ · ' || string_agg(DISTINCT coalesce(ps.provedor, 'provedor não informado'), ', '),
           max(ps.ultima)
      FROM por_sensor ps
     GROUP BY ps.region_id
$$;
REVOKE ALL ON FUNCTION public.ar_local(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ar_local(timestamptz) TO anon, authenticated;

SELECT cron.schedule('openaq-pedir', '16 * * * *', 'SELECT public.openaq_pedir()');
SELECT cron.schedule('openaq-processar', '19 * * * *', 'SELECT public.openaq_processar()');
