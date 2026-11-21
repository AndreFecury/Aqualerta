-- Teste da regra de avisos de chuva (supabase/migrations/20261119_chuva.sql,
-- limites calibrados em 20261121_chuva_calibracao.sql).
-- Roda só num PostGIS LOCAL de teste, depois de supabase/tests/stub_base.sql
-- e das migrações de chuva. Os milímetros abaixo são cenários de teste.
--   psql -v ON_ERROR_STOP=1 -f stub_base.sql -f ../migrations/20261119_chuva.sql --        -f ../migrations/20261119b_chuva_pgnet.sql -f ../migrations/20261119c_chuva_ped.sql --        -f ../migrations/20261121_chuva_calibracao.sql -f chuva_test.sql
\set ON_ERROR_STOP 1
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

-- Manaus com duas estações; Parintins com uma.
SELECT public.chuva_registrar_estacoes(jsonb_build_array(
  jsonb_build_object('id', 6740, 'codigo', '130260310A', 'nome', 'Colônia Antônio Aleixo', 'tipo', 'Pluviométrica',
                     'region_id', 'a0000000-0000-0000-0000-000000000001', 'lat', -3.08671, 'lng', -59.88327),
  jsonb_build_object('id', 6741, 'codigo', '130260304A', 'nome', 'Flores', 'tipo', 'Pluviométrica',
                     'region_id', 'a0000000-0000-0000-0000-000000000001', 'lat', -3.04046, 'lng', -59.99958),
  jsonb_build_object('id', 7000, 'codigo', '130340301A', 'nome', 'Centro', 'tipo', 'Pluviométrica',
                     'region_id', 'a0000000-0000-0000-0000-000000000002', 'lat', -2.63, 'lng', -56.73)));

-- Relógio do teste: 19/11/2026 15:20 (Manaus) = 19:20 UTC.
CREATE TEMP TABLE relogio AS SELECT timestamptz '2026-11-19 19:20:00+00' AS t;

-- Grava uma leitura "confirmada agora" no relógio do teste.
CREATE OR REPLACE FUNCTION pg_temp.chuva(est int, hora timestamptz, mm numeric) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO public.chuva_leituras (estacao_id, hora, mm, lido_em)
    VALUES (est, hora, mm, (SELECT t FROM relogio))
    ON CONFLICT (estacao_id, hora) DO UPDATE SET mm = EXCLUDED.mm, lido_em = EXCLUDED.lido_em;
$$;
CREATE OR REPLACE FUNCTION pg_temp.avisos() RETURNS int
LANGUAGE sql AS $$ SELECT public.chuva_atualizar_avisos((SELECT t FROM relogio)) $$;
CREATE OR REPLACE FUNCTION pg_temp.aviso(reg uuid) RETURNS public.alerts
LANGUAGE sql AS $$ SELECT * FROM public.alerts WHERE region_id = reg AND metadata->>'origem' = 'chuva-cemaden'
                   ORDER BY issued_at DESC LIMIT 1 $$;

-- 1. Chuva fraca: nada.
SELECT pg_temp.chuva(6740, '2026-11-19 19:00+00', 5);
SELECT pg_temp.confere(pg_temp.avisos() = 0, 'chuva fraca não gera aviso');
SELECT pg_temp.confere(pg_temp.aviso('a0000000-0000-0000-0000-000000000001') IS NULL, 'sem aviso em Manaus');

-- 2. 25 mm na hora corrente: amarelo (MEDIUM).
SELECT pg_temp.chuva(6740, '2026-11-19 19:00+00', 25);
SELECT pg_temp.confere(pg_temp.avisos() = 1, '25 mm/h cria aviso');
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).severity = 'MEDIUM', 'nível MEDIUM');
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).title = 'Chuva forte em Manaus: risco de alagamento', 'título');
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).body LIKE 'O pluviômetro Colônia Antônio Aleixo (CEMADEN) registrou 25 mm na última hora e 25 mm em 24 h (leitura das 15:20).%', 'texto com estação, mm e hora de Manaus');
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).flood_event_id IS NULL, 'aviso de chuva não inventa área alagada');

-- 3. Um pluviômetro só com 34,5 mm: segue amarelo (comum em Manaus).
SELECT pg_temp.chuva(6741, '2026-11-19 19:00+00', 34.5);
SELECT pg_temp.confere(pg_temp.avisos() = 0, 'um pluviômetro com 34,5 mm não sobe o nível');
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).severity = 'MEDIUM', 'segue MEDIUM');
--    Outro pluviômetro do município também passa de 30 mm: laranja (HIGH), mesmo alerta.
SELECT pg_temp.chuva(6740, '2026-11-19 19:00+00', 31);
SELECT pg_temp.confere(pg_temp.avisos() = 1, 'subida conta como mudança');
SELECT pg_temp.confere((SELECT count(*) FROM public.alerts WHERE metadata->>'origem' = 'chuva-cemaden') = 1, 'continua um alerta só');
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).severity = 'HIGH', 'nível HIGH');
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).body LIKE 'O pluviômetro Flores (CEMADEN) registrou 34,5 mm%', 'texto passa para a pior estação');

