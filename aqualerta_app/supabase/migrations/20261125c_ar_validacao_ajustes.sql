-- ============================================================
-- AQUALERTA — Fase 1a, ajustes depois do primeiro uso (22/11/2026)
--
-- 1. Umidade: a do AirGradient é medida dentro do aparelho (mediana 43% em
--    Manaus e 48% em Porto Velho contra 65% e 82% no Open-Meteo, em ago-out;
--    nunca passou de 85%). Por isso:
--      - sai a regra "umidade >= 95% = neblina" do sensor saudável;
--      - a umidade AMBIENTE vem do Open-Meteo (grade grosseira, ~10-25 km),
--        pedida junto com a coleta da OpenAQ, em ar_ur_ambiente;
--      - os recortes do resumo usam a umidade ambiente;
--      - a correção da EPA continua usando a umidade do sensor (a fórmula foi
--        ajustada com a umidade interna de sensores parecidos). Recebido e
--        corrigido continuam lado a lado; nenhum é escolhido aqui.
-- 2. net._http_response: o pg_net guarda as respostas por 6 h (pg_net.ttl,
--    configuração do servidor, fora do alcance do papel postgres). Um
--    agendamento apaga as com mais de 30 min (todos os processamentos leem
--    em até 5 min). Risco residual documentado: o esquema net tem acesso
--    público concedido pelo dono (supabase_admin) e não é revogável por nós;
--    a API só expõe public e graphql_public (conferido em 22/11/2026 03:52 UTC)
--    e nenhuma chave/token/senha fica gravada nas tabelas do net.
-- ============================================================

DELETE FROM public.ar_config WHERE chave = 'ur_saturada';
UPDATE public.ar_config SET descricao = 'Corte das faixas de umidade AMBIENTE (Open-Meteo) no resumo (abaixo de)' WHERE chave = 'ur_faixa_1';
UPDATE public.ar_config SET descricao = 'Corte das faixas de umidade AMBIENTE (Open-Meteo) no resumo (acima de)' WHERE chave = 'ur_faixa_2';

CREATE TABLE IF NOT EXISTS public.ar_ur_ambiente (
    region_id uuid NOT NULL REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    hora      timestamptz NOT NULL,
    ur        numeric NOT NULL,
    PRIMARY KEY (region_id, hora)
);
ALTER TABLE public.ar_ur_ambiente ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ar_ur_ambiente FROM PUBLIC, anon, authenticated;

ALTER TABLE public.openaq_pedidos ADD COLUMN IF NOT EXISTS regioes uuid[];
ALTER TABLE public.openaq_pedidos DROP CONSTRAINT IF EXISTS openaq_pedidos_tipo_check;
ALTER TABLE public.openaq_pedidos ADD CONSTRAINT openaq_pedidos_tipo_check CHECK (tipo IN ('locais', 'horas', 'ur_ambiente'));

-- Igual à de 20261124_openaq.sql, mais 1 pedido de umidade ambiente por hora.
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
    ids   uuid[]; lats text; lons text;
BEGIN
    UPDATE public.openaq_estado SET tem_chave = (chave IS NOT NULL) WHERE id = 1 RETURNING * INTO est;
    IF chave IS NULL THEN
        RETURN 0;
    END IF;
    cab := jsonb_build_object('X-API-Key', chave, 'Accept', 'application/json');
    DELETE FROM public.openaq_pedidos WHERE criado_em < p_agora - interval '30 minutes';

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

    -- Umidade ambiente (Open-Meteo, sem chave) nas regiões com sensor.
    SELECT array_agg(mr.id ORDER BY mr.id),
           string_agg(mr.monitoring_config->>'estacao_lat', ',' ORDER BY mr.id),
           string_agg(mr.monitoring_config->>'estacao_lng', ',' ORDER BY mr.id)
      INTO ids, lats, lons
      FROM public.monitored_regions mr
     WHERE mr.id IN (SELECT region_id FROM public.openaq_sensores WHERE parametro = 2)
       AND mr.monitoring_config ? 'estacao_lat';
    IF ids IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.openaq_pedidos WHERE tipo = 'ur_ambiente') THEN
        rid := net.http_get(
            url := 'https://api.open-meteo.com/v1/forecast',
            params := jsonb_build_object('latitude', lats, 'longitude', lons, 'hourly', 'relative_humidity_2m',
                                         'past_days', '2', 'forecast_days', '1',
                                         'timezone', 'GMT', 'timeformat', 'unixtime'),
            timeout_milliseconds := 30000);
        INSERT INTO public.openaq_pedidos (request_id, tipo, regioes, criado_em) VALUES (rid, 'ur_ambiente', ids, p_agora);
        n := n + 1;
    END IF;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.openaq_pedir(timestamptz) FROM PUBLIC, anon, authenticated;

