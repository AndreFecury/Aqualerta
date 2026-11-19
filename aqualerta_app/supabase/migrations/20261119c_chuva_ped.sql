-- ============================================================
-- Chuva: dados de 10 em 10 min pela PED oficial do CEMADEN
--
-- A PED (ped.cemaden.gov.br) exige conta. Com ela:
--   POST https://sgaa.cemaden.gov.br/SGAA/rest/controle-token/tokens
--        {"email","password"} → {"token","timeToExp"}  (token vale 4 h)
--   GET  https://sws.cemaden.gov.br/PED/rest/pcds/pcds-dados-recentes
--        ?rede=11&uf=AM&codibge=1302603   header "token"
--        → últimas 3 h de cada estação: datahora, codestacao, id_sensor, valor
-- Limite da PED: 12 pedidos por minuto (passou, bloqueia). Aqui: 1 por
-- município a cada 5 min (6 municípios = 1,2/min) + 1 token a cada ~4 h.
--
-- Credenciais: SÓ no Vault do Supabase, com os nomes ped_email e ped_senha
-- (cadastradas pelo dono da conta no painel). Nunca no git nem no app.
-- Sem as credenciais, nada muda: a coleta aberta (20261119b) segue sozinha.
--
-- Como entra na regra: chuva_avaliar passa a usar, para "última hora", o
-- maior valor entre o balde de hora cheia (coleta aberta) e a soma móvel de
-- 60 min dos dados de 10 min. A janela é ancorada na última leitura de cada
-- estação, não no relógio: em 19/11/2026 a PED mostrou datahora até ~20 min
-- à frente do UTC do próprio servidor deles.
--
-- Sensor de chuva = id_sensor 10 (o exemplo da documentação da PED). Sem
-- chuva as estações mandam de hora em hora; com chuva, de 10 em 10 min.
-- Idempotente. Depende de 20261119_chuva.sql e 20261119b_chuva_pgnet.sql.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.chuva_leituras_10min (
    estacao_id   integer NOT NULL REFERENCES public.chuva_estacoes(id) ON DELETE CASCADE,
    fim          timestamptz NOT NULL,          -- datahora da PED (fim do intervalo)
    mm           numeric NOT NULL CHECK (mm >= 0),
    qualificacao text,
    lido_em      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (estacao_id, fim)
);
CREATE INDEX IF NOT EXISTS chuva_leituras_10min_fim_idx ON public.chuva_leituras_10min (fim DESC);
ALTER TABLE public.chuva_leituras_10min ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.chuva_leituras_10min FROM anon, authenticated;
GRANT SELECT ON public.chuva_leituras_10min TO anon, authenticated;
DROP POLICY IF EXISTS chuva_leituras_10min_leitura ON public.chuva_leituras_10min;
CREATE POLICY chuva_leituras_10min_leitura ON public.chuva_leituras_10min
    FOR SELECT TO anon, authenticated USING (true);

