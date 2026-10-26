-- ============================================================
-- SEGURIDAD · PASO 3 — Endurecimiento tras la revisión de seguridad (26 oct 2026)
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez. Va DESPUÉS de todos los demás
-- (de `supabase_registro_cliente.sql`, `supabase_diario_comidas.sql` y `supabase_notificaciones.sql`, cuyas funciones sustituye por
-- la versión endurecida: esos tres archivos ya llevan los mismos cambios, así que ejecutar uno de ellos después de este no deshace nada).
--
-- Qué cambia (nada de lo que ve o hace el profesional o el cliente en el uso normal):
--  1) Rutas de archivos del cliente: se rechazan «..», «.» como carpeta, «//», contrabarras y caracteres de control
--     (`cliente_registrar_foto`, `cliente_registrar_comida`).
--  2) Un cliente no puede registrar más de 400 fotos (`cliente_registrar_foto`).
--  3) Avisos al móvil: solo se aceptan direcciones de los servicios de notificaciones de los navegadores (Chrome/Edge/Android,
--     Firefox, Safari, Windows) y como mucho 5 dispositivos por cliente (`cliente_guardar_push`). Antes valía cualquier https://…,
--     y la Edge Function habría hecho una petición a esa dirección cada lunes.
--  4) Bucket `fotos-clientes`: solo imágenes (jpeg, png, webp) y máximo 10 MB por archivo. La app ya reduce y sube JPEG.
--  5) Privilegios: se quita a `anon` todo acceso directo a las tablas de `public` y a `anon`/`authenticated` los permisos de
--     TRUNCATE, REFERENCES y TRIGGER (la RLS ya impedía leer o escribir, esto es una segunda barrera). Las tablas nuevas nacen sin
--     acceso para `anon`. Las funciones `m3m_*` (Método 3M) siguen siendo llamables por `anon`, que es lo que necesitan.
--  6) La función disparador `comidas_cliente_comentario()` deja de ser ejecutable por nadie desde fuera.
-- ============================================================

-- 1) y 2) y 3): funciones endurecidas -------------------------------------------------------------------------------
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
  if ruta is not null and (ruta not like dep::text || '/comidas/%' or length(ruta) > 300 or not public.cliente_ruta_valida(ruta)) then raise exception 'ruta no válida'; end if;
  if (select count(*) from public.comidas_cliente where deportista_id = dep and fecha = p_fecha) >= 20 then raise exception 'demasiadas comidas ese día'; end if;
  insert into public.comidas_cliente (deportista_id, fecha, momento, nota, foto_path)
  values (dep, p_fecha, case when p_momento in ('desayuno', 'media_manana', 'comida', 'merienda', 'cena') then p_momento else 'otro' end, nota, ruta)
  returning * into fila;
  return jsonb_build_object('id', fila.id, 'fecha', fila.fecha, 'momento', fila.momento, 'nota', fila.nota, 'foto_path', fila.foto_path,
                            'comentario', null, 'comentario_fecha', null, 'comentario_leido', true, 'creado', fila.creado);
end $$;

create or replace function public.cliente_guardar_push(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_dep bigint := public.cliente_deportista_id();
begin
  if v_dep is null then raise exception 'sin acceso'; end if;
  -- Solo los servicios de notificaciones de los navegadores (si no, la Edge Function haría peticiones a la dirección que mande el cliente)
  if p_endpoint is null or char_length(p_endpoint) not between 20 and 1000
     or p_endpoint !~ '^https://(fcm\.googleapis\.com|(updates\.)?push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+(\.[a-z0-9-]+)*\.notify\.windows\.com)/[^\s]+$' then
    raise exception 'endpoint no válido';
  end if;
  if (select count(*) from public.push_suscripciones where deportista_id = v_dep and endpoint <> p_endpoint) >= 5 then
    raise exception 'demasiados dispositivos';
  end if;
  -- Si el mismo dispositivo cambia de cuenta, el aviso pasa a la última que lo activó.
  insert into public.push_suscripciones (deportista_id, endpoint) values (v_dep, p_endpoint)
  on conflict (endpoint) do update set deportista_id = excluded.deportista_id;
end $$;

-- 4) Bucket de fotos: solo imágenes y 10 MB ----------------------------------------------------------------------------
update storage.buckets
   set file_size_limit = 10485760,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id = 'fotos-clientes';

-- 5) Privilegios ------------------------------------------------------------------------------------------------------
revoke all on all tables in schema public from anon;
revoke truncate, references, trigger on all tables in schema public from authenticated;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke execute on functions from anon;

-- 6) Disparador interno -----------------------------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.comidas_cliente_comentario()') is not null then
    revoke all on function public.comidas_cliente_comentario() from public, anon, authenticated;
  end if;
end $$;

-- ============================================================
-- Comprobación: ejecuta `supabase_diagnostico_seguridad.sql` (solo lectura); no debe salir ninguna fila «REVISAR».
-- Marcha atrás: grant all on all tables in schema public to anon; update storage.buckets set file_size_limit = null,
--   allowed_mime_types = null where id = 'fotos-clientes';  (las funciones se restauran ejecutando de nuevo los tres SQL originales de arriba
--   de una versión anterior del repositorio).
-- ============================================================