-- Igual à de 20261125b, mais o tipo 'ur_ambiente'.
CREATE OR REPLACE FUNCTION public.openaq_processar(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    p   record;
    j   jsonb;
    loc jsonb;
    n   integer := 0;
    k   integer;
    par smallint;
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
                        distancia_m, ultimo_dado, visto_em, parametro)
                SELECT DISTINCT ON (sen->>'id')
                       p.region_id, (sen->>'id')::bigint, (loc->>'id')::bigint, loc->>'name',
                       loc->'provider'->>'name', loc->'licenses'->0->>'name',
                       (loc->'coordinates'->>'latitude')::double precision,
                       (loc->'coordinates'->>'longitude')::double precision,
                       (loc->>'distance')::double precision,
                       (loc->'datetimeLast'->>'utc')::timestamptz, p_agora,
                       (sen->'parameter'->>'id')::smallint
                  FROM jsonb_array_elements(coalesce(j->'results', '[]')) loc,
                       jsonb_array_elements(coalesce(loc->'sensors', '[]')) sen
                 WHERE (sen->'parameter'->>'id')::int IN (2, 98)
                   AND coalesce(loc->>'isMobile', 'false') = 'false'
                   AND ((sen->'parameter'->>'id')::int = 2
                        OR EXISTS (SELECT 1 FROM jsonb_array_elements(loc->'sensors') s2
                                    WHERE (s2->'parameter'->>'id')::int = 2))
                 ORDER BY sen->>'id';
                locais_ok := true;

            ELSIF p.tipo = 'ur_ambiente' THEN
                IF jsonb_typeof(j) = 'object' THEN j := jsonb_build_array(j); END IF;
                FOR k IN 1..coalesce(array_length(p.regioes, 1), 0) LOOP
                    loc := j -> (k - 1);
                    CONTINUE WHEN loc IS NULL OR loc->'hourly' IS NULL;
                    INSERT INTO public.ar_ur_ambiente AS u (region_id, hora, ur)
                    SELECT p.regioes[k], to_timestamp(t::bigint),
                           (loc->'hourly'->'relative_humidity_2m'->>(i::int - 1))::numeric
                      FROM jsonb_array_elements_text(loc->'hourly'->'time') WITH ORDINALITY AS a(t, i)
                     WHERE nullif(loc->'hourly'->'relative_humidity_2m'->>(i::int - 1), '') IS NOT NULL
                       AND to_timestamp(t::bigint) <= p_agora
                    ON CONFLICT (region_id, hora) DO UPDATE SET ur = excluded.ur;
                END LOOP;

            ELSE -- horas
                SELECT s.parametro INTO par FROM public.openaq_sensores s WHERE s.sensor_id = p.sensor_id LIMIT 1;
                IF par = 98 THEN
                    INSERT INTO public.openaq_ur_horas AS h (sensor_id, hora, ur)
                    SELECT p.sensor_id,
                           coalesce(x->'period'->'datetimeFrom'->>'utc', x->'datetimeFrom'->>'utc')::timestamptz,
                           (x->>'value')::numeric
                      FROM jsonb_array_elements(coalesce(j->'results', '[]')) x
                     WHERE coalesce(x->'period'->'datetimeFrom'->>'utc', x->'datetimeFrom'->>'utc') IS NOT NULL
                       AND (x->>'value') IS NOT NULL
                       AND (x->>'value')::numeric BETWEEN 0 AND 100
                    ON CONFLICT (sensor_id, hora) DO UPDATE SET ur = excluded.ur;
                ELSE
                    INSERT INTO public.openaq_horas AS h (sensor_id, hora, pm25)
                    SELECT p.sensor_id,
                           coalesce(x->'period'->'datetimeFrom'->>'utc', x->'datetimeFrom'->>'utc')::timestamptz,
                           (x->>'value')::numeric
                      FROM jsonb_array_elements(coalesce(j->'results', '[]')) x
                     WHERE coalesce(x->'period'->'datetimeFrom'->>'utc', x->'datetimeFrom'->>'utc') IS NOT NULL
                       AND (x->>'value') IS NOT NULL
                       AND (x->>'value')::numeric BETWEEN 0 AND 1000
                    ON CONFLICT (sensor_id, hora) DO UPDATE SET pm25 = excluded.pm25;
                END IF;
                GET DIAGNOSTICS k = ROW_COUNT;
                IF k > 0 THEN
                    UPDATE public.openaq_sensores SET ultimo_dado = greatest(ultimo_dado,
                           (SELECT max(hora) + interval '1 hour' FROM (
                                SELECT hora FROM public.openaq_horas WHERE sensor_id = p.sensor_id
                                UNION ALL
                                SELECT hora FROM public.openaq_ur_horas WHERE sensor_id = p.sensor_id) t))
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
    DELETE FROM public.openaq_ur_horas WHERE hora < p_agora - interval '3 days';
    DELETE FROM public.ar_ur_ambiente WHERE hora < p_agora - interval '3 days';
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.openaq_processar(timestamptz) FROM PUBLIC, anon, authenticated;

