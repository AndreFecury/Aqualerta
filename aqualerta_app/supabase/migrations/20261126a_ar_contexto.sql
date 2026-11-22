-- ============================================================
-- AQUALERTA — Contexto do ar para o app (Fases 2 e 4), decisões de 22/11/2026
--
-- ar_contexto() (RPC pública) devolve, por região:
--   - se há sensor perto e se ele está saudável;
--   - a comparação sensor × modelo (média das últimas 24 h, nível do IQAr), só
--     quando há dados suficientes (ar_config: comparacao_*) — Fase 4;
--   - divergência ASSIMÉTRICA: "sensor pior" (sensor 2+ níveis acima do
--     modelo) aparece desde o 1º dia; "modelo pior" (2 níveis ou 25 µg/m³
--     acima do sensor) só depois de 5 dias seguidos;
--   - cautela no lugar de "Boa": regiões sem comparação utilizável, em época
--     de fumaça OU com muitos focos a 300 km nas últimas 72 h;
--   - se o aviso por sensor está ligado (tabela ar_aviso_sensor; hoje
--     desligado em todas; Manaus é a única candidata, para julho de 2027).
-- Escolhas (minhas, ajustáveis em ar_config):
--   - época de fumaça: julho a novembro (no teste de 2026 a fumaça forte foi de
--     agosto a outubro; um mês de folga em cada ponta);
--   - "muitos focos": 600 focos polares a 300 km em 72 h (o corte do terço
--     superior foi 611 em Porto Velho e 1.026 em Manaus em ago–out; o menor
--     dos dois, arredondado para baixo, para errar para o lado da cautela);
--   - os focos são os dos arquivos de 10 min do INPE (cobrem a América do Sul),
--     só satélites polares, sem repetição (células de 0,01°), janela móvel de 72 h.
-- ============================================================

INSERT INTO public.ar_config (chave, valor, descricao) VALUES
  ('divergencia_sensor_pior_niveis', 2, 'Sensor pior que o modelo em N+ níveis: frase desde o 1º dia'),
  ('fumaca_epoca_mes_inicio',        7, 'Época de fumaça: primeiro mês'),
  ('fumaca_epoca_mes_fim',          11, 'Época de fumaça: último mês'),
  ('fumaca_focos_300km_72h',       600, 'Muitos focos: focos polares a até 300 km nas últimas 72 h')
ON CONFLICT (chave) DO NOTHING;
UPDATE public.ar_config SET descricao = 'Modelo pior que o sensor: diferença mínima de níveis' WHERE chave = 'divergencia_niveis';
UPDATE public.ar_config SET descricao = 'Modelo pior que o sensor: ou diferença mínima em µg/m³ (média de 24 h)' WHERE chave = 'divergencia_margem_ugm3';
UPDATE public.ar_config SET descricao = 'Modelo pior que o sensor: dias seguidos para a frase aparecer' WHERE chave = 'divergencia_dias_seguidos';

