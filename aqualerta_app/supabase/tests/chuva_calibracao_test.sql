-- Teste dos limites calibrados (20261121_chuva_calibracao.sql). PostGIS LOCAL
-- apenas, depois de stub_base.sql e das quatro migrações de chuva. Os
-- milímetros são cenários de teste inspirados nos dias reais de 2025/2026.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

DELETE FROM public.chuva_leituras;
DELETE FROM public.chuva_leituras_10min;
DELETE FROM public.chuva_estacoes;
SELECT public.chuva_registrar_estacoes(jsonb_build_array(
  jsonb_build_object('id', 1, 'codigo', 'T1', 'nome', 'Um', 'tipo', 'Pluviométrica',
                     'region_id', 'a0000000-0000-0000-0000-000000000001', 'lat', -3.0, 'lng', -60.0),
  jsonb_build_object('id', 2, 'codigo', 'T2', 'nome', 'Dois', 'tipo', 'Pluviométrica',
                     'region_id', 'a0000000-0000-0000-0000-000000000001', 'lat', -3.0, 'lng', -60.0),
  jsonb_build_object('id', 3, 'codigo', 'T3', 'nome', 'Três', 'tipo', 'Pluviométrica',
                     'region_id', 'a0000000-0000-0000-0000-000000000001', 'lat', -3.0, 'lng', -60.0),
  jsonb_build_object('id', 4, 'codigo', 'T4', 'nome', 'Outra cidade', 'tipo', 'Pluviométrica',
                     'region_id', 'a0000000-0000-0000-0000-000000000002', 'lat', -2.6, 'lng', -56.7)));

-- Leitura da hora corrente (coleta aberta), confirmada agora.
CREATE OR REPLACE FUNCTION pg_temp.hora(est int, mm numeric) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO public.chuva_leituras (estacao_id, hora, mm, lido_em)
    VALUES (est, date_trunc('hour', now()), mm, now())
    ON CONFLICT (estacao_id, hora) DO UPDATE SET mm = EXCLUDED.mm, lido_em = EXCLUDED.lido_em;
$$;
CREATE OR REPLACE FUNCTION pg_temp.nivel(est int) RETURNS text
LANGUAGE sql AS $$ SELECT severidade FROM public.chuva_avaliar() WHERE estacao_id = est $$;
CREATE OR REPLACE FUNCTION pg_temp.zera() RETURNS void
LANGUAGE sql AS $$ DELETE FROM public.chuva_leituras; DELETE FROM public.chuva_leituras_10min; $$;

-- 1. Um pluviômetro sozinho.
SELECT pg_temp.hora(1, 19.9);
SELECT pg_temp.confere(pg_temp.nivel(1) = 'LOW', '19,9 mm/h: sem aviso');
SELECT pg_temp.hora(1, 20);
SELECT pg_temp.confere(pg_temp.nivel(1) = 'MEDIUM', '20 mm/h: forte');
SELECT pg_temp.hora(1, 38);
SELECT pg_temp.confere(pg_temp.nivel(1) = 'MEDIUM', '38 mm/h num pluviômetro só: forte');
SELECT pg_temp.hora(1, 40);
SELECT pg_temp.confere(pg_temp.nivel(1) = 'HIGH', '40 mm/h: muito forte');
SELECT pg_temp.hora(1, 60);
SELECT pg_temp.confere(pg_temp.nivel(1) = 'CRITICAL', '60 mm/h (chuva de ~2 anos): extrema');

-- 2. Vários pluviômetros do mesmo município.
SELECT pg_temp.zera();
SELECT pg_temp.hora(1, 31); SELECT pg_temp.hora(2, 33);
SELECT pg_temp.confere(pg_temp.nivel(1) = 'HIGH' AND pg_temp.nivel(2) = 'HIGH', '2 pluviômetros >= 30: muito forte');
SELECT pg_temp.hora(4, 31);
SELECT pg_temp.confere(pg_temp.nivel(4) = 'MEDIUM', 'pluviômetro de outro município não soma');
SELECT pg_temp.hora(3, 25);
SELECT pg_temp.confere(pg_temp.nivel(3) = 'MEDIUM', 'quem tem só 25 mm segue forte');
SELECT pg_temp.hora(1, 41); SELECT pg_temp.hora(2, 42); SELECT pg_temp.hora(3, 40);
SELECT pg_temp.confere(pg_temp.nivel(1) = 'CRITICAL', '3 pluviômetros >= 40: extrema');
SELECT pg_temp.hora(3, 39);
SELECT pg_temp.confere(pg_temp.nivel(1) = 'HIGH', 'só 2 com >= 40: muito forte');

-- 3. Acumulado de 24 h (horas fracas espalhadas).
SELECT pg_temp.zera();
INSERT INTO public.chuva_leituras (estacao_id, hora, mm, lido_em)
SELECT 1, date_trunc('hour', now()) - make_interval(hours => h), mm, now()
FROM generate_series(0, 9) h, (VALUES (5.0)) v(mm);              -- 50 mm
SELECT pg_temp.confere(pg_temp.nivel(1) = 'MEDIUM', '50 mm em 24 h: forte');
UPDATE public.chuva_leituras SET mm = 10;                            -- 100 mm
SELECT pg_temp.confere(pg_temp.nivel(1) = 'HIGH', '100 mm em 24 h: muito forte');
UPDATE public.chuva_leituras SET mm = 13;                            -- 130 mm
SELECT pg_temp.confere(pg_temp.nivel(1) = 'CRITICAL', '130 mm em 24 h (chuva de ~2 anos): extrema');

-- 4. Falha de sensor (acima da chuva de 100 anos do IDF de Manaus).
SELECT pg_temp.zera();
SELECT pg_temp.hora(1, 111.8);   -- caso real de 09/12/2025, sem chuva nos vizinhos
SELECT pg_temp.confere(coalesce(pg_temp.nivel(1), 'LOW') = 'LOW', '111,8 mm numa hora é ignorado');
SELECT pg_temp.hora(1, 105);
SELECT pg_temp.confere(pg_temp.nivel(1) = 'CRITICAL', '105 mm numa hora ainda vale');
SELECT pg_temp.zera();
INSERT INTO public.chuva_leituras_10min (estacao_id, fim, mm, lido_em)
VALUES (1, now() - interval '20 minutes', 40, now()), (1, now() - interval '10 minutes', 2, now());
SELECT pg_temp.confere((SELECT mm_1h FROM public.chuva_avaliar() WHERE estacao_id = 1) = 2,
                       '40 mm em 10 min é ignorado, o resto conta');
INSERT INTO public.chuva_leituras_10min (estacao_id, fim, mm, lido_em)
VALUES (1, now() - interval '30 minutes', 28, now());
SELECT pg_temp.confere((SELECT mm_1h FROM public.chuva_avaliar() WHERE estacao_id = 1) = 30,
                       '28 mm em 10 min vale');

-- 5. Texto do aviso: não cita mais os critérios do INMET.
DELETE FROM public.alerts WHERE metadata->>'origem' = 'chuva-cemaden';
SELECT public.chuva_atualizar_avisos(now());
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.alerts WHERE metadata->>'origem' = 'chuva-cemaden'
                                 AND severity = 'MEDIUM' AND body LIKE '%limites calibrados%'
                                 AND body NOT LIKE '%INMET%'), 'rodapé novo no aviso');

ROLLBACK;
