-- Teste de 20261128c_openaq_loc_ambiguo.sql: o ramo 'locais' de openaq_processar()
-- (e o ramo 'ur_ambiente', que usa a variável renomeada) rodam sem erro.
-- PostGIS LOCAL, banco novo:
--   stub_base, ar_stubs, ar_validacao_stubs, push_teste_stubs, sinal_dados_stubs,
--   20261118_push_fcm, 20261121b_sinal_dados, 20261122_ar, 20261124_openaq,
--   20261125b_ar_validacao, 20261125c_ar_validacao_ajustes, 20261128c_openaq_loc_ambiguo,
--   este arquivo
-- Respostas MONTADAS no formato da documentação da API v3 da OpenAQ; ids e nomes
-- inventados. Manaus = a0000000-...-001, Parintins = ...-002 (stub).
-- Sem a migração 20261128c este teste falha em "2 respostas lidas" (column reference
-- "loc" is ambiguous). A busca de estações NÃO apaga sensor já guardado (bloco 3).
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

-- 3. A busca de estações NÃO apaga sensor guardado.
--    rodar_locais(agora, resposta de Manaus): força a busca diária, responde Manaus
--    com o JSON dado e as demais regiões com resposta vazia, e processa 3 min depois.
CREATE OR REPLACE FUNCTION pg_temp.rodar_locais(p_agora timestamptz, resp_manaus text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM public.openaq_pedidos;
    DELETE FROM net._http_response;
    UPDATE public.openaq_estado SET locais_ok_em = p_agora - interval '30 hours', erro = NULL, erro_em = NULL;
    PERFORM public.openaq_pedir(p_agora);
    INSERT INTO net._http_response (id, status_code, content)
    SELECT p.request_id, 200,
           CASE WHEN p.region_id = 'a0000000-0000-0000-0000-000000000001' THEN resp_manaus
                ELSE '{"meta": {"found": 0}, "results": []}' END
      FROM public.openaq_pedidos p WHERE p.tipo = 'locais';
    PERFORM public.openaq_processar(p_agora + interval '3 minutes');
END $$;
CREATE TEMP TABLE antes AS
SELECT sensor_id, nome, provedor, distancia_m, ultimo_dado, visto_em FROM public.openaq_sensores;
SELECT pg_temp.confere((SELECT count(*) = 2 FROM antes) AND EXISTS (SELECT 1 FROM antes WHERE sensor_id = 7001 AND ultimo_dado = '2026-11-26 11:00+00'),
                       'ponto de partida: sensores 7001 (MP2,5) e 7004 (umidade) de Manaus, com última leitura às 11:00 UTC');

-- 3a. O sensor de Manaus SOME da resposta (a OpenAQ lista só outra estação): é MANTIDO.
SELECT pg_temp.rodar_locais('2026-11-27 14:16+00', $j${
  "meta": {"found": 1}, "results": [
    {"id": 900050, "name": "Manaus - outra estação", "isMobile": false,
     "provider": {"id": 5, "name": "OutroProvedor"}, "licenses": [{"id": 1, "name": "CC BY 4.0"}],
     "coordinates": {"latitude": -3.12, "longitude": -60.03}, "distance": 6000,
     "datetimeLast": {"utc": "2026-11-27T13:00:00Z"},
     "sensors": [{"id": 7099, "parameter": {"id": 2, "name": "pm25"}}]}
  ]}$j$);
SELECT pg_temp.confere((SELECT erro IS NULL FROM public.openaq_estado), '3a: sem erro');
SELECT pg_temp.confere((SELECT count(*) = 2 FROM public.openaq_sensores s JOIN antes a USING (sensor_id)
                         WHERE s.region_id = 'a0000000-0000-0000-0000-000000000001' AND s.sensor_id IN (7001, 7004)),
                       '3a: sensor de Manaus ausente da resposta continua guardado (7001 e 7004)');
SELECT pg_temp.confere((SELECT bool_and(s.nome IS NOT DISTINCT FROM a.nome AND s.provedor IS NOT DISTINCT FROM a.provedor
                                        AND s.distancia_m IS NOT DISTINCT FROM a.distancia_m AND s.visto_em = a.visto_em
                                        AND s.ultimo_dado IS NOT DISTINCT FROM a.ultimo_dado)
                          FROM public.openaq_sensores s JOIN antes a USING (sensor_id) WHERE s.sensor_id IN (7001, 7004)),
                       '3a: a linha mantida não muda (nem visto_em: continua marcando a última vez que a OpenAQ o listou)');
SELECT pg_temp.confere((SELECT count(*) = 1 FROM public.openaq_sensores WHERE sensor_id = 7099 AND provedor = 'OutroProvedor'
                          AND visto_em = '2026-11-27 14:19+00'), '3a: o sensor que aparece é inserido');
SELECT pg_temp.confere((SELECT locais_ok_em = '2026-11-27 14:19+00' FROM public.openaq_estado), '3a: busca marcada como concluída');
-- o que ar_contexto() lê para dizer "tem sensor" (MP2,5 fixo da região) continua lá
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.openaq_sensores WHERE region_id = 'a0000000-0000-0000-0000-000000000001' AND parametro = 2 AND sensor_id = 7001),
                       '3a: Manaus continua com sensor de MP2,5 cadastrado (o cartão não passa a achar que não há sensor)');

