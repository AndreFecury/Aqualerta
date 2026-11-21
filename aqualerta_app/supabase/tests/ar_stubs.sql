-- Tabelas do app que o push usa (no Supabase vêm do schema.sql). Só para o
-- PostGIS local; rode depois de stub_base.sql e antes de 20261118_push_fcm.sql.
CREATE TABLE IF NOT EXISTS public.user_profiles (
  id uuid PRIMARY KEY, fcm_token text, notification_preferences jsonb DEFAULT '{}'::jsonb,
  updated_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.user_monitored_regions (
  user_id uuid NOT NULL, region_id uuid NOT NULL, notify boolean DEFAULT true,
  PRIMARY KEY (user_id, region_id));
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
