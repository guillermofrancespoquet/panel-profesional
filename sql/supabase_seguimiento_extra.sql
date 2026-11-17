-- ============================================================
-- PREGUNTA PROPIA EN EL SEGUIMIENTO SEMANAL (opcional, por cliente)
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere `supabase_clientes_acceso.sql` (usa es_profesional() y cliente_deportista_id()) y `supabase_seguimiento.sql`.
--
-- Si el profesional escribe una pregunta en la ficha del cliente (Seguimiento → «Pregunta propia»), el seguimiento semanal de ese cliente
-- añade una escala de 0 a 10 con esa pregunta (por ejemplo «Dolor de rodilla»). Si no escribe nada, el cliente no ve ninguna pregunta nueva.
--  · La pregunta vive en `clientes_deportivos.seguimiento_extra` ({"pregunta": "...", "desde": "AAAA-MM-DD"}); la ve el cliente solo por
--    `cliente_mi_pregunta()`. No se toca `cliente_mi_ficha` ni `cliente_guardar_seguimiento`.
--  · La respuesta va a `seguimientos_extra` (una fila por cliente y semana, con una copia de la pregunta: si el profesional la cambia,
--    las respuestas antiguas conservan la suya). Tabla «solo profesional».
-- Marcha atrás:  drop table public.seguimientos_extra cascade; alter table public.clientes_deportivos drop column seguimiento_extra;
-- ============================================================

alter table public.clientes_deportivos add column if not exists seguimiento_extra jsonb;
do $$ begin
  alter table public.clientes_deportivos add constraint clientes_deportivos_seg_extra_chk check (
    seguimiento_extra is null or (jsonb_typeof(seguimiento_extra) = 'object' and char_length(coalesce(seguimiento_extra->>'pregunta', '')) <= 80));
exception when duplicate_object then null; end $$;

create table if not exists public.seguimientos_extra (
  id            bigint generated always as identity primary key,
  deportista_id bigint not null references public.clientes_deportivos (id) on delete cascade,
  semana        date   not null,                                            -- lunes (Madrid) de la semana, como `seguimientos`
  pregunta      text   not null check (char_length(pregunta) between 1 and 80),
  valor         smallint not null check (valor between 0 and 10),
  creado        timestamptz not null default now(),
  actualizado   timestamptz not null default now(),
  unique (deportista_id, semana)
);
alter table public.seguimientos_extra enable row level security;
drop policy if exists "solo profesional" on public.seguimientos_extra;
create policy "solo profesional" on public.seguimientos_extra
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());

-- La pregunta del cliente, lo que ya contestó esta semana y sus últimas respuestas a esa misma pregunta. Sin pregunta → null.
create or replace function public.cliente_mi_pregunta()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_dep bigint := public.cliente_deportista_id();
  v_preg text; v_sem date := date_trunc('week', now() at time zone 'Europe/Madrid')::date;
begin
  if v_dep is null then return null; end if;
  select nullif(btrim(seguimiento_extra->>'pregunta'), '') into v_preg from public.clientes_deportivos where id = v_dep;
  if v_preg is null then return null; end if;
  return jsonb_build_object(
    'pregunta', v_preg,
    'valor', (select valor from public.seguimientos_extra where deportista_id = v_dep and semana = v_sem and pregunta = v_preg),
    'serie', coalesce((select jsonb_agg(jsonb_build_object('semana', semana, 'valor', valor) order by semana)
                         from (select semana, valor from public.seguimientos_extra
                                where deportista_id = v_dep and pregunta = v_preg order by semana desc limit 12) s), '[]'::jsonb));
end $$;

-- Guarda (o actualiza) la respuesta de esta semana. Falla si el cliente no tiene pregunta puesta.
create or replace function public.cliente_guardar_extra(p_valor int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dep bigint := public.cliente_deportista_id();
  v_preg text; v_sem date := date_trunc('week', now() at time zone 'Europe/Madrid')::date;
begin
  if v_dep is null then raise exception 'sin acceso'; end if;
  if p_valor is null or p_valor not between 0 and 10 then raise exception 'valor no válido'; end if;
  select nullif(btrim(seguimiento_extra->>'pregunta'), '') into v_preg from public.clientes_deportivos where id = v_dep;
  if v_preg is null then raise exception 'sin pregunta'; end if;
  insert into public.seguimientos_extra (deportista_id, semana, pregunta, valor) values (v_dep, v_sem, v_preg, p_valor)
  on conflict (deportista_id, semana) do update set pregunta = excluded.pregunta, valor = excluded.valor, actualizado = now();
end $$;

revoke all on function public.cliente_mi_pregunta() from public, anon;
revoke all on function public.cliente_guardar_extra(int) from public, anon;
grant execute on function public.cliente_mi_pregunta() to authenticated;
grant execute on function public.cliente_guardar_extra(int) to authenticated;
