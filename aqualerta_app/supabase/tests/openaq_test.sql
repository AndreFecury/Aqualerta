-- Teste da medição local pela OpenAQ (20261124_openaq.sql). PostGIS LOCAL:
--   psql -f stub_base.sql -f ar_stubs.sql -f ../migrations/20261118_push_fcm.sql
--        -f ../migrations/20261122_ar.sql -f ../migrations/20261124_openaq.sql
--        -f openaq_test.sql
-- As respostas abaixo foram MONTADAS no formato da documentação da API v3
-- (docs.openaq.org, lido em 21/11/2026); ainda não há chave para capturar
-- respostas reais. Conferir com uma resposta real quando a chave existir.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
DELETE FROM net.chamadas;
DELETE FROM vault.decrypted_secrets WHERE name = 'openaq_key';

-- 1. Sem chave: nada é pedido.
SELECT pg_temp.confere(public.openaq_pedir('2026-11-22 12:16+00') = 0, 'sem chave: nenhum pedido');
SELECT pg_temp.confere((SELECT NOT tem_chave FROM public.openaq_estado), 'estado diz que não há chave');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM net.chamadas), 'nenhuma chamada de rede');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_local('2026-11-22 12:30+00')), 'ar_local vazio');

-- 2. Com chave: 1 busca de estações por região (Manaus e Parintins no stub).
INSERT INTO vault.decrypted_secrets VALUES ('openaq_key', ' chave-de-teste ');
SELECT pg_temp.confere(public.openaq_pedir('2026-11-22 12:16+00') = 2, '2 buscas de estações');
SELECT pg_temp.confere((SELECT count(*) FROM net.chamadas WHERE url = 'https://api.openaq.org/v3/locations'
                          AND headers->>'X-API-Key' = 'chave-de-teste'
                          AND params->>'radius' = '25000' AND params->>'parameters_id' = '2') = 2,
                       'chave no cabeçalho X-API-Key (sem espaços), raio 25 km, só MP2,5');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM net.chamadas WHERE params->>'coordinates' = '-3.1383,-60.0272'),
                       'coordenadas lat,lon da região');
SELECT pg_temp.confere(public.openaq_pedir('2026-11-22 12:17+00') = 0, 'não repete busca pendente');

-- Respostas: Manaus tem 2 estações (uma com MP2,5 e O3, outra móvel); Parintins nenhuma.
INSERT INTO net._http_response (id, status_code, content)
SELECT p.request_id, 200,
       CASE WHEN p.region_id = 'a0000000-0000-0000-0000-000000000001' THEN $j${
         "meta": {"name": "openaq-api", "page": 1, "limit": 50, "found": 2},
         "results": [
           {"id": 900001, "name": "Manaus - Escola X", "isMobile": false, "isMonitor": false,
            "provider": {"id": 166, "name": "PurpleAir"},
            "licenses": [{"id": 1, "name": "CC BY 4.0", "attribution": {"name": "PurpleAir", "url": null}}],
            "coordinates": {"latitude": -3.10, "longitude": -60.02}, "distance": 4321.5,
            "datetimeLast": {"utc": "2026-11-22T11:00:00Z", "local": "2026-11-22T07:00:00-04:00"},
            "sensors": [{"id": 7001, "name": "pm25 µg/m³", "parameter": {"id": 2, "name": "pm25", "units": "µg/m³", "displayName": "PM2.5"}},
                        {"id": 7002, "name": "o3 ppm", "parameter": {"id": 10, "name": "o3", "units": "ppm", "displayName": "O₃"}}]},
           {"id": 900002, "name": "Ônibus", "isMobile": true,
            "provider": {"id": 1, "name": "Móvel"}, "coordinates": {"latitude": -3.1, "longitude": -60.0}, "distance": 100,
            "datetimeLast": {"utc": "2026-11-22T11:00:00Z"},
            "sensors": [{"id": 7003, "parameter": {"id": 2, "name": "pm25"}}]}
         ]}$j$
       ELSE '{"meta": {"found": 0}, "results": []}' END
  FROM public.openaq_pedidos p WHERE p.tipo = 'locais';
SELECT pg_temp.confere(public.openaq_processar('2026-11-22 12:19+00') = 2, '2 respostas lidas');
SELECT pg_temp.confere((SELECT count(*) FROM public.openaq_sensores) = 1
                   AND (SELECT sensor_id = 7001 AND provedor = 'PurpleAir' AND licenca = 'CC BY 4.0' AND distancia_m = 4321.5
                          FROM public.openaq_sensores), 'só o sensor de MP2,5 fixo (O3 e estação móvel fora)');
