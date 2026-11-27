-- Consultas de docs/ar-previsao-erro.md: o que as tabelas de validação JÁ medem
-- (modelo × sensor, antecedência curta) e como o erro de pico aparece nelas.
-- PostGIS LOCAL, banco novo:
--   stub_base, ar_stubs, ar_validacao_stubs, push_teste_stubs, sinal_dados_stubs,
--   20261118_push_fcm, 20261121b_sinal_dados, 20261122_ar, 20261123b_push_teste,
--   20261124_openaq, 20261125a_ar_pausa, 20261125b, 20261125c, 20261126a,
--   20261126b, 20261127b, 20261128a, este arquivo
-- Valores inventados: 3 dias locais de Manaus (04:00 UTC a 04:00 UTC); no dia 2
-- o sensor fica em 100 µg/m³ (IQAr "Muito ruim") e o modelo em 30 ("Moderada").
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensores_n, valido)
SELECT 'a0000000-0000-0000-0000-000000000001', h, 'continua',
       CASE WHEN h >= '2026-11-20 04:00+00' AND h < '2026-11-21 04:00+00' THEN 30 ELSE 20 END,
       CASE WHEN h >= '2026-11-20 04:00+00' AND h < '2026-11-21 04:00+00' THEN 100 ELSE 20 END,
       1, true
  FROM generate_series('2026-11-19 04:00+00'::timestamptz, '2026-11-22 03:00+00', interval '1 hour') h;

-- A. Viés e concordância modelo × sensor (dias, fuso local).
CREATE TEMP TABLE a AS
SELECT regiao, dias, dif_mediana, dif_q1, dif_q3, correlacao_diaria, dias_mesmo_nivel
  FROM public.ar_validacao_resumo
 WHERE origem = 'continua' AND fuso = 'local' AND recorte = 'todos';
SELECT pg_temp.confere((SELECT count(*) = 1 AND bool_and(dias = 3 AND dias_mesmo_nivel = 2) FROM a),
                       'A: 3 dias, o modelo acerta o nível em 2 deles');

-- B. Dias perdidos: sensor em "Muito ruim"/"Péssima" e modelo em "Boa"/"Moderada".
CREATE TEMP TABLE b AS
SELECT regiao, dia, sensor_24h, modelo_24h, nivel_sensor, nivel_modelo
  FROM public.ar_validacao_dias
 WHERE origem = 'continua' AND fuso = 'local'
   AND nivel_sensor IN ('N4', 'N5') AND nivel_modelo IN ('N1', 'N2')
 ORDER BY dia;
SELECT pg_temp.confere((SELECT count(*) = 1 AND bool_and(dia = '2026-11-20' AND nivel_sensor = 'N4' AND nivel_modelo = 'N2') FROM b),
                       'B: o dia do pico aparece como dia perdido (sensor N4, modelo N2)');

-- C. Pico: maior IQAr de média móvel de 24 h por dia UTC, sensor × modelo.
CREATE TEMP TABLE c AS
WITH m AS (
    SELECT v.region_id, v.hora,
           avg(v.sensor_pm25) OVER w AS s24, avg(v.modelo_pm25) OVER w AS m24, count(*) OVER w AS n
      FROM public.ar_validacao_horas v
     WHERE v.origem = 'continua' AND v.valido
    WINDOW w AS (PARTITION BY v.region_id ORDER BY v.hora RANGE BETWEEN interval '23 hours' PRECEDING AND CURRENT ROW)
)
SELECT r.name AS regiao, (m.hora AT TIME ZONE 'UTC')::date AS dia_utc,
       max(public.ar_iqar('pm2_5', round(m.s24, 1))) AS pico_iqar_sensor,
       max(public.ar_iqar('pm2_5', round(m.m24, 1))) AS pico_iqar_modelo
  FROM m JOIN public.monitored_regions r ON r.id = m.region_id
 WHERE m.n >= 18
 GROUP BY r.name, (m.hora AT TIME ZONE 'UTC')::date;
SELECT pg_temp.confere((SELECT max(pico_iqar_sensor) >= 121 AND max(pico_iqar_modelo) <= 80 FROM c),
                       'C: pico do sensor em N4 (IQAr >= 121) contra modelo em N2 (<= 80)');

-- D. O que estas tabelas NÃO medem: ar_horas guarda 1 valor por hora (a última
--    coleta sobrescreve), então não há previsão arquivada por antecedência.
SELECT pg_temp.confere((SELECT count(*) = 0 FROM information_schema.columns
                         WHERE table_schema = 'public' AND table_name IN ('ar_horas', 'ar_validacao_horas')
                           AND column_name IN ('emitida_em', 'antecedencia_h', 'previsao_emitida_em')),
                       'D: sem coluna de emissão/antecedência: erro de previsão de 24-48 h ainda não é mensurável');
SELECT pg_temp.confere((SELECT count(*) = 2 FROM information_schema.table_constraints
                         WHERE table_schema = 'public' AND table_name = 'ar_horas' AND constraint_type = 'PRIMARY KEY'
                            OR table_schema = 'public' AND table_name = 'ar_validacao_horas' AND constraint_type = 'PRIMARY KEY'),
                       'D: chave única por hora nas duas tabelas (uma só versão do modelo por hora)');
ROLLBACK;
