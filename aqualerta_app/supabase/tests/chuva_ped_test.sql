-- Teste da coleta pela PED (20261119c_chuva_ped.sql). PostGIS LOCAL apenas,
-- depois de stub_base.sql e das três migrações de chuva. As respostas da PED
-- seguem o formato visto na consulta real de 19/11/2026 (datahora,
-- codestacao, id_sensor, valor, qualificacao); os valores de chuva são
-- inventados para simular um temporal.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
-- Responde todos os pedidos pendentes de um tipo.
CREATE OR REPLACE FUNCTION pg_temp.responde(p_tipo text, p_status int, p_corpo text) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO net._http_response (id, status_code, content)
    SELECT request_id, p_status, p_corpo FROM public.chuva_pedidos WHERE tipo = p_tipo
    ON CONFLICT (id) DO NOTHING;
$$;
-- Linha no formato da PED.
CREATE OR REPLACE FUNCTION pg_temp.linha(cod text, fim timestamptz, sensor int, valor numeric) RETURNS jsonb
LANGUAGE sql AS $$
    SELECT jsonb_build_object('cidade', 'MANAUS', 'codestacao', cod,
        'datahora', to_char(fim AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'),
        'id_sensor', sensor, 'latitude', -3.002281, 'longitude', -60.045806, 'nome', 'x',
        'offset', NULL, 'qualificacao', '0000', 'uf', 'AM', 'valor', valor);
$$;

-- Estações reais de Manaus e Parintins (lista gravada), sem pedidos na fila.
DELETE FROM public.chuva_pedidos;
DELETE FROM public.chuva_leituras_10min;
DELETE FROM vault.decrypted_secrets;
DELETE FROM public.alerts WHERE metadata->>'origem' = 'chuva-cemaden';
UPDATE public.chuva_ped_token SET token = NULL, expira_em = NULL;
UPDATE public.chuva_estado SET ped_erro = NULL, ped_ultima_ok = NULL, estacoes_atualizadas_em = NULL;
DELETE FROM public.chuva_estacoes;   -- a lista gravada (passo 3) cadastra de novo

-- 1. Sem conta no Vault: nada muda, só a lista aberta.
SELECT pg_temp.confere(public.chuva_pedir() = 1, 'sem credenciais: só a coleta aberta');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.chuva_pedidos WHERE tipo LIKE 'ped_%'), 'nenhum pedido à PED');
DELETE FROM public.chuva_pedidos;

-- 2. Com conta: pede o token (POST com e-mail e senha), ainda sem dados.
INSERT INTO vault.decrypted_secrets VALUES ('ped_email', 'teste@exemplo.org'), ('ped_senha', 'senha-de-teste');
TRUNCATE net.chamadas;
SELECT pg_temp.confere(public.chuva_pedir() = 2, 'com credenciais: lista + token');
SELECT pg_temp.confere((SELECT body->>'email' = 'teste@exemplo.org' AND body ? 'password'
                        FROM net.chamadas WHERE url = 'https://sgaa.cemaden.gov.br/SGAA/rest/controle-token/tokens'),
                       'POST do token no SGAA com email/password');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.chuva_pedidos WHERE tipo = 'ped_dados'), 'sem token, sem pedido de dados');

-- 3. Token chega: guardado com validade, resposta apagada do pg_net.
SELECT pg_temp.responde('lista', 200, pg_read_file('/s/functions/chuva-cemaden/fixtures/estacoes_recorte.js'));
SELECT pg_temp.responde('ped_token', 200, '{"timeToExp": 14400, "token": "tok-123"}');
CREATE TEMP TABLE ids_token AS SELECT request_id FROM public.chuva_pedidos WHERE tipo = 'ped_token';
SELECT public.chuva_processar();
SELECT pg_temp.confere((SELECT token = 'tok-123' AND expira_em BETWEEN now() + interval '3 hours 59 minutes'
                                                     AND now() + interval '4 hours 1 minute'
                        FROM public.chuva_ped_token), 'token guardado com validade de 4 h');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM net._http_response r JOIN ids_token t ON t.request_id = r.id),
                       'resposta com o token apagada do pg_net');
SELECT pg_temp.confere((SELECT ped_erro IS NULL FROM public.chuva_estado), 'sem erro da PED');

-- 4. Com token: um pedido por município com estação, header e parâmetros certos.
TRUNCATE net.chamadas;
DELETE FROM public.chuva_pedidos;
SELECT public.chuva_pedir();
SELECT pg_temp.confere((SELECT count(*) FROM public.chuva_pedidos WHERE tipo = 'ped_dados') = 2,
                       'um pedido de dados por município (Manaus e Parintins)');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.chuva_pedidos WHERE tipo = 'ped_token'), 'token válido não é pedido de novo');
SELECT pg_temp.confere((SELECT count(*) FROM net.chamadas
                        WHERE url = 'https://sws.cemaden.gov.br/PED/rest/pcds/pcds-dados-recentes'
                          AND headers->>'token' = 'tok-123' AND params->>'rede' = '11' AND params->>'uf' = 'AM'
                          AND params->>'codibge' IN ('1302603', '1303403')) = 2,
                       'URL, header token e parâmetros rede/uf/codibge');

