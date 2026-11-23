-- Teste da Fase A3 (20261127c_saude_push.sql). PostGIS LOCAL, banco novo:
--   cadeia do ar_aviso_teste_test.sql (até 20261127b), saude_stubs,
--   20261127a_saude, 20261127c_saude_push, este arquivo
-- Valores inventados. A = dono, B = outra conta.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.confere(cond boolean, msg text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FALHOU: %', msg; END IF;
    RAISE NOTICE 'ok: %', msg;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.h(x numeric) RETURNS timestamptz LANGUAGE sql AS
$$ SELECT '2026-11-23 12:00+00'::timestamptz + x * interval '1 hour' $$;
CREATE OR REPLACE FUNCTION pg_temp.saude_n() RETURNS bigint LANGUAGE sql AS
$$ SELECT count(*) FROM public.push_fila WHERE teste_origem = 'saude' $$;
-- Roda o vigia e dá a fila por enviada (senão a própria fila parece parada).
CREATE OR REPLACE FUNCTION pg_temp.vig(t timestamptz) RETURNS integer LANGUAGE plpgsql AS
$$ DECLARE n integer; BEGIN n := public.saude_vigiar(t);
   UPDATE public.push_fila SET resultado = '{}' WHERE resultado IS NULL; RETURN n; END $$;

INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b1')
ON CONFLICT DO NOTHING;
INSERT INTO public.user_profiles (id, fcm_token) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'tok-a-0123456789abcdef'),
  ('00000000-0000-0000-0000-0000000000b1', 'tok-b-0123456789abcdef')
ON CONFLICT (id) DO UPDATE SET fcm_token = excluded.fcm_token;
DELETE FROM public.push_fila; DELETE FROM public.hydro_readings; DELETE FROM public.saude_estado;
-- Tudo em dia, menos o que cada passo mexer: só a fonte CEMADEN varia.
INSERT INTO public.chuva_estado (id, ultima_coleta_ok) VALUES (1, pg_temp.h(0))
ON CONFLICT (id) DO UPDATE SET ultima_coleta_ok = excluded.ultima_coleta_ok;

-- 1. Sem dono gravado: acompanha, mas não manda nada.
UPDATE public.chuva_estado SET ultima_coleta_ok = pg_temp.h(-2);         -- 120 min > 6x 5 min
SELECT pg_temp.confere(public.saude_vigiar(pg_temp.h(0)) = 0 AND pg_temp.saude_n() = 0, 'sem dono: nenhum push');
SELECT pg_temp.confere((SELECT em_falha AND NOT avisado FROM public.saude_estado WHERE chave = 'cemaden'), 'falha registrada sem aviso');
UPDATE public.chuva_estado SET ultima_coleta_ok = pg_temp.h(0);
SELECT public.saude_vigiar(pg_temp.h(0));
SELECT pg_temp.confere(pg_temp.saude_n() = 0, 'volta sem falha avisada: nenhum push');

-- 2. Dono gravado: falha vira um push, só para ele.
SELECT pg_temp.confere(NOT has_function_privilege('authenticated', 'public.saude_definir_dono(uuid)', 'EXECUTE')
                   AND NOT has_function_privilege('anon', 'public.saude_vigiar(timestamptz)', 'EXECUTE')
                   AND NOT has_table_privilege('anon', 'public.saude_dono', 'SELECT')
                   AND NOT has_table_privilege('authenticated', 'public.saude_estado', 'SELECT'), 'só o servidor mexe');
SELECT public.saude_definir_dono('00000000-0000-0000-0000-0000000000a1');
UPDATE public.chuva_estado SET ultima_coleta_ok = pg_temp.h(-1);
SELECT pg_temp.confere(public.saude_vigiar(pg_temp.h(0)) = 1, 'entrou em parada: 1 push');
CREATE TEMP TABLE r AS SELECT * FROM public.push_reivindicar(20);
SELECT pg_temp.confere((SELECT array_agg(token) FROM r WHERE token IS NOT NULL) = ARRAY['tok-a-0123456789abcdef'], 'só o dono recebe');
SELECT pg_temp.confere((SELECT bool_and(titulo = 'AquaAlerta · fonte parada: Chuva (CEMADEN)'
                                        AND corpo LIKE 'cemaden parada há 60 min. Visto em 23/11 08:00 (Manaus).%') FROM r WHERE token IS NOT NULL),
                       'título e corpo com a fonte e a hora de Manaus');
