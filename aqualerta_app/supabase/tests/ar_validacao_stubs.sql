-- Imitação local da fila do pg_net, com o acesso público que o Supabase dá.
CREATE TABLE IF NOT EXISTS net.http_request_queue (id bigserial PRIMARY KEY, method text, url text, headers jsonb, body bytea);
GRANT USAGE ON SCHEMA net TO anon, authenticated;
GRANT SELECT ON net._http_response, net.http_request_queue TO anon, authenticated;
