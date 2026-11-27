-- Gera test/fixtures/ar_replay.json: o que as RPCs do servidor (ar_resumo,
-- ar_contexto, ar_agora) devolveriam nos dois instantes de 26/11/2026 para as duas
-- regiões da reconstrução (fixtures/ar_replay_serie.sql). NÃO é um teste: só imprime
-- o JSON. Mesma cadeia de migrações de ar_replay_test.sql. Uso (PostGIS local):
--   psql -q -At -v ON_ERROR_STOP=1 -f stub_base.sql ... -f fixtures/ar_replay_snapshot.sql > ../../test/fixtures/ar_replay.json
-- (as migrações e os stubs também vão com -f, na ordem do cabeçalho de ar_replay_test.sql;
--  as linhas de ruído do psql ficam de fora porque só este arquivo imprime resultado.)
BEGIN;
\ir ar_replay_serie.sql

CREATE OR REPLACE FUNCTION pg_temp.cenario(nome text, regiao uuid, quando timestamptz, rotulo text)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object(
        'regiao', nome, 'instante', quando, 'rotulo', rotulo,
        'resumo',   (SELECT to_jsonb(r) FROM public.ar_resumo(quando) r WHERE r.region_id = regiao),
        'contexto', (SELECT to_jsonb(c) FROM public.ar_contexto(quando) c WHERE c.region_id = regiao),
        'agora',    (SELECT to_jsonb(a) FROM public.ar_agora(quando) a WHERE a.region_id = regiao))
$$;

SELECT jsonb_pretty(jsonb_build_object(
    'aviso', 'RECONSTRUÇÃO: ids, nomes e valores inventados a partir dos fatos informados pelo dono. Não é a série real.',
    'cenarios', jsonb_build_array(
        pg_temp.cenario('Manaus',      'a0000000-0000-0000-0000-000000000001', '2026-11-26 10:00+00', '06:00 locais'),
        pg_temp.cenario('Manaus',      'a0000000-0000-0000-0000-000000000001', '2026-11-26 23:42+00', '19:42 locais'),
        pg_temp.cenario('Porto Velho', 'a0000000-0000-0000-0000-000000000003', '2026-11-26 10:00+00', '06:00 locais'),
        pg_temp.cenario('Porto Velho', 'a0000000-0000-0000-0000-000000000003', '2026-11-26 23:42+00', '19:42 locais'))));
ROLLBACK;