-- Aviso por sensor, por região. Só o servidor muda.
CREATE TABLE IF NOT EXISTS public.ar_aviso_sensor (
    region_id  uuid PRIMARY KEY REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    ligado     boolean NOT NULL DEFAULT false,
    observacao text,
    mudado_em  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.ar_aviso_sensor ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ar_aviso_sensor FROM PUBLIC, anon, authenticated;
INSERT INTO public.ar_aviso_sensor (region_id, ligado, observacao)
SELECT id, false, 'Candidata (teste ago-out 2026 aprovado). Ligar só depois do teste de 2027 (pré-registro v2).'
  FROM public.monitored_regions WHERE name = 'Manaus' AND state_code = 'AM'
ON CONFLICT (region_id) DO NOTHING;

-- Focos polares a até 300 km do ponto da região nas últimas 72 h.
CREATE OR REPLACE FUNCTION public.ar_focos_regionais(p_agora timestamptz DEFAULT now())
RETURNS TABLE (region_id uuid, focos_300km_72h integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
    WITH f AS (
        SELECT DISTINCT round(lat, 2) AS lat, round(lon, 2) AS lon
          FROM public.ar_focos
         WHERE detectado_em > p_agora - interval '72 hours' AND detectado_em <= p_agora
           AND satelite IN ('AQUA_M-T', 'AQUA_M-M', 'TERRA_M-T', 'TERRA_M-M', 'NPP-375', 'NOAA-20', 'NOAA-21')
    )
    SELECT r.id, (SELECT count(*) FROM f
                   WHERE ST_DWithin(ST_SetSRID(ST_MakePoint((r.monitoring_config->>'estacao_lng')::float8,
                                                            (r.monitoring_config->>'estacao_lat')::float8), 4326)::geography,
                                    ST_SetSRID(ST_MakePoint(f.lon::float8, f.lat::float8), 4326)::geography, 300000))::integer
      FROM public.monitored_regions r
     WHERE r.is_public AND r.monitoring_config ? 'estacao_lat'
$$;
REVOKE ALL ON FUNCTION public.ar_focos_regionais(timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ar_contexto(p_agora timestamptz DEFAULT now())
RETURNS TABLE (region_id uuid, tem_sensor boolean, sensor_nome text, sensor_provedor text,
               sensor_distancia_km numeric, sensor_situacao text,
               comparacao_ok boolean, sensor_pm25_24h numeric, sensor_nivel text,
               modelo_pm25_24h numeric, modelo_nivel text,
               sensor_pior boolean, modelo_pior boolean,
               epoca_fumaca boolean, focos_300km_72h integer, cautela_boa boolean,
               aviso_sensor_ligado boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    hora_fim timestamptz := date_trunc('hour', p_agora);
    mes integer := extract(month FROM p_agora AT TIME ZONE 'America/Manaus');
    epoca boolean := mes BETWEEN public.ar_cfg('fumaca_epoca_mes_inicio') AND public.ar_cfg('fumaca_epoca_mes_fim');
BEGIN
    RETURN QUERY
    WITH reg AS (
        SELECT r.id, r.state_code FROM public.monitored_regions r
         WHERE r.is_public AND r.monitoring_config ? 'estacao_lat'
    ), sen AS (
        SELECT DISTINCT ON (s.region_id) s.region_id, s.nome, s.provedor,
               round((s.distancia_m / 1000)::numeric, 0) AS km
          FROM public.openaq_sensores s WHERE s.parametro = 2
         ORDER BY s.region_id, s.distancia_m
    ), h24 AS (
        -- últimas 24 h fechadas, pares válidos (coleta contínua)
        SELECT v.region_id, count(*) AS horas,
               round(avg(v.sensor_pm25), 1) AS sensor, round(avg(v.modelo_pm25), 1) AS modelo,
               max(v.hora) AS ultima
          FROM public.ar_validacao_horas v
         WHERE v.origem = 'continua' AND v.valido
           AND v.hora >= hora_fim - interval '24 hours' AND v.hora < hora_fim
         GROUP BY v.region_id
    ), dias AS (
        SELECT d.region_id, d.dia, d.modelo_24h, d.sensor_24h, d.nivel_modelo, d.nivel_sensor,
               (substr(d.nivel_modelo, 2)::int - substr(d.nivel_sensor, 2)::int >= public.ar_cfg('divergencia_niveis')
                OR d.modelo_24h - d.sensor_24h >= public.ar_cfg('divergencia_margem_ugm3')) AS modelo_pior_dia
          FROM public.ar_validacao_dias d
          JOIN reg ON reg.id = d.region_id
         WHERE d.origem = 'continua' AND d.fuso = 'local'
           AND d.dia <= (p_agora AT TIME ZONE public.regiao_fuso(reg.state_code))::date
           AND d.dia > (p_agora AT TIME ZONE public.regiao_fuso(reg.state_code))::date
                       - public.ar_cfg('comparacao_janela_dias')::int
    ), janela AS (
        SELECT dias.region_id, count(*) AS validos FROM dias GROUP BY dias.region_id
    ), ultimos AS (
        -- os N dias mais recentes; "modelo pior" exige N dias SEGUIDOS (sem buraco)
        SELECT x.region_id, count(*) AS n, bool_and(x.modelo_pior_dia) AS todos, max(x.dia) - min(x.dia) + 1 AS extensao
          FROM (SELECT dias.*, row_number() OVER (PARTITION BY dias.region_id ORDER BY dias.dia DESC) AS k FROM dias) x
         WHERE x.k <= public.ar_cfg('divergencia_dias_seguidos')
         GROUP BY x.region_id
    ), saude AS (
        SELECT reg.id AS region_id,
               CASE WHEN h24.ultima IS NULL
                         OR h24.ultima + interval '1 hour' < p_agora - public.ar_cfg('sensor_max_atraso_h') * interval '1 hour' THEN 'parado'
                    WHEN h24.horas < public.ar_cfg('sensor_min_horas_24h') THEN 'cobertura baixa'
                    ELSE 'saudável' END AS situacao
          FROM reg LEFT JOIN h24 ON h24.region_id = reg.id
    ), fo AS (
        SELECT * FROM public.ar_focos_regionais(p_agora)
    ), base AS (
        SELECT reg.id,
               sen.region_id IS NOT NULL AS tem,
               sen.nome, sen.provedor, sen.km,
               CASE WHEN sen.region_id IS NULL THEN NULL ELSE saude.situacao END AS situacao,
               sen.region_id IS NOT NULL AND saude.situacao = 'saudável'
                 AND coalesce(janela.validos, 0) >= public.ar_cfg('comparacao_min_dias') AS ok,
               h24.sensor, h24.modelo,
               public.ar_nivel(public.ar_iqar('pm2_5', h24.sensor)) AS n_sensor,
               public.ar_nivel(public.ar_iqar('pm2_5', h24.modelo)) AS n_modelo,
               coalesce(janela.validos, 0) >= public.ar_cfg('divergencia_min_dias')
                 AND ultimos.n = public.ar_cfg('divergencia_dias_seguidos')
                 AND ultimos.extensao = public.ar_cfg('divergencia_dias_seguidos')
                 AND ultimos.todos AS mp,
               coalesce(fo.focos_300km_72h, 0) AS focos,
               coalesce(av.ligado, false) AS ligado
          FROM reg
          LEFT JOIN sen ON sen.region_id = reg.id
          LEFT JOIN saude ON saude.region_id = reg.id
          LEFT JOIN janela ON janela.region_id = reg.id
          LEFT JOIN h24 ON h24.region_id = reg.id
          LEFT JOIN ultimos ON ultimos.region_id = reg.id
          LEFT JOIN fo ON fo.region_id = reg.id
          LEFT JOIN public.ar_aviso_sensor av ON av.region_id = reg.id
    )
    SELECT b.id, b.tem, b.nome, b.provedor, b.km, b.situacao,
           b.ok,
           CASE WHEN b.ok THEN b.sensor END, CASE WHEN b.ok THEN b.n_sensor END,
           CASE WHEN b.ok THEN b.modelo END, CASE WHEN b.ok THEN b.n_modelo END,
           b.ok AND substr(b.n_sensor, 2)::int - substr(b.n_modelo, 2)::int >= public.ar_cfg('divergencia_sensor_pior_niveis'),
           b.ok AND coalesce(b.mp, false),
           epoca, b.focos,
           NOT b.ok AND (epoca OR b.focos >= public.ar_cfg('fumaca_focos_300km_72h')),
           b.ligado
      FROM base b;
END $$;
REVOKE ALL ON FUNCTION public.ar_contexto(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ar_contexto(timestamptz) TO anon, authenticated;