-- Pares: sem a regra de neblina; com a umidade ambiente.
CREATE OR REPLACE FUNCTION public.ar_validacao_registrar(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    n integer;
    desde timestamptz := date_trunc('hour', p_agora) - interval '26 hours';
    ate   timestamptz := date_trunc('hour', p_agora);
BEGIN
    WITH pm AS (
        SELECT s.region_id, s.location_id, m.hora, m.pm25, m.marcas
          FROM public.ar_sensor_marcas(desde, ate) m
          JOIN public.openaq_sensores s ON s.sensor_id = m.sensor_id AND s.parametro = 2
    ), ur AS (
        SELECT s.location_id, u.hora, avg(u.ur) AS ur
          FROM public.openaq_ur_horas u
          JOIN public.openaq_sensores s ON s.sensor_id = u.sensor_id AND s.parametro = 98
         WHERE u.hora >= desde AND u.hora < ate
         GROUP BY s.location_id, u.hora
    ), marcado AS (
        -- "sem_ur" (umidade do sensor ausente) só impede a correção da EPA.
        SELECT pm.region_id, pm.hora, pm.pm25, ur.ur,
               pm.marcas || CASE WHEN ur.ur IS NULL THEN ARRAY['sem_ur'] ELSE '{}'::text[] END AS marcas,
               NOT (pm.marcas && ARRAY['travado', 'salto']) AS ok
          FROM pm LEFT JOIN ur ON ur.location_id = pm.location_id AND ur.hora = pm.hora
    ), por_regiao AS (
        SELECT mc.region_id, mc.hora,
               round(avg(mc.pm25) FILTER (WHERE mc.ok), 2) AS sensor,
               round(avg(public.ar_correcao_epa(mc.pm25, mc.ur)) FILTER (WHERE mc.ok), 2) AS epa,
               round(avg(mc.ur), 1) AS ur,
               (count(*) FILTER (WHERE mc.ok))::integer AS n_ok,
               coalesce((SELECT array_agg(DISTINCT m ORDER BY m)
                           FROM marcado m2, unnest(m2.marcas) m
                          WHERE m2.region_id = mc.region_id AND m2.hora = mc.hora), '{}') AS marcas
          FROM marcado mc
         GROUP BY mc.region_id, mc.hora
    )
    INSERT INTO public.ar_validacao_horas AS v
           (region_id, hora, origem, modelo_pm25, sensor_pm25, sensor_pm25_epa, sensores_n,
            ur_sensor, ur_modelo, marcas, valido, registrado_em)
    SELECT pr.region_id, pr.hora, 'continua', ah.pm2_5, pr.sensor, pr.epa, pr.n_ok,
           pr.ur, ua.ur, pr.marcas, pr.n_ok > 0 AND ah.pm2_5 IS NOT NULL, p_agora
      FROM por_regiao pr
      LEFT JOIN public.ar_horas ah ON ah.region_id = pr.region_id AND ah.hora = pr.hora
      LEFT JOIN public.ar_ur_ambiente ua ON ua.region_id = pr.region_id AND ua.hora = pr.hora
    ON CONFLICT (region_id, hora, origem) DO UPDATE
       SET modelo_pm25 = excluded.modelo_pm25, sensor_pm25 = excluded.sensor_pm25,
           sensor_pm25_epa = excluded.sensor_pm25_epa, sensores_n = excluded.sensores_n,
           ur_sensor = excluded.ur_sensor, ur_modelo = excluded.ur_modelo,
           marcas = excluded.marcas, valido = excluded.valido,
           registrado_em = excluded.registrado_em;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.ar_validacao_registrar(timestamptz) FROM PUBLIC, anon, authenticated;

-- Horas antigas marcadas com a regra que saiu voltam a valer (só se a regra
-- de neblina era o único motivo).
UPDATE public.ar_validacao_horas
   SET marcas = array_remove(marcas, 'ur_saturada'),
       valido = sensores_n > 0 AND modelo_pm25 IS NOT NULL AND sensor_pm25 IS NOT NULL
             AND NOT (array_remove(marcas, 'ur_saturada') && ARRAY['travado', 'salto'])
 WHERE 'ur_saturada' = ANY(marcas);

-- Views: a umidade dos recortes passa a ser a ambiente (as colunas mudam,
-- então as views são recriadas).
DROP VIEW IF EXISTS public.ar_validacao_resumo;
DROP VIEW IF EXISTS public.ar_validacao_dias;

CREATE VIEW public.ar_validacao_dias WITH (security_invoker = true) AS
SELECT v.region_id, r.name AS regiao, v.origem, f.fuso, f.dia,
       count(*)::integer AS horas,
       round(avg(v.modelo_pm25), 1) AS modelo_24h,
       round(avg(v.sensor_pm25), 1) AS sensor_24h,
       round(avg(v.sensor_pm25_epa), 1) AS sensor_epa_24h,
       count(v.sensor_pm25_epa)::integer AS horas_epa,
       round(avg(v.ur_modelo), 0) AS ur_ambiente_media,
       round(avg(v.ur_sensor), 0) AS ur_sensor_media,
       public.ar_nivel(public.ar_iqar('pm2_5', round(avg(v.modelo_pm25), 1))) AS nivel_modelo,
       public.ar_nivel(public.ar_iqar('pm2_5', round(avg(v.sensor_pm25), 1))) AS nivel_sensor,
       public.ar_nivel(public.ar_iqar('pm2_5', round(avg(v.sensor_pm25_epa), 1))) AS nivel_sensor_epa
  FROM public.ar_validacao_horas v
  JOIN public.monitored_regions r ON r.id = v.region_id
  CROSS JOIN LATERAL (VALUES
      ('local', (v.hora AT TIME ZONE public.regiao_fuso(r.state_code))::date),
      ('utc',   (v.hora AT TIME ZONE 'UTC')::date)) f(fuso, dia)
 WHERE v.valido AND v.modelo_pm25 IS NOT NULL AND v.sensor_pm25 IS NOT NULL
 GROUP BY v.region_id, r.name, v.origem, f.fuso, f.dia
HAVING count(*) >= public.ar_cfg('dia_min_horas');

CREATE VIEW public.ar_validacao_resumo WITH (security_invoker = true) AS
WITH d AS (
    SELECT d.* FROM public.ar_validacao_dias d
), recortes AS (
    SELECT d.*, 'todos' AS recorte FROM d
    UNION ALL
    SELECT d.*, 'umidade ambiente (Open-Meteo, grade grosseira) '
                || CASE WHEN d.ur_ambiente_media < public.ar_cfg('ur_faixa_1') THEN 'abaixo de ' || public.ar_cfg('ur_faixa_1')
                        WHEN d.ur_ambiente_media > public.ar_cfg('ur_faixa_2') THEN 'acima de ' || public.ar_cfg('ur_faixa_2')
                        ELSE 'entre ' || public.ar_cfg('ur_faixa_1') || ' e ' || public.ar_cfg('ur_faixa_2') END
      FROM d WHERE d.ur_ambiente_media IS NOT NULL
    UNION ALL
    SELECT d.*, 'fumaça ' || fu.raio_km || ' km: ' || fu.classe
      FROM d JOIN public.ar_fumaca_dias fu ON fu.region_id = d.region_id AND fu.dia = d.dia
     WHERE d.fuso = 'local'
)
SELECT regiao, origem, fuso, recorte,
       count(*)::integer AS dias,
       min(dia) AS de, max(dia) AS ate,
       round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY modelo_24h - sensor_24h)::numeric, 1) AS dif_mediana,
       round(percentile_cont(0.25) WITHIN GROUP (ORDER BY modelo_24h - sensor_24h)::numeric, 1) AS dif_q1,
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY modelo_24h - sensor_24h)::numeric, 1) AS dif_q3,
       round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY modelo_24h - sensor_epa_24h)::numeric, 1) AS dif_mediana_epa,
       round(corr(modelo_24h, sensor_24h)::numeric, 2) AS correlacao_diaria,
       round(corr(modelo_24h, sensor_epa_24h)::numeric, 2) AS correlacao_diaria_epa,
       count(*) FILTER (WHERE nivel_modelo = nivel_sensor)::integer AS dias_mesmo_nivel,
       count(*) FILTER (WHERE nivel_modelo = nivel_sensor_epa)::integer AS dias_mesmo_nivel_epa,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY sensor_24h)::numeric, 1) AS sensor_mediana,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY modelo_24h)::numeric, 1) AS modelo_mediana
  FROM recortes
 GROUP BY regiao, origem, fuso, recorte;

REVOKE ALL ON public.ar_validacao_dias, public.ar_validacao_resumo FROM PUBLIC, anon, authenticated;

-- Retenção das respostas do pg_net: 30 min (o ttl do servidor é 6 h).
SELECT cron.schedule('net-limpar', '*/15 * * * *',
                     $c$DELETE FROM net._http_response WHERE created < now() - interval '30 minutes'$c$);
