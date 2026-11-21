-- ============================================================
-- Calibração dos avisos de chuva com 1 ano de dados reais (21/11/2026)
--
-- Base: chuva hora a hora de nov/2025 a nov/2026 nos pluviômetros do
-- CEMADEN dos municípios monitorados, comparada com os 12 dias em que a
-- Prefeitura/Defesa Civil ou a imprensa registraram alagamentos em Manaus,
-- e com o relatório IDF de Manaus (SGB/CPRM, 2015).
--
-- O que os dados mostraram com os limites antigos (INMET 20/30/60 mm/h e
-- 50/100 mm/24 h) em Manaus:
--   * ~96 dias de aviso por ano, sendo ~57 "muito forte" e ~15 "extrema".
--     50 mm em 24 h acontece em ~66 dias/ano em algum pluviômetro, e
--     100 mm/24 h fica abaixo da chuva de 2 anos de retorno (126,7 mm).
--   * Um único pluviômetro com 30 mm/h é comum (~36 dias/ano); nos dias com
--     alagamento registrado, quase sempre 2 ou mais passaram de 30 mm/h.
--   * Uma hora de 111,8 mm sem chuva em nenhum vizinho (09/12/2025) era
--     falha de sensor: passa da chuva de 100 anos de Manaus (106 mm em 1 h).
--
-- Regra nova (mesma detecção: os 12 dias de alagamento continuam com aviso;
-- muda o nível, que agora acompanha o tamanho do evento):
--   MEDIUM   (forte)       1 h >= 20 mm em algum pluviômetro, ou 24 h >= 50
--   HIGH     (muito forte) 1 h >= 40 em um, ou >= 30 em 2+ do município,
--                          ou 24 h >= 100
--   CRITICAL (extrema)     1 h >= 60 em um (≈ chuva de 2 anos), ou >= 40 em
--                          3+ do município, ou 24 h >= 130 (≈ 2 anos)
-- Simulação no ano: Manaus 96 dias com aviso (62 forte, 23 muito forte,
-- 11 extrema) contra 96 (24/57/15) da regra antiga.
--
-- Filtro de falha de sensor pelo IDF: hora > 110 mm e 10 min > 35 mm são
-- ignoradas (acima das chuvas de 100 anos: 106 mm e 29 mm).
--
-- Troca chuva_avaliar() (mesma assinatura) e o rodapé do texto do aviso, que
-- citava os critérios do INMET. Idempotente.
-- ============================================================
CREATE OR REPLACE FUNCTION public.chuva_avaliar(p_agora timestamptz DEFAULT now())
RETURNS TABLE (estacao_id integer, region_id uuid, nome text,
               mm_1h numeric, mm_24h numeric, lido_em timestamptz, severidade text)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    WITH h AS (   -- baldes de hora cheia (coleta aberta)
        SELECT l.estacao_id,
               max(l.mm) FILTER (WHERE l.hora >= date_trunc('hour', p_agora) - interval '1 hour') AS h1,
               sum(l.mm) FILTER (WHERE l.hora > p_agora - interval '24 hours') AS d24,
               max(l.lido_em) AS lido
        FROM public.chuva_leituras l
        WHERE l.hora > p_agora - interval '25 hours'
          AND l.hora <= p_agora
          AND l.mm <= 110
        GROUP BY l.estacao_id
    ),
    u AS (        -- última leitura de 10 min de cada estação (relógio da PED)
        SELECT d.estacao_id, max(d.fim) AS ultimo
        FROM public.chuva_leituras_10min d
        WHERE d.fim > p_agora - interval '3 hours'
          AND d.fim <= p_agora + interval '30 minutes'
        GROUP BY d.estacao_id
    ),
    m AS (        -- soma dos 60 min que terminam na última leitura
        SELECT u.estacao_id, sum(d.mm) AS r60, max(d.lido_em) AS lido
        FROM u
        JOIN public.chuva_leituras_10min d
          ON d.estacao_id = u.estacao_id
         AND d.fim > u.ultimo - interval '60 minutes'
         AND d.fim <= u.ultimo
        WHERE u.ultimo > p_agora - interval '90 minutes'
          AND d.mm <= 35
        GROUP BY u.estacao_id
    ),
    v AS (
        SELECT e.id, e.region_id, e.nome,
               greatest(coalesce(h.h1, 0), coalesce(m.r60, 0)) AS h1,
               greatest(coalesce(h.d24, 0), coalesce(m.r60, 0)) AS d24,
               greatest(h.lido, m.lido) AS lido   -- greatest ignora NULL
        FROM public.chuva_estacoes e
        LEFT JOIN h ON h.estacao_id = e.id
        LEFT JOIN m ON m.estacao_id = e.id
        WHERE e.ativa
          AND greatest(coalesce(h.lido, '-infinity'), coalesce(m.lido, '-infinity'))
              > p_agora - interval '40 minutes'
    ),
    r AS (        -- quantos pluviômetros do município estão com chuva muito forte
        SELECT v.*,
               count(*) FILTER (WHERE v.h1 >= 30) OVER (PARTITION BY v.region_id) AS n30,
               count(*) FILTER (WHERE v.h1 >= 40) OVER (PARTITION BY v.region_id) AS n40
        FROM v
    )
    SELECT id, region_id, nome, h1, d24, lido,
           CASE
             WHEN h1 >= 60 OR (h1 >= 40 AND n40 >= 3) OR d24 >= 130 THEN 'CRITICAL'
             WHEN h1 >= 40 OR (h1 >= 30 AND n30 >= 2) OR d24 >= 100 THEN 'HIGH'
             WHEN h1 >= 20 OR d24 >= 50 THEN 'MEDIUM'
             ELSE 'LOW' END
    FROM r;
