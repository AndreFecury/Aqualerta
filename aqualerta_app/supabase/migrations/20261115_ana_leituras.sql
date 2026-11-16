-- ============================================================
-- AquaAlerta: leituras automáticas de nível dos rios (ANA)
--
-- Busca a cada 30 minutos o nível das estações em
-- telemetriaws1.ana.gov.br (serviço público de telemetria da ANA)
-- e grava em hydro_readings. Roda inteiro dentro do Supabase
-- (pg_net + pg_cron): não precisa de servidor nem de chave.
-- Pode rodar este arquivo mais de uma vez.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- 1. As estações e as cotas ficam em 20261116_dados_reais.sql.

-- 2. Uma leitura por estação e horário (evita duplicar).
CREATE UNIQUE INDEX IF NOT EXISTS hydro_readings_estacao_hora
    ON public.hydro_readings (station_id, recorded_at);

-- 3. Pedidos feitos à ANA e ainda não processados.
CREATE TABLE IF NOT EXISTS public.ana_requisicoes (
    request_id  BIGINT PRIMARY KEY,
    station_id  UUID NOT NULL REFERENCES public.hydro_stations(id) ON DELETE CASCADE,
    criado_em   TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.ana_requisicoes ENABLE ROW LEVEL SECURITY;  -- sem políticas: fora da API

-- 4. Pede à ANA os últimos 2 dias de cada estação ativa.
CREATE OR REPLACE FUNCTION public.ana_solicitar_leituras()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    e        record;
    hoje     date := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
    pedidos  integer := 0;
BEGIN
    FOR e IN SELECT id, ana_code FROM public.hydro_stations WHERE is_active LOOP
        INSERT INTO public.ana_requisicoes (request_id, station_id)
        VALUES (
            net.http_get(
                url := 'http://telemetriaws1.ana.gov.br/ServiceANA.asmx/DadosHidrometeorologicos'
                    || '?codEstacao=' || e.ana_code
                    || '&dataInicio=' || to_char(hoje - 2, 'DD/MM/YYYY')
                    || '&dataFim='    || to_char(hoje, 'DD/MM/YYYY'),
                timeout_milliseconds := 60000
            ),
            e.id
        );
        pedidos := pedidos + 1;
    END LOOP;
    RETURN pedidos;
END $$;

-- 5. Lê as respostas que já chegaram e grava as leituras.
--    A ANA envia o nível em centímetros e a hora no horário de Brasília.
CREATE OR REPLACE FUNCTION public.ana_processar_respostas()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    gravadas integer := 0;
    n        integer;
    r        record;
BEGIN
    FOR r IN
        SELECT q.request_id, q.station_id, resp.status_code, resp.content
        FROM public.ana_requisicoes q
        JOIN net._http_response resp ON resp.id = q.request_id
    LOOP
        IF r.status_code = 200 AND r.content IS NOT NULL THEN
            INSERT INTO public.hydro_readings (station_id, recorded_at, water_level_m, source)
            SELECT r.station_id,
                   (trim(substring(bloco FROM '<DataHora>([^<]+)</DataHora>'))::timestamp
                        AT TIME ZONE 'America/Sao_Paulo'),
                   round(substring(bloco FROM '<Nivel>([^<]+)</Nivel>')::numeric / 100, 2),
                   'ANA'
            FROM regexp_split_to_table(r.content, '</DadosHidrometereologicos>') AS bloco
            WHERE substring(bloco FROM '<Nivel>([^<]+)</Nivel>') IS NOT NULL
              AND substring(bloco FROM '<DataHora>([^<]+)</DataHora>') IS NOT NULL
            ON CONFLICT (station_id, recorded_at) DO NOTHING;
            GET DIAGNOSTICS n = ROW_COUNT;
            gravadas := gravadas + n;
        END IF;
        DELETE FROM public.ana_requisicoes WHERE request_id = r.request_id;
    END LOOP;

    -- Pedidos sem resposta há mais de 1 dia e leituras com mais de 90 dias.
    DELETE FROM public.ana_requisicoes WHERE criado_em < now() - interval '1 day';
    DELETE FROM public.hydro_readings WHERE source = 'ANA' AND recorded_at < now() - interval '90 days';
    RETURN gravadas;
END $$;

REVOKE ALL ON FUNCTION public.ana_solicitar_leituras() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ana_processar_respostas() FROM PUBLIC, anon, authenticated;

-- 6. Agenda: pede a cada 30 min e processa 5 min depois.
SELECT cron.schedule('ana-solicitar-leituras', '*/30 * * * *', 'SELECT public.ana_solicitar_leituras()');
SELECT cron.schedule('ana-processar-respostas', '5,35 * * * *', 'SELECT public.ana_processar_respostas()');

-- 7. Primeira busca agora (o processamento roda no próximo :05 ou :35).
SELECT public.ana_solicitar_leituras() AS pedidos_enviados;
