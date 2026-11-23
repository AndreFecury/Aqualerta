-- Teste da Fase A1 (20261127a_saude.sql). PostGIS LOCAL, banco novo:
--   stub_base, saude_stubs, 20261127a_saude, este arquivo
-- Valores inventados para exercitar as regras.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
-- Agora fixo: 22/11 12:00 UTC.
CREATE OR REPLACE FUNCTION pg_temp.ag() RETURNS timestamptz LANGUAGE sql AS $$ SELECT '2026-11-22 12:00+00'::timestamptz $$;
CREATE OR REPLACE FUNCTION pg_temp.sit(f text, i text DEFAULT NULL) RETURNS text LANGUAGE sql AS
$$ SELECT situacao FROM public.saude_fontes(pg_temp.ag()) WHERE fonte = f AND (i IS NULL OR item LIKE i || '%') $$;

-- 3 estações: Manaus (15 min, em dia), Parintins (60 min, 5 h sem dado), Itacoatiara (nunca leu).
DELETE FROM public.hydro_readings; DELETE FROM public.alerts;
INSERT INTO public.hydro_stations (ana_code, name) VALUES ('16350002', 'Parintins'), ('16030000', 'Itacoatiara') ON CONFLICT DO NOTHING;
INSERT INTO public.hydro_readings
SELECT id, 16, pg_temp.ag() - interval '10 minutes' - g * interval '15 minutes' FROM public.hydro_stations, generate_series(0, 20) g
 WHERE ana_code = '14990000';
INSERT INTO public.hydro_readings
SELECT id, 5, pg_temp.ag() - interval '5 hours' - g * interval '1 hour' FROM public.hydro_stations, generate_series(0, 10) g
 WHERE ana_code = '16350002';

SELECT pg_temp.confere((SELECT count(*) FROM public.saude_fontes(pg_temp.ag()) WHERE fonte = 'ana') = 3, 'ANA: uma linha por estação ativa');
SELECT pg_temp.confere((SELECT cadencia_min FROM public.saude_fontes(pg_temp.ag()) WHERE item LIKE 'Manaus%') = 15
                   AND (SELECT cadencia_min FROM public.saude_fontes(pg_temp.ag()) WHERE item LIKE 'Parintins%') = 60,
                       'cada estação com a própria cadência (mediana)');
SELECT pg_temp.confere(pg_temp.sit('ana', 'Manaus') = 'ok', 'Manaus em dia');
-- Parintins: 5 h de idade - 2 h de folga = 180 min = 3x a cadência -> atrasada (parada só acima de 6x).
SELECT pg_temp.confere(pg_temp.sit('ana', 'Parintins') = 'atrasada', 'Parintins atrasada');
SELECT pg_temp.confere(pg_temp.sit('ana', 'Itacoatiara') = 'sem_dado', 'estação que nunca leu: sem_dado, nunca ok');
SELECT pg_temp.confere((SELECT regiao FROM public.saude_fontes(pg_temp.ag()) WHERE item LIKE 'Parintins%') = 'Parintins', 'estação ligada à região');

-- Demais fontes: nada gravado ainda.
SELECT pg_temp.confere(pg_temp.sit('cemaden') = 'sem_dado' AND pg_temp.sit('satelite') = 'sem_dado'
                   AND pg_temp.sit('ar_modelo') = 'sem_dado' AND pg_temp.sit('openaq_coletor') = 'sem_dado',
                       'fonte sem registro: sem_dado');
SELECT pg_temp.confere(pg_temp.sit('push_fila') = 'ok', 'fila vazia: em dia');
SELECT pg_temp.confere((public.saude_resumo(pg_temp.ag())->>'falha')::boolean = false, 'sem_dado e atrasada não falham');
SELECT pg_temp.confere(jsonb_array_length(public.saude_resumo(pg_temp.ag())->'sem_dado') = 5, 'sem_dado listado no resumo');

INSERT INTO public.chuva_estado VALUES (1, pg_temp.ag() - interval '20 minutes');        -- 4x 5 min: atrasada
INSERT INTO public.satelite_verificacoes VALUES ('a0000000-0000-0000-0000-000000000001', pg_temp.ag() - interval '1 hour');
INSERT INTO public.ar_estado VALUES (1, pg_temp.ag() - interval '7 hours');               -- 7x 60 min: parada
INSERT INTO public.openaq_estado VALUES (1, pg_temp.ag() - interval '30 minutes');
INSERT INTO public.openaq_sensores VALUES ('a0000000-0000-0000-0000-000000000001', 13574643, 'Manaus', 2),
                                          ('a0000000-0000-0000-0000-000000000001', 13574644, 'Manaus', 98);
INSERT INTO public.openaq_horas VALUES (13574643, pg_temp.ag() - interval '12 hours', 10);  -- aparelho fora do ar
INSERT INTO public.push_fila (criado_em) VALUES (pg_temp.ag() - interval '5 hours');        -- 10x 30 min: parada
INSERT INTO public.push_fila (criado_em, tentativas) VALUES (pg_temp.ag() - interval '9 hours', 3);  -- desistido: não conta

SELECT pg_temp.confere(pg_temp.sit('cemaden') = 'atrasada', 'CEMADEN atrasada');
SELECT pg_temp.confere(pg_temp.sit('satelite') = 'ok', 'satélite ok');
SELECT pg_temp.confere(pg_temp.sit('ar_modelo') = 'parada', 'modelo do ar parado');
SELECT pg_temp.confere((SELECT count(*) FROM public.saude_fontes(pg_temp.ag()) WHERE fonte = 'openaq_sensor') = 1,
                       'OpenAQ: só sensores de PM2.5');
