-- ============================================================
-- Água detectada por satélite (Copernicus EMS — GFM, Sentinel-1)
--
-- Informação COMPLEMENTAR. Nada aqui mexe em alerts nem em
-- ana_atualizar_alertas(): o nível do alerta continua vindo só das cotas
-- oficiais. Radar banda C mostra água aberta; não enxerga água sob floresta
-- densa, então isto nunca é a "extensão total da cheia".
--
-- Idempotente: pode rodar de novo sem efeito colateral.
-- Fonte e limites: docs/satelite-fonte.md
-- ============================================================

-- ------------------------------------------------------------
-- 1. Observações
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.satelite_observacoes (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    region_id         uuid NOT NULL REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    fonte             text NOT NULL,
    produto           text NOT NULL,
    observado_em      timestamptz NOT NULL,          -- passagem do satélite
    ingerido_em       timestamptz NOT NULL DEFAULT now(),
    area_agua_km2     numeric NOT NULL,              -- contagem de pixels, não o polígono simplificado
    area_inundada_km2 numeric NULL,                  -- água fora da máscara de referência do GFM
    geom              geometry(MultiPolygon, 4326) NULL,  -- simplificada; NULL depois de 90 dias
    cobertura_pct     numeric NULL,                  -- quanto do quadrado a passagem cobriu
    metadata          jsonb NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT satelite_observacoes_unica UNIQUE (region_id, fonte, produto, observado_em)
);
CREATE INDEX IF NOT EXISTS satelite_observacoes_geom_idx
    ON public.satelite_observacoes USING gist (geom);
CREATE INDEX IF NOT EXISTS satelite_observacoes_regiao_data_idx
    ON public.satelite_observacoes (region_id, observado_em DESC);

-- Leitura pública; escrita só pelo servidor (service role ignora RLS).
ALTER TABLE public.satelite_observacoes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.satelite_observacoes FROM anon, authenticated;
GRANT SELECT ON public.satelite_observacoes TO anon, authenticated;
DROP POLICY IF EXISTS satelite_observacoes_leitura ON public.satelite_observacoes;
CREATE POLICY satelite_observacoes_leitura ON public.satelite_observacoes
    FOR SELECT TO anon, authenticated USING (true);

