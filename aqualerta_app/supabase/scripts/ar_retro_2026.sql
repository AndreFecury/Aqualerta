-- ============================================================
-- AQUALERTA — Fase 1b: carga do teste retroativo (ago-out 2026). Uso único.
-- Roda no SQL Editor, em 3 passos (o pg_net responde entre eles):
--   1) este arquivo inteiro (cria as tabelas e as funções, dispara os pedidos)
--   2) SELECT public.ar_retro_processar();      -- lê as respostas
--   3) SELECT public.ar_retro_montar();         -- grava em ar_validacao_horas (origem 'retro')
-- Fontes: OpenAQ /v3/sensors/{id}/hours (chave no Vault), Open-Meteo
-- air-quality (CAMS) e archive (umidade a 2 m). Tudo fechado (sem anon).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.ar_retro_pedidos (
    request_id bigint PRIMARY KEY,
    tipo       text NOT NULL CHECK (tipo IN ('sensor', 'modelo', 'ur_modelo')),
    sensor_id  bigint,
    pagina     integer,
    regioes    uuid[],
    criado_em  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.ar_retro_bruto (
    sensor_id bigint NOT NULL,
    parametro smallint NOT NULL,
    hora      timestamptz NOT NULL,
    valor     numeric NOT NULL,
    PRIMARY KEY (sensor_id, hora)
);
CREATE TABLE IF NOT EXISTS public.ar_retro_modelo (
    region_id uuid NOT NULL,
    hora      timestamptz NOT NULL,
    pm25      numeric,
    ur        numeric,
    PRIMARY KEY (region_id, hora)
);
CREATE TABLE IF NOT EXISTS public.ar_retro_log (
    em timestamptz NOT NULL DEFAULT now(), etapa text, detalhe text
);
ALTER TABLE public.ar_retro_pedidos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_retro_bruto   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_retro_modelo  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_retro_log     ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ar_retro_pedidos, public.ar_retro_bruto, public.ar_retro_modelo, public.ar_retro_log
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ar_retro_pedir()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    s record; pg integer; rid bigint; n integer := 0;
    ids uuid[]; lats text; lons text;
    cab jsonb := jsonb_build_object('X-API-Key', public.openaq_chave(), 'Accept', 'application/json');
BEGIN
    IF public.openaq_chave() IS NULL THEN RAISE EXCEPTION 'sem openaq_key no Vault'; END IF;
    FOR s IN SELECT DISTINCT sensor_id FROM public.openaq_sensores ORDER BY sensor_id LOOP
        FOR pg IN 1..3 LOOP
            rid := net.http_get(
                url := 'https://api.openaq.org/v3/sensors/' || s.sensor_id || '/hours',
                params := jsonb_build_object('datetime_from', '2026-07-31T00:00:00Z',
                                             'datetime_to', '2026-11-01T04:00:00Z',
                                             'limit', '1000', 'page', pg::text),
                headers := cab, timeout_milliseconds := 60000);
            INSERT INTO public.ar_retro_pedidos (request_id, tipo, sensor_id, pagina) VALUES (rid, 'sensor', s.sensor_id, pg);
            n := n + 1;
        END LOOP;
    END LOOP;

    SELECT array_agg(r.id ORDER BY r.id),
           string_agg(r.monitoring_config->>'estacao_lat', ',' ORDER BY r.id),
           string_agg(r.monitoring_config->>'estacao_lng', ',' ORDER BY r.id)
      INTO ids, lats, lons
      FROM public.monitored_regions r
     WHERE r.id IN (SELECT region_id FROM public.openaq_sensores);
    rid := net.http_get(
        url := 'https://air-quality-api.open-meteo.com/v1/air-quality',
        params := jsonb_build_object('latitude', lats, 'longitude', lons, 'hourly', 'pm2_5',
                                     'start_date', '2026-07-31', 'end_date', '2026-10-31',
                                     'timezone', 'GMT', 'timeformat', 'unixtime'),
        timeout_milliseconds := 60000);
    INSERT INTO public.ar_retro_pedidos (request_id, tipo, regioes) VALUES (rid, 'modelo', ids);
    rid := net.http_get(
        url := 'https://archive-api.open-meteo.com/v1/archive',
        params := jsonb_build_object('latitude', lats, 'longitude', lons, 'hourly', 'relative_humidity_2m',
                                     'start_date', '2026-07-31', 'end_date', '2026-10-31',
                                     'timezone', 'GMT', 'timeformat', 'unixtime'),
        timeout_milliseconds := 60000);
    INSERT INTO public.ar_retro_pedidos (request_id, tipo, regioes) VALUES (rid, 'ur_modelo', ids);
    RETURN n + 2;
END $$;
REVOKE ALL ON FUNCTION public.ar_retro_pedir() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ar_retro_processar()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    p record; j jsonb; loc jsonb; k integer; n integer; total integer := 0; pend integer;
BEGIN
    FOR p IN
        SELECT rp.*, r.status_code, r.error_msg, r.content
          FROM public.ar_retro_pedidos rp JOIN net._http_response r ON r.id = rp.request_id
         ORDER BY rp.request_id
    LOOP
        IF p.status_code IS DISTINCT FROM 200 THEN
            INSERT INTO public.ar_retro_log (etapa, detalhe)
            VALUES (p.tipo, coalesce(p.sensor_id::text, '') || ' página ' || coalesce(p.pagina::text, '-') || ': '
                            || coalesce(p.error_msg, 'HTTP ' || coalesce(p.status_code::text, '?')));
        ELSE
            j := p.content::jsonb;
            IF p.tipo = 'sensor' THEN
                INSERT INTO public.ar_retro_bruto (sensor_id, parametro, hora, valor)
                SELECT p.sensor_id, (SELECT s.parametro FROM public.openaq_sensores s WHERE s.sensor_id = p.sensor_id LIMIT 1),
                       (x->'period'->'datetimeFrom'->>'utc')::timestamptz, (x->>'value')::numeric
                  FROM jsonb_array_elements(coalesce(j->'results', '[]')) x
                 WHERE x->'period'->'datetimeFrom'->>'utc' IS NOT NULL AND x->>'value' IS NOT NULL
                ON CONFLICT (sensor_id, hora) DO UPDATE SET valor = excluded.valor;
                GET DIAGNOSTICS n = ROW_COUNT;
                INSERT INTO public.ar_retro_log (etapa, detalhe)
                VALUES ('sensor', p.sensor_id || ' página ' || p.pagina || ': ' || n || ' horas (found '
                                  || coalesce(j->'meta'->>'found', '?') || ')');
            ELSE
                IF jsonb_typeof(j) = 'object' THEN j := jsonb_build_array(j); END IF;
                FOR k IN 1..array_length(p.regioes, 1) LOOP
                    loc := j -> (k - 1);
                    IF p.tipo = 'modelo' THEN
                        INSERT INTO public.ar_retro_modelo (region_id, hora, pm25)
                        SELECT p.regioes[k], to_timestamp(t::bigint), nullif(loc->'hourly'->'pm2_5'->>(i::int - 1), '')::numeric
                          FROM jsonb_array_elements_text(loc->'hourly'->'time') WITH ORDINALITY AS a(t, i)
                        ON CONFLICT (region_id, hora) DO UPDATE SET pm25 = excluded.pm25;
                    ELSE
                        INSERT INTO public.ar_retro_modelo (region_id, hora, ur)
                        SELECT p.regioes[k], to_timestamp(t::bigint), nullif(loc->'hourly'->'relative_humidity_2m'->>(i::int - 1), '')::numeric
                          FROM jsonb_array_elements_text(loc->'hourly'->'time') WITH ORDINALITY AS a(t, i)
                        ON CONFLICT (region_id, hora) DO UPDATE SET ur = excluded.ur;
                    END IF;
                    GET DIAGNOSTICS n = ROW_COUNT;
                    INSERT INTO public.ar_retro_log (etapa, detalhe) VALUES (p.tipo, p.regioes[k] || ': ' || n || ' horas');
                END LOOP;
            END IF;
        END IF;
        total := total + 1;
        DELETE FROM public.ar_retro_pedidos WHERE request_id = p.request_id;
        DELETE FROM net._http_response WHERE id = p.request_id;
    END LOOP;
    SELECT count(*) INTO pend FROM public.ar_retro_pedidos;
    RETURN total || ' respostas lidas; ' || pend || ' ainda pendentes';
END $$;
REVOKE ALL ON FUNCTION public.ar_retro_processar() FROM PUBLIC, anon, authenticated;

-- Mesmas regras da coleta contínua (ar_sensor_marcas + ar_validacao_registrar),
-- aplicadas ao histórico.
CREATE OR REPLACE FUNCTION public.ar_retro_montar()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE n integer;
BEGIN
    DELETE FROM public.ar_validacao_horas WHERE origem = 'retro';
    WITH pm AS (
        SELECT s.region_id, s.location_id, b.sensor_id, b.hora, b.valor AS pm25,
               lag(b.valor) OVER w AS ant, lag(b.hora) OVER w AS hora_ant,
               min(b.valor) OVER k AS kmin, max(b.valor) OVER k AS kmax,
               count(*) OVER k AS kn, min(b.hora) OVER k AS kdesde
          FROM public.ar_retro_bruto b
          JOIN public.openaq_sensores s ON s.sensor_id = b.sensor_id AND s.parametro = 2
         WHERE b.valor BETWEEN 0 AND 1000
        WINDOW w AS (PARTITION BY b.sensor_id ORDER BY b.hora),
               k AS (PARTITION BY b.sensor_id ORDER BY b.hora ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)
    ), ur AS (
        SELECT s.location_id, b.hora, avg(b.valor) AS ur
          FROM public.ar_retro_bruto b
          JOIN public.openaq_sensores s ON s.sensor_id = b.sensor_id AND s.parametro = 98
         WHERE b.valor BETWEEN 0 AND 100
         GROUP BY s.location_id, b.hora
    ), marcado AS (
        SELECT pm.region_id, pm.hora, pm.pm25, ur.ur,
               array_remove(ARRAY[
                   CASE WHEN pm.kn >= public.ar_cfg('sensor_travado_horas') AND pm.kmin = pm.kmax
                             AND pm.hora - pm.kdesde = (public.ar_cfg('sensor_travado_horas') - 1) * interval '1 hour'
                        THEN 'travado' END,
                   CASE WHEN pm.hora_ant = pm.hora - interval '1 hour'
                             AND abs(pm.pm25 - pm.ant) > public.ar_cfg('sensor_salto_max_ugm3') THEN 'salto' END,
                   CASE WHEN ur.ur >= public.ar_cfg('ur_saturada') THEN 'ur_saturada' END,
                   CASE WHEN ur.ur IS NULL THEN 'sem_ur' END], NULL) AS marcas
          FROM pm LEFT JOIN ur ON ur.location_id = pm.location_id AND ur.hora = pm.hora
    ), ok AS (
        SELECT m.*, NOT (m.marcas && ARRAY['travado', 'salto', 'ur_saturada']) AS ok FROM marcado m
    ), por_regiao AS (
        SELECT o.region_id, o.hora,
               round(avg(o.pm25) FILTER (WHERE o.ok), 2) AS sensor,
               round(avg(public.ar_correcao_epa(o.pm25, o.ur)) FILTER (WHERE o.ok), 2) AS epa,
               round(avg(o.ur), 1) AS ur,
               (count(*) FILTER (WHERE o.ok))::integer AS n_ok,
               coalesce((SELECT array_agg(DISTINCT x ORDER BY x) FROM ok o2, unnest(o2.marcas) x
                          WHERE o2.region_id = o.region_id AND o2.hora = o.hora), '{}') AS marcas
          FROM ok o GROUP BY o.region_id, o.hora
    )
    INSERT INTO public.ar_validacao_horas
           (region_id, hora, origem, modelo_pm25, sensor_pm25, sensor_pm25_epa, sensores_n,
            ur_sensor, ur_modelo, marcas, valido)
    SELECT pr.region_id, pr.hora, 'retro', m.pm25, pr.sensor, pr.epa, pr.n_ok, pr.ur, m.ur, pr.marcas,
           pr.n_ok > 0 AND m.pm25 IS NOT NULL
      FROM por_regiao pr
      LEFT JOIN public.ar_retro_modelo m ON m.region_id = pr.region_id AND m.hora = pr.hora;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.ar_retro_montar() FROM PUBLIC, anon, authenticated;

SELECT public.ar_retro_pedir() AS pedidos;
