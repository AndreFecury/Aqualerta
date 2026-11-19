-- Base mínima para testar migrações num PostGIS LOCAL (não roda em produção).
-- Imita só o que as migrações de satélite/chuva usam do schema do Supabase.
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS extensions;
DO $$ BEGIN
  CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE SCHEMA IF NOT EXISTS net;
CREATE TABLE IF NOT EXISTS net.chamadas (url text, body jsonb);
CREATE OR REPLACE FUNCTION net.http_post(url text, body jsonb, params jsonb DEFAULT '{}', headers jsonb DEFAULT '{}', timeout_milliseconds int DEFAULT 5000)
RETURNS bigint LANGUAGE sql AS $$ INSERT INTO net.chamadas VALUES (url, body); SELECT 1::bigint $$;
CREATE SCHEMA IF NOT EXISTS cron;
CREATE TABLE IF NOT EXISTS cron.job (jobname text PRIMARY KEY, schedule text, command text);
CREATE OR REPLACE FUNCTION cron.schedule(n text, s text, c text) RETURNS bigint LANGUAGE sql AS
$$ INSERT INTO cron.job VALUES (n,s,c) ON CONFLICT (jobname) DO UPDATE SET schedule=EXCLUDED.schedule, command=EXCLUDED.command; SELECT 1::bigint $$;

CREATE OR REPLACE FUNCTION public.metros_br(v numeric)
RETURNS text LANGUAGE sql IMMUTABLE
AS $$ SELECT replace(to_char(v, 'FM9990.00'), '.', ',') $$;

CREATE TABLE IF NOT EXISTS public.monitored_regions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, state_code text,
  is_public boolean DEFAULT true, monitoring_config jsonb DEFAULT '{}'::jsonb,
  geometry geometry(Polygon,4326));
INSERT INTO public.monitored_regions (id, name, state_code, monitoring_config) VALUES
 ('a0000000-0000-0000-0000-000000000001','Manaus','AM',
  '{"origem":"ibge","municipio_ibge":"1302603","estacao_ana":"14990000","estacao_lat":-3.1383,"estacao_lng":-60.0272}'),
 ('a0000000-0000-0000-0000-000000000002','Parintins','AM',
  '{"origem":"ibge","municipio_ibge":"1303403","estacao_ana":"16350002","estacao_lat":-2.6306,"estacao_lng":-56.7519}')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS public.flood_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), region_id uuid NOT NULL, detected_at timestamptz NOT NULL DEFAULT now(),
  severity text, center_lat float8, center_lng float8, processing_metadata jsonb);
CREATE TABLE IF NOT EXISTS public.alerts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), flood_event_id uuid, region_id uuid NOT NULL,
  title text NOT NULL, body text NOT NULL, severity text NOT NULL, status text NOT NULL DEFAULT 'ACTIVE',
  valid_from timestamptz NOT NULL DEFAULT now(), valid_until timestamptz, issued_at timestamptz DEFAULT now(),
  resolved_at timestamptz, metadata jsonb);

CREATE TABLE IF NOT EXISTS public.hydro_stations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), ana_code text UNIQUE, name text, river text,
  alert_level_m numeric, flood_level_m numeric, emergency_level_m numeric, is_active boolean DEFAULT true);
CREATE TABLE IF NOT EXISTS public.hydro_readings (
  station_id uuid, water_level_m numeric, recorded_at timestamptz);
-- Rio Negro em Manaus abaixo da cota, com um alerta antigo do rio ainda ativo.
INSERT INTO public.hydro_stations (ana_code, name, river, alert_level_m, flood_level_m, emergency_level_m)
VALUES ('14990000','Manaus','Rio Negro',27,27.5,29) ON CONFLICT DO NOTHING;
INSERT INTO public.hydro_readings SELECT id, 16.2, now() - interval '10 minutes' FROM public.hydro_stations WHERE ana_code = '14990000';
INSERT INTO public.alerts (region_id, title, body, severity, metadata)
SELECT 'a0000000-0000-0000-0000-000000000001', 'Rio Negro acima da cota de alerta em Manaus', 'teste', 'MEDIUM',
       '{"origem":"telemetria-ana"}'
WHERE NOT EXISTS (SELECT 1 FROM public.alerts WHERE metadata->>'origem' = 'telemetria-ana');
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;

-- pg_net assíncrono de mentira: http_get só registra e devolve um id; o
-- teste grava a "resposta" em net._http_response com esse id.
CREATE TABLE IF NOT EXISTS net._http_response (
  id bigint PRIMARY KEY, status_code integer, content_type text, headers jsonb,
  content text, timed_out boolean, error_msg text, created timestamptz NOT NULL DEFAULT now());
CREATE SEQUENCE IF NOT EXISTS net.pedido_seq;
CREATE OR REPLACE FUNCTION net.http_get(url text, params jsonb DEFAULT '{}', headers jsonb DEFAULT '{}', timeout_milliseconds int DEFAULT 5000)
RETURNS bigint LANGUAGE sql AS $$ INSERT INTO net.chamadas VALUES (url, NULL); SELECT nextval('net.pedido_seq') $$;
CREATE OR REPLACE FUNCTION cron.unschedule(n text) RETURNS boolean LANGUAGE sql AS
$$ DELETE FROM cron.job WHERE jobname = n RETURNING true $$;
