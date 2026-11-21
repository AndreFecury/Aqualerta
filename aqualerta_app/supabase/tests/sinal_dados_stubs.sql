-- Imitação local do que o Supabase já tem: realtime.send (grava o envio numa
-- tabela) e a publicação supabase_realtime com as tabelas de antes.
CREATE SCHEMA IF NOT EXISTS realtime;
CREATE TABLE IF NOT EXISTS realtime.enviados (payload jsonb, evento text, topico text, privado boolean);
CREATE OR REPLACE FUNCTION realtime.send(payload jsonb, event text, topic text, private boolean DEFAULT true)
RETURNS void LANGUAGE sql AS
$$ INSERT INTO realtime.enviados VALUES (payload, event, topic, private) $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        CREATE PUBLICATION supabase_realtime FOR TABLE public.alerts, public.flood_events, public.hydro_readings;
    END IF;
END $$;