-- 5. Temporal no Tarumã: 34 mm em 60 min, com o relógio da PED 15 min à
--    frente (como visto em 19/11). Sensor 240 com valor alto é ignorado.
--    Jorge Teixeira seco, de hora em hora. (A coleta aberta deste ciclo
--    fica de fora do teste.)
DELETE FROM public.chuva_pedidos WHERE tipo IN ('lista', 'horario');
SELECT pg_temp.responde('ped_dados', 200, (
    SELECT jsonb_agg(l)::text FROM (
        SELECT pg_temp.linha('130260326A', now() + interval '15 minutes' - make_interval(mins => 10 * k), 10,
                             (ARRAY[2, 9, 12, 6, 3, 2, 0.4, 0, 0])[k + 1]) AS l
        FROM generate_series(0, 8) k
        UNION ALL SELECT pg_temp.linha('130260326A', now() + interval '15 minutes', 240, 99)
        UNION ALL SELECT pg_temp.linha('130260335A', date_trunc('hour', now()) + interval '20 minutes' - make_interval(hours => k), 10, 0)
        FROM generate_series(0, 2) k
        UNION ALL SELECT pg_temp.linha('999999999X', now(), 10, 50)   -- estação de fora
    ) s));
SELECT public.chuva_processar();
SELECT pg_temp.confere((SELECT count(*) FROM public.chuva_leituras_10min WHERE estacao_id = 9707) = 9,
                       '9 leituras de 10 min do Tarumã (sensor 240 fora)');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.chuva_leituras_10min WHERE mm = 99), 'sensor 240 ignorado');
SELECT pg_temp.confere((SELECT count(*) FROM public.chuva_leituras_10min WHERE estacao_id = 9711) = 3, 'estação seca gravada');
SELECT pg_temp.confere((SELECT mm_1h FROM public.chuva_avaliar() WHERE estacao_id = 9707) = 34,
                       'soma móvel de 60 min = 34 mm (ancorada na última leitura)');
SELECT pg_temp.confere((SELECT severidade FROM public.chuva_avaliar() WHERE estacao_id = 9707) = 'MEDIUM',
                       '34 mm/h num pluviômetro só = nível médio (calibração 21/11)');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.alerts WHERE status = 'ACTIVE' AND severity = 'MEDIUM'
                                 AND metadata->>'origem' = 'chuva-cemaden'
                                 AND region_id = 'a0000000-0000-0000-0000-000000000001'
                                 AND body LIKE '%Tarumã%34 mm na última hora%'),
                       'aviso de chuva forte em Manaus, citando o Tarumã');
SELECT pg_temp.confere((SELECT ped_ultima_ok IS NOT NULL AND ped_erro IS NULL FROM public.chuva_estado), 'estado da PED ok');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.chuva_pedidos), 'fila vazia');

-- 6. Leitura de 10 min velha (última há mais de 90 min) não conta.
SELECT pg_temp.confere((SELECT coalesce(max(mm_1h), 0) FROM public.chuva_avaliar(now() + interval '2 hours')
                        WHERE estacao_id = 9707) = 0, 'leitura velha sai da conta');

-- 7. Token derrubado (401 nos dados): apaga o token para pedir outro.
DELETE FROM public.chuva_pedidos;
SELECT public.chuva_pedir();
SELECT pg_temp.responde('ped_dados', 401, '');
SELECT public.chuva_processar();
SELECT pg_temp.confere((SELECT token IS NULL FROM public.chuva_ped_token), '401 nos dados apaga o token');
SELECT pg_temp.confere((SELECT ped_erro LIKE 'dados: token não aceito%' FROM public.chuva_estado), 'erro registrado');
-- Leituras já gravadas continuam valendo.
SELECT pg_temp.confere((SELECT mm_1h FROM public.chuva_avaliar() WHERE estacao_id = 9707) = 34, 'leituras anteriores mantidas');

-- 8. Senha errada: registra, não guarda token e não insiste por 1 h.
DELETE FROM public.chuva_pedidos;
SELECT public.chuva_pedir();
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM public.chuva_pedidos WHERE tipo = 'ped_token'), 'pede token novo');
SELECT pg_temp.responde('ped_token', 401, '{"message":"Usuário ou senha inválidos"}');
SELECT public.chuva_processar();
SELECT pg_temp.confere((SELECT ped_erro LIKE 'token recusado (HTTP 401)%' FROM public.chuva_estado), 'senha errada registrada');
SELECT pg_temp.confere((SELECT ped_erro NOT LIKE '%inválidos%' FROM public.chuva_estado), 'corpo da resposta não vai para o log');
DELETE FROM public.chuva_pedidos;   -- sem pedido de token recente na fila
SELECT public.chuva_pedir();
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.chuva_pedidos WHERE tipo = 'ped_token'),
                       'depois de senha recusada, espera 1 h antes de tentar de novo');

-- 9. Faxina: 10 min com mais de 3 dias saem.
INSERT INTO public.chuva_leituras_10min (estacao_id, fim, mm) VALUES (9707, now() - interval '4 days', 1);
DELETE FROM public.chuva_pedidos;
SELECT public.chuva_processar();
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.chuva_leituras_10min WHERE fim < now() - interval '3 days'),
                       'leituras com mais de 3 dias apagadas');

-- 10. Coleta aberta continua igual (balde de hora cheia ainda conta).
INSERT INTO public.chuva_leituras (estacao_id, hora, mm, lido_em)
VALUES (9716, date_trunc('hour', now()), 22, now())
ON CONFLICT (estacao_id, hora) DO UPDATE SET mm = 22, lido_em = now();
SELECT pg_temp.confere((SELECT mm_1h FROM public.chuva_avaliar() WHERE estacao_id = 9716) = 22,
                       'hora cheia da coleta aberta segue valendo');

ROLLBACK;
\echo 'chuva_ped_test: TODOS OK'
