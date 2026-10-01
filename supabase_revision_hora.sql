-- ============================================================
-- HORA DE LA PRÓXIMA REVISIÓN (para el aviso del cliente y «Añadir al calendario»)
-- ============================================================
-- Ejecutar en Supabase → SQL Editor DESPUÉS de supabase_formularios.sql. Es ADITIVO: añade una columna y vuelve a definir
-- `cliente_mi_ficha` (la misma de supabase_formularios.sql + `proxima_revision_hora`; esta versión sustituye a la anterior).
-- Sin ejecutarlo, el panel sigue funcionando y el cliente ve la fecha sin hora.
-- ============================================================

alter table public.clientes_deportivos add column if not exists proxima_revision_hora text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'clientes_deportivos_revision_hora_fmt') then
    alter table public.clientes_deportivos add constraint clientes_deportivos_revision_hora_fmt
      check (proxima_revision_hora is null or proxima_revision_hora ~ '^([01][0-9]|2[0-3]):[0-5][0-9]');
  end if;
end $$;

create or replace function public.cliente_mi_ficha()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'nombre', d.nombre, 'deporte', d.deporte, 'objetivo', d.objetivo,
           'plan_url', d.plan_url, 'proxima_revision', d.proxima_revision,
           'proxima_revision_hora', left(d.proxima_revision_hora, 5),
           'forms', jsonb_build_object(
             'inicial_hecho',   d.formularios->'inicial'->>'hecho',
             'anamnesis_hecho', d.formularios->'anamnesis'->>'hecho',
             'seguimiento_activo', coalesce((d.formularios->'seguimiento'->>'activo')::boolean, false),
             'seguimiento_ultimo', d.formularios->'seguimiento'->>'ultimo',
             'seguimiento_pendiente',
               coalesce((d.formularios->'seguimiento'->>'activo')::boolean, false)
               and (nullif(d.formularios->'seguimiento'->>'ultimo', '') is null
                    or (d.formularios->'seguimiento'->>'ultimo')::date
                       < date_trunc('week', now() at time zone 'Europe/Madrid')::date)
           ))
    from public.clientes_deportivos d
   where d.id = public.cliente_deportista_id()
$$;

revoke all on function public.cliente_mi_ficha() from public, anon;
grant execute on function public.cliente_mi_ficha() to authenticated;

-- Comprobación (opcional):  select id, nombre, proxima_revision, proxima_revision_hora from public.clientes_deportivos;
-- Marcha atrás: alter table public.clientes_deportivos drop column proxima_revision_hora;  (y volver a ejecutar el bloque de cliente_mi_ficha de supabase_formularios.sql)
