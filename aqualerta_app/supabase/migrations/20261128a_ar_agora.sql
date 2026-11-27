-- ============================================================
-- AQUALERTA — indicador "agora" (média de MP2,5 das últimas 3 h do sensor)
--
-- O IQAr oficial (Conama 506/2024) usa média de 24 h e continua sendo a
-- categoria oficial. Esta migração acrescenta, AO LADO dele, a média das
-- últimas 3 horas válidas do sensor e a "faixa equivalente" dela (os pontos
-- de corte do MP2,5 do IQAr aplicados à média de 3 h; NÃO é o IQAr oficial e
-- nunca é rotulada como "AQI dos EUA").
--
--   ar_agora_serie()  série hora a hora (mesma regra de hora válida do
--                     ar_nowcast: sensores_n > 0 e sensor_pm25 não nulo);
--                     3 horas SEGUIDAS válidas; média de 24 h do sensor só com
--                     sensor_min_horas_24h horas.
--   ar_agora()        RPC pública: valor mais recente por região. Só vale se a
--                     última hora válida estiver dentro de sensor_max_atraso_h
--                     (sensor parado = sem linha; nada de "agora" velho).
--   ar_gatilho_serie() série que o aviso por sensor usa. Com
--                     agora_gatilho_ligado = 0 (PADRÃO) é exatamente o NowCast
--                     de antes. Com 1, quando a faixa de 3 h está
--                     agora_niveis_aviso (2) ou mais níveis acima da de 24 h
--                     do próprio sensor E a última hora, sozinha, ainda está acima
--                     de aviso_limite_ugm3, o valor é o MAIOR entre a média de 3 h
--                     e o NowCast (só pode somar, nunca tirar). A regra de 2 horas
--                     seguidas acima do limite continua valendo. A exigência da
--                     última hora evita que UMA hora de pico (a média de 3 h a
--                     carrega por 3 h) vire aviso depois de o ar já ter limpado.
--
-- NÃO muda nada em produção: o gatilho nasce desligado e os avisos por
-- sensor seguem desligados em todas as regiões (ar_aviso_sensor.ligado).
-- Ligar o gatilho é decisão do dono. Idempotente.
-- ============================================================

INSERT INTO public.ar_config (chave, valor, descricao) VALUES
  ('agora_niveis_aviso',   2, 'Média de 3 h: níveis acima do nível de 24 h do sensor para "o ar piorou"'),
  ('agora_gatilho_ligado', 0, 'Aviso por sensor usa a média de 3 h quando o ar piorou (1 = sim; 0 = só NowCast, como antes)')
