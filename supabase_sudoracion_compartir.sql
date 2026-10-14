-- ============================================================
-- TEST DE SUDORACIÓN VISIBLE PARA EL CLIENTE
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere `supabase_sudoracion.sql` y `supabase_clientes_acceso.sql` (usa cliente_deportista_id()).
--
-- Desde la ficha del deportista (Mediciones → Test de sudoración) el profesional pulsa «Compartir con el cliente» en cada test.
-- El cliente lo ve en «Mis datos» con un resumen explicado en lenguaje sencillo. Solo recibe lo necesario para esa
-- explicación (fecha, actividad, condiciones y resultados): NUNCA las notas ni la ropa ni los datos de la balanza.
-- ============================================================

alter table public.tests_sudoracion add column if not exists visible_cliente boolean not null default false;

create or replace function public.cliente_mis_tests_sudoracion()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'fecha', t.fecha, 'actividad', t.actividad, 'duracion_min', t.duracion_min,
           'intensidad', t.intensidad, 'temperatura_c', t.temperatura_c, 'humedad_pct', t.humedad_pct,
           'ambiente', t.ambiente, 'medido', t.sodio_mmol_l is not null, 'resultados', t.resultados)
         order by t.fecha, t.id), '[]'::jsonb)
    from public.tests_sudoracion t
   where t.deportista_id = public.cliente_deportista_id()
     and t.visible_cliente
$$;

revoke all on function public.cliente_mis_tests_sudoracion() from public, anon;
grant execute on function public.cliente_mis_tests_sudoracion() to authenticated;

-- Comprobación (opcional):  select id, fecha, visible_cliente from public.tests_sudoracion order by fecha desc;
-- Marcha atrás: alter table public.tests_sudoracion drop column visible_cliente; drop function public.cliente_mis_tests_sudoracion();