$$;

-- Mesmo corpo de 20261119_chuva.sql; só o rodapé do texto mudou.
CREATE OR REPLACE FUNCTION public.chuva_atualizar_avisos(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    r        record;
    pior     record;
    atual    record;
    fuso     text;
    titulo   text;
    texto    text;
    mudancas integer := 0;
BEGIN
    FOR r IN
        SELECT mr.id, mr.name, mr.state_code FROM public.monitored_regions mr
        WHERE EXISTS (SELECT 1 FROM public.chuva_estacoes e WHERE e.region_id = mr.id AND e.ativa)
    LOOP
        fuso := CASE r.state_code WHEN 'AC' THEN 'America/Rio_Branco' ELSE 'America/Manaus' END;

        SELECT * INTO pior FROM public.chuva_avaliar(p_agora) a
        WHERE a.region_id = r.id
        ORDER BY public.chuva_rank(a.severidade) DESC, a.mm_1h DESC, a.mm_24h DESC
        LIMIT 1;

        SELECT * INTO atual FROM public.alerts al
        WHERE al.region_id = r.id AND al.status = 'ACTIVE'
          AND al.metadata->>'origem' = 'chuva-cemaden'
        ORDER BY al.issued_at DESC LIMIT 1;

        IF pior.estacao_id IS NOT NULL AND pior.severidade <> 'LOW' THEN
            titulo := CASE pior.severidade
                WHEN 'CRITICAL' THEN 'Chuva extrema em ' || r.name || ': risco de grandes alagamentos'
                WHEN 'HIGH'     THEN 'Chuva muito forte em ' || r.name || ': alagamentos prováveis'
                ELSE                 'Chuva forte em ' || r.name || ': risco de alagamento' END;
            texto := 'O pluviômetro ' || pior.nome || ' (CEMADEN) registrou '
                  || public.chuva_mm_br(pior.mm_1h) || ' mm na última hora e '
                  || public.chuva_mm_br(pior.mm_24h) || ' mm em 24 h (leitura das '
                  || to_char(pior.lido_em AT TIME ZONE fuso, 'HH24:MI') || '). '
                  || 'Ruas e igarapés podem alagar em minutos: evite áreas alagadas, não atravesse '
                  || 'correnteza e fique longe de encostas. '
                  || 'Aviso automático do AquaAlerta com dados do CEMADEN e limites calibrados com '
                  || 'os alagamentos de 2025/2026; não substitui a Defesa Civil. Emergência: 199 (Defesa Civil) '
                  || 'ou 193 (Bombeiros).';

            IF atual.id IS NULL THEN
                INSERT INTO public.alerts
                    (region_id, title, body, severity, status, valid_from, issued_at, metadata)
                VALUES (r.id, titulo, texto, pior.severidade, 'ACTIVE', pior.lido_em, p_agora,
                        jsonb_build_object('origem', 'chuva-cemaden', 'estacao_cemaden', pior.estacao_id,
                                           'mm_1h', pior.mm_1h, 'mm_24h', pior.mm_24h,
                                           'ultimo_gatilho', p_agora));
                mudancas := mudancas + 1;
            ELSIF public.chuva_rank(pior.severidade) > public.chuva_rank(atual.severity) THEN
                UPDATE public.alerts
                   SET severity = pior.severidade, title = titulo, body = texto,
                       metadata = metadata || jsonb_build_object('estacao_cemaden', pior.estacao_id,
                                  'mm_1h', pior.mm_1h, 'mm_24h', pior.mm_24h, 'ultimo_gatilho', p_agora)
                 WHERE id = atual.id;
                mudancas := mudancas + 1;
            ELSE
                -- Mesmo nível ou menor: só renova o prazo (sem push).
                UPDATE public.alerts
                   SET metadata = metadata || jsonb_build_object('ultimo_gatilho', p_agora)
                 WHERE id = atual.id;
            END IF;

        ELSIF atual.id IS NOT NULL
              AND coalesce((atual.metadata->>'ultimo_gatilho')::timestamptz, atual.issued_at)
                  < p_agora - interval '2 hours' THEN
            UPDATE public.alerts
               SET status = 'RESOLVED', resolved_at = p_agora, valid_until = p_agora,
                   body = body || ' Encerrado às ' || to_char(p_agora AT TIME ZONE fuso, 'HH24:MI')
                          || ': 2 h sem chuva forte nos pluviômetros do município.'
             WHERE id = atual.id;
            mudancas := mudancas + 1;
        END IF;
    END LOOP;
    RETURN mudancas;
END $$;
REVOKE ALL ON FUNCTION public.chuva_atualizar_avisos(timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chuva_atualizar_avisos(timestamptz) TO service_role;
