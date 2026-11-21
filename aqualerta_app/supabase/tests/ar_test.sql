-- Teste da qualidade do ar (20261122_ar.sql). PostGIS LOCAL apenas.
-- Ordem: stub_base.sql, ar_stubs.sql, ../migrations/20261118_push_fcm.sql,
-- ../migrations/20261122_ar.sql e, na MESMA sessão do psql,
-- fixtures/ar_respostas.sql seguido deste arquivo.
-- As respostas do Open-Meteo e do INPE são reais (21/11/2026); os cenários
-- de fumaça e de aviso usam valores inventados, marcados como tal.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

-- 1. IQAr: exemplo do próprio MMA e fronteiras das faixas.
SELECT pg_temp.confere(public.ar_iqar('pm10', 210) = 168, 'MMA: MP10 210 -> 168');
SELECT pg_temp.confere(public.ar_iqar('o3', 135) = 86, 'MMA: O3 135 -> 86');
SELECT pg_temp.confere(public.ar_iqar('no2', 220) = 60, 'MMA: NO2 220 -> 60');
SELECT pg_temp.confere(public.ar_iqar('pm2_5', 15) = 40 AND public.ar_iqar('pm2_5', 16) = 41
                   AND public.ar_iqar('pm2_5', 50) = 80 AND public.ar_iqar('pm2_5', 51) = 81
                   AND public.ar_iqar('pm2_5', 75) = 120 AND public.ar_iqar('pm2_5', 76) = 121
                   AND public.ar_iqar('pm2_5', 125) = 200 AND public.ar_iqar('pm2_5', 126) = 201
                   AND public.ar_iqar('pm2_5', 300) = 400, 'MP2,5 nas fronteiras 15/16, 50/51, 75/76, 125/126, 300');
SELECT pg_temp.confere(public.ar_iqar('pm2_5', 999) = 400 AND public.ar_iqar('pm2_5', NULL) IS NULL,
                       'acima da escala = 400; sem dado = NULL');
SELECT pg_temp.confere(public.ar_iqar('pm2_5', 15.5) = 41 AND public.ar_iqar('pm2_5', 16.5) = 41
                   AND public.ar_iqar('pm2_5', 15.4) = 40, 'arredonda X,5 para o par (15,5->16; 16,5->16)');
SELECT pg_temp.confere(public.ar_iqar('co', 9.0) = 40 AND public.ar_iqar('co', 9.1) = 41
                   AND public.ar_iqar('co', 9.04) = 40, 'CO em ppm com uma casa');
SELECT pg_temp.confere(public.ar_nivel(40) = 'N1' AND public.ar_nivel(41) = 'N2' AND public.ar_nivel(121) = 'N4'
                   AND public.ar_nivel(201) = 'N5', 'níveis N1..N5');

-- 2. Pedidos: 1 ao Open-Meteo (todas as regiões) + arquivos de focos.
DELETE FROM net.chamadas;
SELECT pg_temp.confere(public.ar_pedir('2026-11-21 21:11+00') = 9, '1 pedido do modelo + 8 arquivos de focos');
SELECT pg_temp.confere((SELECT count(*) FROM net.chamadas WHERE url LIKE 'https://air-quality-api.open-meteo.com/%'
                          AND params->>'latitude' = '-3.1383,-2.6306' AND params->>'timeformat' = 'unixtime') = 1,
                       'coordenadas das regiões na ordem do id, horário em unixtime');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM net.chamadas WHERE url LIKE '%focos_10min_20261121_2050.csv')
                   AND EXISTS (SELECT 1 FROM net.chamadas WHERE url LIKE '%focos_10min_20261121_1940.csv')
                   AND NOT EXISTS (SELECT 1 FROM net.chamadas WHERE url LIKE '%focos_10min_20261121_2100.csv'),
                       'focos de 20 a 90 min atrás');
SELECT pg_temp.confere(public.ar_pedir('2026-11-21 21:12+00') = 0, 'pedidos pendentes não se repetem');

-- 3. Respostas reais: modelo, um arquivo de focos, um 404 recente e o resto vazio.
INSERT INTO net._http_response (id, status_code, content)
SELECT request_id, 200, (SELECT conteudo FROM ar_fixture WHERE nome = 'open_meteo')
FROM public.ar_pedidos WHERE tipo = 'modelo';
INSERT INTO net._http_response (id, status_code, content)
SELECT request_id, 200, (SELECT conteudo FROM ar_fixture WHERE nome = 'focos')
FROM public.ar_pedidos WHERE arquivo = '20261121_2050';
INSERT INTO net._http_response (id, status_code, content)
SELECT request_id, 404, 'not found' FROM public.ar_pedidos WHERE arquivo = '20261121_2040';
INSERT INTO net._http_response (id, status_code, content)
SELECT request_id, 200, E'lat,lon,satelite,data\n'
FROM public.ar_pedidos WHERE tipo = 'focos' AND arquivo NOT IN ('20261121_2050', '20261121_2040');

