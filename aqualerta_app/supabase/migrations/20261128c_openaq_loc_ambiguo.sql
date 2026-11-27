-- ============================================================
-- AQUALERTA — corrige "column reference "loc" is ambiguous" em openaq_processar()
--
-- Desde 20261125c, o ramo 'locais' falhava em TODA rodada: a variável plpgsql
-- `loc jsonb` colidia com o alias `loc` de `FROM jsonb_array_elements(...) loc`.
-- O sub-bloco EXCEPTION engolia o erro (gravava em openaq_estado.erro) e as
-- horas dos sensores seguiam carregando, mas a busca diária de estações nunca
-- terminava (openaq_estado.locais_ok_em parada desde 22/11/2026).
--
-- A ÚNICA mudança: a variável passa a se chamar v_loc (declaração e ramo
-- 'ur_ambiente', onde ela é usada). O alias `loc` do ramo 'locais' fica como
-- estava. O resto da função é idêntico a 20261125c.
--
-- EFEITO AO APLICAR: a busca de estações volta a funcionar no próximo
-- openaq_pedir() (:16). Para cada região, o ramo 'locais' SUBSTITUI a lista de
-- sensores pelo que a OpenAQ devolve na hora (DELETE + INSERT, como sempre foi
-- desenhado). Um sensor que a OpenAQ não lista mais some da lista da região.
--
-- DESFAZER: reaplicar a função de 20261125c_ar_validacao_ajustes.sql (o ramo
-- 'locais' volta a falhar). Nenhuma tabela, cron ou permissão muda.
-- ============================================================

CREATE OR REPLACE FUNCTION public.openaq_processar(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    p   record;
    j   jsonb;
    v_loc jsonb;
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
                    v_loc := j -> (k - 1);
                    CONTINUE WHEN v_loc IS NULL OR v_loc->'hourly' IS NULL;
                    INSERT INTO public.ar_ur_ambiente AS u (region_id, hora, ur)
                    SELECT p.regioes[k], to_timestamp(t::bigint),
                           (v_loc->'hourly'->'relative_humidity_2m'->>(i::int - 1))::numeric
                      FROM jsonb_array_elements_text(v_loc->'hourly'->'time') WITH ORDINALITY AS a(t, i)
                     WHERE nullif(v_loc->'hourly'->'relative_humidity_2m'->>(i::int - 1), '') IS NOT NULL
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
