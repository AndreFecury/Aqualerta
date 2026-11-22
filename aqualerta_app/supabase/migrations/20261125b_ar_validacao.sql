-- ============================================================
-- AQUALERTA — Fase 1a: validação do modelo de ar contra sensores (só o dono vê)
--
-- Nada disto aparece no app e nada corrige o modelo.
--   - ar_config: limiares (tabela fechada; mudar aqui, não no código).
--   - Coleta também a umidade relativa (OpenAQ, parâmetro 98) do mesmo aparelho.
--   - ar_validacao_horas: por região e hora, modelo (CAMS via Open-Meteo,
--     valor da hora H) ao lado do sensor (média da hora que começa em H), o
--     sensor como recebido e com a correção da EPA, a umidade e marcas de
--     sensor doente (travado, salto impossível, umidade saturada).
--   - Views fechadas (security_invoker): ar_validacao_dias (dia local e dia
--     UTC), ar_validacao_resumo, ar_validacao_resumo_horario, ar_cobertura.
--   - ar_fumaca_dias: preenchida pelo script do teste retroativo (Fase 1b).
--   - net._http_response e net.http_request_queue: sem acesso para anon e
--     authenticated.
-- Consultar no SQL Editor:  select * from public.ar_validacao_resumo;
-- ============================================================

-- ------------------------------------------------------------
-- 1. Configuração
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ar_config (
    chave     text PRIMARY KEY,
    valor     numeric NOT NULL,
    descricao text NOT NULL
);
INSERT INTO public.ar_config (chave, valor, descricao) VALUES
  ('dia_min_horas',            18,  'Horas válidas (modelo e sensor) para um dia contar'),
  ('sensor_max_atraso_h',       3,  'Sensor saudável: última leitura há no máximo N horas'),
  ('sensor_min_horas_24h',     18,  'Sensor saudável: horas válidas nas últimas 24 h'),
  ('sensor_travado_horas',      6,  'Mesmo valor por N horas seguidas = travado'),
  ('sensor_salto_max_ugm3',   150,  'Variação maior que isto entre horas seguidas = salto impossível'),
  ('ur_saturada',              95,  'Umidade a partir da qual a hora do sensor é descartada (neblina)'),
  ('ur_faixa_1',               70,  'Corte das faixas de umidade no resumo (abaixo de)'),
  ('ur_faixa_2',               85,  'Corte das faixas de umidade no resumo (acima de)'),
  ('comparacao_janela_dias',   28,  'Janela da comparação no cartão (Fase 4)'),
  ('comparacao_min_dias',      14,  'Dias válidos na janela para mostrar a comparação (Fase 4)'),
  ('divergencia_niveis',        2,  'Diferença mínima de níveis para chamar de divergência (Fase 4)'),
  ('divergencia_margem_ugm3',  25,  'Ou diferença mínima em µg/m³ na média de 24 h (Fase 4)'),
  ('divergencia_dias_seguidos', 5,  'Dias seguidos divergentes para a frase aparecer (Fase 4)'),
  ('divergencia_min_dias',     21,  'Dias válidos na janela para a frase aparecer (Fase 4)'),
  ('aviso_horas_seguidas',      2,  'Horas seguidas acima do limite para abrir aviso pelo sensor (Fase 3)'),
  ('aviso_fim_horas',           3,  'Horas seguidas abaixo do limite para encerrar (histerese, Fase 3)')
