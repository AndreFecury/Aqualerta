-- Teste do indicador "agora" (20261128a_ar_agora.sql). PostGIS LOCAL, banco novo:
--   stub_base, ar_stubs, ar_validacao_stubs, push_teste_stubs, sinal_dados_stubs,
--   20261118_push_fcm, 20261121b_sinal_dados, 20261122_ar, 20261123b_push_teste,
--   20261124_openaq, 20261125a_ar_pausa, 20261125b, 20261125c, 20261126a,
--   20261126b, 20261127b, 20261128a, 20261128d, este arquivo
-- (20261128d recria ar_agora() com as colunas de "sensor sem dados": sensor parado
-- agora é uma linha com valores NULL e sensor_parado = true, não a ausência de linha)
-- Valores inventados para exercitar as regras. Manaus = a0000000-...-001.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
-- Série do sensor, hora a hora, a partir de 22/11 00:00 UTC (hora i = início da hora).
CREATE OR REPLACE FUNCTION pg_temp.serie(valores numeric[]) RETURNS void LANGUAGE sql AS $$
    DELETE FROM public.ar_validacao_horas WHERE origem = 'continua';
    INSERT INTO public.ar_validacao_horas (region_id, hora, origem, modelo_pm25, sensor_pm25, sensores_n, valido)
    SELECT 'a0000000-0000-0000-0000-000000000001', '2026-11-22 00:00+00'::timestamptz + (i - 1) * interval '1 hour',
           'continua', NULL, valores[i], 1, false
      FROM generate_subscripts(valores, 1) i;
$$;
CREATE OR REPLACE FUNCTION pg_temp.agora(horas integer) RETURNS timestamptz LANGUAGE sql AS
$$ SELECT '2026-11-22 00:30+00'::timestamptz + horas * interval '1 hour' $$;
-- 21 horas limpas (10 µg/m³) seguidas de "fim".
CREATE OR REPLACE FUNCTION pg_temp.limpo21(fim numeric[]) RETURNS numeric[] LANGUAGE sql AS
$$ SELECT array_fill(10::numeric, ARRAY[21]) || fim $$;

-- 0. Padrões: gatilho desligado, avisos por sensor desligados.
SELECT pg_temp.confere(public.ar_cfg('agora_gatilho_ligado') = 0 AND public.ar_cfg('agora_niveis_aviso') = 2,
                       'gatilho de 3 h nasce DESLIGADO; aviso "piorou" = 2 níveis');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_aviso_sensor WHERE ligado), 'avisos por sensor seguem desligados');

-- 1. 21 h limpas, depois 250, 120 e 10 µg/m³: média de 3 h = 126,7 (faixa
--    "Péssima"), média de 24 h = 24,6 (faixa "Moderada").
SELECT pg_temp.serie(pg_temp.limpo21(ARRAY[250,120,10]));
CREATE TEMP TABLE a AS SELECT * FROM public.ar_agora(pg_temp.agora(24));
SELECT pg_temp.confere((SELECT count(*) = 1 AND bool_and(pm25_3h = 126.7 AND nivel_3h = 'N5' AND iqar_3h > 200
                                              AND pm25_24h_sensor = 24.6 AND nivel_24h_sensor = 'N2'
                                              AND piorou AND ate = '2026-11-23 00:00+00')
                          FROM a),
                       'média de 3 h (126,7 = N5) ao lado da de 24 h (24,6 = N2): o ar piorou 3 níveis');

-- 2. Diferença de 1 nível só não é "piorou".
SELECT pg_temp.serie(pg_temp.limpo21(ARRAY[40,40,40]));
SELECT pg_temp.confere((SELECT nivel_24h_sensor = 'N1' AND nivel_3h = 'N2' AND NOT piorou
                          FROM public.ar_agora(pg_temp.agora(24))), '1 nível acima: não avisa');

-- 3. Sensor parado: sem linha (nunca um "agora" velho).
SELECT pg_temp.serie(pg_temp.limpo21(ARRAY[250,120,10]));
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.ar_agora(pg_temp.agora(26)) WHERE pm25_3h IS NOT NULL AND NOT sensor_parado),
                       '2 h depois do último dado: ainda vale');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.ar_agora(pg_temp.agora(30)) WHERE pm25_3h IS NULL AND nivel_3h IS NULL AND sensor_parado),
                       'sensor parado há 6 h: sem número de "agora" (nada velho), marcado como parado');

-- 4. Hora faltando: só vale com 3 horas SEGUIDAS; usa o último trio completo
--    (horas 19, 20 e 21 = 10, 10, 250 -> média 90; termina às 22:00).
DELETE FROM public.ar_validacao_horas WHERE hora = '2026-11-22 22:00+00';
SELECT pg_temp.confere((SELECT pm25_3h = 90 AND ate = '2026-11-22 22:00+00' FROM public.ar_agora(pg_temp.agora(24))),
                       'furo na série: usa o último trio de horas seguidas (e diz até quando)');