-- 4. A chuva diminui: o nível não desce (sem spam de push).
UPDATE relogio SET t = t + interval '50 minutes';   -- 20:10 UTC
SELECT pg_temp.chuva(6740, '2026-11-19 20:00+00', 2);
SELECT pg_temp.chuva(6741, '2026-11-19 20:00+00', 1);
SELECT pg_temp.confere(pg_temp.avisos() = 0, 'chuva diminuindo não muda o aviso');
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).severity = 'HIGH', 'segue HIGH');

-- 5. Encerra 2 h depois do último gatilho (último gatilho foi 20:10 com 34,5 mm da hora anterior).
UPDATE relogio SET t = timestamptz '2026-11-19 22:05+00';
SELECT pg_temp.chuva(6740, '2026-11-19 22:00+00', 0);
SELECT pg_temp.chuva(6741, '2026-11-19 22:00+00', 0);
SELECT pg_temp.confere(pg_temp.avisos() = 0, 'menos de 2 h desde o último gatilho: não encerra');
UPDATE relogio SET t = timestamptz '2026-11-19 22:15+00';
SELECT pg_temp.chuva(6740, '2026-11-19 22:00+00', 0);
SELECT pg_temp.confere(pg_temp.avisos() = 1, 'mais de 2 h: encerra');
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).status = 'RESOLVED', 'status RESOLVED');
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).body LIKE '%Encerrado às 18:15: 2 h sem chuva forte%', 'motivo do encerramento');

-- 6. 24 h: 55 mm espalhados (nenhuma hora acima de 20) → amarelo pelo acumulado.
UPDATE relogio SET t = timestamptz '2026-11-20 12:10+00';
SELECT pg_temp.chuva(7000, timestamptz '2026-11-20 00:00+00' + (h || ' hours')::interval, 4.6)
FROM generate_series(0, 11) h;                       -- 12 × 4,6 = 55,2 mm
SELECT pg_temp.confere(pg_temp.avisos() = 1, 'acumulado de 24 h gera aviso');
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000002')).severity = 'MEDIUM', '55 mm/24 h = MEDIUM');

-- 7. Dado velho não vira aviso (coleta parada há 1 h).
UPDATE relogio SET t = timestamptz '2026-11-21 10:00+00';
INSERT INTO public.chuva_leituras (estacao_id, hora, mm, lido_em)
VALUES (6740, '2026-11-21 09:00+00', 70, '2026-11-21 09:00+00');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.chuva_avaliar('2026-11-21 10:00+00') WHERE estacao_id = 6740),
                       'leitura de 1 h atrás não conta');

-- 8. Valor impossível (falha de sensor) é ignorado.
UPDATE relogio SET t = timestamptz '2026-11-22 10:00+00';
SELECT pg_temp.chuva(6740, '2026-11-22 10:00+00', 3600.2);
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.chuva_avaliar('2026-11-22 10:00+00')
                                   WHERE estacao_id = 6740 AND severidade <> 'LOW'), '3600 mm/h é ignorado');

-- 9. A rotina do rio não encerra mais o aviso de chuva.
UPDATE relogio SET t = timestamptz '2026-11-23 10:10+00';
DELETE FROM public.chuva_leituras;
SELECT pg_temp.chuva(6740, '2026-11-23 10:00+00', 25);
SELECT pg_temp.avisos();
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).status = 'ACTIVE', 'aviso de chuva ativo');
SELECT public.ana_atualizar_alertas();                -- rio de Manaus abaixo da cota (stub)
SELECT pg_temp.confere((pg_temp.aviso('a0000000-0000-0000-0000-000000000001')).status = 'ACTIVE',
                       'ana_atualizar_alertas não encerra o aviso de chuva');
SELECT pg_temp.confere((SELECT status FROM public.alerts WHERE metadata->>'origem' = 'telemetria-ana') = 'RESOLVED',
                       'mas continua encerrando o alerta do rio');

-- 10. View pública.
SELECT pg_temp.confere((SELECT count(*) FROM public.v_chuva_agora) = 3, 'view lista as 3 estações');

ROLLBACK;
\echo 'chuva_test.sql: todos os testes passaram'