ON CONFLICT (chave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.ar_cfg(p_chave text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT valor FROM public.ar_config WHERE chave = p_chave
$$;
REVOKE ALL ON FUNCTION public.ar_cfg(text) FROM PUBLIC, anon, authenticated;

-- Fuso de cada região (Acre é UTC-5; Amazonas e Rondônia, UTC-4).
CREATE OR REPLACE FUNCTION public.regiao_fuso(p_uf text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE upper(p_uf) WHEN 'AC' THEN 'America/Rio_Branco'
                            WHEN 'RO' THEN 'America/Porto_Velho'
                            ELSE 'America/Manaus' END
$$;

-- Correção da EPA para sensores ópticos de baixo custo (correção nacional dos
-- EUA, Barkjohn et al. 2021, com a extensão para fumaça intensa). Entrada:
-- MP2,5 do sensor (µg/m³) e umidade relativa (%). Sem umidade, sem correção.
CREATE OR REPLACE FUNCTION public.ar_correcao_epa(x numeric, ur numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN x IS NULL OR ur IS NULL THEN NULL
        ELSE greatest(0, round(CASE
            WHEN x < 30  THEN 0.524 * x - 0.0862 * ur + 5.75
            WHEN x < 50  THEN (0.786 * (x / 20 - 1.5) + 0.524 * (1 - (x / 20 - 1.5))) * x - 0.0862 * ur + 5.75
            WHEN x < 210 THEN 0.786 * x - 0.0862 * ur + 5.75
            WHEN x < 260 THEN (0.69 * (x / 50 - 4.2) + 0.786 * (1 - (x / 50 - 4.2))) * x
                              - 0.0862 * ur * (1 - (x / 50 - 4.2))
                              + 2.966 * (x / 50 - 4.2) + 5.75 * (1 - (x / 50 - 4.2))
                              + 0.000884 * x * x * (x / 50 - 4.2)
            ELSE 2.966 + 0.69 * x + 0.000884 * x * x
        END, 1))
    END
$$;

-- ------------------------------------------------------------
-- 2. Umidade relativa dos sensores (parâmetro 98)
-- ------------------------------------------------------------
ALTER TABLE public.openaq_sensores ADD COLUMN IF NOT EXISTS parametro smallint NOT NULL DEFAULT 2;

CREATE TABLE IF NOT EXISTS public.openaq_ur_horas (
    sensor_id bigint NOT NULL,
    hora      timestamptz NOT NULL,           -- início da hora (UTC)
    ur        numeric NOT NULL,
    PRIMARY KEY (sensor_id, hora)
);

-- Igual à de 20261124_openaq.sql, guardando também os sensores de umidade.
CREATE OR REPLACE FUNCTION public.openaq_processar(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    p   record;
    j   jsonb;
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
                   -- umidade só de estação que também mede MP2,5
                   AND ((sen->'parameter'->>'id')::int = 2
                        OR EXISTS (SELECT 1 FROM jsonb_array_elements(loc->'sensors') s2
                                    WHERE (s2->'parameter'->>'id')::int = 2))
                 ORDER BY sen->>'id';
                locais_ok := true;

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
                       AND (x->>'value')::numeric BETWEEN 0 AND 1000   -- descarta leitura impossível
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
    -- Os pares da validação ficam em ar_validacao_horas; aqui só 3 dias.
    DELETE FROM public.openaq_horas WHERE hora < p_agora - interval '3 days';
    DELETE FROM public.openaq_ur_horas WHERE hora < p_agora - interval '3 days';
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.openaq_processar(timestamptz) FROM PUBLIC, anon, authenticated;

-- A média local (20261124) usa só os sensores de MP2,5.
CREATE OR REPLACE FUNCTION public.ar_local(p_agora timestamptz DEFAULT now())
RETURNS TABLE (region_id uuid, pm25_24h numeric, iqar integer, sensores integer,
               distancia_km numeric, fontes text, atualizado_em timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
    WITH por_sensor AS (
        SELECT s.region_id, s.sensor_id, s.distancia_m, s.provedor,
               avg(h.pm25) AS media, count(*) AS horas, max(h.hora) + interval '1 hour' AS ultima
          FROM public.openaq_sensores s
          JOIN public.openaq_horas h ON h.sensor_id = s.sensor_id
                                    AND h.hora >= date_trunc('hour', p_agora) - interval '24 hours'
                                    AND h.hora <  date_trunc('hour', p_agora)
         WHERE s.parametro = 2
         GROUP BY s.region_id, s.sensor_id, s.distancia_m, s.provedor
        HAVING count(*) >= 18
    )
    SELECT ps.region_id,
           round(avg(ps.media), 1),
           public.ar_iqar('pm2_5', round(avg(ps.media), 1)),
           count(*)::integer,
           round((max(ps.distancia_m) / 1000)::numeric, 0),
           'OpenAQ · ' || string_agg(DISTINCT coalesce(ps.provedor, 'provedor não informado'), ', '),
           max(ps.ultima)
      FROM por_sensor ps
     GROUP BY ps.region_id
$$;
REVOKE ALL ON FUNCTION public.ar_local(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ar_local(timestamptz) TO anon, authenticated;

-- ------------------------------------------------------------
-- 3. Pares horários e saúde do sensor
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ar_validacao_horas (
    region_id        uuid NOT NULL REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    hora             timestamptz NOT NULL,      -- modelo: valor da hora H; sensor: média de [H, H+1)
    origem           text NOT NULL CHECK (origem IN ('continua', 'retro')),
    modelo_pm25      numeric,
    sensor_pm25      numeric,                   -- como a OpenAQ entrega
    sensor_pm25_epa  numeric,                   -- com ar_correcao_epa
    sensores_n       integer NOT NULL DEFAULT 0,
    ur_sensor        numeric,
    ur_modelo        numeric,                   -- Open-Meteo, quando o sensor não tem umidade
    marcas           text[] NOT NULL DEFAULT '{}',  -- travado, salto, ur_saturada, sem_ur
    valido           boolean NOT NULL DEFAULT false,
    registrado_em    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (region_id, hora, origem)
);

-- Dias de fumaça (Fase 1b): focos do INPE em raio de 300 e de 500 km nos
-- últimos 3 dias, em terços (poucos/medios/muitos) dentro do período.
CREATE TABLE IF NOT EXISTS public.ar_fumaca_dias (
    region_id uuid NOT NULL REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    dia       date NOT NULL,                    -- dia local da região
    raio_km   integer NOT NULL CHECK (raio_km IN (300, 500)),
    focos_3d  integer NOT NULL,
    classe    text NOT NULL CHECK (classe IN ('poucos', 'medios', 'muitos')),
    PRIMARY KEY (region_id, dia, raio_km)
);

-- Saúde por sensor e hora: travado (mesmo valor por N horas seguidas) e
-- salto (diferença impossível para a hora anterior).
CREATE OR REPLACE FUNCTION public.ar_sensor_marcas(p_desde timestamptz, p_ate timestamptz)
RETURNS TABLE (sensor_id bigint, hora timestamptz, pm25 numeric, marcas text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH h AS (
        SELECT o.sensor_id, o.hora, o.pm25,
               lag(o.pm25) OVER w AS ant, lag(o.hora) OVER w AS hora_ant,
               min(o.pm25) OVER k AS kmin, max(o.pm25) OVER k AS kmax,
               count(*) OVER k AS kn, min(o.hora) OVER k AS kdesde
          FROM public.openaq_horas o
         WHERE o.hora >= p_desde - interval '1 day' AND o.hora < p_ate
        WINDOW w AS (PARTITION BY o.sensor_id ORDER BY o.hora),
               k AS (PARTITION BY o.sensor_id ORDER BY o.hora
                     ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)
    )
    SELECT h.sensor_id, h.hora, h.pm25,
           array_remove(ARRAY[
               CASE WHEN h.kn >= public.ar_cfg('sensor_travado_horas') AND h.kmin = h.kmax
                         AND h.hora - h.kdesde = (public.ar_cfg('sensor_travado_horas') - 1) * interval '1 hour'
                    THEN 'travado' END,
               CASE WHEN h.hora_ant = h.hora - interval '1 hour'
                         AND abs(h.pm25 - h.ant) > public.ar_cfg('sensor_salto_max_ugm3')
                    THEN 'salto' END
           ], NULL)
      FROM h
     WHERE h.hora >= p_desde
$$;
REVOKE ALL ON FUNCTION public.ar_sensor_marcas(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;

-- Grava os pares das últimas 26 h (o sensor às vezes chega atrasado).
CREATE OR REPLACE FUNCTION public.ar_validacao_registrar(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    n integer;
    desde timestamptz := date_trunc('hour', p_agora) - interval '26 hours';
    ate   timestamptz := date_trunc('hour', p_agora);
BEGIN
    WITH pm AS (
        SELECT s.region_id, s.location_id, m.hora, m.pm25, m.marcas
          FROM public.ar_sensor_marcas(desde, ate) m
          JOIN public.openaq_sensores s ON s.sensor_id = m.sensor_id AND s.parametro = 2
    ), ur AS (
        SELECT s.location_id, u.hora, avg(u.ur) AS ur
          FROM public.openaq_ur_horas u
          JOIN public.openaq_sensores s ON s.sensor_id = u.sensor_id AND s.parametro = 98
         WHERE u.hora >= desde AND u.hora < ate
         GROUP BY s.location_id, u.hora
    ), por_sensor AS (
        SELECT pm.region_id, pm.hora, pm.pm25, ur.ur,
               pm.marcas
               || CASE WHEN ur.ur >= public.ar_cfg('ur_saturada') THEN ARRAY['ur_saturada'] ELSE '{}'::text[] END
               || CASE WHEN ur.ur IS NULL THEN ARRAY['sem_ur'] ELSE '{}'::text[] END AS marcas
          FROM pm LEFT JOIN ur ON ur.location_id = pm.location_id AND ur.hora = pm.hora
    ), marcado AS (
        -- "sem_ur" só impede a correção da EPA; não invalida a hora.
        SELECT ps.*, NOT (ps.marcas && ARRAY['travado', 'salto', 'ur_saturada']) AS ok FROM por_sensor ps
    ), por_regiao AS (
        SELECT mc.region_id, mc.hora,
               round(avg(mc.pm25) FILTER (WHERE mc.ok), 2) AS sensor,
               round(avg(public.ar_correcao_epa(mc.pm25, mc.ur)) FILTER (WHERE mc.ok), 2) AS epa,
               round(avg(mc.ur), 1) AS ur,
               (count(*) FILTER (WHERE mc.ok))::integer AS n_ok,
               coalesce((SELECT array_agg(DISTINCT m ORDER BY m)
                           FROM marcado m2, unnest(m2.marcas) m
                          WHERE m2.region_id = mc.region_id AND m2.hora = mc.hora), '{}') AS marcas
          FROM marcado mc
         GROUP BY mc.region_id, mc.hora
    )
    INSERT INTO public.ar_validacao_horas AS v
           (region_id, hora, origem, modelo_pm25, sensor_pm25, sensor_pm25_epa, sensores_n,
            ur_sensor, marcas, valido, registrado_em)
    SELECT pr.region_id, pr.hora, 'continua', ah.pm2_5, pr.sensor, pr.epa, pr.n_ok,
           pr.ur, pr.marcas, pr.n_ok > 0 AND ah.pm2_5 IS NOT NULL, p_agora
      FROM por_regiao pr
      LEFT JOIN public.ar_horas ah ON ah.region_id = pr.region_id AND ah.hora = pr.hora
    ON CONFLICT (region_id, hora, origem) DO UPDATE
       SET modelo_pm25 = excluded.modelo_pm25, sensor_pm25 = excluded.sensor_pm25,
           sensor_pm25_epa = excluded.sensor_pm25_epa, sensores_n = excluded.sensores_n,
           ur_sensor = excluded.ur_sensor, marcas = excluded.marcas, valido = excluded.valido,
           registrado_em = excluded.registrado_em;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.ar_validacao_registrar(timestamptz) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 4. Views fechadas (security_invoker: valem as permissões de quem lê)
-- ------------------------------------------------------------
-- Métrica principal: dias (o modelo global sai de 3 em 3 h; a hora é
-- interpolada). Cada dia aparece duas vezes: no dia local da região e no
-- dia UTC, para medir o efeito do fuso.
CREATE OR REPLACE VIEW public.ar_validacao_dias WITH (security_invoker = true) AS
SELECT v.region_id, r.name AS regiao, v.origem, f.fuso, f.dia,
       count(*)::integer AS horas,
       round(avg(v.modelo_pm25), 1) AS modelo_24h,
       round(avg(v.sensor_pm25), 1) AS sensor_24h,
       round(avg(v.sensor_pm25_epa), 1) AS sensor_epa_24h,
       count(v.sensor_pm25_epa)::integer AS horas_epa,
       round(avg(coalesce(v.ur_sensor, v.ur_modelo)), 0) AS ur_media,
       public.ar_nivel(public.ar_iqar('pm2_5', round(avg(v.modelo_pm25), 1))) AS nivel_modelo,
       public.ar_nivel(public.ar_iqar('pm2_5', round(avg(v.sensor_pm25), 1))) AS nivel_sensor,
       public.ar_nivel(public.ar_iqar('pm2_5', round(avg(v.sensor_pm25_epa), 1))) AS nivel_sensor_epa
  FROM public.ar_validacao_horas v
  JOIN public.monitored_regions r ON r.id = v.region_id
  CROSS JOIN LATERAL (VALUES
      ('local', (v.hora AT TIME ZONE public.regiao_fuso(r.state_code))::date),
      ('utc',   (v.hora AT TIME ZONE 'UTC')::date)) f(fuso, dia)
 WHERE v.valido AND v.modelo_pm25 IS NOT NULL AND v.sensor_pm25 IS NOT NULL
 GROUP BY v.region_id, r.name, v.origem, f.fuso, f.dia
HAVING count(*) >= public.ar_cfg('dia_min_horas');

-- Resumo por região, origem e fuso, em recortes: todos os dias, faixas de
-- umidade e classes de fumaça (300 e 500 km). Diferença = modelo - sensor,
-- em µg/m³, pela mediana dos dias. Sem porcentagem.
CREATE OR REPLACE VIEW public.ar_validacao_resumo WITH (security_invoker = true) AS
WITH d AS (
    SELECT d.* FROM public.ar_validacao_dias d
), recortes AS (
    SELECT d.*, 'todos' AS recorte FROM d
    UNION ALL
    SELECT d.*, CASE WHEN d.ur_media < public.ar_cfg('ur_faixa_1') THEN 'umidade abaixo de ' || public.ar_cfg('ur_faixa_1')
                     WHEN d.ur_media > public.ar_cfg('ur_faixa_2') THEN 'umidade acima de ' || public.ar_cfg('ur_faixa_2')
                     ELSE 'umidade entre ' || public.ar_cfg('ur_faixa_1') || ' e ' || public.ar_cfg('ur_faixa_2') END
      FROM d WHERE d.ur_media IS NOT NULL
    UNION ALL
    SELECT d.*, 'fumaça ' || fu.raio_km || ' km: ' || fu.classe
      FROM d JOIN public.ar_fumaca_dias fu ON fu.region_id = d.region_id AND fu.dia = d.dia
     WHERE d.fuso = 'local'
)
SELECT regiao, origem, fuso, recorte,
       count(*)::integer AS dias,
       min(dia) AS de, max(dia) AS ate,
       round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY modelo_24h - sensor_24h)::numeric, 1) AS dif_mediana,
       round(percentile_cont(0.25) WITHIN GROUP (ORDER BY modelo_24h - sensor_24h)::numeric, 1) AS dif_q1,
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY modelo_24h - sensor_24h)::numeric, 1) AS dif_q3,
       round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY modelo_24h - sensor_epa_24h)::numeric, 1) AS dif_mediana_epa,
       round(corr(modelo_24h, sensor_24h)::numeric, 2) AS correlacao_diaria,
       round(corr(modelo_24h, sensor_epa_24h)::numeric, 2) AS correlacao_diaria_epa,
       count(*) FILTER (WHERE nivel_modelo = nivel_sensor)::integer AS dias_mesmo_nivel,
       count(*) FILTER (WHERE nivel_modelo = nivel_sensor_epa)::integer AS dias_mesmo_nivel_epa,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY sensor_24h)::numeric, 1) AS sensor_mediana,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY modelo_24h)::numeric, 1) AS modelo_mediana
  FROM recortes
 GROUP BY regiao, origem, fuso, recorte;

