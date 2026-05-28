-- ============================================================
-- AQUALERTA — Schema Supabase (PostgreSQL + PostGIS)
-- Execute no SQL Editor do Supabase: https://app.supabase.com
-- ============================================================

-- Habilitar extensões necessárias
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================
-- TABELA: usuarios (gerenciada pelo Supabase Auth)
-- Apenas metadados extras ficam aqui
-- ============================================================
CREATE TABLE IF NOT EXISTS public.user_profiles (
    id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    display_name    TEXT,
    fcm_token       TEXT,
    notification_preferences JSONB DEFAULT '{
        "push": true,
        "sound": true,
        "min_severity": "MEDIUM"
    }'::jsonb,
    created_at      TIMESTAMPTZ DEFAULT now(),
    updated_at      TIMESTAMPTZ DEFAULT now()
);

-- Criar perfil automaticamente ao registrar
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
BEGIN
  INSERT INTO public.user_profiles (id, display_name)
  VALUES (
    new.id,
    new.raw_user_meta_data->>'display_name'
  );
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- ============================================================
-- TABELA: regiões monitoradas
-- ============================================================
CREATE TABLE IF NOT EXISTS public.monitored_regions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name            TEXT NOT NULL,
    description     TEXT,
    -- Geometria: PostGIS POLYGON em WGS84
    geometry        GEOMETRY(POLYGON, 4326),
    -- Centroide gerado automaticamente
    centroid        GEOMETRY(POINT, 4326) GENERATED ALWAYS AS (ST_Centroid(geometry)) STORED,
    area_km2        NUMERIC(12, 2) DEFAULT 0,
    state_code      VARCHAR(2),
    municipality    TEXT,
    is_public       BOOLEAN DEFAULT true,
    created_by      UUID REFERENCES auth.users(id),
    monitoring_config JSONB DEFAULT '{
        "satellite_frequency_hours": 12,
        "alert_thresholds": {
            "flood_area_km2": 1.0,
            "min_severity": "MEDIUM"
        }
    }'::jsonb,
    created_at      TIMESTAMPTZ DEFAULT now(),
    updated_at      TIMESTAMPTZ DEFAULT now()
);

-- Índices geoespaciais
CREATE INDEX IF NOT EXISTS idx_regions_geometry   ON public.monitored_regions USING GIST(geometry);
CREATE INDEX IF NOT EXISTS idx_regions_centroid   ON public.monitored_regions USING GIST(centroid);
CREATE INDEX IF NOT EXISTS idx_regions_state      ON public.monitored_regions(state_code);
CREATE INDEX IF NOT EXISTS idx_regions_public     ON public.monitored_regions(is_public) WHERE is_public = true;

