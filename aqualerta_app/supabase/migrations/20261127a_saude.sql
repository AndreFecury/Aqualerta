-- ============================================================
-- AquaAlerta: saúde das fontes (Fase A1)
--
-- saude_fontes(): uma linha por fonte (ANA por estação, OpenAQ por sensor),
-- com a última vez que deu certo, a cadência esperada, a idade e a situação
-- (ok, atrasada, parada, sem_dado). saude_resumo(): a regra de falha que o
-- vigia de fora (GitHub Actions) e o push do dono usam.
-- Só leitura, pública (anon): nomes de fonte, estação, sensor e região, que
-- já são públicos, mais datas e contagens. Nada pessoal, nenhum segredo.
-- Pode rodar este arquivo mais de uma vez.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.saude_cfg (
    chave     text PRIMARY KEY,
    valor     numeric NOT NULL,
    descricao text NOT NULL
);
ALTER TABLE public.saude_cfg ENABLE ROW LEVEL SECURITY;           -- sem políticas: fora da API
REVOKE ALL ON public.saude_cfg FROM PUBLIC, anon, authenticated;
INSERT INTO public.saude_cfg (chave, valor, descricao) VALUES
  ('atrasada_x',              2,    'Atrasada: idade acima de N vezes a cadência'),
  ('parada_x',                6,    'Parada: idade acima de N vezes a cadência'),
  ('ana_cadencia_padrao_min', 60,   'ANA: cadência quando a estação tem menos de 3 leituras em 48 h'),
  ('ana_cadencia_min_min',    15,   'ANA: menor cadência aceita (min)'),
  ('ana_cadencia_max_min',    1440, 'ANA: maior cadência aceita (min)'),
  ('ana_folga_min',           120,  'ANA: atraso normal da telemetria (em produção, 73 a 103 min em 23/11), descontado da idade'),
  ('ana_fracao_parada',       0.3333, 'ANA: falha se pelo menos esta fração das estações estiver parada'),
  ('cemaden_cadencia_min',    5,    'CEMADEN: coleta a cada N min'),
  ('satelite_cadencia_min',   360,  'Satélite: verificação a cada N min'),
  ('ar_modelo_cadencia_min',  60,   'Modelo do ar (Open-Meteo/CAMS): a cada N min'),
  ('openaq_cadencia_min',     60,   'OpenAQ: coleta e média horária a cada N min'),
  ('openaq_folga_min',        120,  'OpenAQ: atraso normal da média horária, descontado da idade'),
  ('push_cadencia_min',       30,   'Fila de push: envio a cada N min')
