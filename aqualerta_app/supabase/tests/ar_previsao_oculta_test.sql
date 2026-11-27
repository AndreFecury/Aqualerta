-- Teste da chave que esconde a previsão de 48 h (20261128b_ar_previsao_oculta.sql).
-- PostGIS LOCAL, banco novo:
--   stub_base, ar_stubs, ar_validacao_stubs, push_teste_stubs, sinal_dados_stubs,
--   20261118_push_fcm, 20261121b_sinal_dados, 20261122_ar, 20261123b_push_teste,
--   20261124_openaq, 20261125a_ar_pausa, 20261125b, 20261125c, 20261126a,
--   20261126b, 20261127b, 20261128a, 20261128b, este arquivo
-- Valores inventados. Manaus = a0000000-...-001.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;

-- Modelo: 30 h passadas em 35 µg/m³ e, depois de 22/11 12:00 UTC, 48 h em 120 µg/m³
-- (a previsão de pico existe).
INSERT INTO public.ar_horas (region_id, hora, pm2_5)
SELECT 'a0000000-0000-0000-0000-000000000001', h,
       CASE WHEN h > '2026-11-22 12:00+00' THEN 120 ELSE 35 END
  FROM generate_series('2026-11-21 06:00+00'::timestamptz, '2026-11-24 12:00+00', interval '1 hour') h;
CREATE TEMP TABLE esperado AS
SELECT iqar, hora FROM public.v_ar_indice_horas
 WHERE region_id = 'a0000000-0000-0000-0000-000000000001'
   AND hora > '2026-11-22 12:00+00' AND hora <= '2026-11-24 12:00+00' AND iqar IS NOT NULL
 ORDER BY iqar DESC, hora LIMIT 1;
SELECT pg_temp.confere((SELECT iqar > 120 FROM esperado), 'há previsão de pico alto nos dados (a view guarda o valor)');

-- 1. Padrão: escondida.
SELECT pg_temp.confere(public.ar_cfg('previsao_48h_visivel') = 0, 'chave nasce em 0 (escondida)');
CREATE TEMP TABLE oculta AS SELECT * FROM public.ar_resumo('2026-11-22 12:00+00')
 WHERE region_id = 'a0000000-0000-0000-0000-000000000001';
SELECT pg_temp.confere((SELECT iqar_previsto_48h IS NULL AND hora_pior_prevista IS NULL FROM oculta),
                       'padrão: iqar_previsto_48h e hora_pior_prevista vêm NULL');
SELECT pg_temp.confere((SELECT iqar IS NOT NULL AND nivel IS NOT NULL AND poluente IS NOT NULL AND pm2_5_24 IS NOT NULL
                          AND atualizado_em IS NOT NULL FROM oculta),
                       'o índice de agora e o resto continuam');

-- 2. Ligada: volta como antes, com o valor da view.
UPDATE public.ar_config SET valor = 1 WHERE chave = 'previsao_48h_visivel';
CREATE TEMP TABLE visivel AS SELECT * FROM public.ar_resumo('2026-11-22 12:00+00')
 WHERE region_id = 'a0000000-0000-0000-0000-000000000001';
SELECT pg_temp.confere((SELECT v.iqar_previsto_48h = e.iqar AND v.hora_pior_prevista = e.hora FROM visivel v, esperado e),
                       'chave em 1: previsão igual à da view');
-- Só as duas colunas mudam.
SELECT pg_temp.confere((SELECT o.iqar IS NOT DISTINCT FROM v.iqar AND o.nivel IS NOT DISTINCT FROM v.nivel
                          AND o.poluente IS NOT DISTINCT FROM v.poluente AND o.pm2_5_24 IS NOT DISTINCT FROM v.pm2_5_24
                          AND o.tendencia IS NOT DISTINCT FROM v.tendencia AND o.focos_24h = v.focos_24h
                          AND o.fumaca_provavel = v.fumaca_provavel AND o.atualizado_em IS NOT DISTINCT FROM v.atualizado_em
                          AND o.hora IS NOT DISTINCT FROM v.hora
                          FROM oculta o, visivel v),
                       'ligada ou desligada, todas as outras colunas são iguais');

-- 3. Chave apagada: escondida (nunca aparece por acidente).
DELETE FROM public.ar_config WHERE chave = 'previsao_48h_visivel';
SELECT pg_temp.confere((SELECT iqar_previsto_48h IS NULL AND hora_pior_prevista IS NULL
                          FROM public.ar_resumo('2026-11-22 12:00+00') WHERE region_id = 'a0000000-0000-0000-0000-000000000001'),
                       'sem a linha da chave: também escondida');

-- 4. Reaplicar a migração não religa a previsão (ON CONFLICT DO NOTHING) e a RPC segue pública.
INSERT INTO public.ar_config (chave, valor, descricao) VALUES ('previsao_48h_visivel', 1, 'dono ligou');
INSERT INTO public.ar_config (chave, valor, descricao) VALUES ('previsao_48h_visivel', 0, 'a migração de novo')
ON CONFLICT (chave) DO NOTHING;
SELECT pg_temp.confere(public.ar_cfg('previsao_48h_visivel') = 1, 'reaplicar a migração não desfaz a escolha do dono');
SELECT pg_temp.confere(has_function_privilege('anon', 'public.ar_resumo(timestamptz)', 'EXECUTE')
                   AND has_function_privilege('authenticated', 'public.ar_resumo(timestamptz)', 'EXECUTE'),
                       'ar_resumo continua pública');
ROLLBACK;