-- Controle de quando cada região foi verificada (evita bater na fonte à toa).
CREATE TABLE IF NOT EXISTS public.satelite_verificacoes (
    region_id     uuid PRIMARY KEY REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    verificado_em timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.satelite_verificacoes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.satelite_verificacoes FROM anon, authenticated;

-- ------------------------------------------------------------
-- 2. Leitura pelo app
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_satelite_ultima
WITH (security_invoker = on) AS
SELECT DISTINCT ON (o.region_id)
    o.region_id,
    o.fonte,
    o.produto,
    o.observado_em,
    o.ingerido_em,
    o.area_agua_km2,
    o.area_inundada_km2,
    o.cobertura_pct,
    o.geom IS NOT NULL AS tem_geometria,
    round((extract(epoch FROM now() - o.observado_em) / 3600)::numeric, 1) AS idade_horas,
    o.metadata
FROM public.satelite_observacoes o
ORDER BY o.region_id, o.observado_em DESC;
GRANT SELECT ON public.v_satelite_ultima TO anon, authenticated;

-- FeatureCollection da última observação da região. "observacao" traz os
-- números mesmo quando não há geometria (água zero ou já podada); null
-- quando a região ainda não tem observação.
CREATE OR REPLACE FUNCTION public.satelite_geojson(p_region uuid)
RETURNS json
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, extensions
AS $$
    SELECT json_build_object(
        'type', 'FeatureCollection',
        'observacao', (
            SELECT json_build_object(
                'region_id', u.region_id, 'fonte', u.fonte, 'produto', u.produto,
                'observado_em', u.observado_em, 'area_agua_km2', u.area_agua_km2,
                'area_inundada_km2', u.area_inundada_km2, 'cobertura_pct', u.cobertura_pct,
                'idade_horas', u.idade_horas,
                'excluida_pct', u.metadata->'excluida_pct',
                'atribuicao', u.metadata->>'atribuicao')
            FROM public.v_satelite_ultima u WHERE u.region_id = p_region),
        'features', COALESCE((
            SELECT json_agg(json_build_object(
                'type', 'Feature',
                'geometry', ST_AsGeoJSON(o.geom, 4)::json,
                'properties', json_build_object('observado_em', o.observado_em)))
            FROM (SELECT geom, observado_em FROM public.satelite_observacoes
                  WHERE region_id = p_region
                  ORDER BY observado_em DESC LIMIT 1) o
            WHERE o.geom IS NOT NULL AND NOT ST_IsEmpty(o.geom)), '[]'::json)
    );
$$;
REVOKE ALL ON FUNCTION public.satelite_geojson(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.satelite_geojson(uuid) TO anon, authenticated;

-- ------------------------------------------------------------
-- 3. Escrita pela Edge Function (service role apenas)
-- ------------------------------------------------------------

-- Regiões a verificar agora (nenhuma verificada há menos de 50 min) e a
-- última observação de cada. Marca a verificação na mesma transação.
CREATE OR REPLACE FUNCTION public.satelite_regioes_para_verificar(p_region uuid DEFAULT NULL)
RETURNS TABLE (id uuid, name text, lat float8, lng float8, desde timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
    RETURN QUERY
    WITH alvo AS (
        SELECT r.id, r.name::text AS name,
               (r.monitoring_config->>'estacao_lat')::float8 AS lat,
               (r.monitoring_config->>'estacao_lng')::float8 AS lng
        FROM public.monitored_regions r
        LEFT JOIN public.satelite_verificacoes v ON v.region_id = r.id
        WHERE r.is_public
          AND r.monitoring_config ? 'estacao_lat'
          AND (p_region IS NULL OR r.id = p_region)
          AND (v.verificado_em IS NULL OR v.verificado_em < now() - interval '50 minutes')
    ), marca AS (
        INSERT INTO public.satelite_verificacoes AS sv (region_id, verificado_em)
        SELECT alvo.id, now() FROM alvo
        ON CONFLICT (region_id) DO UPDATE SET verificado_em = EXCLUDED.verificado_em
        RETURNING sv.region_id
    )
    SELECT a.id, a.name, a.lat, a.lng,
           (SELECT max(o.observado_em) FROM public.satelite_observacoes o
             WHERE o.region_id = a.id)
    FROM alvo a JOIN marca m ON m.region_id = a.id;
END $$;
REVOKE ALL ON FUNCTION public.satelite_regioes_para_verificar(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.satelite_regioes_para_verificar(uuid) TO service_role;

-- Recebe a água (MultiPolygon lon/lat) e o quadrado da região.
-- A Edge Function já manda polígonos contornados e simplificados
-- (50 m), sem manchas < 25 pixels = 0,04 km² (só no desenho; as áreas vêm da contagem de
-- pixels). Aqui só corrige se vier inválido, garante o recorte e grava.
-- Nada de ST_Union aqui: fundir milhares de pixels no banco era lento.
-- Devolve true se a observação é nova.
CREATE OR REPLACE FUNCTION public.satelite_registrar(p jsonb)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_recorte geometry;
    v_agua    geometry;
    v_id      uuid;
BEGIN
    -- Já gravada: sai antes de mexer na geometria.
    IF EXISTS (SELECT 1 FROM public.satelite_observacoes o
               WHERE o.region_id = (p->>'region_id')::uuid AND o.fonte = p->>'fonte'
                 AND o.produto = p->>'produto'
                 AND o.observado_em = (p->>'observado_em')::timestamptz) THEN
        RETURN false;
    END IF;

    v_recorte := ST_SetSRID(ST_GeomFromGeoJSON(p->>'recorte'), 4326);

    IF jsonb_array_length(COALESCE(p->'agua'->'coordinates', '[]'::jsonb)) > 0 THEN
        v_agua := ST_SetSRID(ST_GeomFromGeoJSON(p->>'agua'), 4326);
        IF NOT ST_IsValid(v_agua) THEN
            v_agua := ST_CollectionExtract(ST_MakeValid(v_agua), 3);
        END IF;
        -- Os vértices já estão na grade da região; o recorte é só garantia.
        IF NOT ST_CoveredBy(v_agua, v_recorte) THEN
            v_agua := ST_CollectionExtract(ST_Intersection(v_agua, v_recorte), 3);
        END IF;
        v_agua := ST_Multi(v_agua);
    END IF;
    v_agua := COALESCE(v_agua, ST_GeomFromText('MULTIPOLYGON EMPTY', 4326));

    INSERT INTO public.satelite_observacoes
        (region_id, fonte, produto, observado_em, area_agua_km2, area_inundada_km2,
         geom, cobertura_pct, metadata)
    VALUES ((p->>'region_id')::uuid, p->>'fonte', p->>'produto',
            (p->>'observado_em')::timestamptz,
            (p->>'area_agua_km2')::numeric, (p->>'area_inundada_km2')::numeric,
            v_agua, (p->>'cobertura_pct')::numeric,
            COALESCE(p->'metadata', '{}'::jsonb)
              || jsonb_build_object('recorte_bbox',
                   json_build_array(ST_XMin(v_recorte), ST_YMin(v_recorte),
                                    ST_XMax(v_recorte), ST_YMax(v_recorte))))
    ON CONFLICT ON CONSTRAINT satelite_observacoes_unica DO NOTHING
    RETURNING id INTO v_id;

    RETURN v_id IS NOT NULL;
END $$;
REVOKE ALL ON FUNCTION public.satelite_registrar(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.satelite_registrar(jsonb) TO service_role;

-- ------------------------------------------------------------
-- 4. Retenção: depois de 90 dias fica só o resumo numérico
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.satelite_podar()
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
    WITH p AS (
        UPDATE public.satelite_observacoes SET geom = NULL
        WHERE geom IS NOT NULL AND observado_em < now() - interval '90 days'
        RETURNING 1)
    SELECT count(*)::int FROM p;
$$;
REVOKE ALL ON FUNCTION public.satelite_podar() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 5. Agendamento (pg_cron + pg_net, mesmo padrão do push_cutucar)
--
-- Uma chamada por região, para cada uma ter seu próprio limite de CPU na
-- Edge Function e uma falha não atrapalhar as outras. A cada 6 h: o
-- Sentinel-1 só passa no mesmo ponto a cada ~6–12 dias, mais que isso é
-- desperdício. Endereço da função não é segredo.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.satelite_cutucar()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    r record;
    n integer := 0;
BEGIN
    FOR r IN SELECT id FROM public.monitored_regions
             WHERE is_public AND monitoring_config ? 'estacao_lat' LOOP
        BEGIN
            PERFORM net.http_post(
                url     := 'https://gayykjlkdtmmzovdbjkb.supabase.co/functions/v1/satelite-ingest',
                body    := jsonb_build_object('region_id', r.id),
                headers := '{"Content-Type": "application/json"}'::jsonb,
                timeout_milliseconds := 120000);
            n := n + 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'satelite_cutucar: %', SQLERRM;
        END;
    END LOOP;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.satelite_cutucar() FROM PUBLIC, anon, authenticated;

SELECT cron.schedule('satelite-ingest', '17 */6 * * *', 'SELECT public.satelite_cutucar()');
SELECT cron.schedule('satelite-podar', '23 4 * * 0', 'SELECT public.satelite_podar()');