ON CONFLICT (chave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.saude_cfg_valor(p text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS
$$ SELECT valor FROM public.saude_cfg WHERE chave = p $$;
REVOKE ALL ON FUNCTION public.saude_cfg_valor(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.saude_situacao(ultimo timestamptz, cadencia numeric, folga numeric, agora timestamptz)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT CASE
        WHEN ultimo IS NULL THEN 'sem_dado'
        WHEN extract(epoch FROM agora - ultimo) / 60 - folga > public.saude_cfg_valor('parada_x') * cadencia THEN 'parada'
        WHEN extract(epoch FROM agora - ultimo) / 60 - folga > public.saude_cfg_valor('atrasada_x') * cadencia THEN 'atrasada'
        ELSE 'ok' END
$$;
REVOKE ALL ON FUNCTION public.saude_situacao(timestamptz, numeric, numeric, timestamptz) FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public.saude_fontes(timestamptz);
CREATE FUNCTION public.saude_fontes(p_agora timestamptz DEFAULT now())
RETURNS TABLE (fonte text, item text, regiao text, ultimo_ok timestamptz, cadencia_min numeric,
               idade_min numeric, situacao text, alerta_ativo boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    cad numeric;
    t   timestamptz;
BEGIN
    -- ANA: uma linha por estação ativa, cada uma com a cadência das próprias leituras (mediana em 48 h).
    RETURN QUERY
    WITH est AS (
        SELECT s.id, s.ana_code, s.name::text AS nome,
               (SELECT string_agg(r.name::text, ', ' ORDER BY r.name) FROM public.monitored_regions r
                 WHERE r.monitoring_config->>'estacao_ana' = s.ana_code) AS regioes,
               EXISTS (SELECT 1 FROM public.alerts a JOIN public.monitored_regions r ON r.id = a.region_id
                        WHERE r.monitoring_config->>'estacao_ana' = s.ana_code AND a.status = 'ACTIVE') AS alerta,
               (SELECT max(h.recorded_at) FROM public.hydro_readings h
                 WHERE h.station_id = s.id AND h.recorded_at <= p_agora) AS ultima,
               (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY g.min)
                  FROM (SELECT extract(epoch FROM h.recorded_at - lag(h.recorded_at) OVER (ORDER BY h.recorded_at)) / 60 AS min,
                               count(*) OVER () AS n
                          FROM public.hydro_readings h
                         WHERE h.station_id = s.id AND h.recorded_at > p_agora - interval '48 hours'
                           AND h.recorded_at <= p_agora) g
                 WHERE g.min > 0 AND g.n >= 3) AS mediana
          FROM public.hydro_stations s
         WHERE s.is_active
    ), c AS (
        SELECT e.*, round(least(greatest(coalesce(e.mediana::numeric, public.saude_cfg_valor('ana_cadencia_padrao_min')),
                                         public.saude_cfg_valor('ana_cadencia_min_min')),
                                public.saude_cfg_valor('ana_cadencia_max_min')), 1) AS cad
          FROM est e
    )
    SELECT 'ana'::text, c.nome || ' (' || c.ana_code || ')', c.regioes, c.ultima, c.cad,
           round((extract(epoch FROM p_agora - c.ultima) / 60)::numeric, 1),
           public.saude_situacao(c.ultima, c.cad, public.saude_cfg_valor('ana_folga_min'), p_agora), c.alerta
      FROM c ORDER BY c.ana_code;

    -- CEMADEN (chuva).
    cad := public.saude_cfg_valor('cemaden_cadencia_min');
    SELECT e.ultima_coleta_ok INTO t FROM public.chuva_estado e WHERE e.id = 1;
    RETURN QUERY SELECT 'cemaden'::text, NULL::text, NULL::text, t, cad,
                        round((extract(epoch FROM p_agora - t) / 60)::numeric, 1),
                        public.saude_situacao(t, cad, 0, p_agora), false;

    -- Satélite: a última verificação de qualquer região.
    cad := public.saude_cfg_valor('satelite_cadencia_min');
    SELECT max(v.verificado_em) INTO t FROM public.satelite_verificacoes v;
    RETURN QUERY SELECT 'satelite'::text, NULL::text, NULL::text, t, cad,
                        round((extract(epoch FROM p_agora - t) / 60)::numeric, 1),
                        public.saude_situacao(t, cad, 0, p_agora), false;

    -- Modelo do ar.
    cad := public.saude_cfg_valor('ar_modelo_cadencia_min');
    SELECT e.modelo_ok_em INTO t FROM public.ar_estado e WHERE e.id = 1;
    RETURN QUERY SELECT 'ar_modelo'::text, NULL::text, NULL::text, t, cad,
                        round((extract(epoch FROM p_agora - t) / 60)::numeric, 1),
                        public.saude_situacao(t, cad, 0, p_agora), false;

    -- OpenAQ: o coletor (nosso) e cada sensor de PM2.5 (aparelho de terceiros).
    cad := public.saude_cfg_valor('openaq_cadencia_min');
    SELECT e.horas_ok_em INTO t FROM public.openaq_estado e WHERE e.id = 1;
    RETURN QUERY SELECT 'openaq_coletor'::text, NULL::text, NULL::text, t, cad,
                        round((extract(epoch FROM p_agora - t) / 60)::numeric, 1),
                        public.saude_situacao(t, cad, 0, p_agora), false;
    RETURN QUERY
    SELECT 'openaq_sensor'::text, x.nome || ' (' || x.sensor_id || ')', x.regioes, x.ultima, cad,
           round((extract(epoch FROM p_agora - x.ultima) / 60)::numeric, 1),
           public.saude_situacao(x.ultima, cad, public.saude_cfg_valor('openaq_folga_min'), p_agora), false
      FROM (SELECT s.sensor_id, min(s.nome) AS nome,
                   string_agg(DISTINCT r.name::text, ', ') AS regioes,
                   (SELECT max(h.hora) + interval '1 hour' FROM public.openaq_horas h
                     WHERE h.sensor_id = s.sensor_id AND h.hora < p_agora) AS ultima
              FROM public.openaq_sensores s JOIN public.monitored_regions r ON r.id = s.region_id
             WHERE s.parametro = 2
             GROUP BY s.sensor_id) x
     ORDER BY x.sensor_id;

    -- Fila de push: idade do item pendente mais antigo; fila vazia = em dia.
    cad := public.saude_cfg_valor('push_cadencia_min');
    SELECT coalesce(min(f.criado_em), p_agora) INTO t FROM public.push_fila f
     WHERE f.resultado IS NULL AND f.tentativas < 3 AND f.criado_em <= p_agora;
    RETURN QUERY SELECT 'push_fila'::text, NULL::text, NULL::text, t, cad,
                        round((extract(epoch FROM p_agora - t) / 60)::numeric, 1),
                        public.saude_situacao(t, cad, 0, p_agora), false;
END $$;
REVOKE ALL ON FUNCTION public.saude_fontes(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.saude_fontes(timestamptz) TO anon, authenticated, service_role;

-- Regra de falha, num só lugar:
--   ANA: alguma estação de região com alerta ativo parada, OU pelo menos 1/3
--        das estações paradas ao mesmo tempo. Vira UM motivo só.
--   CEMADEN, satélite, modelo do ar, coletor OpenAQ e fila de push: parada.
--   Sensor OpenAQ parado NÃO falha (aparelho de terceiros, fica só visível).
--   sem_dado não falha, mas aparece em sem_dado[].
DROP FUNCTION IF EXISTS public.saude_resumo(timestamptz);
CREATE FUNCTION public.saude_resumo(p_agora timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    motivos  text[] := '{}';
    n_ana    integer;
    paradas  text[];
    criticas text[];
    outras   text[];
    sem      text[];
    cont     jsonb;
BEGIN
    WITH f AS (SELECT * FROM public.saude_fontes(p_agora))
    SELECT count(*) FILTER (WHERE fonte = 'ana'),
           coalesce(array_agg(item ORDER BY item) FILTER (WHERE fonte = 'ana' AND situacao = 'parada'), '{}'),
           coalesce(array_agg(item ORDER BY item) FILTER (WHERE fonte = 'ana' AND situacao = 'parada' AND alerta_ativo), '{}'),
           coalesce(array_agg(fonte || ' parada há ' || round(idade_min) || ' min' ORDER BY fonte)
                    FILTER (WHERE fonte IN ('cemaden', 'satelite', 'ar_modelo', 'openaq_coletor', 'push_fila') AND situacao = 'parada'), '{}'),
           coalesce(array_agg(fonte || coalesce(' ' || item, '') ORDER BY fonte, item) FILTER (WHERE situacao = 'sem_dado'), '{}'),
           (SELECT jsonb_object_agg(q.situacao, q.n) FROM (SELECT f2.situacao, count(*) n FROM f f2 GROUP BY 1) q)
      INTO n_ana, paradas, criticas, outras, sem, cont
      FROM f;

    IF cardinality(criticas) > 0
       OR (n_ana > 0 AND cardinality(paradas) >= n_ana * public.saude_cfg_valor('ana_fracao_parada')) THEN
        motivos := motivos || ('ANA: ' || cardinality(paradas) || ' de ' || n_ana || ' estações paradas'
                   || CASE WHEN cardinality(criticas) > 0 THEN ' (com alerta ativo: ' || array_to_string(criticas, ', ') || ')' ELSE '' END
                   || ': ' || array_to_string(paradas, ', '));
    END IF;
    motivos := motivos || outras;

    RETURN jsonb_build_object(
        'verificado_em', p_agora,
        'falha', cardinality(motivos) > 0,
        'motivos', to_jsonb(motivos),
        'ana', jsonb_build_object('estacoes', n_ana, 'paradas', cardinality(paradas)),
        'sem_dado', to_jsonb(sem),
        'contagem', coalesce(cont, '{}'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.saude_resumo(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.saude_resumo(timestamptz) TO anon, authenticated, service_role;
