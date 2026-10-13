-- ============================================================
-- NOTA DEL PROFESIONAL PARA EL CLIENTE
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- ORDEN: ejecutar DESPUÉS de supabase_seguimiento.sql (la función `cliente_mi_ficha` de aquí es la misma
-- de ese archivo más la nota; esta versión sustituye a la anterior).
--
-- El profesional escribe un mensaje corto en la ficha («Nota para el cliente») y el cliente lo ve arriba en
-- su área. Va aparte de las notas privadas, que el cliente nunca recibe.
-- ============================================================

alter table public.clientes_deportivos add column if not exists nota_cliente text;
alter table public.clientes_deportivos add column if not exists nota_cliente_fecha date;

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
           'nota', case when coalesce(btrim(d.nota_cliente), '') = '' then null
                        else jsonb_build_object('texto', d.nota_cliente, 'fecha', d.nota_cliente_fecha) end,
           'forms', jsonb_build_object(
             'inicial_hecho',   d.formularios->'inicial'->>'hecho',
             'anamnesis_hecho', d.formularios->'anamnesis'->>'hecho',
             'seguimiento_activo', coalesce((d.formularios->'seguimiento'->>'activo')::boolean, false),
             'seguimiento_propio', true,
             'seguimiento_ultimo', coalesce((select max(s.semana)::text from public.seguimientos s where s.deportista_id = d.id),
                                            d.formularios->'seguimiento'->>'ultimo'),
             -- pendiente = activo y aún sin enviar el de esta semana (lunes a domingo, hora de Madrid)
             'seguimiento_pendiente',
               coalesce((d.formularios->'seguimiento'->>'activo')::boolean, false)
               and not exists (select 1 from public.seguimientos s
                                where s.deportista_id = d.id
                                  and s.semana = date_trunc('week', now() at time zone 'Europe/Madrid')::date)
           ))
    from public.clientes_deportivos d
   where d.id = public.cliente_deportista_id()
$$;

revoke all on function public.cliente_mi_ficha() from public, anon;
grant execute on function public.cliente_mi_ficha() to authenticated;

-- Comprobación (opcional):  select id, nombre, nota_cliente, nota_cliente_fecha from public.clientes_deportivos;
-- Marcha atrás: alter table public.clientes_deportivos drop column nota_cliente, drop column nota_cliente_fecha;
--   (y volver a ejecutar el bloque de cliente_mi_ficha de supabase_seguimiento.sql)
