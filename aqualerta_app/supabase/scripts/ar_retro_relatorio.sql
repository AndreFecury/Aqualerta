-- ============================================================
-- AQUALERTA — Fase 1b: funções do relatório retroativo (só o dono; fechadas).
-- NowCast da EPA para MP2,5 (média ponderada de 12 h):
--   c1 = hora mais recente ... c12; w* = min/max das horas disponíveis;
--   w = max(w*, 0,5); NowCast = soma(w^(i-1)·ci) / soma(w^(i-1));
--   exige 2 das 3 horas mais recentes. É "índice em tempo quase real",
--   NÃO o IQAr oficial (que usa a média de 24 h).
-- Simulação do aviso: abre com N horas seguidas acima do limite
-- (ar_config.aviso_horas_seguidas), fecha com M horas seguidas abaixo
-- (ar_config.aviso_fim_horas). Horas sem dado não contam para nenhum lado.
-- ============================================================

CREATE OR REPLACE FUNCTION public.ar_retro_nowcast(p_epa boolean)
RETURNS TABLE (region_id uuid, hora timestamptz, nowcast numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH h AS (
        SELECT v.region_id, v.hora, CASE WHEN p_epa THEN v.sensor_pm25_epa ELSE v.sensor_pm25 END AS c
          FROM public.ar_validacao_horas v
         WHERE v.origem = 'retro' AND v.valido
    ), janela AS (
        SELECT t.region_id, t.hora,
               (extract(epoch FROM t.hora - x.hora) / 3600)::int + 1 AS i, x.c
          FROM h t
          JOIN h x ON x.region_id = t.region_id AND x.hora <= t.hora AND x.hora > t.hora - interval '12 hours'
         WHERE x.c IS NOT NULL
    ), w AS (
        SELECT region_id, hora,
               greatest(CASE WHEN max(c) > 0 THEN min(c) / max(c) ELSE 1 END, 0.5) AS w,
               count(*) FILTER (WHERE i <= 3) AS recentes
          FROM janela GROUP BY region_id, hora
    )
    SELECT j.region_id, j.hora, round(sum(power(w.w, j.i - 1) * j.c) / sum(power(w.w, j.i - 1)), 1)
      FROM janela j JOIN w ON w.region_id = j.region_id AND w.hora = j.hora
     WHERE w.recentes >= 2
     GROUP BY j.region_id, j.hora
$$;
REVOKE ALL ON FUNCTION public.ar_retro_nowcast(boolean) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ar_retro_simular(p_limite numeric, p_epa boolean)
RETURNS TABLE (regiao text, limite numeric, serie text, episodios integer, horas_em_aviso integer,
               dias_com_aviso integer, maior_nowcast numeric, inicios text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    reg record; h record;
    abre integer := public.ar_cfg('aviso_horas_seguidas');
    fecha integer := public.ar_cfg('aviso_fim_horas');
    acima integer; abaixo integer; ativo boolean; ant timestamptz;
    ep integer; horas integer; dias date[]; maior numeric; ini text[];
BEGIN
    FOR reg IN SELECT DISTINCT r.id, r.name, r.state_code FROM public.monitored_regions r
                JOIN public.ar_validacao_horas v ON v.region_id = r.id AND v.origem = 'retro' ORDER BY r.name LOOP
        acima := 0; abaixo := 0; ativo := false; ant := NULL; ep := 0; horas := 0; dias := '{}'; maior := 0; ini := '{}';
        FOR h IN SELECT n.hora, n.nowcast FROM public.ar_retro_nowcast(p_epa) n
                  WHERE n.region_id = reg.id
                    AND (n.hora AT TIME ZONE public.regiao_fuso(reg.state_code))::date BETWEEN '2026-08-01' AND '2026-10-31'
                  ORDER BY n.hora LOOP
            -- buraco de dados: zera as contagens seguidas
            IF ant IS NOT NULL AND h.hora - ant > interval '1 hour' THEN acima := 0; abaixo := 0; END IF;
            ant := h.hora;
            maior := greatest(maior, h.nowcast);
            IF h.nowcast > p_limite THEN acima := acima + 1; abaixo := 0; ELSE abaixo := abaixo + 1; acima := 0; END IF;
            IF NOT ativo AND acima >= abre THEN
                ativo := true; ep := ep + 1;
                ini := ini || to_char(h.hora AT TIME ZONE public.regiao_fuso(reg.state_code), 'DD/MM HH24"h"');
            ELSIF ativo AND abaixo >= fecha THEN
                ativo := false;
            END IF;
            IF ativo THEN
                horas := horas + 1;
                dias := array_append(dias, (h.hora AT TIME ZONE public.regiao_fuso(reg.state_code))::date);
            END IF;
        END LOOP;
        regiao := reg.name; limite := p_limite; serie := CASE WHEN p_epa THEN 'corrigido EPA' ELSE 'como recebido' END;
        episodios := ep; horas_em_aviso := horas;
        dias_com_aviso := (SELECT count(DISTINCT d) FROM unnest(dias) d);
        maior_nowcast := maior;
        inicios := array_to_string(ini[1:12], ', ') || CASE WHEN array_length(ini, 1) > 12 THEN ' …' ELSE '' END;
        RETURN NEXT;
    END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.ar_retro_simular(numeric, boolean) FROM PUBLIC, anon, authenticated;
