-- ============================================================
-- AQUALERTA — "sensor sem dados há X horas" no ar_agora()
--
-- Achado em produção (26/11/2026): o único sensor de Manaus parou de mandar
-- leituras e o cartão ficou só com o modelo CAMS, que subestima fumaça lá. O
-- app já sabia que o sensor estava "parado" (ar_contexto), mas não há quantas
-- horas, e ar_agora() (20261128a) simplesmente não devolvia linha.
--
-- ar_agora() passa a devolver UMA linha por região com sensor (ou com
--    leituras guardadas), com os mesmos campos de antes (valores NULL quando
--    não há 3 horas válidas recentes) mais:
--      ultima_leitura  fim da última hora válida do sensor
--      sensor_parado   última leitura anterior a sensor_max_atraso_h (3 h) ou nunca
--      sem_dados_h     horas inteiras desde a última leitura, só quando parado
--    O tipo de retorno muda (colunas novas): DROP + CREATE, mesmas permissões.
--    O app publicado NÃO chama ar_agora; o app novo ainda não saiu.
--    ar_resumo() não muda (o app lê o atraso daqui).
--
-- NÃO liga avisos por sensor e não mexe em ar_aviso_sensor. Idempotente.
-- DESFAZER: recriar ar_agora() como em 20261128a_ar_agora.sql (DROP FUNCTION antes).
-- ============================================================

DROP FUNCTION IF EXISTS public.ar_agora(timestamptz);
CREATE FUNCTION public.ar_agora(p_agora timestamptz DEFAULT now())
RETURNS TABLE (region_id uuid, pm25_3h numeric, iqar_3h integer, nivel_3h text,
               pm25_24h_sensor numeric, nivel_24h_sensor text, piorou boolean, ate timestamptz,
               ultima_leitura timestamptz, sensor_parado boolean, sem_dados_h integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH ult AS (
        SELECT v.region_id, max(v.hora) + interval '1 hour' AS ultima
          FROM public.ar_validacao_horas v
         WHERE v.origem = 'continua' AND v.sensores_n > 0 AND v.sensor_pm25 IS NOT NULL
           AND v.hora < date_trunc('hour', p_agora)
         GROUP BY v.region_id
    ), reg AS (
        SELECT s.region_id FROM public.openaq_sensores s WHERE s.parametro = 2
        UNION
        SELECT u.region_id FROM ult u
    ), ag AS (
        SELECT DISTINCT ON (s.region_id)
               s.region_id, s.pm25_3h, public.ar_iqar('pm2_5', s.pm25_3h) AS iqar_3h, s.nivel_3h,
               s.pm25_24h AS pm25_24h_sensor, s.nivel_24h AS nivel_24h_sensor, s.piorou,
               s.hora + interval '1 hour' AS ate
          FROM public.ar_agora_serie('continua', date_trunc('hour', p_agora) - interval '12 hours',
                                     date_trunc('hour', p_agora)) s
         WHERE s.hora + interval '1 hour' >= p_agora - public.ar_cfg('sensor_max_atraso_h') * interval '1 hour'
         ORDER BY s.region_id, s.hora DESC
    )
    SELECT reg.region_id, ag.pm25_3h, ag.iqar_3h, ag.nivel_3h, ag.pm25_24h_sensor, ag.nivel_24h_sensor,
           coalesce(ag.piorou, false), ag.ate,
           ult.ultima,
           (ult.ultima IS NULL OR ult.ultima < p_agora - public.ar_cfg('sensor_max_atraso_h') * interval '1 hour'),
           CASE WHEN ult.ultima IS NOT NULL
                 AND ult.ultima < p_agora - public.ar_cfg('sensor_max_atraso_h') * interval '1 hour'
                THEN floor(extract(epoch FROM p_agora - ult.ultima) / 3600)::integer END
      FROM reg
      LEFT JOIN ult ON ult.region_id = reg.region_id
      LEFT JOIN ag  ON ag.region_id  = reg.region_id
$$;
REVOKE ALL ON FUNCTION public.ar_agora(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ar_agora(timestamptz) TO anon, authenticated, service_role;
