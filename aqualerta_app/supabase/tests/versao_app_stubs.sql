-- Imitação local de auth.sessions do Supabase (só as colunas usadas).
CREATE TABLE IF NOT EXISTS auth.sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL,
  created_at timestamptz, updated_at timestamptz, refreshed_at timestamp without time zone);
