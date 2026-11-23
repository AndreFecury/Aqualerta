-- Tabelas mínimas que saude_fontes() lê (no Supabase vêm das migrações de
-- ANA, chuva, satélite, ar, OpenAQ e push). Só para o PostGIS local; rode
-- depois de stub_base.sql e antes de 20261127a_saude.sql.
CREATE TABLE IF NOT EXISTS public.chuva_estado (id integer PRIMARY KEY DEFAULT 1, ultima_coleta_ok timestamptz);
CREATE TABLE IF NOT EXISTS public.satelite_verificacoes (region_id uuid PRIMARY KEY, verificado_em timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.ar_estado (id integer PRIMARY KEY DEFAULT 1, modelo_ok_em timestamptz);
CREATE TABLE IF NOT EXISTS public.openaq_estado (id integer PRIMARY KEY DEFAULT 1, horas_ok_em timestamptz);
CREATE TABLE IF NOT EXISTS public.openaq_sensores (region_id uuid, sensor_id bigint, nome text, parametro smallint DEFAULT 2,
                                                   PRIMARY KEY (region_id, sensor_id));
CREATE TABLE IF NOT EXISTS public.openaq_horas (sensor_id bigint, hora timestamptz, pm25 numeric, PRIMARY KEY (sensor_id, hora));
CREATE TABLE IF NOT EXISTS public.push_fila (id bigserial PRIMARY KEY, criado_em timestamptz NOT NULL DEFAULT now(),
                                             tentativas integer NOT NULL DEFAULT 0, resultado jsonb);
