-- ============================================================
-- Chuva: coleta pelo próprio banco (pg_net), sem Edge Function
--
-- Em 19/11/2026 o CEMADEN passou a recusar o IP de saída das Edge
-- Functions (depois de uma rajada de pedidos nossa), mas continuou
-- respondendo ao pg_net do banco. A coleta passa a seguir o mesmo padrão
-- da ANA (ana_solicitar_leituras / ana_processar_respostas):
--
--   chuva_pedir()     a cada 5 min: pede a lista do Brasil (acumulado de
--                     24 h por estação) e o hora a hora das estações que
--                     estão com chuva (no máximo 8, as de mais chuva).
--   chuva_processar() 2 min depois: lê as respostas, grava as leituras e
--                     atualiza os avisos (chuva_atualizar_avisos).
--
-- Estação seca há 24 h ganha o zero da hora corrente sem pedido extra.
-- Poucos pedidos por ciclo de propósito: o CEMADEN bloqueia rajadas.
-- Idempotente. Depende de 20261119_chuva.sql.
-- ============================================================

ALTER TABLE public.chuva_estacoes ADD COLUMN IF NOT EXISTS acum24h    numeric;
ALTER TABLE public.chuva_estacoes ADD COLUMN IF NOT EXISTS acum24h_em timestamptz;