-- 3b. Resposta VAZIA: nada é apagado.
SELECT pg_temp.rodar_locais('2026-11-28 14:16+00', '{"meta": {"found": 0}, "results": []}');
SELECT pg_temp.confere((SELECT erro IS NULL FROM public.openaq_estado), '3b: sem erro');
SELECT pg_temp.confere((SELECT count(*) = 3 FROM public.openaq_sensores WHERE region_id = 'a0000000-0000-0000-0000-000000000001'),
                       '3b: resposta vazia: os 3 sensores de Manaus continuam');
SELECT pg_temp.confere((SELECT locais_ok_em = '2026-11-28 14:19+00' FROM public.openaq_estado), '3b: busca marcada como concluída mesmo vazia');

-- 3c. Sensor que APARECE de novo é atualizado; ultimo_dado nunca anda para trás.
SELECT pg_temp.rodar_locais('2026-11-29 14:16+00', $j${
  "meta": {"found": 1}, "results": [
    {"id": 900001, "name": "Manaus - estação teste (renomeada)", "isMobile": false,
     "provider": {"id": 1, "name": "AirGradient"}, "licenses": [{"id": 1, "name": "CC BY 4.0"}],
     "coordinates": {"latitude": -3.10, "longitude": -60.02}, "distance": 3500,
     "datetimeLast": {"utc": "2026-11-26T09:00:00Z"},
     "sensors": [{"id": 7001, "parameter": {"id": 2, "name": "pm25"}}]}
  ]}$j$);
SELECT pg_temp.confere((SELECT nome = 'Manaus - estação teste (renomeada)' AND distancia_m = 3500 AND visto_em = '2026-11-29 14:19+00'
                          FROM public.openaq_sensores WHERE sensor_id = 7001),
                       '3c: sensor que aparece é atualizado (nome, distância, visto_em)');
SELECT pg_temp.confere((SELECT ultimo_dado = '2026-11-26 11:00+00' FROM public.openaq_sensores WHERE sensor_id = 7001),
                       '3c: ultimo_dado não anda para trás (resposta dizia 09:00, já havia 11:00)');
SELECT pg_temp.confere((SELECT count(*) = 3 FROM public.openaq_sensores WHERE region_id = 'a0000000-0000-0000-0000-000000000001')
                       AND EXISTS (SELECT 1 FROM public.openaq_sensores WHERE sensor_id = 7004 AND visto_em = (SELECT visto_em FROM antes WHERE sensor_id = 7004)),
                       '3c: os que não aparecem (7004, 7099) seguem guardados e intactos');
ROLLBACK;
