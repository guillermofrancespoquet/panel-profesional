-- ============================================================
-- DIARIO DE COMIDAS DEL CLIENTE (foto o nota + comentario del profesional)
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere haber ejecutado antes `supabase_clientes_acceso.sql` y `supabase_registro_cliente.sql`
-- (usa es_profesional(), cliente_deportista_id() y el bucket privado `fotos-clientes`, cuyas políticas ya
-- permiten a cada cliente subir y ver lo que está en su carpeta `<id>/…`: las fotos de comidas van a `<id>/comidas/…`,
-- así que NO hace falta tocar Storage).
--
-- El cliente anota una comida (momento, foto y/o una nota corta) desde su área; el profesional la ve en la ficha
-- (Seguimiento → «Diario de comidas»), la comenta y el cliente ve el comentario.
--  · `comidas_cliente`: una fila por comida. Tabla «solo profesional»; el cliente solo entra por las funciones `cliente_*`.
--  · Solo se pueden anotar comidas de los últimos 14 días (ni futuras).
--  · Si el profesional escribe o cambia el comentario, un disparador marca `comentario_leido = false` para que
--    el cliente vea el aviso «comentarios nuevos»; al abrir su diario se marcan como leídos.
-- ============================================================

create table if not exists public.comidas_cliente (
  id               bigint generated always as identity primary key,
  deportista_id    bigint not null references public.clientes_deportivos (id) on delete cascade,
  fecha            date   not null,
  momento          text   not null default 'otro' check (momento in ('desayuno', 'media_manana', 'comida', 'merienda', 'cena', 'otro')),
  nota             text   check (nota is null or char_length(nota) <= 300),
  foto_path        text   unique check (foto_path is null or char_length(foto_path) <= 300),
  comentario       text   check (comentario is null or char_length(comentario) <= 300),
  comentario_fecha timestamptz,
  comentario_leido boolean not null default true,
  creado           timestamptz not null default now(),
  check (nota is not null or foto_path is not null)
);
create index if not exists comidas_cliente_dep_fecha on public.comidas_cliente (deportista_id, fecha desc, id desc);

alter table public.comidas_cliente enable row level security;
drop policy if exists "solo profesional" on public.comidas_cliente;
create policy "solo profesional" on public.comidas_cliente
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());

-- Cuando cambia el comentario del profesional: fecha nueva y «sin leer» para el cliente.
create or replace function public.comidas_cliente_comentario()
returns trigger
language plpgsql
as $$
begin
  if new.comentario is distinct from old.comentario then
    new.comentario := nullif(btrim(new.comentario), '');
    new.comentario_fecha := case when new.comentario is null then null else now() end;
    new.comentario_leido := (new.comentario is null);
  end if;
  return new;
end $$;
drop trigger if exists comidas_cliente_comentario on public.comidas_cliente;
create trigger comidas_cliente_comentario before update on public.comidas_cliente
  for each row execute function public.comidas_cliente_comentario();

-- Funciones del cliente --------------------------------------------------------------------------------
-- Sus comidas de los últimos 30 días. `dep` es la carpeta del cliente en el bucket (la app sube a `<dep>/comidas/…`).
create or replace function public.cliente_mis_comidas()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'dep', public.cliente_deportista_id(),
           'comidas', coalesce((select jsonb_agg(jsonb_build_object(
                                  'id', c.id, 'fecha', c.fecha, 'momento', c.momento, 'nota', c.nota, 'foto_path', c.foto_path,
                                  'comentario', c.comentario, 'comentario_fecha', c.comentario_fecha, 'comentario_leido', c.comentario_leido,
                                  'creado', c.creado) order by c.fecha desc, c.id desc)
                                from public.comidas_cliente c
                               where c.deportista_id = public.cliente_deportista_id()
                                 and c.fecha >= (now() at time zone 'Europe/Madrid')::date - 30), '[]'::jsonb))
$$;

-- Anotar una comida (la foto, si hay, ya está subida al bucket dentro de `<dep>/comidas/`).
create or replace function public.cliente_registrar_comida(p_fecha date, p_momento text, p_nota text, p_path text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  dep   bigint := public.cliente_deportista_id();
  hoy   date   := (now() at time zone 'Europe/Madrid')::date;
  nota  text   := nullif(btrim(coalesce(p_nota, '')), '');
  ruta  text   := nullif(btrim(coalesce(p_path, '')), '');
  fila  public.comidas_cliente;
begin
  if dep is null then raise exception 'sin acceso'; end if;
  if p_fecha is null or p_fecha > hoy or p_fecha < hoy - 14 then raise exception 'fecha no válida'; end if;
  if nota is null and ruta is null then raise exception 'falta la foto o la nota'; end if;
  if nota is not null and char_length(nota) > 300 then raise exception 'nota demasiado larga'; end if;
  if ruta is not null and (ruta not like dep::text || '/comidas/%' or length(ruta) > 300) then raise exception 'ruta no válida'; end if;
  if (select count(*) from public.comidas_cliente where deportista_id = dep and fecha = p_fecha) >= 20 then raise exception 'demasiadas comidas ese día'; end if;
  insert into public.comidas_cliente (deportista_id, fecha, momento, nota, foto_path)
  values (dep, p_fecha, case when p_momento in ('desayuno', 'media_manana', 'comida', 'merienda', 'cena') then p_momento else 'otro' end, nota, ruta)
  returning * into fila;
  return jsonb_build_object('id', fila.id, 'fecha', fila.fecha, 'momento', fila.momento, 'nota', fila.nota, 'foto_path', fila.foto_path,
                            'comentario', null, 'comentario_fecha', null, 'comentario_leido', true, 'creado', fila.creado);
end $$;

-- Borra la fila y devuelve la ruta de la foto para que la app quite también el archivo del bucket.
create or replace function public.cliente_borrar_comida(p_id bigint)
returns text
language sql
security definer
set search_path = public
as $$
  delete from public.comidas_cliente where id = p_id and deportista_id = public.cliente_deportista_id() returning foto_path
$$;

-- Al abrir su diario, el cliente marca como leídos los comentarios nuevos.
create or replace function public.cliente_marcar_comentarios_leidos()
returns void
language sql
security definer
set search_path = public
as $$
  update public.comidas_cliente set comentario_leido = true
   where deportista_id = public.cliente_deportista_id() and not comentario_leido
$$;

revoke all on function public.cliente_mis_comidas() from public, anon;
revoke all on function public.cliente_registrar_comida(date, text, text, text) from public, anon;
revoke all on function public.cliente_borrar_comida(bigint) from public, anon;
revoke all on function public.cliente_marcar_comentarios_leidos() from public, anon;
grant execute on function public.cliente_mis_comidas() to authenticated;
grant execute on function public.cliente_registrar_comida(date, text, text, text) to authenticated;
grant execute on function public.cliente_borrar_comida(bigint) to authenticated;
grant execute on function public.cliente_marcar_comentarios_leidos() to authenticated;

-- Comprobación (opcional):  select id, deportista_id, fecha, momento, comentario is not null as comentada from public.comidas_cliente order by creado desc;
-- Marcha atrás: drop table public.comidas_cliente;
--   drop function public.cliente_mis_comidas(), public.cliente_registrar_comida(date, text, text, text), public.cliente_borrar_comida(bigint),
--     public.cliente_marcar_comentarios_leidos(), public.comidas_cliente_comentario();
