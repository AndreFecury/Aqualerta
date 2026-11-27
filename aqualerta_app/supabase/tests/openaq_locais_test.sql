-- Teste de 20261128c_openaq_loc_ambiguo.sql: o ramo 'locais' de openaq_processar()
-- (e o ramo 'ur_ambiente', que usa a variável renomeada) rodam sem erro.
-- PostGIS LOCAL, banco novo:
--   stub_base, ar_stubs, ar_validacao_stubs, push_teste_stubs, sinal_dados_stubs,
--   20261118_push_fcm, 20261121b_sinal_dados, 20261122_ar, 20261124_openaq,
--   20261125b_ar_validacao, 20261125c_ar_validacao_ajustes, 20261128c_openaq_loc_ambiguo,
--   este arquivo
-- Respostas MONTADAS no formato da documentação da API v3 da OpenAQ; ids e nomes
-- inventados. Manaus = a0000000-...-001, Parintins = ...-002 (stub).
-- Sem a migração 20261128c este teste falha em "2 respostas lidas" e em
-- "sem erro gravado" (column reference "loc" is ambiguous).
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
DELETE FROM net.chamadas;
INSERT INTO vault.decrypted_secrets VALUES ('openaq_key', 'chave-de-teste') ON CONFLICT (name) DO UPDATE SET decrypted_secret = 'chave-de-teste';

-- 0. A função não declara mais uma variável chamada loc (era o que colidia com o alias).
SELECT pg_temp.confere(pg_get_functiondef('public.openaq_processar(timestamptz)'::regprocedure) !~ E'\\mloc\\s+jsonb',
                       'sem variável plpgsql "loc jsonb" em openaq_processar');

-- 1. Busca de estações: 1 pedido por região.
SELECT pg_temp.confere(public.openaq_pedir('2026-11-26 14:16+00') = 2, '2 buscas de estações');
INSERT INTO net._http_response (id, status_code, content)
SELECT p.request_id, 200,
       CASE WHEN p.region_id = 'a0000000-0000-0000-0000-000000000001' THEN $j${
         "meta": {"name": "openaq-api", "page": 1, "limit": 50, "found": 2},
         "results": [
           {"id": 900001, "name": "Manaus - estação teste", "isMobile": false, "isMonitor": false,
            "provider": {"id": 1, "name": "AirGradient"},
            "licenses": [{"id": 1, "name": "CC BY 4.0", "attribution": {"name": "AirGradient", "url": null}}],
            "coordinates": {"latitude": -3.10, "longitude": -60.02}, "distance": 2026.9,
            "datetimeLast": {"utc": "2026-11-26T10:00:00Z"},
            "sensors": [{"id": 7001, "name": "pm25 µg/m³", "parameter": {"id": 2, "name": "pm25", "units": "µg/m³"}},
                        {"id": 7004, "name": "rh %", "parameter": {"id": 98, "name": "relativehumidity", "units": "%"}},
                        {"id": 7002, "name": "o3 ppm", "parameter": {"id": 10, "name": "o3", "units": "ppm"}}]},
           {"id": 900002, "name": "Ônibus", "isMobile": true,
            "provider": {"id": 2, "name": "Móvel"}, "coordinates": {"latitude": -3.1, "longitude": -60.0}, "distance": 100,
            "datetimeLast": {"utc": "2026-11-26T11:00:00Z"},
            "sensors": [{"id": 7003, "parameter": {"id": 2, "name": "pm25"}}]}
         ]}$j$
       ELSE '{"meta": {"found": 0}, "results": []}' END
  FROM public.openaq_pedidos p WHERE p.tipo = 'locais';
SELECT pg_temp.confere(public.openaq_processar('2026-11-26 14:19+00') = 2, '2 respostas lidas');
SELECT pg_temp.confere((SELECT erro IS NULL FROM public.openaq_estado), 'sem erro gravado em openaq_estado');
SELECT pg_temp.confere((SELECT locais_ok_em = '2026-11-26 14:19+00' FROM public.openaq_estado), 'locais_ok_em atualizado (era o que estava parado)');
SELECT pg_temp.confere((SELECT count(*) = 2 AND array_agg(sensor_id ORDER BY sensor_id) = ARRAY[7001, 7004]::bigint[]
                          AND bool_and(provedor = 'AirGradient' AND licenca = 'CC BY 4.0' AND region_id = 'a0000000-0000-0000-0000-000000000001')
                          FROM public.openaq_sensores),
                       'MP2,5 e umidade da estação fixa; O3 e estação móvel fora; Parintins sem sensor');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.openaq_pedidos) AND NOT EXISTS (SELECT 1 FROM net._http_response),
                       'pedidos e respostas limpos');

-- 2. Ramo 'ur_ambiente' (usa a variável v_loc): umidade do Open-Meteo gravada.
DELETE FROM net.chamadas;
SELECT pg_temp.confere(public.openaq_pedir('2026-11-26 15:16+00') = 3, '2 séries de horas + 1 umidade ambiente');
INSERT INTO net._http_response (id, status_code, content)
SELECT p.request_id, 200, CASE p.tipo
    WHEN 'ur_ambiente' THEN '{"hourly": {"time": [1795687200, 1795690800, 1795780800], "relative_humidity_2m": [97, 91, 50]}}'
    ELSE jsonb_build_object('results', jsonb_build_array(jsonb_build_object(
           'value', CASE WHEN p.sensor_id = 7004 THEN 52 ELSE 25 END,
           'period', jsonb_build_object('datetimeFrom', jsonb_build_object('utc', '2026-11-26T10:00:00Z')))))::text END
  FROM public.openaq_pedidos p;
SELECT public.openaq_processar('2026-11-26 15:19+00');
SELECT pg_temp.confere((SELECT erro IS NULL OR erro_em < '2026-11-26 15:00+00' FROM public.openaq_estado),
                       'ramos de horas e umidade ambiente sem erro novo');
SELECT pg_temp.confere((SELECT count(*) = 2 FROM public.ar_ur_ambiente), 'umidade ambiente gravada (a hora futura, 27/11 12:00 UTC, fica fora)');
SELECT pg_temp.confere((SELECT count(*) = 1 FROM public.openaq_horas WHERE sensor_id = 7001 AND pm25 = 25), 'hora do sensor gravada');

-- 3. Depois de um dia, a lista é SUBSTITUÍDA pelo que a OpenAQ devolve na hora
--    (efeito esperado: um sensor que sumiu da resposta sai da lista da região).
UPDATE public.openaq_estado SET locais_ok_em = '2026-11-25 09:00+00', erro = NULL, erro_em = NULL;
SELECT pg_temp.confere(public.openaq_pedir('2026-11-27 14:16+00') >= 2, 'nova busca diária de estações');
INSERT INTO net._http_response (id, status_code, content)
SELECT p.request_id, 200, '{"meta": {"found": 0}, "results": []}'
  FROM public.openaq_pedidos p WHERE p.tipo = 'locais';
SELECT public.openaq_processar('2026-11-27 14:19+00');
SELECT pg_temp.confere((SELECT erro IS NULL FROM public.openaq_estado) AND NOT EXISTS (SELECT 1 FROM public.openaq_sensores),
                       'resposta sem estações: a lista da região é esvaziada, sem erro');
ROLLBACK;
