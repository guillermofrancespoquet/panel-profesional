-- ============================================================
-- AUTORREGISTRO DEL CLIENTE: PESO Y FOTOS
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere haber ejecutado antes `supabase_clientes_acceso.sql` (usa es_profesional() y cliente_deportista_id()).
--
-- El cliente anota su peso cuando quiera y sube fotos de progreso desde su área; el profesional lo ve en la ficha.
--  · `pesos_cliente`: un peso por deportista y día (si anota otro el mismo día, se sustituye).
--  · `fotos_cliente`: una fila por foto (la imagen va a un bucket PRIVADO distinto: `fotos-clientes`).
--  · Las tablas son «solo profesional»; el cliente solo entra por las funciones `cliente_*` de abajo.
--  · Bucket `fotos-clientes`: cada cliente solo puede subir, ver y borrar lo que está en su carpeta (`<id>/…`);
--    el profesional lo ve todo. No toca las políticas del bucket `deportistas-docs`.
--    (Si ya ejecutaste una versión anterior de este archivo, vuelve a ejecutar este: sustituye las políticas por unas que funcionan.)
-- Los pesos son autodeclarados: en el panel salen en una serie aparte y etiquetada, nunca mezclados con la antropometría.
-- ============================================================

create table if not exists public.pesos_cliente (
  id            bigint generated always as identity primary key,
  deportista_id bigint not null references public.clientes_deportivos (id) on delete cascade,
  fecha         date   not null,
  peso          numeric(5,2) not null check (peso between 20 and 400),
  creado        timestamptz not null default now(),
  unique (deportista_id, fecha)
);

create table if not exists public.fotos_cliente (
  id            bigint generated always as identity primary key,
  deportista_id bigint not null references public.clientes_deportivos (id) on delete cascade,
  fecha         date   not null,
  vista         text   not null default 'otra' check (vista in ('frente', 'lado', 'espalda', 'otra')),
  path          text   not null unique,
  creado        timestamptz not null default now()
);
create index if not exists fotos_cliente_dep_fecha on public.fotos_cliente (deportista_id, fecha desc);

alter table public.pesos_cliente enable row level security;
alter table public.fotos_cliente enable row level security;
drop policy if exists "solo profesional" on public.pesos_cliente;
drop policy if exists "solo profesional" on public.fotos_cliente;
create policy "solo profesional" on public.pesos_cliente
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());
create policy "solo profesional" on public.fotos_cliente
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());

-- Bucket privado de fotos ------------------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('fotos-clientes', 'fotos-clientes', false)
  on conflict (id) do update set public = false;

-- OJO: `cliente_deportista_id()` está cerrada a `authenticated` a propósito (solo la usan funciones SECURITY DEFINER),
-- así que las políticas NO pueden llamarla directamente: lo hace esta función auxiliar, igual que `puede_ver_archivo`.
create or replace function public.puede_usar_foto(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.es_profesional()
      or exists (select 1 where p_name like public.cliente_deportista_id()::text || '/%')
$$;
revoke all on function public.puede_usar_foto(text) from public, anon;
grant execute on function public.puede_usar_foto(text) to authenticated;

drop policy if exists "fotos-clientes: leer" on storage.objects;
drop policy if exists "fotos-clientes: subir" on storage.objects;
drop policy if exists "fotos-clientes: borrar" on storage.objects;
create policy "fotos-clientes: leer" on storage.objects
  for select to authenticated
  using (bucket_id = 'fotos-clientes' and public.puede_usar_foto(name));
create policy "fotos-clientes: subir" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'fotos-clientes' and public.puede_usar_foto(name));
create policy "fotos-clientes: borrar" on storage.objects
  for delete to authenticated
  using (bucket_id = 'fotos-clientes' and public.puede_usar_foto(name));

-- Funciones del cliente --------------------------------------------------------------------------------
-- Guardar un peso (hoy o un día reciente; un peso por día).
create or replace function public.cliente_guardar_peso(p_fecha date, p_peso numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  dep   bigint := public.cliente_deportista_id();
  hoy   date   := (now() at time zone 'Europe/Madrid')::date;
  fila  public.pesos_cliente;
begin
  if dep is null then raise exception 'sin acceso'; end if;
  if p_peso is null or p_peso < 20 or p_peso > 400 then raise exception 'peso no válido'; end if;
  if p_fecha is null or p_fecha > hoy or p_fecha < hoy - 366 then raise exception 'fecha no válida'; end if;
  insert into public.pesos_cliente (deportista_id, fecha, peso) values (dep, p_fecha, round(p_peso, 1))
  on conflict (deportista_id, fecha) do update set peso = excluded.peso, creado = now()
  returning * into fila;
  return jsonb_build_object('id', fila.id, 'fecha', fila.fecha, 'peso', fila.peso);
end $$;

create or replace function public.cliente_mis_pesos()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'fecha', p.fecha, 'peso', p.peso) order by p.fecha), '[]'::jsonb)
    from public.pesos_cliente p
   where p.deportista_id = public.cliente_deportista_id()
