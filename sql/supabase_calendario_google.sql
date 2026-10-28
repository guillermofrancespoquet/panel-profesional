-- Calendario de Google: id del evento de cada cita (para poder moverlo o borrarlo después).
-- Va junto a la Edge Function «calendario-google» (sql/supabase_funcion_calendario_google.ts). Sin esta columna el panel
-- envía igualmente las citas a Google, pero avisa de que, al mover una, se duplicaría el evento.
-- `citas` ya es «solo profesional» (RLS): la columna nueva hereda ese acceso; el cliente no lee nunca esta tabla.
alter table public.citas add column if not exists google_event_id text;
