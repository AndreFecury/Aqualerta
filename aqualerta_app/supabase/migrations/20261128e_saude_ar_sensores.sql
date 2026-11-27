-- ============================================================
-- AQUALERTA — verificação de saúde: sensor do ar sem dados há mais de N horas
--
-- saude_ar_sensores(): SÓ LEITURA, uma linha por região com sensor de MP2,5,
-- dizendo se o sensor está sem dados há mais de ar_config.sensor_max_atraso_h
-- (3 h): situacao 'ok' | 'sem_dados' | 'sem_dado' (nunca mandou). Pública como
-- saude_fontes() (nome de região e de sensor, datas e contagens).
--
-- NÃO entra em saude_resumo(), saude_fontes() nem no vigia (saude_vigiar): sensor
-- de terceiros parado continua sem derrubar o alerta do dono (decisão de
-- 20261127a); isto só deixa visível. Para o vigia passar a avisar, é uma decisão
-- à parte. Não liga avisos por sensor. Idempotente.
-- DESFAZER: DROP FUNCTION public.saude_ar_sensores(timestamptz);
-- ============================================================

-- Verificação de saúde (só leitura): região com sensor sem dados há mais de N horas.
-- Pública como saude_fontes(): nome de região e de sensor, datas e contagens.
CREATE OR REPLACE FUNCTION public.saude_ar_sensores(p_agora timestamptz DEFAULT now())
RETURNS TABLE (regiao text, sensores text, ultima_leitura timestamptz, horas_sem_dados numeric,
               limite_h numeric, situacao text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH reg AS (
        SELECT r.id, r.name::text AS regiao,
               string_agg(DISTINCT s.nome, ', ' ORDER BY s.nome) AS sensores
          FROM public.monitored_regions r
          JOIN public.openaq_sensores s ON s.region_id = r.id AND s.parametro = 2
         GROUP BY r.id, r.name
    ), ult AS (
        SELECT v.region_id, max(v.hora) + interval '1 hour' AS ultima
          FROM public.ar_validacao_horas v
         WHERE v.origem = 'continua' AND v.sensores_n > 0 AND v.sensor_pm25 IS NOT NULL
           AND v.hora < date_trunc('hour', p_agora)
         GROUP BY v.region_id
    )
    SELECT reg.regiao, reg.sensores, ult.ultima,
           round((extract(epoch FROM p_agora - ult.ultima) / 3600)::numeric, 1),
           public.ar_cfg('sensor_max_atraso_h'),
           CASE WHEN ult.ultima IS NULL THEN 'sem_dado'
                WHEN ult.ultima < p_agora - public.ar_cfg('sensor_max_atraso_h') * interval '1 hour' THEN 'sem_dados'
                ELSE 'ok' END
      FROM reg LEFT JOIN ult ON ult.region_id = reg.id
     ORDER BY reg.regiao
$$;
REVOKE ALL ON FUNCTION public.saude_ar_sensores(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.saude_ar_sensores(timestamptz) TO anon, authenticated, service_role;