SELECT public.push_concluir((SELECT jsonb_agg(jsonb_build_object('fila_id', fila_id, 'alert_id', alert_id, 'user_id', user_id,
                                                                  'token', token, 'ok', true)) FROM r));

-- 3. Continua parada: nada novo.
SELECT pg_temp.confere(pg_temp.vig(pg_temp.h(0.25)) = 0 AND pg_temp.vig(pg_temp.h(3)) = 0, 'continua parada: sem push repetido');
-- 4. Atrasada não é "volta".
UPDATE public.chuva_estado SET ultima_coleta_ok = pg_temp.h(3) - interval '20 minutes';
SELECT pg_temp.confere(pg_temp.vig(pg_temp.h(3)) = 0
                   AND (SELECT em_falha FROM public.saude_estado WHERE chave = 'cemaden'), 'atrasada: ainda em falha, sem push');
-- 5. Volta a ok: um push de volta.
UPDATE public.chuva_estado SET ultima_coleta_ok = pg_temp.h(3);
SELECT pg_temp.confere(pg_temp.vig(pg_temp.h(3)) = 1, 'voltou: 1 push');
SELECT pg_temp.confere((SELECT titulo_fixo = 'AquaAlerta · fonte de volta: Chuva (CEMADEN)' AND corpo_fixo LIKE '%depois de 180 min com problema.'
                          FROM public.push_fila WHERE teste_origem = 'saude' ORDER BY id DESC LIMIT 1), 'texto da volta');

-- 6. Pisca-pisca dentro de 6 h: a nova falha não avisa, e a volta dela também não.
UPDATE public.chuva_estado SET ultima_coleta_ok = pg_temp.h(3);
SELECT pg_temp.confere(pg_temp.vig(pg_temp.h(4)) = 0, 'nova falha 4 h depois do último aviso: espera');
UPDATE public.chuva_estado SET ultima_coleta_ok = pg_temp.h(4);
SELECT pg_temp.confere(pg_temp.vig(pg_temp.h(4)) = 0, 'volta de falha não avisada: sem push');
UPDATE public.chuva_estado SET ultima_coleta_ok = pg_temp.h(5);
SELECT pg_temp.confere(pg_temp.vig(pg_temp.h(7)) = 1, 'nova falha depois de 6 h: avisa de novo');
SELECT pg_temp.confere(pg_temp.saude_n() = 3, 'no total: falha, volta, falha');

-- 7. ANA: uma estação parada de 3, sem alerta ativo, é 1/3: aviso único.
UPDATE public.chuva_estado SET ultima_coleta_ok = pg_temp.h(7);
SELECT pg_temp.vig(pg_temp.h(7));
INSERT INTO public.hydro_stations (ana_code, name) VALUES ('16350002', 'Parintins'), ('16030000', 'Itacoatiara') ON CONFLICT DO NOTHING;
INSERT INTO public.hydro_readings SELECT id, 1, pg_temp.h(7) - g * interval '15 minutes' FROM public.hydro_stations, generate_series(0, 8) g
 WHERE ana_code IN ('14990000', '16030000');
INSERT INTO public.hydro_readings SELECT id, 1, pg_temp.h(-10) - g * interval '1 hour' FROM public.hydro_stations, generate_series(0, 8) g
 WHERE ana_code = '16350002';
CREATE TEMP TABLE antes AS SELECT pg_temp.saude_n() AS n;
SELECT pg_temp.confere(pg_temp.vig(pg_temp.h(7)) = 1, 'ANA pela regra: 1 push');
SELECT pg_temp.confere((SELECT titulo_fixo = 'AquaAlerta · fonte parada: Níveis dos rios (ANA)' AND corpo_fixo LIKE 'ANA: 1 de 3 estações paradas: Parintins (16350002)%'
                          FROM public.push_fila WHERE teste_origem = 'saude' ORDER BY id DESC LIMIT 1), 'aviso único da ANA com a estação');
SELECT pg_temp.confere(EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'saude-vigiar' AND schedule = '4,19,34,49 * * * *'), 'agenda a cada 15 min');
ROLLBACK;