-- Apoio: correlação horária (o modelo é interpolado entre saídas de 3 h).
CREATE OR REPLACE VIEW public.ar_validacao_resumo_horario WITH (security_invoker = true) AS
SELECT r.name AS regiao, v.origem,
       count(*)::integer AS horas,
       round(corr(v.modelo_pm25, v.sensor_pm25)::numeric, 2) AS correlacao_horaria,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY v.modelo_pm25 - v.sensor_pm25)::numeric, 1) AS dif_mediana_horaria
  FROM public.ar_validacao_horas v
  JOIN public.monitored_regions r ON r.id = v.region_id
 WHERE v.valido AND v.modelo_pm25 IS NOT NULL AND v.sensor_pm25 IS NOT NULL
 GROUP BY r.name, v.origem;

-- Cobertura por região com sensor: mostra quando caiu.
CREATE OR REPLACE VIEW public.ar_cobertura WITH (security_invoker = true) AS
WITH v AS (
    SELECT * FROM public.ar_validacao_horas WHERE origem = 'continua'
)
SELECT r.id AS region_id, r.name AS regiao,
       max(v.hora) FILTER (WHERE v.valido) + interval '1 hour' AS ultima_hora_valida,
       count(*) FILTER (WHERE v.valido AND v.hora >= date_trunc('hour', now()) - interval '24 hours')::integer AS horas_validas_24h,
       count(*) FILTER (WHERE NOT v.valido AND v.hora >= date_trunc('hour', now()) - interval '24 hours')::integer AS horas_descartadas_24h,
       (SELECT array_agg(DISTINCT m ORDER BY m) FROM v v2, unnest(v2.marcas) m
         WHERE v2.region_id = r.id AND v2.hora >= date_trunc('hour', now()) - interval '24 hours') AS marcas_24h,
       CASE
         WHEN max(v.hora) FILTER (WHERE v.valido) IS NULL
              OR max(v.hora) FILTER (WHERE v.valido) + interval '1 hour'
                 < now() - public.ar_cfg('sensor_max_atraso_h') * interval '1 hour' THEN 'parado'
         WHEN count(*) FILTER (WHERE v.valido AND v.hora >= date_trunc('hour', now()) - interval '24 hours')
              < public.ar_cfg('sensor_min_horas_24h') THEN 'cobertura baixa'
         ELSE 'saudável' END AS situacao
  FROM public.monitored_regions r
  LEFT JOIN v ON v.region_id = r.id
 WHERE EXISTS (SELECT 1 FROM public.openaq_sensores s WHERE s.region_id = r.id AND s.parametro = 2)
 GROUP BY r.id, r.name;

-- ------------------------------------------------------------
-- 5. Permissões: nada disto é público
-- ------------------------------------------------------------
ALTER TABLE public.ar_config          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_validacao_horas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ar_fumaca_dias     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.openaq_ur_horas    ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ar_config, public.ar_validacao_horas, public.ar_fumaca_dias, public.openaq_ur_horas,
              public.ar_validacao_dias, public.ar_validacao_resumo, public.ar_validacao_resumo_horario,
              public.ar_cobertura
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON net._http_response, net.http_request_queue FROM anon, authenticated;

-- ------------------------------------------------------------
-- 6. Agenda: depois do ar (:14) e da OpenAQ (:19)
-- ------------------------------------------------------------
SELECT cron.schedule('ar-validacao', '25 * * * *', 'SELECT public.ar_validacao_registrar()');
