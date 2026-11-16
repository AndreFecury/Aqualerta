-- ============================================================
-- AquaAlerta v3: views usadas pelas telas novas
-- Rodar uma vez no SQL Editor do Supabase (depois do schema.sql).
-- O app funciona sem elas, mas sem os contornos reais no mapa
-- e sem a tela Rios.
-- ============================================================

-- Regiões com contorno em GeoJSON e centro.
CREATE OR REPLACE VIEW public.v_regioes_mapa
WITH (security_invoker = on) AS
SELECT
    mr.id,
    mr.name,
    mr.state_code,
    mr.municipality,
    mr.area_km2,
    ST_AsGeoJSON(mr.geometry)::json        AS geojson,
    ST_Y(ST_Centroid(mr.geometry))          AS center_lat,
    ST_X(ST_Centroid(mr.geometry))          AS center_lng
FROM public.monitored_regions mr
WHERE mr.is_public = true;

-- Eventos de inundação dos últimos 30 dias ou ligados a um alerta ativo,
-- com a área real
-- (affected_geometry) quando existir; senão, o contorno da região.
CREATE OR REPLACE VIEW public.v_eventos_mapa
WITH (security_invoker = on) AS
SELECT
    fe.id,
    fe.region_id,
    mr.name                                  AS region_name,
    mr.state_code,
    fe.detected_at,
    fe.severity,
    fe.flooded_area_km2,
    fe.affected_geometry IS NOT NULL         AS area_real,
    ST_AsGeoJSON(COALESCE(fe.affected_geometry, mr.geometry))::json AS geojson
FROM public.flood_events fe
JOIN public.monitored_regions mr ON mr.id = fe.region_id
WHERE fe.detected_at > now() - interval '30 days'
   OR fe.id IN (SELECT a.flood_event_id FROM public.alerts a WHERE a.status = 'ACTIVE');

-- Estações da ANA com posição, cotas e a leitura mais recente.
CREATE OR REPLACE VIEW public.v_estacoes_nivel
WITH (security_invoker = on) AS
SELECT
    hs.id,
    hs.ana_code,
    hs.name,
    hs.river,
    ST_Y(hs.location)                        AS lat,
    ST_X(hs.location)                        AS lng,
    hs.normal_level_m,
    hs.alert_level_m,
    hs.flood_level_m,
    hs.emergency_level_m,
    ult.water_level_m,
    ult.recorded_at
FROM public.hydro_stations hs
LEFT JOIN LATERAL (
    SELECT hr.water_level_m, hr.recorded_at
    FROM public.hydro_readings hr
    WHERE hr.station_id = hs.id AND hr.water_level_m IS NOT NULL
    ORDER BY hr.recorded_at DESC
    LIMIT 1
) ult ON true
WHERE hs.is_active = true;

GRANT SELECT ON public.v_regioes_mapa, public.v_eventos_mapa, public.v_estacoes_nivel
    TO anon, authenticated;

-- Leituras atualizadas em tempo real na tela Rios.
-- (Pode rodar mais de uma vez: só adiciona se ainda não estiver.)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'hydro_readings'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.hydro_readings;
    END IF;
END $$;
