-- ============================================================
-- AquaAlerta: push de saúde para a conta do dono (Fase A3)
--
-- Segundo aviso, independente do vigia do GitHub: quando uma fonte entra em
-- "parada" (ANA pela regra do resumo) e quando volta a "ok", um push vai só
-- para a conta do dono. Espera mínima de 6 h entre avisos de falha da mesma
-- fonte; a volta só é avisada se a falha foi avisada.
-- Limite: se o próprio Supabase (ou a fila de push) cair, este aviso também
-- cai. Para isso existe o vigia de fora (.github/workflows/saude-fontes.yml).
--
-- O dono é gravado no SQL Editor, nunca no repositório:
--   SELECT public.saude_definir_dono('<uuid da sua conta>');
-- Pode rodar este arquivo mais de uma vez.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.saude_dono (
    id      integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    usuario uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE
);
ALTER TABLE public.saude_dono ENABLE ROW LEVEL SECURITY;          -- sem políticas: fora da API
REVOKE ALL ON public.saude_dono FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.saude_estado (
    chave        text PRIMARY KEY,
    em_falha     boolean NOT NULL DEFAULT false,
    desde        timestamptz,
    avisado      boolean NOT NULL DEFAULT false,   -- a falha atual já foi avisada
    ultimo_push  timestamptz,                      -- último aviso de falha
    motivo       text
);
ALTER TABLE public.saude_estado ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.saude_estado FROM PUBLIC, anon, authenticated;

INSERT INTO public.saude_cfg (chave, valor, descricao) VALUES
  ('push_espera_h', 6, 'Push de saúde: espera mínima entre avisos de falha da mesma fonte (h)')
ON CONFLICT (chave) DO NOTHING;

-- push_fila aceita itens de saúde (só para teste_para, com texto pronto).
ALTER TABLE public.push_fila DROP CONSTRAINT IF EXISTS push_fila_alerta_ou_teste;
ALTER TABLE public.push_fila ADD CONSTRAINT push_fila_alerta_ou_teste
    CHECK (alert_id IS NOT NULL OR ar_aviso_id IS NOT NULL
           OR (teste_para IS NOT NULL AND teste_origem IN ('cheia', 'chuva', 'ar', 'saude')));

CREATE OR REPLACE FUNCTION public.saude_definir_dono(usuario uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    INSERT INTO public.saude_dono (id, usuario) VALUES (1, usuario)
    ON CONFLICT (id) DO UPDATE SET usuario = excluded.usuario
$$;
REVOKE ALL ON FUNCTION public.saude_definir_dono(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.saude_nome_fonte(chave text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE chave
        WHEN 'ana'            THEN 'Níveis dos rios (ANA)'
        WHEN 'cemaden'        THEN 'Chuva (CEMADEN)'
        WHEN 'satelite'       THEN 'Satélite'
        WHEN 'ar_modelo'      THEN 'Modelo do ar'
        WHEN 'openaq_coletor' THEN 'Coletor da OpenAQ'
        WHEN 'push_fila'      THEN 'Fila de push'
        ELSE chave END
$$;

-- Chamado pelo cron. Devolve quantos pushes pôs na fila.
CREATE OR REPLACE FUNCTION public.saude_vigiar(p_agora timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    resumo jsonb := public.saude_resumo(p_agora);
    dono   uuid;
    espera numeric := public.saude_cfg_valor('push_espera_h');
    f      record;
    est    public.saude_estado;
    n      integer := 0;
    hora   text;
BEGIN
    SELECT d.usuario INTO dono FROM public.saude_dono d
      JOIN public.user_profiles p ON p.id = d.usuario
     WHERE d.id = 1 AND p.fcm_token IS NOT NULL AND p.fcm_token <> '';

    FOR f IN
        -- ANA: falha pela regra do resumo; volta quando nenhuma estação está parada.
        SELECT 'ana'::text AS chave,
               (SELECT m FROM jsonb_array_elements_text(resumo->'motivos') m WHERE m LIKE 'ANA:%' LIMIT 1) AS motivo,
               EXISTS (SELECT 1 FROM jsonb_array_elements_text(resumo->'motivos') m WHERE m LIKE 'ANA:%') AS falha,
               coalesce((resumo->'ana'->>'paradas')::int, 0) = 0 AS voltou
        UNION ALL
        SELECT s.fonte, s.fonte || ' parada há ' || round(s.idade_min) || ' min',
               s.situacao = 'parada', s.situacao = 'ok'
          FROM public.saude_fontes(p_agora) s
         WHERE s.fonte IN ('cemaden', 'satelite', 'ar_modelo', 'openaq_coletor', 'push_fila')
    LOOP
        INSERT INTO public.saude_estado (chave) VALUES (f.chave) ON CONFLICT (chave) DO NOTHING;
        SELECT * INTO est FROM public.saude_estado WHERE chave = f.chave FOR UPDATE;
        hora := to_char(p_agora AT TIME ZONE 'America/Manaus', 'DD/MM HH24:MI');

        IF f.falha AND NOT est.em_falha THEN
            -- Entrou em falha.
            IF dono IS NOT NULL AND (est.ultimo_push IS NULL OR est.ultimo_push <= p_agora - espera * interval '1 hour') THEN
                INSERT INTO public.push_fila (severity, motivo, teste_para, teste_origem, titulo_fixo, corpo_fixo)
                VALUES ('HIGH', 'novo', dono, 'saude',
                        'AquaAlerta · fonte parada: ' || public.saude_nome_fonte(f.chave),
                        f.motivo || '. Visto em ' || hora || ' (Manaus). Aviso só para o dono do app.');
                UPDATE public.saude_estado SET em_falha = true, desde = p_agora, avisado = true,
                       ultimo_push = p_agora, motivo = f.motivo WHERE chave = f.chave;
                n := n + 1;
            ELSE
                UPDATE public.saude_estado SET em_falha = true, desde = p_agora, avisado = false,
                       motivo = f.motivo WHERE chave = f.chave;
            END IF;
        ELSIF f.falha THEN
            UPDATE public.saude_estado SET motivo = f.motivo WHERE chave = f.chave;
        ELSIF est.em_falha AND f.voltou THEN
            -- Voltou: avisa só se a falha foi avisada.
            IF est.avisado AND dono IS NOT NULL THEN
                INSERT INTO public.push_fila (severity, motivo, teste_para, teste_origem, titulo_fixo, corpo_fixo)
                VALUES ('LOW', 'baixou', dono, 'saude',
                        'AquaAlerta · fonte de volta: ' || public.saude_nome_fonte(f.chave),
                        'Voltou ao normal em ' || hora || ' (Manaus), depois de '
                            || round(extract(epoch FROM p_agora - est.desde) / 60) || ' min com problema.');
                n := n + 1;
            END IF;
            UPDATE public.saude_estado SET em_falha = false, desde = p_agora, avisado = false, motivo = NULL
             WHERE chave = f.chave;
        END IF;
    END LOOP;

    IF n > 0 THEN PERFORM public.push_cutucar(); END IF;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.saude_vigiar(timestamptz) FROM PUBLIC, anon, authenticated;

SELECT cron.schedule('saude-vigiar', '4,19,34,49 * * * *', 'SELECT public.saude_vigiar()');
