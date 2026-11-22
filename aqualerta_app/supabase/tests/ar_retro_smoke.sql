\set ON_ERROR_STOP 1
INSERT INTO vault.decrypted_secrets VALUES ('openaq_key', 'k') ON CONFLICT (name) DO UPDATE SET decrypted_secret = 'k';
INSERT INTO public.openaq_sensores (region_id, sensor_id, location_id, parametro) VALUES
 ('a0000000-0000-0000-0000-000000000001', 7001, 900001, 2), ('a0000000-0000-0000-0000-000000000001', 7004, 900001, 98);
DELETE FROM net.chamadas;
\i ../scripts/ar_retro_2026.sql
SELECT count(*) AS pedidos_openaq FROM net.chamadas WHERE url LIKE 'https://api.openaq.org/v3/sensors/%/hours';
-- respostas: 2 horas de MP2,5 e umidade; modelo com 2 horas
INSERT INTO net._http_response (id, status_code, content)
SELECT p.request_id, 200, CASE
  WHEN p.tipo = 'sensor' AND p.pagina = 1 THEN jsonb_build_object('meta', jsonb_build_object('found', 2), 'results', jsonb_build_array(
      jsonb_build_object('value', CASE WHEN p.sensor_id = 7004 THEN 75 ELSE 20 END, 'period', jsonb_build_object('datetimeFrom', jsonb_build_object('utc', '2026-08-10T04:00:00Z'))),
      jsonb_build_object('value', CASE WHEN p.sensor_id = 7004 THEN 76 ELSE 22 END, 'period', jsonb_build_object('datetimeFrom', jsonb_build_object('utc', '2026-08-10T05:00:00Z')))))::text
  WHEN p.tipo = 'sensor' THEN '{"results": []}'
  WHEN p.tipo = 'modelo' THEN '{"hourly": {"time": [1786334400, 1786338000], "pm2_5": [30, 31]}}'
  ELSE '{"hourly": {"time": [1786334400, 1786338000], "relative_humidity_2m": [80, 81]}}' END
FROM public.ar_retro_pedidos p;
SELECT public.ar_retro_processar();
SELECT public.ar_retro_montar() AS pares;
SELECT hora, modelo_pm25, sensor_pm25, sensor_pm25_epa, ur_sensor, ur_modelo, marcas, valido FROM public.ar_validacao_horas WHERE origem = 'retro' ORDER BY hora;
SELECT etapa, detalhe FROM public.ar_retro_log ORDER BY em;