-- ============================================================
-- TABELA: regiões monitoradas por usuário (N:N)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.user_monitored_regions (
    user_id         UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    region_id       UUID REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    notify          BOOLEAN DEFAULT true,
    min_severity    TEXT DEFAULT 'MEDIUM'
                    CHECK (min_severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    subscribed_at   TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (user_id, region_id)
);

CREATE INDEX IF NOT EXISTS idx_umr_user   ON public.user_monitored_regions(user_id);
CREATE INDEX IF NOT EXISTS idx_umr_region ON public.user_monitored_regions(region_id);

-- ============================================================
-- TABELA: eventos de enchente
-- ============================================================
CREATE TABLE IF NOT EXISTS public.flood_events (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    region_id           UUID NOT NULL REFERENCES public.monitored_regions(id),
    detected_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    geojson_path        TEXT,                     -- Caminho no Supabase Storage / R2
    thumbnail_path      TEXT,
    flooded_area_km2    NUMERIC(10, 2) DEFAULT 0,
    affected_geometry   GEOMETRY(MULTIPOLYGON, 4326),
    severity            TEXT NOT NULL DEFAULT 'MEDIUM'
                        CHECK (severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    confidence          NUMERIC(3, 2) DEFAULT 0.75
                        CHECK (confidence BETWEEN 0 AND 1),
    satellite_type      TEXT DEFAULT 'SENTINEL_1_SAR',
    source_image_id     TEXT,
    processing_metadata JSONB,
    created_at          TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_fe_region_time  ON public.flood_events(region_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_fe_severity     ON public.flood_events(severity, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_fe_geometry     ON public.flood_events USING GIST(affected_geometry);
CREATE INDEX IF NOT EXISTS idx_fe_detected_at  ON public.flood_events(detected_at DESC);

-- ============================================================
-- TABELA: alertas
-- ============================================================
CREATE TABLE IF NOT EXISTS public.alerts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    flood_event_id  UUID REFERENCES public.flood_events(id),
    region_id       UUID NOT NULL REFERENCES public.monitored_regions(id),
    title           TEXT NOT NULL,
    body            TEXT NOT NULL,
    severity        TEXT NOT NULL
                    CHECK (severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    status          TEXT NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE','RESOLVED','SUPERSEDED')),
    valid_from      TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_until     TIMESTAMPTZ,
    issued_at       TIMESTAMPTZ DEFAULT now(),
    resolved_at     TIMESTAMPTZ,
    metadata        JSONB
);

CREATE INDEX IF NOT EXISTS idx_alerts_region_status ON public.alerts(region_id, status, issued_at DESC);
CREATE INDEX IF NOT EXISTS idx_alerts_active        ON public.alerts(status, issued_at DESC) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS idx_alerts_severity      ON public.alerts(severity, status);

-- ============================================================
-- TABELA: entregas de alertas (tracking de leitura)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.alert_deliveries (
    alert_id        UUID REFERENCES public.alerts(id) ON DELETE CASCADE,
    user_id         UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    delivered_via   TEXT DEFAULT 'APP'
                    CHECK (delivered_via IN ('FCM','WEBSOCKET','APP','EMAIL')),
    delivered_at    TIMESTAMPTZ DEFAULT now(),
    acknowledged_at TIMESTAMPTZ,
    PRIMARY KEY (alert_id, user_id, delivered_via)
);

-- ============================================================
-- TABELA: estações hidrológicas (ANA)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.hydro_stations (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ana_code        TEXT UNIQUE NOT NULL,
    name            TEXT NOT NULL,
    river           TEXT,
    location        GEOMETRY(POINT, 4326) NOT NULL,
    normal_level_m  NUMERIC(6, 2),
    alert_level_m   NUMERIC(6, 2),
    flood_level_m   NUMERIC(6, 2),
    emergency_level_m NUMERIC(6, 2),
    is_active       BOOLEAN DEFAULT true,
    metadata        JSONB,
    created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hydro_location ON public.hydro_stations USING GIST(location);

-- ============================================================
-- TABELA: leituras hidrológicas
-- ============================================================
CREATE TABLE IF NOT EXISTS public.hydro_readings (
    id              BIGSERIAL PRIMARY KEY,
    station_id      UUID NOT NULL REFERENCES public.hydro_stations(id),
    recorded_at     TIMESTAMPTZ NOT NULL,
    water_level_m   NUMERIC(6, 2),
    flow_m3s        NUMERIC(12, 2),
    status          TEXT CHECK (status IN ('NORMAL','ALERT','FLOOD','EMERGENCY')),
    source          TEXT DEFAULT 'ANA'
);

CREATE INDEX IF NOT EXISTS idx_hr_station_time ON public.hydro_readings(station_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_hr_time         ON public.hydro_readings(recorded_at DESC);

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================

-- user_profiles: usuário só vê e edita o próprio perfil
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users_own_profile" ON public.user_profiles
    FOR ALL USING (auth.uid() = id);

-- monitored_regions: regiões públicas são visíveis a todos autenticados
ALTER TABLE public.monitored_regions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_regions_read" ON public.monitored_regions
    FOR SELECT USING (is_public = true OR auth.uid() = created_by);
CREATE POLICY "own_regions_write" ON public.monitored_regions
    FOR INSERT WITH CHECK (auth.uid() = created_by);
CREATE POLICY "own_regions_update" ON public.monitored_regions
    FOR UPDATE USING (auth.uid() = created_by);

-- user_monitored_regions: usuário só vê as suas
ALTER TABLE public.user_monitored_regions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_subscriptions" ON public.user_monitored_regions
    FOR ALL USING (auth.uid() = user_id);

-- flood_events: leitura pública para autenticados
ALTER TABLE public.flood_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated_read_events" ON public.flood_events
    FOR SELECT USING (auth.role() = 'authenticated');

-- alerts: leitura pública para autenticados
ALTER TABLE public.alerts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated_read_alerts" ON public.alerts
    FOR SELECT USING (auth.role() = 'authenticated');

-- alert_deliveries: usuário só vê as suas
ALTER TABLE public.alert_deliveries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_deliveries" ON public.alert_deliveries
    FOR ALL USING (auth.uid() = user_id);

-- hydro_stations: leitura pública para autenticados
ALTER TABLE public.hydro_stations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated_read_stations" ON public.hydro_stations
    FOR SELECT USING (auth.role() = 'authenticated');

-- hydro_readings: leitura pública para autenticados
ALTER TABLE public.hydro_readings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated_read_readings" ON public.hydro_readings
    FOR SELECT USING (auth.role() = 'authenticated');

-- ============================================================
-- REALTIME — habilitar para alertas em tempo real
-- ============================================================
ALTER PUBLICATION supabase_realtime ADD TABLE public.alerts;
ALTER PUBLICATION supabase_realtime ADD TABLE public.flood_events;

-- ============================================================
-- SEED: regiões públicas da Amazônia
-- ============================================================
INSERT INTO public.monitored_regions
    (id, name, description, state_code, municipality, area_km2, is_public,
     geometry)
VALUES
    (
        uuid_generate_v4(),
        'Manaus',
        'Região metropolitana de Manaus — maior cidade da Amazônia',
        'AM', 'Manaus', 11401,
        true,
        ST_GeomFromText(
            'POLYGON((-60.1 -3.3, -59.8 -3.3, -59.8 -3.0, -60.1 -3.0, -60.1 -3.3))',
            4326)
    ),
    (
        uuid_generate_v4(),
        'Rio Solimões — Tefé',
        'Trecho do rio Solimões próximo a Tefé',
        'AM', 'Tefé', 23000,
        true,
        ST_GeomFromText(
            'POLYGON((-65.5 -3.8, -64.5 -3.8, -64.5 -3.2, -65.5 -3.2, -65.5 -3.8))',
            4326)
    ),
    (
        uuid_generate_v4(),
        'Porto Velho',
        'Região de Porto Velho — Rio Madeira',
        'RO', 'Porto Velho', 34097,
        true,
        ST_GeomFromText(
            'POLYGON((-64.0 -8.9, -63.5 -8.9, -63.5 -8.5, -64.0 -8.5, -64.0 -8.9))',
            4326)
    ),
    (
        uuid_generate_v4(),
        'Óbidos — Rio Amazonas',
        'Estreitamento do rio Amazonas em Óbidos — estação hidrológica estratégica',
        'PA', 'Óbidos', 49853,
        true,
        ST_GeomFromText(
            'POLYGON((-55.7 -2.0, -55.3 -2.0, -55.3 -1.7, -55.7 -1.7, -55.7 -2.0))',
            4326)
    ),
    (
        uuid_generate_v4(),
        'Santarém',
        'Confluência dos rios Tapajós e Amazonas',
        'PA', 'Santarém', 22887,
        true,
        ST_GeomFromText(
            'POLYGON((-54.9 -2.6, -54.4 -2.6, -54.4 -2.2, -54.9 -2.2, -54.9 -2.6))',
            4326)
    ),
    (
        uuid_generate_v4(),
        'Rio Branco',
        'Bacia do Rio Acre — suscetível a inundações sazonais',
        'AC', 'Rio Branco', 9962,
        true,
        ST_GeomFromText(
            'POLYGON((-68.0 -10.1, -67.6 -10.1, -67.6 -9.8, -68.0 -9.8, -68.0 -10.1))',
            4326)
    ),
    (
        uuid_generate_v4(),
        'Belém',
        'Região metropolitana de Belém — Estuário Amazônico',
        'PA', 'Belém', 1059,
        true,
        ST_GeomFromText(
            'POLYGON((-48.7 -1.6, -48.3 -1.6, -48.3 -1.2, -48.7 -1.2, -48.7 -1.6))',
            4326)
    ),
    (
        uuid_generate_v4(),
        'Macapá',
        'Margem do rio Amazonas — próximo à foz',
        'AP', 'Macapá', 6563,
        true,
        ST_GeomFromText(
            'POLYGON((-51.2 0.1, -50.9 0.1, -50.9 0.4, -51.2 0.4, -51.2 0.1))',
            4326)
    )
ON CONFLICT DO NOTHING;

-- ============================================================
-- SEED: estações hidrológicas críticas da ANA
-- ============================================================
INSERT INTO public.hydro_stations
    (ana_code, name, river, location,
     normal_level_m, alert_level_m, flood_level_m, emergency_level_m)
VALUES
    ('14390000', 'Manaus',       'Rio Negro',    ST_GeomFromText('POINT(-60.0212 -3.1319)', 4326),  22.0, 27.0, 29.0, 29.5),
    ('17050001', 'Óbidos',       'Rio Amazonas', ST_GeomFromText('POINT(-55.5177 -1.9177)', 4326),   7.0, 10.0, 11.5, 12.0),
    ('15400000', 'Porto Velho',  'Rio Madeira',  ST_GeomFromText('POINT(-63.9068 -8.7612)', 4326),  11.0, 14.0, 17.0, 17.5),
    ('13850000', 'Tefé',         'Rio Solimões', ST_GeomFromText('POINT(-64.7092 -3.3642)', 4326),   8.0, 12.0, 14.0, 14.5),
    ('18850000', 'Santarém',     'Rio Tapajós',  ST_GeomFromText('POINT(-54.7108 -2.4449)', 4326),   4.0,  6.5,  8.0,  8.5)
ON CONFLICT (ana_code) DO NOTHING;

-- ============================================================
-- SEED: alertas de exemplo (remova em produção)
-- ============================================================
-- Descomente para popular com dados de teste:
/*
WITH region AS (
    SELECT id FROM public.monitored_regions WHERE name = 'Manaus' LIMIT 1
)
INSERT INTO public.alerts (region_id, title, body, severity, status, issued_at)
SELECT
    region.id,
    'Nível do Rio Negro acima do normal',
    'O rio Negro em Manaus atingiu 27,3m — acima do nível de alerta (27m). Monitoramento intensificado.',
    'HIGH',
    'ACTIVE',
    now() - interval '2 hours'
FROM region;

WITH region AS (
    SELECT id FROM public.monitored_regions WHERE name = 'Porto Velho' LIMIT 1
)
INSERT INTO public.alerts (region_id, title, body, severity, status, issued_at)
SELECT
    region.id,
    'Rio Madeira com elevação significativa',
    'Estação de Porto Velho registra 15,2m — monitoramento em curso.',
    'MEDIUM',
    'ACTIVE',
    now() - interval '5 hours'
FROM region;
*/

-- ============================================================
-- VIEW: eventos recentes com nome da região
-- ============================================================
CREATE OR REPLACE VIEW public.v_recent_flood_events AS
SELECT
    fe.id,
    fe.region_id,
    mr.name      AS region_name,
    mr.state_code,
    fe.detected_at,
    fe.flooded_area_km2,
    fe.severity,
    fe.confidence,
    fe.satellite_type,
    fe.geojson_path,
    fe.thumbnail_path,
    ST_X(ST_Centroid(mr.geometry)) AS center_lng,
    ST_Y(ST_Centroid(mr.geometry)) AS center_lat
FROM public.flood_events fe
JOIN public.monitored_regions mr ON mr.id = fe.region_id
WHERE fe.detected_at > now() - interval '72 hours'
ORDER BY fe.detected_at DESC;

-- ============================================================
-- VIEW: alertas ativos com região
-- ============================================================
CREATE OR REPLACE VIEW public.v_active_alerts AS
SELECT
    a.id,
    a.region_id,
    mr.name      AS region_name,
    mr.state_code,
    a.title,
    a.body,
    a.severity,
    a.status,
    a.issued_at,
    a.flood_event_id,
    ST_X(ST_Centroid(mr.geometry)) AS center_lng,
    ST_Y(ST_Centroid(mr.geometry)) AS center_lat
FROM public.alerts a
JOIN public.monitored_regions mr ON mr.id = a.region_id
WHERE a.status = 'ACTIVE'
ORDER BY a.issued_at DESC;
