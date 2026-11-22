-- Estado de produção antes da Fase 0: aviso de ar ativo e perfis com ar ligado.
INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b1')
ON CONFLICT DO NOTHING;
INSERT INTO public.user_profiles (id, fcm_token, notification_preferences) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'tok-a-0123456789abcdef', '{"min_severity":"HIGH","ar":true}'),
  ('00000000-0000-0000-0000-0000000000b1', 'tok-b-0123456789abcdef', '{}')
ON CONFLICT DO NOTHING;
INSERT INTO public.user_monitored_regions (user_id, region_id) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'a0000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-0000000000b1', 'a0000000-0000-0000-0000-000000000001')
ON CONFLICT DO NOTHING;
INSERT INTO public.alerts (region_id, title, body, severity, metadata)
VALUES ('a0000000-0000-0000-0000-000000000001', 'Ar muito ruim em Manaus', 'Aviso de teste.', 'HIGH', '{"origem":"ar-cams","iqar":150}');
INSERT INTO public.ar_regiao (region_id, iqar, acima) VALUES ('a0000000-0000-0000-0000-000000000001', 150, 3)
ON CONFLICT DO NOTHING;
DELETE FROM public.push_fila;