$$;

create or replace function public.cliente_borrar_peso(p_id bigint)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.pesos_cliente where id = p_id and deportista_id = public.cliente_deportista_id()
$$;

-- Rutas de archivos que escribe el cliente: sin «..» ni «.» como carpeta, sin «//», sin contrabarras ni caracteres de control.
create or replace function public.cliente_ruta_valida(p_ruta text)
returns boolean
language sql
immutable
as $$
  select p_ruta is not null
     and p_ruta !~ '(^|/)\.\.?(/|$)'
     and p_ruta !~ '//'
     and position(E'\\' in p_ruta) = 0
     and p_ruta !~ '[[:cntrl:]]'
$$;
revoke all on function public.cliente_ruta_valida(text) from public, anon, authenticated;

-- Registrar una foto ya subida al bucket (la ruta debe empezar por la carpeta del propio cliente; máximo 400 por cliente).
create or replace function public.cliente_registrar_foto(p_path text, p_fecha date, p_vista text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  dep   bigint := public.cliente_deportista_id();
  hoy   date   := (now() at time zone 'Europe/Madrid')::date;
  fila  public.fotos_cliente;
begin
  if dep is null then raise exception 'sin acceso'; end if;
  if p_path is null or p_path not like dep::text || '/%' or length(p_path) > 300 or not public.cliente_ruta_valida(p_path) then raise exception 'ruta no válida'; end if;
  if (select count(*) from public.fotos_cliente where deportista_id = dep) >= 400 then raise exception 'demasiadas fotos'; end if;
  if p_fecha is null or p_fecha > hoy or p_fecha < hoy - 366 then raise exception 'fecha no válida'; end if;
  insert into public.fotos_cliente (deportista_id, fecha, vista, path)
  values (dep, p_fecha, case when p_vista in ('frente', 'lado', 'espalda') then p_vista else 'otra' end, p_path)
  returning * into fila;
  return jsonb_build_object('id', fila.id, 'fecha', fila.fecha, 'vista', fila.vista, 'path', fila.path);
end $$;

create or replace function public.cliente_mis_fotos()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  -- `dep` es la carpeta del cliente en el bucket (la app sube a `<dep>/…`)
  select jsonb_build_object(
           'dep', public.cliente_deportista_id(),
           'fotos', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'fecha', f.fecha, 'vista', f.vista, 'path', f.path)
                                               order by f.fecha, f.id)
                                from public.fotos_cliente f
                               where f.deportista_id = public.cliente_deportista_id()), '[]'::jsonb))
$$;

-- Borra la fila y devuelve la ruta para que la app quite también el archivo del bucket.
create or replace function public.cliente_borrar_foto(p_id bigint)
returns text
language sql
security definer
set search_path = public
as $$
  delete from public.fotos_cliente where id = p_id and deportista_id = public.cliente_deportista_id() returning path
$$;

revoke all on function public.cliente_guardar_peso(date, numeric) from public, anon;
revoke all on function public.cliente_mis_pesos() from public, anon;
revoke all on function public.cliente_borrar_peso(bigint) from public, anon;
revoke all on function public.cliente_registrar_foto(text, date, text) from public, anon;
revoke all on function public.cliente_mis_fotos() from public, anon;
revoke all on function public.cliente_borrar_foto(bigint) from public, anon;
grant execute on function public.cliente_guardar_peso(date, numeric) to authenticated;
grant execute on function public.cliente_mis_pesos() to authenticated;
grant execute on function public.cliente_borrar_peso(bigint) to authenticated;
grant execute on function public.cliente_registrar_foto(text, date, text) to authenticated;
grant execute on function public.cliente_mis_fotos() to authenticated;
grant execute on function public.cliente_borrar_foto(bigint) to authenticated;

-- ============================================================
-- COMPROBACIONES (opcionales, una a una)
-- ============================================================
-- select count(*) from public.pesos_cliente;                      -- 0 al principio
-- select id, public from storage.buckets where id = 'fotos-clientes';   -- public = false
-- select policyname, cmd from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'fotos-clientes:%';
--
-- MARCHA ATRÁS: drop table public.pesos_cliente, public.fotos_cliente;
--   drop function public.cliente_guardar_peso(date, numeric), public.cliente_mis_pesos(), public.cliente_borrar_peso(bigint),
--     public.cliente_registrar_foto(text, date, text), public.cliente_mis_fotos(), public.cliente_borrar_foto(bigint);
--   (el bucket y sus políticas se quitan desde Storage)