CREATE TABLE IF NOT EXISTS public.chuva_pedidos (
    request_id bigint PRIMARY KEY,           -- id do pg_net
    tipo       text NOT NULL CHECK (tipo IN ('lista', 'horario')),
    estacao_id integer,
    criado_em  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.chuva_pedidos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.chuva_pedidos FROM anon, authenticated;

-- ------------------------------------------------------------
-- Pedidos
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chuva_pedir()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    e record;
    n integer := 0;
BEGIN
    -- Pedido sem resposta há mais de 30 min: desiste.
    DELETE FROM public.chuva_pedidos WHERE criado_em < now() - interval '30 minutes';

    INSERT INTO public.chuva_pedidos (request_id, tipo)
    VALUES (net.http_get(url := 'https://resources.cemaden.gov.br/dados/311_24.json',
                         timeout_milliseconds := 30000), 'lista');
    n := 1;

    FOR e IN
        SELECT id FROM public.chuva_estacoes
        WHERE ativa AND acum24h > 0 AND acum24h_em > now() - interval '30 minutes'
        ORDER BY acum24h DESC
        LIMIT 8
    LOOP
        INSERT INTO public.chuva_pedidos (request_id, tipo, estacao_id)
        VALUES (net.http_get(
                    url := 'https://mapservices.cemaden.gov.br/MapaInterativoWS/resources/horario/'
                           || e.id || '/24',
                    timeout_milliseconds := 20000), 'horario', e.id);
        n := n + 1;
    END LOOP;
    RETURN n;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'chuva_pedir: %', SQLERRM;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.chuva_pedir() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Leitura das respostas
-- ------------------------------------------------------------

-- Resposta do endpoint "horario" → leituras por hora (início da hora, UTC).
-- Mesma regra de nucleo.ts: o dia avança quando o rótulo da hora volta
-- para trás (23h → 0h); valor nulo fica de fora (sem dado não é zero).
CREATE OR REPLACE FUNCTION public.chuva_ler_horario(p_estacao integer, j jsonb)
RETURNS TABLE (estacao_id integer, hora timestamptz, mm numeric)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    i     integer;
    h     integer;
    h_ant integer := NULL;
    dia   integer := 0;
    data  text;
    v     jsonb;
BEGIN
    IF j IS NULL OR jsonb_typeof(j->'horarios') <> 'array' THEN RETURN; END IF;
    FOR i IN 0 .. jsonb_array_length(j->'horarios') - 1 LOOP
        h := NULLIF(regexp_replace(j->'horarios'->>i, '\D', '', 'g'), '')::int;
        IF h IS NULL THEN EXIT; END IF;
        IF h_ant IS NOT NULL AND h < h_ant THEN dia := dia + 1; END IF;
        h_ant := h;
        data := j->'datas'->>dia;
        IF data IS NULL THEN EXIT; END IF;
        v := j->'acumulados'->dia->i;
        IF v IS NULL OR jsonb_typeof(v) <> 'number' OR (v::text)::numeric < 0 THEN CONTINUE; END IF;
        estacao_id := p_estacao;
        hora := (to_date(data, 'DD/MM/YYYY') + make_interval(hours => h))::timestamp AT TIME ZONE 'UTC';
        mm := round((v::text)::numeric, 1);
        RETURN NEXT;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.chuva_processar()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    p          record;
    lista      jsonb;
    txt        text;
    lidas      integer := 0;
    falhas     integer := 0;
    erros      text[] := '{}';
    gravadas   integer := 0;
    n          integer;
    hora_atual timestamptz := date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
    tem_algo   boolean := false;
BEGIN
    FOR p IN
        SELECT cp.*, r.status_code, r.timed_out, r.error_msg, r.content
        FROM public.chuva_pedidos cp
        JOIN net._http_response r ON r.id = cp.request_id
        ORDER BY cp.tipo DESC   -- 'lista' antes de 'horario'
    LOOP
        tem_algo := true;
        BEGIN
            IF p.status_code IS DISTINCT FROM 200 THEN
                RAISE EXCEPTION '%', coalesce(p.error_msg, 'HTTP ' || coalesce(p.status_code::text, '?'));
            END IF;

            IF p.tipo = 'lista' THEN
                txt := p.content;
                lista := substr(txt, strpos(txt, '(') + 1,
                                length(txt) - strpos(reverse(txt), ')') - strpos(txt, '('))::jsonb;

                -- Lista de estações: renova uma vez por dia (novas ou desativadas).
                -- Antes dos acumulados, para a primeira coleta já ter onde gravar.
                IF coalesce((SELECT estacoes_atualizadas_em FROM public.chuva_estado WHERE id = 1),
                            '-infinity') < now() - interval '24 hours' THEN
                    PERFORM public.chuva_registrar_estacoes(coalesce((
                        SELECT jsonb_agg(jsonb_build_object(
                            'id', (x->>'idestacao')::int, 'codigo', x->>'codestacao',
                            'nome', x->>'nomeestacao', 'tipo', x->>'tipoestacao',
                            'region_id', mr.id, 'lat', (x->>'latitude')::float8,
                            'lng', (x->>'longitude')::float8))
                        FROM jsonb_array_elements(lista->0->'estacao') x
                        JOIN public.monitored_regions mr
                          ON mr.is_public
                         AND (mr.monitoring_config->>'municipio_ibge')::int = (x->>'codibge')::int
                        WHERE (x->>'status')::int = 0
                          AND x->>'tipoestacao' ~* '(pluviom|hidrol)'
                          AND jsonb_typeof(x->'latitude') = 'number'), '[]'::jsonb));
                END IF;

                -- Acumulado de 24 h das nossas estações.
                WITH s AS (
                    SELECT (x->>'idestacao')::int AS id,
                           CASE WHEN jsonb_typeof(x->'acumulado') = 'number'
                                     AND (x->>'acumulado')::numeric >= 0
                                THEN (x->>'acumulado')::numeric END AS acum
                    FROM jsonb_array_elements(lista->0->'estacao') x
                )
                UPDATE public.chuva_estacoes e
                   SET acum24h = s.acum, acum24h_em = now()
                  FROM s WHERE s.id = e.id;

                -- Seca há 24 h: a hora corrente também é zero.
                INSERT INTO public.chuva_leituras AS l (estacao_id, hora, mm, lido_em)
                SELECT e.id, hora_atual, 0, now()
                FROM public.chuva_estacoes e
                WHERE e.ativa AND e.acum24h = 0 AND e.acum24h_em > now() - interval '1 minute'
                ON CONFLICT (estacao_id, hora) DO UPDATE SET mm = 0, lido_em = now();
                GET DIAGNOSTICS n = ROW_COUNT;
                lidas := lidas + n;
                gravadas := gravadas + n;


            ELSE -- horario
                INSERT INTO public.chuva_leituras AS l (estacao_id, hora, mm, lido_em)
                SELECT h.estacao_id, h.hora, h.mm, now()
                FROM public.chuva_ler_horario(p.estacao_id, p.content::jsonb) h
                WHERE EXISTS (SELECT 1 FROM public.chuva_estacoes e WHERE e.id = h.estacao_id)
                ON CONFLICT (estacao_id, hora) DO UPDATE SET mm = EXCLUDED.mm, lido_em = now();
                GET DIAGNOSTICS n = ROW_COUNT;
                gravadas := gravadas + n;
                lidas := lidas + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            falhas := falhas + 1;
            erros := erros || (p.tipo || coalesce(' ' || p.estacao_id, '') || ': ' || left(SQLERRM, 120));
        END;
        DELETE FROM public.chuva_pedidos WHERE request_id = p.request_id;
    END LOOP;

    IF tem_algo THEN
        UPDATE public.chuva_estado
           SET ultima_coleta = now(),
               ultima_coleta_ok = CASE WHEN lidas > 0 THEN now() ELSE ultima_coleta_ok END,
               estacoes_lidas = lidas,
               estacoes_com_falha = falhas,
               ultimo_erro = CASE WHEN falhas > 0 THEN left(array_to_string(erros, '; '), 500) END
         WHERE id = 1;
        PERFORM public.chuva_atualizar_avisos();
    END IF;
    RETURN gravadas;
END $$;
REVOKE ALL ON FUNCTION public.chuva_processar() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Agendamento: sai a Edge Function, entra o banco.
-- ------------------------------------------------------------
DO $$ BEGIN
    PERFORM cron.unschedule('chuva-cemaden');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
SELECT cron.schedule('chuva-pedir',     '*/5 * * * *',    'SELECT public.chuva_pedir()');
SELECT cron.schedule('chuva-processar', '2-59/5 * * * *', 'SELECT public.chuva_processar()');