ON CONFLICT (chave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.ar_agora_serie(p_origem text, p_desde timestamptz, p_ate timestamptz)
RETURNS TABLE (region_id uuid, hora timestamptz, pm25_1h numeric, pm25_3h numeric, pm25_24h numeric,
               nivel_3h text, nivel_24h text, piorou boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH h AS (
        SELECT v.region_id, v.hora, v.sensor_pm25 AS c
          FROM public.ar_validacao_horas v
         WHERE v.origem = p_origem AND v.sensores_n > 0 AND v.sensor_pm25 IS NOT NULL
           AND v.hora >= p_desde - interval '23 hours' AND v.hora < p_ate
    ), w AS (
        SELECT h.region_id, h.hora, h.c,
               avg(h.c) OVER w3 AS a3, count(h.c) OVER w3 AS n3,
               avg(h.c) OVER w24 AS a24, count(h.c) OVER w24 AS n24
          FROM h
        WINDOW w3  AS (PARTITION BY h.region_id ORDER BY h.hora
                       RANGE BETWEEN interval '2 hours' PRECEDING AND CURRENT ROW),
               w24 AS (PARTITION BY h.region_id ORDER BY h.hora
                       RANGE BETWEEN interval '23 hours' PRECEDING AND CURRENT ROW)
    ), n AS (
        SELECT w.region_id, w.hora, round(w.c, 1) AS p1, round(w.a3, 1) AS p3,
               CASE WHEN w.n24 >= public.ar_cfg('sensor_min_horas_24h') THEN round(w.a24, 1) END AS p24
          FROM w
         WHERE w.hora >= p_desde AND w.n3 = 3          -- 3 horas válidas SEGUIDAS
    )
    SELECT n.region_id, n.hora, n.p1, n.p3, n.p24,
           public.ar_nivel(public.ar_iqar('pm2_5', n.p3)),
           public.ar_nivel(public.ar_iqar('pm2_5', n.p24)),
           n.p24 IS NOT NULL
             AND substr(public.ar_nivel(public.ar_iqar('pm2_5', n.p3)), 2)::int
               - substr(public.ar_nivel(public.ar_iqar('pm2_5', n.p24)), 2)::int
                 >= public.ar_cfg('agora_niveis_aviso')
      FROM n
$$;
REVOKE ALL ON FUNCTION public.ar_agora_serie(text, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ar_agora(p_agora timestamptz DEFAULT now())
RETURNS TABLE (region_id uuid, pm25_3h numeric, iqar_3h integer, nivel_3h text,
               pm25_24h_sensor numeric, nivel_24h_sensor text, piorou boolean, ate timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT DISTINCT ON (s.region_id)
           s.region_id, s.pm25_3h, public.ar_iqar('pm2_5', s.pm25_3h), s.nivel_3h,
           s.pm25_24h, s.nivel_24h, s.piorou, s.hora + interval '1 hour'
      FROM public.ar_agora_serie('continua', date_trunc('hour', p_agora) - interval '12 hours',
                                 date_trunc('hour', p_agora)) s
     WHERE s.hora + interval '1 hour' >= p_agora - public.ar_cfg('sensor_max_atraso_h') * interval '1 hour'
     ORDER BY s.region_id, s.hora DESC
$$;
REVOKE ALL ON FUNCTION public.ar_agora(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ar_agora(timestamptz) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.ar_gatilho_serie(p_origem text, p_desde timestamptz, p_ate timestamptz)
RETURNS TABLE (region_id uuid, hora timestamptz, valor numeric, via text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH lig AS (SELECT public.ar_cfg('agora_gatilho_ligado') = 1 AS on_)
    SELECT n.region_id, n.hora,
           CASE WHEN lig.on_ AND s.piorou AND s.pm25_1h > public.ar_cfg('aviso_limite_ugm3') THEN greatest(n.nowcast, s.pm25_3h) ELSE n.nowcast END,
           CASE WHEN lig.on_ AND s.piorou AND s.pm25_1h > public.ar_cfg('aviso_limite_ugm3') AND s.pm25_3h > n.nowcast THEN '3h' ELSE 'nowcast' END
      FROM public.ar_nowcast(p_origem, p_desde, p_ate) n
      CROSS JOIN lig
      LEFT JOIN public.ar_agora_serie(p_origem, p_desde, p_ate) s
             ON s.region_id = n.region_id AND s.hora = n.hora
$$;
REVOKE ALL ON FUNCTION public.ar_gatilho_serie(text, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;

-- Igual à de 20261127b_ar_aviso_teste.sql; a ÚNICA mudança é a série da repetição
-- (ar_gatilho_serie no lugar de ar_nowcast).
CREATE OR REPLACE FUNCTION public.ar_avisos_atualizar(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    reg    record;
    h      record;
    atual  public.ar_avisos;
    limite numeric := public.ar_cfg('aviso_limite_ugm3');
    critico numeric := public.ar_cfg('aviso_critico_ugm3');
    abre   integer := public.ar_cfg('aviso_horas_seguidas');
    fecha  integer := public.ar_cfg('aviso_fim_horas');
    acima integer; abaixo integer; ativo boolean; ant timestamptz;
    v_inicio timestamptz; v_fim timestamptz; maior numeric; ultimo numeric; ultima_hora timestamptz;
    sev text;
    mudancas integer := 0;
BEGIN
    FOR reg IN
        SELECT r.id, coalesce(a.ligado, false) AS ligado
          FROM public.monitored_regions r
          LEFT JOIN public.ar_aviso_sensor a ON a.region_id = r.id
         WHERE r.is_public
    LOOP
        SELECT * INTO atual FROM public.ar_avisos
         WHERE region_id = reg.id AND situacao = 'ativo' AND teste_para IS NULL;   -- teste não conta

        IF NOT reg.ligado THEN
            IF atual.id IS NOT NULL THEN
                UPDATE public.ar_avisos SET situacao = 'encerrado', fim = p_agora, atualizado_em = p_agora,
                       motivo_fim = 'avisos de ar desligados nesta região'
                 WHERE id = atual.id;
                mudancas := mudancas + 1;
            END IF;
            CONTINUE;
        END IF;

        acima := 0; abaixo := 0; ativo := false; ant := NULL; v_inicio := NULL; v_fim := NULL;
        maior := 0; ultimo := NULL; ultima_hora := NULL;
        FOR h IN SELECT n.hora, n.valor AS nowcast FROM public.ar_gatilho_serie('continua', p_agora - interval '48 hours', p_agora) n
                  WHERE n.region_id = reg.id ORDER BY n.hora LOOP
            IF ant IS NOT NULL AND h.hora - ant > interval '1 hour' THEN acima := 0; abaixo := 0; END IF;
            ant := h.hora; ultimo := h.nowcast; ultima_hora := h.hora;
            IF h.nowcast > limite THEN acima := acima + 1; abaixo := 0; ELSE abaixo := abaixo + 1; acima := 0; END IF;
            IF NOT ativo AND acima >= abre THEN
                ativo := true; v_inicio := h.hora - (abre - 1) * interval '1 hour'; maior := 0; v_fim := NULL;
            ELSIF ativo AND abaixo >= fecha THEN
                ativo := false; v_fim := h.hora + interval '1 hour';
            END IF;
            IF ativo THEN maior := greatest(maior, h.nowcast); END IF;
        END LOOP;

        -- Sensor parado: sem hora válida recente, não mantém aviso aberto.
        IF ultima_hora IS NULL OR ultima_hora + interval '1 hour' < p_agora - public.ar_cfg('sensor_max_atraso_h') * interval '1 hour' THEN
            IF atual.id IS NOT NULL THEN
                UPDATE public.ar_avisos SET situacao = 'encerrado', fim = p_agora, atualizado_em = p_agora,
                       motivo_fim = 'o sensor parou de mandar leituras'
                 WHERE id = atual.id;
                mudancas := mudancas + 1;
            END IF;
            CONTINUE;
        END IF;

        IF ativo THEN
            sev := CASE WHEN ultimo > critico THEN 'CRITICAL' ELSE 'HIGH' END;
            IF atual.id IS NULL THEN
                INSERT INTO public.ar_avisos (region_id, severity, limite_ugm3, nowcast_atual, nowcast_max, inicio, atualizado_em)
                VALUES (reg.id, sev, limite, ultimo, maior, v_inicio, p_agora);
                mudancas := mudancas + 1;
            ELSE
                UPDATE public.ar_avisos
                   SET severity = sev, nowcast_atual = ultimo, nowcast_max = greatest(coalesce(nowcast_max, 0), maior),
                       atualizado_em = p_agora
                 WHERE id = atual.id
                   AND (severity IS DISTINCT FROM sev OR nowcast_atual IS DISTINCT FROM ultimo);
                IF FOUND THEN mudancas := mudancas + 1; END IF;
            END IF;
        ELSIF atual.id IS NOT NULL THEN
            UPDATE public.ar_avisos SET situacao = 'encerrado', fim = coalesce(v_fim, p_agora), atualizado_em = p_agora,
                   nowcast_atual = ultimo,
                   motivo_fim = 'o índice ficou abaixo de ' || limite || ' µg/m³ por ' || fecha || ' h seguidas'
             WHERE id = atual.id;
            mudancas := mudancas + 1;
        END IF;
    END LOOP;
    RETURN mudancas;
END $$;
REVOKE ALL ON FUNCTION public.ar_avisos_atualizar(timestamptz) FROM PUBLIC, anon, authenticated;