SELECT pg_temp.serie(ARRAY[10,10]::numeric[]);
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_agora(pg_temp.agora(2)) WHERE pm25_3h IS NOT NULL),
                       'menos de 3 horas válidas: sem "agora" (o sensor não está parado, só faltam horas)');
-- hora descartada pela saúde do sensor (sensores_n = 0) não conta
SELECT pg_temp.serie(ARRAY[10,10,10,10]::numeric[]);
UPDATE public.ar_validacao_horas SET sensores_n = 0 WHERE hora = '2026-11-22 02:00+00';
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_agora(pg_temp.agora(4)) WHERE ate = '2026-11-22 04:00+00'),
                       'hora travada/descartada (sensores_n = 0) não entra na média de 3 h');

-- 5. Menos de 18 h de dados em 24 h: mostra a média de 3 h, mas não afirma "piorou".
SELECT pg_temp.serie(ARRAY[10,10,10,10,10,10,10,250,120,10]::numeric[]);
SELECT pg_temp.confere((SELECT pm25_3h = 126.7 AND nivel_24h_sensor IS NULL AND NOT piorou FROM public.ar_agora(pg_temp.agora(10))),
                       'cobertura de 24 h insuficiente: sem comparação, sem "piorou"');

-- 6. Gatilho. Série em que a média de 3 h passa o NowCast: 100, 100, 100 depois de 21 h limpas.
SELECT pg_temp.serie(pg_temp.limpo21(ARRAY[100,100,100]));
CREATE TEMP TABLE desl AS SELECT * FROM public.ar_gatilho_serie('continua', '2026-11-22 00:00+00', pg_temp.agora(24));
SELECT pg_temp.confere((SELECT bool_and(d.valor = n.nowcast AND d.via = 'nowcast')
                          FROM desl d JOIN public.ar_nowcast('continua', '2026-11-22 00:00+00', pg_temp.agora(24)) n
                            ON n.region_id = d.region_id AND n.hora = d.hora),
                       'gatilho desligado: série idêntica ao NowCast de antes');
UPDATE public.ar_config SET valor = 1 WHERE chave = 'agora_gatilho_ligado';
SELECT pg_temp.confere((SELECT o.valor = 100 AND o.via = '3h' AND o.valor > d.valor
                          FROM public.ar_gatilho_serie('continua', '2026-11-22 00:00+00', pg_temp.agora(24)) o
                          JOIN desl d ON d.region_id = o.region_id AND d.hora = o.hora
                         WHERE o.hora = '2026-11-22 23:00+00'),
                       'gatilho ligado e o ar piorou: usa a média de 3 h (100) no lugar do NowCast mais baixo');
SELECT pg_temp.confere((SELECT bool_and(o.valor >= d.valor)
                          FROM public.ar_gatilho_serie('continua', '2026-11-22 00:00+00', pg_temp.agora(24)) o
                          JOIN desl d ON d.region_id = o.region_id AND d.hora = o.hora),
                       'ligar o gatilho nunca baixa o valor (só soma)');

-- 7. Uma única hora de pico seguida de ar limpo NÃO abre aviso (a média de 3 h a
--    carregaria por 3 h; a última hora tem de estar acima do limite).
UPDATE public.ar_aviso_sensor SET ligado = true WHERE region_id = 'a0000000-0000-0000-0000-000000000001';
SELECT pg_temp.serie(pg_temp.limpo21(ARRAY[10,250,10,10,10]));
SELECT public.ar_avisos_atualizar(pg_temp.agora(26));
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.ar_avisos), 'pico de 1 hora + ar limpo: sem aviso, mesmo com o gatilho ligado');
-- e a regra de 2 horas seguidas continua valendo com o gatilho ligado
SELECT pg_temp.serie(pg_temp.limpo21(ARRAY[100,100,100,100]));
SELECT public.ar_avisos_atualizar(pg_temp.agora(25));
SELECT pg_temp.confere((SELECT count(*) = 1 AND bool_and(situacao = 'ativo') FROM public.ar_avisos), 'ar ruim por 2+ horas seguidas abre aviso (gatilho ligado)');
-- sensor parado fecha, como antes (nada novo aqui)
SELECT public.ar_avisos_atualizar(pg_temp.agora(40));
SELECT pg_temp.confere((SELECT motivo_fim = 'o sensor parou de mandar leituras' FROM public.ar_avisos), 'sensor parado continua fechando o aviso');

-- 8. Permissões: a RPC é pública; as internas, não.
SELECT pg_temp.confere(has_function_privilege('anon', 'public.ar_agora(timestamptz)', 'EXECUTE')
                   AND has_function_privilege('authenticated', 'public.ar_agora(timestamptz)', 'EXECUTE')
                   AND NOT has_function_privilege('anon', 'public.ar_agora_serie(text, timestamptz, timestamptz)', 'EXECUTE')
                   AND NOT has_function_privilege('authenticated', 'public.ar_gatilho_serie(text, timestamptz, timestamptz)', 'EXECUTE'),
                       'ar_agora é pública; série e gatilho são do servidor');
ROLLBACK;