SELECT public.ar_processar('2026-11-21 21:14+00');
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_horas) = 192, '96 horas x 2 regiões gravadas');
SELECT pg_temp.confere((SELECT pm2_5 FROM public.ar_horas WHERE region_id = 'a0000000-0000-0000-0000-000000000001'
                          AND hora = '2026-11-21 21:00+00') = 26.7, 'Manaus 21/11 21h UTC: 26,7 µg/m³ (real)');
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_focos) = 183, '183 focos do arquivo real');
SELECT pg_temp.confere((SELECT focos FROM public.ar_focos_arquivos WHERE nome = '20261121_2050') = 183
                   AND NOT EXISTS (SELECT 1 FROM public.ar_focos_arquivos WHERE nome = '20261121_2040'),
                       'arquivo lido marcado; 404 recente fica para a próxima');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_pedidos) AND NOT EXISTS (SELECT 1 FROM net._http_response),
                       'fila e respostas limpas');
SELECT pg_temp.confere((SELECT modelo_ok_em = '2026-11-21 21:14+00' AND focos_ok_em IS NOT NULL AND erro IS NULL
                          FROM public.ar_estado), 'estado da coleta ok');

-- 4. Índice com os dados reais (conta feita fora do banco: Manaus 54, Parintins 57, ambos por MP2,5).
SELECT pg_temp.confere((SELECT iqar = 54 AND nivel = 'N2' AND poluente = 'pm2_5' AND pm2_5_24 = 27.3
                          FROM public.ar_resumo('2026-11-21 21:00+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000001'), 'Manaus: IQAr 54, moderada, MP2,5');
SELECT pg_temp.confere((SELECT iqar FROM public.ar_resumo('2026-11-21 21:00+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000002') = 57, 'Parintins: IQAr 57');
SELECT pg_temp.confere((SELECT iqar_previsto_48h IS NOT NULL AND hora_pior_prevista > '2026-11-21 21:00+00'
                               AND tendencia IN ('sobe', 'desce', 'estavel')
                          FROM public.ar_resumo('2026-11-21 21:00+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000001'), 'previsão de 48 h e tendência');
SELECT pg_temp.confere((SELECT count(*) FROM public.ar_resumo('2026-11-21 21:00+00') WHERE iqar IS NULL) = 0
                   AND (SELECT iqar FROM public.ar_resumo('2026-11-25 21:00+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000001') IS NULL,
                       'sem dado recente (> 6 h): índice vazio, não inventa');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.alerts WHERE metadata->>'origem' = 'ar-cams'),
                       'ar moderado não gera aviso');

-- 5. Fumaça provável (cenário inventado): 12 focos VIIRS perto de Manaus.
INSERT INTO public.ar_focos (lat, lon, satelite, detectado_em)
SELECT -3.2 - k * 0.02, -60.1, 'NOAA-20', '2026-11-21 18:00+00' FROM generate_series(1, 12) k;
INSERT INTO public.ar_focos (lat, lon, satelite, detectado_em)   -- o mesmo fogo no GOES não conta
SELECT -3.2 - k * 0.02, -60.1, 'GOES-19', '2026-11-21 18:10+00' FROM generate_series(1, 12) k;
SELECT pg_temp.confere((SELECT focos_24h = 12 AND fumaca_provavel FROM public.ar_resumo('2026-11-21 21:00+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000001'),
                       '12 focos em 100 km + MP2,5 de 27: fumaça provável');
SELECT pg_temp.confere((SELECT NOT fumaca_provavel FROM public.ar_resumo('2026-11-21 21:00+00')
                         WHERE region_id = 'a0000000-0000-0000-0000-000000000002'),
                       'Parintins sem focos por perto: sem fumaça');

-- 6. Aviso (cenário inventado): Parintins com MP2,5 = 100 µg/m³ (IQAr 160, N4).
CREATE OR REPLACE FUNCTION pg_temp.pm(v numeric) RETURNS void LANGUAGE sql AS $$
    UPDATE public.ar_horas SET pm2_5 = v WHERE region_id = 'a0000000-0000-0000-0000-000000000002' $$;
INSERT INTO public.user_profiles (id, fcm_token, notification_preferences) VALUES
  ('b0000000-0000-0000-0000-000000000001', 'tok-quer-ar', '{}'),
  ('b0000000-0000-0000-0000-000000000002', 'tok-sem-ar', '{"ar": false}');
INSERT INTO public.user_monitored_regions (user_id, region_id) VALUES
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002'),
  ('b0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002');
DELETE FROM public.push_fila;
SELECT pg_temp.pm(100);
SELECT pg_temp.confere(public.ar_atualizar_avisos('2026-11-21 21:00+00') = 0, '1ª coleta acima de 120: ainda não avisa');
SELECT pg_temp.confere(public.ar_atualizar_avisos('2026-11-21 22:00+00') = 1, '2ª coleta seguida: avisa');
SELECT pg_temp.confere((SELECT severity = 'HIGH' AND title = 'Qualidade do ar muito ruim em Parintins'
                               AND body LIKE 'O modelo CAMS (Copernicus) estima IQAr 160%partículas finas (MP2,5)%'
                               AND body LIKE '%Estimativa de modelo, não medição local%'
                               AND (metadata->>'iqar')::int = 160
                          FROM public.alerts WHERE metadata->>'origem' = 'ar-cams' AND status = 'ACTIVE'),
                       'alerta HIGH, origem ar-cams, texto com índice e ressalva');
SELECT pg_temp.confere((SELECT count(*) FROM public.push_fila) = 1, 'entrou na fila de push');
SELECT pg_temp.confere((SELECT count(*) = 1 AND bool_and(token = 'tok-quer-ar' AND titulo = 'Ar muito ruim: proteja-se')
                          FROM public.push_reivindicar(20) WHERE token IS NOT NULL),
                       'push só para quem não desligou o ar, com título próprio');
SELECT pg_temp.pm(150);   -- IQAr 228, N5
SELECT pg_temp.confere(public.ar_atualizar_avisos('2026-11-21 23:00+00') = 1, 'subida conta como mudança');
SELECT pg_temp.confere((SELECT severity FROM public.alerts WHERE metadata->>'origem' = 'ar-cams' AND status = 'ACTIVE') = 'CRITICAL',
                       'sobe para CRITICAL (péssima)');
SELECT pg_temp.pm(20);
SELECT pg_temp.confere(public.ar_atualizar_avisos('2026-11-22 00:00+00') = 0, '1 coleta abaixo: mantém');
SELECT pg_temp.confere(public.ar_atualizar_avisos('2026-11-22 01:00+00') = 1, '2ª coleta abaixo conta como mudança');
SELECT pg_temp.confere((SELECT status FROM public.alerts WHERE metadata->>'origem' = 'ar-cams') = 'RESOLVED',
                       '2 coletas abaixo: encerra');

-- 7. Aviso de cheia continua indo para todos (o filtro do ar não afeta).
DELETE FROM public.push_fila;
INSERT INTO public.alerts (region_id, title, body, severity, metadata)
VALUES ('a0000000-0000-0000-0000-000000000002', 'Rio Amazonas acima da cota', 'x', 'HIGH', '{"origem":"telemetria-ana"}');
SELECT pg_temp.confere((SELECT count(*) FROM public.push_reivindicar(20) WHERE token IS NOT NULL) = 2,
                       'cheia: push para os dois');

-- 8. Acesso: leitura pública do que o app mostra; o resto fechado.
SELECT pg_temp.confere(has_table_privilege('anon', 'public.ar_horas', 'SELECT')
                   AND has_table_privilege('anon', 'public.ar_estado', 'SELECT')
                   AND NOT has_table_privilege('anon', 'public.ar_pedidos', 'SELECT')
                   AND NOT has_table_privilege('authenticated', 'public.ar_regiao', 'SELECT')
                   AND NOT has_table_privilege('anon', 'public.ar_horas', 'INSERT')
                   AND has_function_privilege('anon', 'public.ar_resumo(timestamptz)', 'EXECUTE')
                   AND NOT has_function_privilege('anon', 'public.ar_pedir(timestamptz)', 'EXECUTE')
                   AND NOT has_function_privilege('authenticated', 'public.ar_atualizar_avisos(timestamptz)', 'EXECUTE'),
                       'permissões');
SELECT pg_temp.confere((SELECT count(*) FROM cron.job WHERE jobname IN ('ar-pedir', 'ar-processar', 'ar-podar')) = 3,
                       'crons agendados');

-- 9. Poda.
SELECT public.ar_podar('2026-12-30 00:00+00');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_horas) AND NOT EXISTS (SELECT 1 FROM public.ar_focos),
                       'poda apaga horas > 30 dias e focos > 7 dias');

ROLLBACK;
