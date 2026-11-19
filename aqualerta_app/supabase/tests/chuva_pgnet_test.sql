-- Teste da coleta pelo banco (20261119b_chuva_pgnet.sql) com respostas REAIS
-- do CEMADEN gravadas em supabase/functions/chuva-cemaden/fixtures/.
-- Roda só num PostGIS LOCAL, depois de stub_base.sql e das duas migrações.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

DELETE FROM public.chuva_estacoes;
UPDATE public.chuva_estado SET estacoes_atualizadas_em = NULL;

-- 1. Agendamento: a Edge Function sai do cron, entram pedir/processar.
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'chuva-cemaden'), 'cron da Edge Function removido');
SELECT pg_temp.confere((SELECT count(*) FROM cron.job WHERE jobname IN ('chuva-pedir','chuva-processar')) = 2, 'crons do banco criados');

-- 2. Primeiro ciclo: só a lista (ainda não há estação conhecida com chuva).
SELECT pg_temp.confere(public.chuva_pedir() = 1, 'primeiro ciclo pede só a lista');
INSERT INTO net._http_response (id, status_code, content)
SELECT request_id, 200, pg_read_file('/s/functions/chuva-cemaden/fixtures/estacoes_recorte.js')
FROM public.chuva_pedidos WHERE tipo = 'lista';
SELECT pg_temp.confere(public.chuva_processar() > 0, 'processa a lista real');
SELECT pg_temp.confere((SELECT count(*) FROM public.chuva_estacoes WHERE region_id = 'a0000000-0000-0000-0000-000000000001') = 14,
                       'cadastra as 14 estações de Manaus');
SELECT pg_temp.confere((SELECT count(*) FROM public.chuva_estacoes WHERE region_id = 'a0000000-0000-0000-0000-000000000002') = 3,
                       'e as 3 de Parintins');
SELECT pg_temp.confere((SELECT acum24h FROM public.chuva_estacoes WHERE id = 6740) = 0, 'acumulado real de 24 h gravado');
SELECT pg_temp.confere((SELECT count(*) FROM public.chuva_estacoes WHERE acum24h IS NULL) >= 1, 'estação sem dado fica nula, não zero');
SELECT pg_temp.confere((SELECT count(*) FROM public.chuva_leituras WHERE mm = 0) >= 10, 'estações secas ganham o zero da hora');
SELECT pg_temp.confere(NOT EXISTS (SELECT 1 FROM public.chuva_pedidos), 'pedido respondido sai da fila');
SELECT pg_temp.confere((SELECT ultima_coleta_ok IS NOT NULL AND estacoes_com_falha = 0 FROM public.chuva_estado), 'estado da coleta ok');

-- 3. Segundo ciclo: estação com chuva ganha o pedido hora a hora.
UPDATE public.chuva_estacoes SET acum24h = 12.5, acum24h_em = now() WHERE id = 6740;
-- (Na lista real, Mauazinho também tinha 0,4 mm: entra junto.)
SELECT pg_temp.confere(public.chuva_pedir() = 1 + (SELECT count(*) FROM public.chuva_estacoes WHERE acum24h > 0),
                       'pede a lista + o hora a hora só das estações com chuva');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM net.chamadas WHERE url LIKE '%/horario/6740/24'), 'URL do hora a hora');
SELECT pg_temp.confere((SELECT estacao_id FROM public.chuva_pedidos WHERE tipo = 'horario' ORDER BY request_id LIMIT 1) = 6740,
                       'a de mais chuva primeiro');
INSERT INTO net._http_response (id, status_code, content)
SELECT request_id, 200, pg_read_file('/s/functions/chuva-cemaden/fixtures/horario_manaus_6740.json')
FROM public.chuva_pedidos WHERE tipo = 'horario';
INSERT INTO net._http_response (id, status_code, timed_out, error_msg)
SELECT request_id, NULL, true, 'Timeout of 30000 ms reached' FROM public.chuva_pedidos WHERE tipo = 'lista';
SELECT public.chuva_processar();
SELECT pg_temp.confere((SELECT count(*) FROM public.chuva_leituras WHERE estacao_id = 6740 AND hora <= '2026-11-19 03:00+00') = 49, '49 horas reais da estação (48 + a corrente da resposta)');
SELECT pg_temp.confere((SELECT min(hora) FROM public.chuva_leituras WHERE estacao_id = 6740) = '2026-11-17 03:00+00', 'primeira hora em UTC');
SELECT pg_temp.confere((SELECT estacoes_com_falha = 1 AND ultimo_erro LIKE 'lista: Timeout%' FROM public.chuva_estado),
                       'falha da lista registrada sem derrubar o resto');

-- 4. Mesma regra do nucleo.ts para o hora a hora.
SELECT pg_temp.confere((SELECT count(*) FROM public.chuva_ler_horario(1,
    '{"horarios":["22h","23h","0h","1h"],"datas":["18/11/2026","19/11/2026"],"acumulados":[[12.34,null,null,null],[null,null,41,null]]}'::jsonb)) = 2,
    'nulo fica de fora');
SELECT pg_temp.confere((SELECT hora FROM public.chuva_ler_horario(1,
    '{"horarios":["22h","23h","0h","1h"],"datas":["18/11/2026","19/11/2026"],"acumulados":[[12.34,null,null,null],[null,null,41,null]]}'::jsonb)
    WHERE mm = 41) = '2026-11-19 00:00+00', 'virada do dia');

ROLLBACK;
\echo 'chuva_pgnet_test.sql: todos os testes passaram'
