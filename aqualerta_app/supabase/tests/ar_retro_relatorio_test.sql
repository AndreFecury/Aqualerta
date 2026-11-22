\set ON_ERROR_STOP 1
\i ../scripts/ar_retro_relatorio.sql
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;
-- Série inventada: 10 h a 20, 4 h a 100 (pico), 6 h a 20. Início 10/08 04:00 UTC = 00h local.
INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensor_pm25_epa, valido)
SELECT 'a0000000-0000-0000-0000-000000000001', '2026-08-10 04:00+00'::timestamptz + i * interval '1 hour', 'retro', 10,
       CASE WHEN i BETWEEN 10 AND 13 THEN 100 ELSE 20 END, CASE WHEN i BETWEEN 10 AND 13 THEN 70 ELSE 10 END, true
  FROM generate_series(0, 19) i;
-- NowCast na 1ª hora do pico: w* = 20/100 = 0,2 -> w = 0,5; (100 + 20·(0,5+...+0,5^9)) / (1+0,5+...+0,5^9)
SELECT pg_temp.confere((SELECT nowcast FROM public.ar_retro_nowcast(false) WHERE hora = '2026-08-10 14:00+00')
                       = round((100 + 20 * (0.5 + 0.25 + 0.125 + 0.0625 + 0.03125 + 0.015625 + 0.0078125 + 0.00390625 + 0.001953125))
                               / (1 + 0.5 + 0.25 + 0.125 + 0.0625 + 0.03125 + 0.015625 + 0.0078125 + 0.00390625 + 0.001953125), 1),
                       'NowCast na 1ª hora do pico (fórmula da EPA)');
SELECT pg_temp.confere((SELECT nowcast FROM public.ar_retro_nowcast(false) WHERE hora = '2026-08-10 06:00+00') = 20
                   AND NOT EXISTS (SELECT 1 FROM public.ar_retro_nowcast(false) WHERE hora = '2026-08-10 04:00+00'),
                       'série constante: NowCast = valor; 1ª hora sem 2 de 3 recentes não tem valor');
SELECT * FROM public.ar_retro_nowcast(false) WHERE hora BETWEEN '2026-08-10 13:00+00' AND '2026-08-10 22:00+00' ORDER BY hora;
SELECT * FROM public.ar_retro_simular(50, false);
SELECT pg_temp.confere((SELECT episodios = 1 AND dias_com_aviso = 1 FROM public.ar_retro_simular(50, false)), 'pico de 4 h abre 1 aviso a 50');
SELECT pg_temp.confere((SELECT episodios = 0 FROM public.ar_retro_simular(75, true)), 'corrigido (70) não passa de 75');
ROLLBACK;
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;
INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensor_pm25_epa, valido)
SELECT 'a0000000-0000-0000-0000-000000000001', '2026-08-10 04:00+00'::timestamptz + i * interval '1 hour', 'retro', 10,
       CASE WHEN i BETWEEN 10 AND 13 THEN 100 ELSE 20 END, CASE WHEN i BETWEEN 10 AND 13 THEN 70 ELSE 10 END, true
  FROM generate_series(0, 19) i;
SELECT pg_temp.confere((SELECT array_agg(DISTINCT dia) FROM public.ar_retro_dias_aviso(50, false)) = ARRAY['2026-08-10'::date],
                       'dias com aviso: o dia local do pico');
ROLLBACK;
