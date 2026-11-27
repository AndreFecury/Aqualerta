-- Teste de 20261128d_ar_sensor_sem_dados.sql e 20261128e_saude_ar_sensores.sql: "sensor sem dados há X horas" em
-- ar_agora() e a verificação de saúde saude_ar_sensores(). PostGIS LOCAL, banco novo:
--   stub_base, ar_stubs, ar_validacao_stubs, push_teste_stubs, sinal_dados_stubs,
--   20261118_push_fcm, 20261121b_sinal_dados, 20261122_ar, 20261123b_push_teste,
--   20261124_openaq, 20261125a_ar_pausa, 20261125b, 20261125c, 20261126a,
--   20261126b, 20261127b, 20261128a, 20261128d, 20261128e, este arquivo
-- Reproduz o achado de 26/11/2026 com valores inventados: Manaus (…01) parou de
-- mandar leituras às 10:00 UTC (180-188 µg/m³ às 05-06h locais) e às 19:42 locais
-- (23:42 UTC) continua sem dados; Parintins (…02) está saudável.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.horas(regiao uuid, de timestamptz, ate timestamptz, valor numeric) RETURNS void LANGUAGE sql AS $$
    INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensores_n, valido)
    SELECT regiao, h, 'continua', 30, valor, 1, true
      FROM generate_series(de, ate, interval '1 hour') h
    ON CONFLICT (region_id, hora, origem) DO UPDATE SET sensor_pm25 = excluded.sensor_pm25, sensores_n = 1;
$$;

INSERT INTO public.openaq_sensores (region_id, sensor_id, location_id, nome, provedor, distancia_m, parametro) VALUES
 ('a0000000-0000-0000-0000-000000000001', 7001, 900001, 'Manaus', 'AirGradient', 2026.9, 2),
 ('a0000000-0000-0000-0000-000000000002', 7101, 900101, 'Parintins', 'AirGradient', 1500, 2);

-- 1. Sensores cadastrados, nenhuma leitura: parado, sem número de horas.
SELECT pg_temp.confere((SELECT count(*) = 2 AND bool_and(sensor_parado AND sem_dados_h IS NULL AND ultima_leitura IS NULL AND pm25_3h IS NULL)
                          FROM public.ar_agora('2026-11-26 23:42+00')),
                       'sensor sem nenhuma leitura: parado, sem horas (nunca mandou)');
SELECT pg_temp.confere((SELECT bool_and(situacao = 'sem_dado' AND horas_sem_dados IS NULL AND limite_h = 3) FROM public.saude_ar_sensores('2026-11-26 23:42+00')),
                       'saúde: "sem_dado" quando o sensor nunca mandou');

-- 2. Manaus: última leitura às 10:00 UTC (hora 09:00-10:00 é a última). Parintins: em dia.
SELECT pg_temp.horas('a0000000-0000-0000-0000-000000000001', '2026-11-25 10:00+00', '2026-11-26 09:00+00', 184);
SELECT pg_temp.horas('a0000000-0000-0000-0000-000000000002', '2026-11-25 10:00+00', '2026-11-26 22:00+00', 20);
CREATE TEMP TABLE a AS SELECT * FROM public.ar_agora('2026-11-26 23:42+00');
SELECT pg_temp.confere((SELECT sensor_parado AND sem_dados_h = 13 AND ultima_leitura = '2026-11-26 10:00+00'
                          AND pm25_3h IS NULL AND nivel_3h IS NULL AND NOT piorou
                          FROM a WHERE region_id = 'a0000000-0000-0000-0000-000000000001'),
                       'Manaus: parado, sem dados há 13 h, última leitura 10:00 UTC, sem número de "agora"');
SELECT pg_temp.confere((SELECT NOT sensor_parado AND sem_dados_h IS NULL AND pm25_3h = 20 AND ultima_leitura = '2026-11-26 23:00+00'
                          FROM a WHERE region_id = 'a0000000-0000-0000-0000-000000000002'),
                       'Parintins: em dia, com o "agora" de 3 h');

-- 3. Limite exato: 3 h sem leitura ainda não é "parado"; 3 h e 1 min é.
SELECT pg_temp.confere((SELECT NOT sensor_parado FROM public.ar_agora('2026-11-26 13:00+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000001'), 'exatamente 3 h: ainda não parado');
SELECT pg_temp.confere((SELECT sensor_parado AND sem_dados_h = 3 FROM public.ar_agora('2026-11-26 13:01+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000001'), '3 h e 1 min: parado, sem dados há 3 h');

-- 4. Verificação de saúde: aponta Manaus, não Parintins.
CREATE TEMP TABLE s AS SELECT * FROM public.saude_ar_sensores('2026-11-26 23:42+00');
SELECT pg_temp.confere((SELECT situacao = 'sem_dados' AND horas_sem_dados = 13.7 AND limite_h = 3 AND sensores = 'Manaus'
                          AND ultima_leitura = '2026-11-26 10:00+00' FROM s WHERE regiao = 'Manaus'),
                       'saúde: Manaus sinalizada (sem dados há 13,7 h, limite 3 h)');
SELECT pg_temp.confere((SELECT situacao = 'ok' FROM s WHERE regiao = 'Parintins'), 'saúde: Parintins ok');
SELECT pg_temp.confere((SELECT count(*) FILTER (WHERE situacao <> 'ok') = 1 FROM s), 'só uma região sinalizada');

-- 5. Só leitura e pública, como saude_fontes(). (saude_resumo(), saude_fontes() e o vigia
--    não são tocados por esta migração: sensor de terceiros parado só fica visível.)
SELECT pg_temp.confere((SELECT provolatile = 's' FROM pg_proc WHERE oid = 'public.saude_ar_sensores(timestamptz)'::regprocedure),
                       'saude_ar_sensores é STABLE (só leitura)');
SELECT pg_temp.confere(has_function_privilege('anon', 'public.saude_ar_sensores(timestamptz)', 'EXECUTE')
                   AND has_function_privilege('anon', 'public.ar_agora(timestamptz)', 'EXECUTE')
                   AND NOT has_function_privilege('anon', 'public.ar_agora_serie(text, timestamptz, timestamptz)', 'EXECUTE'),
                       'permissões: saúde e ar_agora públicas; série interna fechada');

-- 6. Nenhum aviso por sensor é ligado por esta migração, mesmo com o sensor de Manaus parado.
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_aviso_sensor WHERE ligado), 'avisos por sensor seguem desligados');
SELECT public.ar_avisos_atualizar('2026-11-26 23:42+00');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_avisos), 'nenhum aviso aberto');
ROLLBACK;
