-- ============================================================
-- Um sinal leve de "dados mudaram" no lugar do tempo real por linha
--
-- Antes: o app ouvia as mudanças de alerts, flood_events e hydro_readings
-- (postgres_changes). Cada linha virava uma mensagem para cada aparelho
-- aberto: a coleta da ANA grava ~416 leituras/dia, então 200 aparelhos
-- abertos dariam ~2,5 milhões de mensagens/mês (o plano gratuito tem 2
-- milhões), e cada lote fazia todos recarregarem tudo, inclusive os
-- contornos dos municípios. O banco ainda checava a permissão de cada
-- aparelho para cada linha.
--
-- Agora: gatilhos só marcam que algo mudou (dados_sinal.mudou_em). Um cron
-- a cada minuto manda UMA mensagem de broadcast no canal público "dados"
-- (evento "mudou") se houve mudança desde o último envio. No máximo 1
-- mensagem por minuto por aparelho, qualquer que seja o tamanho do lote.
-- Mudança só de metadata em alerts (o "ultimo_gatilho" da chuva, a cada
-- 5 min durante um aviso) não conta: nada muda na tela.
--
-- hydro_readings sai da publicação do tempo real (era a maior parte das
-- mensagens). alerts e flood_events ficam por enquanto, para as versões
-- antigas do app (até 4.9.1) continuarem atualizando sozinhas; mudam pouco.
--
-- Idempotente.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.dados_sinal (
    id          integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    mudou_em    timestamptz NOT NULL DEFAULT now(),
    enviado_em  timestamptz,
    versao      bigint NOT NULL DEFAULT 0
);
INSERT INTO public.dados_sinal (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.dados_sinal ENABLE ROW LEVEL SECURITY;   -- sem política: só o banco usa
REVOKE ALL ON public.dados_sinal FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.dados_marcar_mudanca()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.dados_sinal SET mudou_em = now() WHERE id = 1;
    RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.dados_marcar_mudanca() FROM PUBLIC, anon, authenticated;

-- Leituras: um gatilho por comando, e só se alguma linha entrou de fato
-- (a coleta usa ON CONFLICT DO NOTHING; lote repetido não é mudança).
CREATE OR REPLACE FUNCTION public.dados_marcar_leituras()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM novas) THEN
        UPDATE public.dados_sinal SET mudou_em = now() WHERE id = 1;
    END IF;
    RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.dados_marcar_leituras() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS dados_sinal_leituras ON public.hydro_readings;
CREATE TRIGGER dados_sinal_leituras
    AFTER INSERT ON public.hydro_readings
    REFERENCING NEW TABLE AS novas
    FOR EACH STATEMENT EXECUTE FUNCTION public.dados_marcar_leituras();

DROP TRIGGER IF EXISTS dados_sinal_eventos ON public.flood_events;
CREATE TRIGGER dados_sinal_eventos
    AFTER INSERT OR UPDATE OR DELETE ON public.flood_events
    FOR EACH STATEMENT EXECUTE FUNCTION public.dados_marcar_mudanca();

DROP TRIGGER IF EXISTS dados_sinal_alertas_novos ON public.alerts;
CREATE TRIGGER dados_sinal_alertas_novos
    AFTER INSERT OR DELETE ON public.alerts
    FOR EACH STATEMENT EXECUTE FUNCTION public.dados_marcar_mudanca();

-- Alteração de alerta: só o que aparece na tela.
DROP TRIGGER IF EXISTS dados_sinal_alertas_mudados ON public.alerts;
CREATE TRIGGER dados_sinal_alertas_mudados
    AFTER UPDATE ON public.alerts
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status
       OR OLD.severity IS DISTINCT FROM NEW.severity
       OR OLD.title IS DISTINCT FROM NEW.title
       OR OLD.body IS DISTINCT FROM NEW.body
       OR OLD.region_id IS DISTINCT FROM NEW.region_id
       OR OLD.flood_event_id IS DISTINCT FROM NEW.flood_event_id
       OR OLD.resolved_at IS DISTINCT FROM NEW.resolved_at)
    EXECUTE FUNCTION public.dados_marcar_mudanca();

-- Chamado pelo cron a cada minuto. Devolve true quando mandou o sinal.
CREATE OR REPLACE FUNCTION public.dados_enviar_sinal()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    s public.dados_sinal;
BEGIN
    SELECT * INTO s FROM public.dados_sinal WHERE id = 1 FOR UPDATE;
    IF s.enviado_em IS NOT NULL AND s.mudou_em <= s.enviado_em THEN
        RETURN false;
    END IF;
    UPDATE public.dados_sinal
       SET enviado_em = now(), versao = versao + 1
     WHERE id = 1
    RETURNING * INTO s;
    -- Canal público (private = false): só diz "mudou", sem dado nenhum.
    PERFORM realtime.send(jsonb_build_object('versao', s.versao), 'mudou', 'dados', false);
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.dados_enviar_sinal() FROM PUBLIC, anon, authenticated;

SELECT cron.schedule('dados-sinal', '* * * * *', 'SELECT public.dados_enviar_sinal()');

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication_tables
               WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
                 AND tablename = 'hydro_readings') THEN
        ALTER PUBLICATION supabase_realtime DROP TABLE public.hydro_readings;
    END IF;
END $$;