-- Token da PED: privado (sem leitura pública, sem política).
CREATE TABLE IF NOT EXISTS public.chuva_ped_token (
    id        integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    token     text,
    expira_em timestamptz
);
INSERT INTO public.chuva_ped_token (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.chuva_ped_token ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.chuva_ped_token FROM anon, authenticated;

ALTER TABLE public.chuva_estado ADD COLUMN IF NOT EXISTS ped_ultima_ok timestamptz;
ALTER TABLE public.chuva_estado ADD COLUMN IF NOT EXISTS ped_erro      text;

ALTER TABLE public.chuva_pedidos DROP CONSTRAINT IF EXISTS chuva_pedidos_tipo_check;
ALTER TABLE public.chuva_pedidos ADD CONSTRAINT chuva_pedidos_tipo_check
    CHECK (tipo IN ('lista', 'horario', 'ped_token', 'ped_dados'));

-- Credenciais do Vault (NULL se não cadastradas ou se não há Vault).
CREATE OR REPLACE FUNCTION public.chuva_ped_credenciais(OUT email text, OUT senha text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    SELECT max(decrypted_secret) FILTER (WHERE name = 'ped_email'),
           max(decrypted_secret) FILTER (WHERE name = 'ped_senha')
      INTO email, senha
      FROM vault.decrypted_secrets
     WHERE name IN ('ped_email', 'ped_senha');
EXCEPTION WHEN OTHERS THEN
    email := NULL; senha := NULL;
END $$;
REVOKE ALL ON FUNCTION public.chuva_ped_credenciais() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Pedidos: a coleta aberta de antes + a PED quando houver conta.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chuva_pedir()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    e    record;
    m    record;
    cred record;
    tk   record;
    n    integer := 0;
BEGIN
    -- Pedido sem resposta há mais de 30 min: desiste.
    DELETE FROM public.chuva_pedidos WHERE criado_em < now() - interval '30 minutes';

    -- Coleta aberta (lista do Brasil + hora a hora das estações com chuva).
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

    -- PED (só com conta cadastrada no Vault).
    SELECT * INTO cred FROM public.chuva_ped_credenciais();
    IF cred.email IS NOT NULL AND cred.senha IS NOT NULL THEN
        SELECT token, expira_em INTO tk FROM public.chuva_ped_token WHERE id = 1;

        -- Token novo 15 min antes de vencer; no máximo um pedido a cada 10 min
        -- (senha errada não vira martelada no servidor deles).
        IF (tk.token IS NULL OR tk.expira_em < now() + interval '15 minutes')
           AND NOT EXISTS (SELECT 1 FROM public.chuva_pedidos
                           WHERE tipo = 'ped_token' AND criado_em > now() - interval '10 minutes')
           AND coalesce((SELECT ped_erro LIKE 'token recusado%' AND ultima_coleta > now() - interval '1 hour'
                         FROM public.chuva_estado WHERE id = 1), false) IS NOT TRUE
        THEN
            INSERT INTO public.chuva_pedidos (request_id, tipo)
            VALUES (net.http_post(
                        url := 'https://sgaa.cemaden.gov.br/SGAA/rest/controle-token/tokens',
                        body := jsonb_build_object('email', cred.email, 'password', cred.senha),
                        headers := '{"Content-Type": "application/json", "Accept": "application/json"}'::jsonb,
                        timeout_milliseconds := 20000), 'ped_token');
            n := n + 1;
        END IF;

        IF tk.token IS NOT NULL AND tk.expira_em > now() + interval '2 minutes' THEN
            FOR m IN
                SELECT DISTINCT mr.state_code AS uf, mr.monitoring_config->>'municipio_ibge' AS ibge
                FROM public.monitored_regions mr
                JOIN public.chuva_estacoes ce ON ce.region_id = mr.id AND ce.ativa
                WHERE mr.state_code IS NOT NULL AND mr.monitoring_config ? 'municipio_ibge'
                ORDER BY 1, 2
                LIMIT 10   -- teto de segurança: 10 pedidos a cada 5 min = 2/min
            LOOP
                INSERT INTO public.chuva_pedidos (request_id, tipo)
                VALUES (net.http_get(
                            url := 'https://sws.cemaden.gov.br/PED/rest/pcds/pcds-dados-recentes',
                            params := jsonb_build_object('rede', '11', 'uf', m.uf,
                                                         'codibge', m.ibge, 'formato', 'JSON'),
                            headers := jsonb_build_object('token', tk.token, 'Accept', 'application/json'),
                            timeout_milliseconds := 20000), 'ped_dados');
                n := n + 1;
            END LOOP;
        END IF;
    END IF;
    RETURN n;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'chuva_pedir: %', SQLERRM;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.chuva_pedir() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Leitura das respostas
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chuva_processar()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    p          record;
    lista      jsonb;
    j          jsonb;
    txt        text;
    lidas      integer := 0;
    falhas     integer := 0;
    erros      text[] := '{}';
    gravadas   integer := 0;
    n          integer;
    hora_atual timestamptz := date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
    tem_algo   boolean := false;
    ped_ok     boolean := false;
    erro_ped   text := NULL;
    token_caiu boolean := false;
BEGIN
    FOR p IN
        SELECT cp.*, r.status_code, r.timed_out, r.error_msg, r.content
        FROM public.chuva_pedidos cp
        JOIN net._http_response r ON r.id = cp.request_id
        -- lista antes de horario; token antes dos dados da PED
        ORDER BY CASE cp.tipo WHEN 'lista' THEN 0 WHEN 'horario' THEN 1
                              WHEN 'ped_token' THEN 2 ELSE 3 END
    LOOP
        tem_algo := true;
        BEGIN
            IF p.tipo = 'ped_token' THEN
                IF p.status_code IN (400, 401, 403, 404) THEN
                    -- Nada do corpo vai para o log: pode ecoar dados da conta.
                    RAISE EXCEPTION 'token recusado (HTTP %): confira ped_email/ped_senha no Vault', p.status_code;
                ELSIF p.status_code IS DISTINCT FROM 200 THEN
                    RAISE EXCEPTION 'token: %', coalesce(p.error_msg, 'HTTP ' || coalesce(p.status_code::text, '?'));
                END IF;
                j := p.content::jsonb;
                IF coalesce(j->>'token', '') = '' THEN
                    RAISE EXCEPTION 'token: resposta sem token';
                END IF;
                UPDATE public.chuva_ped_token
                   SET token = j->>'token',
                       expira_em = now() + make_interval(secs => coalesce(
                           CASE WHEN jsonb_typeof(j->'timeToExp') = 'number'
                                THEN (j->>'timeToExp')::numeric END, 4 * 3600))
                 WHERE id = 1;
                -- A resposta guardada pelo pg_net tem o token: apaga já.
                BEGIN
                    DELETE FROM net._http_response WHERE id = p.request_id;
                EXCEPTION WHEN OTHERS THEN NULL;
                END;

            ELSIF p.tipo = 'ped_dados' THEN
                IF p.status_code IN (400, 401) THEN
                    -- Token vencido ou invalidado: o próximo ciclo pede outro.
                    -- (Apagado fora deste bloco: o RAISE desfaria o UPDATE.)
                    token_caiu := true;
                    RAISE EXCEPTION 'dados: token não aceito (HTTP %)', p.status_code;
                ELSIF p.status_code IS DISTINCT FROM 200 THEN
                    RAISE EXCEPTION 'dados: %', coalesce(p.error_msg, 'HTTP ' || coalesce(p.status_code::text, '?'));
                END IF;
                j := p.content::jsonb;
                IF jsonb_typeof(j) <> 'array' THEN
                    RAISE EXCEPTION 'dados: resposta não é lista';
                END IF;
                INSERT INTO public.chuva_leituras_10min AS l (estacao_id, fim, mm, qualificacao, lido_em)
                SELECT DISTINCT ON (e.id, x.fim) e.id, x.fim, x.mm, x.q, now()
                FROM (
                    SELECT d->>'codestacao' AS cod,
                           (d->>'datahora')::timestamp AT TIME ZONE 'UTC' AS fim,
                           round((d->>'valor')::numeric, 2) AS mm,
                           d->>'qualificacao' AS q
                    FROM jsonb_array_elements(j) d
                    WHERE coalesce(d->>'id_sensor', d->>'sensor') = '10'
                      AND jsonb_typeof(d->'valor') = 'number'
                      AND (d->>'valor')::numeric BETWEEN 0 AND 150
                      AND d->>'datahora' ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}'
                ) x
                JOIN public.chuva_estacoes e ON e.codigo = x.cod
                ORDER BY e.id, x.fim
                ON CONFLICT (estacao_id, fim) DO UPDATE
                   SET mm = EXCLUDED.mm, qualificacao = EXCLUDED.qualificacao, lido_em = now();
                GET DIAGNOSTICS n = ROW_COUNT;
                gravadas := gravadas + n;
                lidas := lidas + 1;
                ped_ok := true;

            ELSIF p.status_code IS DISTINCT FROM 200 THEN
                RAISE EXCEPTION '%', coalesce(p.error_msg, 'HTTP ' || coalesce(p.status_code::text, '?'));

            ELSIF p.tipo = 'lista' THEN
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
            IF p.tipo LIKE 'ped_%' THEN
                erro_ped := left(SQLERRM, 200);
            END IF;
        END;
        DELETE FROM public.chuva_pedidos WHERE request_id = p.request_id;
    END LOOP;

    IF token_caiu THEN
        UPDATE public.chuva_ped_token SET token = NULL, expira_em = NULL WHERE id = 1;
    END IF;

    IF tem_algo THEN
        UPDATE public.chuva_estado
           SET ultima_coleta = now(),
               ultima_coleta_ok = CASE WHEN lidas > 0 THEN now() ELSE ultima_coleta_ok END,
               estacoes_lidas = lidas,
               estacoes_com_falha = falhas,
               ultimo_erro = CASE WHEN falhas > 0 THEN left(array_to_string(erros, '; '), 500) END,
               ped_ultima_ok = CASE WHEN ped_ok THEN now() ELSE chuva_estado.ped_ultima_ok END,
               ped_erro = CASE WHEN erro_ped IS NOT NULL THEN erro_ped
                               WHEN ped_ok THEN NULL
                               ELSE chuva_estado.ped_erro END
         WHERE id = 1;
        PERFORM public.chuva_atualizar_avisos();
    END IF;

    -- 10 min guardados por 3 dias (o hora a hora segue em chuva_leituras).
    DELETE FROM public.chuva_leituras_10min WHERE fim < now() - interval '3 days';
    RETURN gravadas;
END $$;
REVOKE ALL ON FUNCTION public.chuva_processar() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Regra: "última hora" passa a considerar a soma móvel de 60 min.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chuva_avaliar(p_agora timestamptz DEFAULT now())
RETURNS TABLE (estacao_id integer, region_id uuid, nome text,
               mm_1h numeric, mm_24h numeric, lido_em timestamptz, severidade text)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    WITH h AS (   -- baldes de hora cheia (coleta aberta)
        SELECT l.estacao_id,
               max(l.mm) FILTER (WHERE l.hora >= date_trunc('hour', p_agora) - interval '1 hour') AS h1,
               sum(l.mm) FILTER (WHERE l.hora > p_agora - interval '24 hours') AS d24,
               max(l.lido_em) AS lido
        FROM public.chuva_leituras l
        WHERE l.hora > p_agora - interval '25 hours'
          AND l.hora <= p_agora
          AND l.mm <= 150
        GROUP BY l.estacao_id
    ),
    u AS (        -- última leitura de 10 min de cada estação (relógio da PED)
        SELECT d.estacao_id, max(d.fim) AS ultimo
        FROM public.chuva_leituras_10min d
        WHERE d.fim > p_agora - interval '3 hours'
          AND d.fim <= p_agora + interval '30 minutes'
        GROUP BY d.estacao_id
    ),
    m AS (        -- soma dos 60 min que terminam na última leitura
        SELECT u.estacao_id, sum(d.mm) AS r60, max(d.lido_em) AS lido
        FROM u
        JOIN public.chuva_leituras_10min d
          ON d.estacao_id = u.estacao_id
         AND d.fim > u.ultimo - interval '60 minutes'
         AND d.fim <= u.ultimo
        WHERE u.ultimo > p_agora - interval '90 minutes'
          AND d.mm <= 150
        GROUP BY u.estacao_id
    ),
    v AS (
        SELECT e.id, e.region_id, e.nome,
               greatest(coalesce(h.h1, 0), coalesce(m.r60, 0)) AS h1,
               greatest(coalesce(h.d24, 0), coalesce(m.r60, 0)) AS d24,
               greatest(h.lido, m.lido) AS lido   -- greatest ignora NULL
        FROM public.chuva_estacoes e
        LEFT JOIN h ON h.estacao_id = e.id
        LEFT JOIN m ON m.estacao_id = e.id
        WHERE e.ativa
          AND greatest(coalesce(h.lido, '-infinity'), coalesce(m.lido, '-infinity'))
              > p_agora - interval '40 minutes'
    )
    SELECT id, region_id, nome, h1, d24, lido,
           CASE
             WHEN h1 > 60 OR d24 > 100 THEN 'CRITICAL'
             WHEN h1 >= 30 OR d24 >= 50 THEN 'HIGH'
             WHEN h1 >= 20 THEN 'MEDIUM'
             ELSE 'LOW' END
    FROM v;
$$;
