-- ============================================================
-- PLAN DE COMPETICIÓN VISIBLE PARA EL CLIENTE
-- ============================================================
-- Ejecutar en Supabase → SQL Editor. Es ADITIVO: añade dos columnas a `planes_competicion` y una función.
--
-- Cómo funciona: desde Plan de competición → «Compartir con el cliente», el panel guarda junto al plan una copia ya
-- calculada (`snapshot`: avisos y bloques antes / durante / después) y marca `visible_cliente`. El cliente la lee por
-- `cliente_mis_planes()`, que solo devuelve los planes compartidos de SU deportista y solo hasta el día siguiente a la
-- competición (margen de un día porque el plan incluye la recuperación). Pasado ese día el cliente deja de verlo; el plan
-- sigue guardado en la ficha del profesional.
-- ============================================================

alter table public.planes_competicion add column if not exists visible_cliente boolean not null default false;
alter table public.planes_competicion add column if not exists snapshot jsonb;

create or replace function public.cliente_mis_planes()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'fecha', p.fecha, 'hora', p.hora_inicio, 'evento', p.evento,
           'deporte', p.deporte, 'snapshot', p.snapshot) order by p.fecha, p.id), '[]'::jsonb)
    from public.planes_competicion p
   where p.deportista_id = public.cliente_deportista_id()
     and p.visible_cliente
     and p.snapshot is not null
     and p.fecha >= (now() at time zone 'Europe/Madrid')::date - 1
$$;

revoke all on function public.cliente_mis_planes() from public, anon;
grant execute on function public.cliente_mis_planes() to authenticated;

-- Comprobación (opcional):
--   select id, fecha, evento, visible_cliente, snapshot is not null as tiene_copia from public.planes_competicion order by fecha desc;
-- Marcha atrás: alter table public.planes_competicion drop column visible_cliente, drop column snapshot; drop function public.cliente_mis_planes();
