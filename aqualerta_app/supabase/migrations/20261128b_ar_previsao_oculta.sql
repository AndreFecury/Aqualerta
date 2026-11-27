-- ============================================================
-- AQUALERTA — chave de servidor para esconder a previsão de 48 h do ar
--
-- A previsão numérica de 48 h (ar_resumo.iqar_previsto_48h e
-- hora_pior_prevista) é experimental: ainda não foi validada contra valores
-- observados (pico observado ~IQAr 177 contra ~70 previstos; ver
-- docs/ar-previsao-erro.md). O app novo já a esconde, mas quem usa 4.10.2 ou
-- anterior continuaria vendo o número. Esta chave esconde no servidor.
--
--   ar_config.previsao_48h_visivel = 0 (PADRÃO)  -> as duas colunas vêm NULL
--   ar_config.previsao_48h_visivel = 1           -> como antes
--
-- Chave ausente também esconde (ar_cfg devolve NULL). Nada mais muda: o resto
-- de ar_resumo é idêntico a 20261122_ar.sql (mesmas colunas e tipos). Os dados
-- continuam em v_ar_indice_horas para a validação. O app trata NULL como "sem
-- previsão". Para mostrar de novo: UPDATE public.ar_config SET valor = 1
-- WHERE chave = 'previsao_48h_visivel';  Idempotente.
-- ============================================================

INSERT INTO public.ar_config (chave, valor, descricao) VALUES
  ('previsao_48h_visivel', 0, 'ar_resumo devolve a previsão de 48 h? (1 = sim; 0 = não, experimental e sem validação)')
ON CONFLICT (chave) DO NOTHING;

-- Igual à de 20261122_ar.sql; a ÚNICA mudança são as duas colunas da previsão.
CREATE OR REPLACE FUNCTION public.ar_resumo(p_agora timestamptz DEFAULT now())
RETURNS TABLE (region_id uuid, hora timestamptz, iqar integer, nivel text, poluente text,
               pm2_5_24 numeric, iqar_previsto_48h integer, hora_pior_prevista timestamptz,
               tendencia text, focos_24h integer, fumaca_provavel boolean,
               atualizado_em timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
    WITH agora AS (
        SELECT DISTINCT ON (v.region_id) v.*
        FROM public.v_ar_indice_horas v
        WHERE v.hora <= p_agora AND v.hora > p_agora - interval '6 hours' AND v.iqar IS NOT NULL
        ORDER BY v.region_id, v.hora DESC
    ), ontem AS (
        SELECT DISTINCT ON (v.region_id) v.region_id, v.pm2_5_24
        FROM public.v_ar_indice_horas v
        WHERE v.hora <= p_agora - interval '24 hours' AND v.hora > p_agora - interval '27 hours'
        ORDER BY v.region_id, v.hora DESC
    ), prev AS (
        SELECT DISTINCT ON (v.region_id) v.region_id, v.iqar, v.hora
        FROM public.v_ar_indice_horas v
        WHERE v.hora > p_agora AND v.hora <= p_agora + interval '48 hours' AND v.iqar IS NOT NULL
        ORDER BY v.region_id, v.iqar DESC, v.hora
    ), centro AS (
        SELECT r.id,
               ST_SetSRID(ST_MakePoint((r.monitoring_config->>'estacao_lng')::float8,
                                       (r.monitoring_config->>'estacao_lat')::float8), 4326)::geography AS g
        FROM public.monitored_regions r
        WHERE r.is_public AND r.monitoring_config ? 'estacao_lat'
    ), focos AS (
        -- Só satélites de órbita polar (VIIRS/MODIS): o GOES repete o mesmo
        -- fogo a cada 10 min. Mesmo fogo em satélites diferentes conta 1
        -- (células de ~1 km).
        SELECT c.id, count(DISTINCT (round(f.lat, 2), round(f.lon, 2)))::integer AS n
        FROM centro c
        JOIN public.ar_focos f
          ON f.detectado_em > p_agora - interval '24 hours'
         AND f.satelite IN ('AQUA_M-T', 'AQUA_M-M', 'TERRA_M-T', 'TERRA_M-M', 'NPP-375', 'NOAA-20', 'NOAA-21')
         AND ST_DWithin(c.g, ST_SetSRID(ST_MakePoint(f.lon, f.lat), 4326)::geography, 100000)
        GROUP BY c.id
    )
    SELECT c.id, a.hora, a.iqar, public.ar_nivel(a.iqar), a.poluente,
           round(a.pm2_5_24, 1),
           CASE WHEN public.ar_cfg('previsao_48h_visivel') = 1 THEN p.iqar END,
           CASE WHEN public.ar_cfg('previsao_48h_visivel') = 1 THEN p.hora END,
           CASE WHEN a.pm2_5_24 IS NULL OR o.pm2_5_24 IS NULL THEN NULL
                WHEN a.pm2_5_24 - o.pm2_5_24 >= greatest(2, o.pm2_5_24 * 0.15) THEN 'sobe'
                WHEN o.pm2_5_24 - a.pm2_5_24 >= greatest(2, o.pm2_5_24 * 0.15) THEN 'desce'
                ELSE 'estavel' END,
           coalesce(fo.n, 0),
           coalesce(fo.n, 0) >= 10 AND a.pm2_5_24 > 15
               AND (a.pm2_5_24 >= 25 OR a.pm2_5_24 - coalesce(o.pm2_5_24, a.pm2_5_24) >= 2),
           (SELECT max(h.ingerido_em) FROM public.ar_horas h WHERE h.region_id = c.id)
    FROM centro c
    LEFT JOIN agora a ON a.region_id = c.id
    LEFT JOIN ontem o ON o.region_id = c.id
    LEFT JOIN prev p ON p.region_id = c.id
    LEFT JOIN focos fo ON fo.id = c.id;
$$;
REVOKE ALL ON FUNCTION public.ar_resumo(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ar_resumo(timestamptz) TO anon, authenticated, service_role;
