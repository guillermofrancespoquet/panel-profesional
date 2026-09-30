-- ============================================================
-- FORMULARIOS DEL CLIENTE (Cuestionario inicial, Anamnesis y Seguimiento semanal)
-- ============================================================
-- Ejecutar en Supabase → SQL Editor. Es ADITIVO: solo añade una columna y una función, y amplía
-- `cliente_mi_ficha` con un apartado nuevo `forms`. No quita ningún acceso.
--
-- Cómo funciona: los formularios son de Google Forms (los enlaces van en cliente.html). Google no avisa
-- cuando alguien contesta, así que la marca de «hecho» la pone el propio cliente con un botón
-- («Ya lo he enviado») o la pones tú en la ficha del deportista. Se guarda en
-- `clientes_deportivos.formularios` (jsonb):
--   { "inicial":     { "hecho": "2026-10-02" },
--     "anamnesis":   { "hecho": "2026-10-02" },
--     "seguimiento": { "activo": true, "ultimo": "2026-10-02" } }
-- El seguimiento solo aparece si lo activas para ese cliente y vuelve a quedar pendiente cada lunes.
-- ============================================================

alter table public.clientes_deportivos
  add column if not exists formularios jsonb not null default '{}'::jsonb;

-- Ficha del cliente: la misma de antes + el estado de sus formularios (sin notas privadas).
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
           'forms', jsonb_build_object(
             'inicial_hecho',   d.formularios->'inicial'->>'hecho',
             'anamnesis_hecho', d.formularios->'anamnesis'->>'hecho',
             'seguimiento_activo', coalesce((d.formularios->'seguimiento'->>'activo')::boolean, false),
             'seguimiento_ultimo', d.formularios->'seguimiento'->>'ultimo',
             -- pendiente = activo y aún no enviado desde el lunes de esta semana (hora de Madrid)
             'seguimiento_pendiente',
               coalesce((d.formularios->'seguimiento'->>'activo')::boolean, false)
               and (nullif(d.formularios->'seguimiento'->>'ultimo', '') is null
                    or (d.formularios->'seguimiento'->>'ultimo')::date
                       < date_trunc('week', now() at time zone 'Europe/Madrid')::date)
           ))
    from public.clientes_deportivos d
   where d.id = public.cliente_deportista_id()
$$;

-- El cliente marca un formulario como enviado (solo el suyo y solo esos tres tipos).
create or replace function public.cliente_marcar_formulario(p_tipo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint := public.cliente_deportista_id();
  hoy  text   := to_char((now() at time zone 'Europe/Madrid')::date, 'YYYY-MM-DD');
begin
  if v_id is null then raise exception 'no autorizado'; end if;
  if p_tipo in ('inicial', 'anamnesis') then
    update public.clientes_deportivos
       set formularios = jsonb_set(coalesce(formularios, '{}'::jsonb), array[p_tipo], jsonb_build_object('hecho', hoy))
     where id = v_id;
  elsif p_tipo = 'seguimiento' then
    update public.clientes_deportivos
       set formularios = jsonb_set(coalesce(formularios, '{}'::jsonb), '{seguimiento}',
                                   coalesce(formularios->'seguimiento', '{}'::jsonb) || jsonb_build_object('ultimo', hoy))
     where id = v_id and coalesce((formularios->'seguimiento'->>'activo')::boolean, false);
  else
    raise exception 'tipo no valido';
  end if;
end $$;

revoke all on function public.cliente_mi_ficha() from public, anon;
revoke all on function public.cliente_marcar_formulario(text) from public, anon;
grant execute on function public.cliente_mi_ficha() to authenticated;
grant execute on function public.cliente_marcar_formulario(text) to authenticated;

-- ============================================================
-- Comprobación (opcional):
--   select id, nombre, formularios from public.clientes_deportivos limit 5;
-- Marcha atrás de la columna (solo si hiciera falta): alter table public.clientes_deportivos drop column formularios;
--   (y volver a ejecutar el bloque de cliente_mi_ficha de supabase_clientes_acceso.sql)
-- ============================================================
