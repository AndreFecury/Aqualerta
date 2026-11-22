-- Imitação local de auth.users e alert_deliveries do Supabase (só o usado).
CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY);
CREATE TABLE IF NOT EXISTS public.alert_deliveries (
  alert_id uuid REFERENCES public.alerts(id) ON DELETE CASCADE, user_id uuid,
  delivered_via text, delivered_at timestamptz, PRIMARY KEY (alert_id, user_id, delivered_via));
