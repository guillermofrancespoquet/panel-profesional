-- ============================================================
-- CITAS: MARCAR COMO «HECHA»
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- En la agenda, las citas que ya pasaron tienen un botón ✓ («Marcar como hecha») que registra la consulta
-- en la ficha del deportista y deja marcada la cita. Esta columna guarda esa marca.
-- Sin este SQL el botón registra la consulta igualmente, pero avisa de que no puede marcar la cita.
-- ============================================================

alter table public.citas add column if not exists hecha boolean not null default false;

-- Comprobación (opcional):  select id, cliente, fecha, hecha from public.citas order by fecha desc limit 10;
-- Marcha atrás:  alter table public.citas drop column hecha;