SELECT pg_temp.confere((SELECT locais_ok_em = '2026-11-22 12:19+00' FROM public.openaq_estado), 'data da busca gravada');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.openaq_pedidos) AND NOT EXISTS (SELECT 1 FROM net._http_response),
                       'pedidos e respostas limpos');

-- 3. Próxima hora: pede as médias horárias do sensor; não busca estações de novo.
DELETE FROM net.chamadas;
SELECT pg_temp.confere(public.openaq_pedir('2026-11-22 13:16+00') = 1, '1 pedido de horas');
SELECT pg_temp.confere((SELECT url = 'https://api.openaq.org/v3/sensors/7001/hours'
                           AND params->>'datetime_from' = '2026-11-21T11:00:00Z' FROM net.chamadas),
                       'horas das últimas 26 h');
-- 22 horas com 20 µg/m³ e 1 com 50 (média 21,3), mais 1 leitura impossível.
INSERT INTO net._http_response (id, status_code, content)
SELECT p.request_id, 200, jsonb_build_object('results',
         (SELECT jsonb_agg(jsonb_build_object(
                    'value', CASE WHEN h = 0 THEN 50 ELSE 20 END,
                    'parameter', jsonb_build_object('id', 2, 'name', 'pm25'),
                    'period', jsonb_build_object('label', '1hour', 'interval', '01:00:00',
                        'datetimeFrom', jsonb_build_object('utc', to_char(('2026-11-22 12:00+00'::timestamptz - h * interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
                        'datetimeTo', jsonb_build_object('utc', to_char(('2026-11-22 13:00+00'::timestamptz - h * interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))))
            FROM generate_series(0, 22) h)
         || jsonb_build_array(jsonb_build_object('value', -999, 'period',
                jsonb_build_object('datetimeFrom', jsonb_build_object('utc', '2026-11-21T12:00:00Z'))))
       )::text
  FROM public.openaq_pedidos p;
SELECT pg_temp.confere(public.openaq_processar('2026-11-22 13:19+00') = 1, 'resposta de horas lida');
SELECT pg_temp.confere((SELECT count(*) FROM public.openaq_horas) = 23, '23 horas gravadas, -999 descartado');

-- 4. Média de 24 h: 23 horas (>= 18) -> vale.
SELECT pg_temp.confere((SELECT pm25_24h = 21.3 AND iqar = public.ar_iqar('pm2_5', 21.3) AND sensores = 1
                           AND distancia_km = 4 AND fontes = 'OpenAQ · PurpleAir'
                           AND atualizado_em = '2026-11-22 13:00+00'
                          FROM public.ar_local('2026-11-22 13:30+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000001'), 'média de 24 h, IQAr do MMA e fonte');
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_local('2026-11-22 13:30+00')) = 1, 'Parintins sem sensor: fora');
-- Sete horas depois, só 17 das 24 horas na janela: não mostra média incompleta.
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_local('2026-11-22 20:30+00')), 'menos de 18 h: sem média');

-- 5. Chave recusada: erro claro no estado.
DELETE FROM net.chamadas;
SELECT public.openaq_pedir('2026-11-22 14:16+00');
INSERT INTO net._http_response (id, status_code, content)
SELECT request_id, 401, '{"detail":"Invalid credentials"}' FROM public.openaq_pedidos;
SELECT public.openaq_processar('2026-11-22 14:19+00');
SELECT pg_temp.confere((SELECT erro LIKE 'chave recusada pela OpenAQ (HTTP 401)%' FROM public.openaq_estado), 'erro de chave registrado');

-- 6. Permissões e agenda.
SELECT pg_temp.confere(has_function_privilege('anon', 'public.ar_local(timestamptz)', 'EXECUTE')
                   AND NOT has_function_privilege('authenticated', 'public.openaq_pedir(timestamptz)', 'EXECUTE')
                   AND NOT has_function_privilege('authenticated', 'public.openaq_chave()', 'EXECUTE')
                   AND NOT has_table_privilege('authenticated', 'public.openaq_sensores', 'SELECT'),
                       'app só lê ar_local e o estado; chave nunca sai do banco');
SELECT pg_temp.confere((SELECT count(*) FROM cron.job WHERE jobname IN ('openaq-pedir', 'openaq-processar')) = 2, 'agenda criada');
ROLLBACK;