SELECT pg_temp.confere(pg_temp.sit('openaq_sensor') = 'parada' AND pg_temp.sit('openaq_coletor') = 'ok', 'sensor parado, coletor ok');
SELECT pg_temp.confere(pg_temp.sit('push_fila') = 'parada'
                   AND (SELECT idade_min FROM public.saude_fontes(pg_temp.ag()) WHERE fonte = 'push_fila') = 300,
                       'fila: idade do pendente mais antigo, ignora desistidos');

CREATE TEMP TABLE r AS SELECT public.saude_resumo(pg_temp.ag()) AS j;
SELECT pg_temp.confere((SELECT (j->>'falha')::boolean FROM r), 'parada em fonte central falha');
SELECT pg_temp.confere((SELECT j->'motivos' ? 'ar_modelo parada há 420 min' AND j->'motivos' ? 'push_fila parada há 300 min'
                          AND j::text NOT LIKE '%openaq_sensor parada%' FROM r),
                       'motivos listados; sensor OpenAQ parado não falha');
DELETE FROM public.push_fila; UPDATE public.ar_estado SET modelo_ok_em = pg_temp.ag();
SELECT pg_temp.confere((public.saude_resumo(pg_temp.ag())->>'falha')::boolean = false, 'tudo de volta: sem falha');

-- ANA: Parintins parada (9 h sem dado, cadência 60).
DELETE FROM public.hydro_readings WHERE station_id = (SELECT id FROM public.hydro_stations WHERE ana_code = '16350002');
INSERT INTO public.hydro_readings
SELECT id, 5, pg_temp.ag() - interval '9 hours' - g * interval '1 hour' FROM public.hydro_stations, generate_series(0, 10) g
 WHERE ana_code = '16350002';
SELECT pg_temp.confere(pg_temp.sit('ana', 'Parintins') = 'parada', 'Parintins parada');
-- 1 de 3 paradas é exatamente 1/3: falha.
SELECT pg_temp.confere((public.saude_resumo(pg_temp.ag())->>'falha')::boolean, 'limite 1/3: 1 de 3 paradas falha');
-- Com 4 estações em dia e 1 parada (1/5), sem alerta ativo: não falha.
INSERT INTO public.hydro_stations (ana_code, name) VALUES ('15040000', 'Teste A'), ('15050000', 'Teste B') ON CONFLICT DO NOTHING;
INSERT INTO public.hydro_readings
SELECT id, 1, pg_temp.ag() - g * interval '1 hour' FROM public.hydro_stations, generate_series(0, 5) g
 WHERE ana_code IN ('15040000', '15050000', '16030000');
SELECT pg_temp.confere((public.saude_resumo(pg_temp.ag())->>'falha')::boolean = false, '1 de 5 paradas, sem alerta ativo: não falha');
-- A mesma estação parada, agora numa região com alerta ativo: falha num motivo só.
INSERT INTO public.alerts (region_id, title, body, severity, status)
VALUES ('a0000000-0000-0000-0000-000000000002', 'Cheia em Parintins', 'teste', 'HIGH', 'ACTIVE');
CREATE TEMP TABLE r2 AS SELECT public.saude_resumo(pg_temp.ag()) AS j;
SELECT pg_temp.confere((SELECT (j->>'falha')::boolean AND jsonb_array_length(j->'motivos') = 1
                          AND j->'motivos'->>0 LIKE 'ANA: 1 de 5 estações paradas (com alerta ativo: Parintins (16350002))%' FROM r2),
                       'estação parada em região com alerta ativo falha, num motivo só');
-- Estação que perdeu todas as leituras: sem_dado, não parada.
DELETE FROM public.hydro_readings WHERE station_id = (SELECT id FROM public.hydro_stations WHERE ana_code = '15040000');
SELECT pg_temp.confere((SELECT jsonb_array_length(j->'motivos') = 1 FROM (SELECT public.saude_resumo(pg_temp.ag()) j) x)
                   AND pg_temp.sit('ana', 'Teste A') = 'sem_dado', 'estação sem leitura nenhuma: sem_dado, e a ANA vira um aviso só');

-- Permissões: anon executa as duas RPCs e nada mais.
SELECT pg_temp.confere(has_function_privilege('anon', 'public.saude_fontes(timestamptz)', 'EXECUTE')
                   AND has_function_privilege('anon', 'public.saude_resumo(timestamptz)', 'EXECUTE')
                   AND NOT has_function_privilege('anon', 'public.saude_situacao(timestamptz,numeric,numeric,timestamptz)', 'EXECUTE')
                   AND NOT has_function_privilege('anon', 'public.saude_cfg_valor(text)', 'EXECUTE')
                   AND NOT has_table_privilege('anon', 'public.saude_cfg', 'SELECT'), 'anon: só as duas RPCs');
SET LOCAL ROLE anon;
SELECT pg_temp.confere((SELECT count(*) FROM public.saude_fontes()) > 0, 'anon chama saude_fontes()');
SELECT pg_temp.confere(public.saude_resumo() ? 'falha', 'anon chama saude_resumo()');
RESET ROLE;
ROLLBACK;
