-- ============================================================
-- ÁREA DE CLIENTES — paso 3 de seguridad (profesional vs cliente)
-- ============================================================
-- Ejecutar en Supabase → SQL Editor, DESPUÉS de haber ejecutado los pasos 1 y 2 de seguridad
-- (supabase_seguridad_1_tokens.sql y supabase_seguridad_2_cerrar.sql) y ANTES de dar acceso a ningún cliente.
--
-- Por qué hace falta: hoy la política de todas las tablas es "cualquier usuario con sesión". En cuanto exista
-- una cuenta de cliente, esa cuenta vería los datos de TODOS los clientes (y tus notas privadas). Este script:
--   1) Marca quién es profesional (tabla `profesionales`); solo esa cuenta puede tocar las tablas y los archivos.
--   2) Crea la tabla `clientes_acceso`: qué cuenta de correo corresponde a qué deportista.
--   3) Crea funciones que devuelven a cada cliente SOLO lo suyo y SOLO lo permitido
--      (ficha básica, resumen de valoraciones y los archivos que tú marques como visibles).
--   4) Cambia las políticas de las tablas y de Storage: profesional = todo; cliente = nada directo.
--
-- ⚠️ ANTES DE EJECUTAR: cambia TU_CORREO@EJEMPLO.COM (apartado 1) por el correo de tu usuario de Supabase.
-- Todo el script se ejecuta como una sola transacción: si algo falla (por ejemplo, no encuentra tu usuario),
-- NO se cambia nada y no te quedas sin acceso.
-- ============================================================

-- 1) Profesionales --------------------------------------------------------------------------------------
create table if not exists public.profesionales (
  user_id uuid primary key references auth.users (id) on delete cascade
);
alter table public.profesionales enable row level security;   -- sin políticas: solo la leen las funciones de abajo
revoke all on public.profesionales from anon, authenticated;

do $$
declare n int;
begin
  insert into public.profesionales (user_id)
  select id from auth.users where lower(email) = lower('TU_CORREO@EJEMPLO.COM')
  on conflict do nothing;

  select count(*) into n from public.profesionales;
  if n = 0 then
    raise exception 'No se ha encontrado tu usuario. Cambia TU_CORREO@EJEMPLO.COM por tu correo de Supabase y vuelve a ejecutar.';
  end if;
end $$;

create or replace function public.es_profesional()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.profesionales where user_id = auth.uid())
$$;
revoke all on function public.es_profesional() from public, anon;
grant execute on function public.es_profesional() to authenticated;

-- 2) Qué cuenta corresponde a qué deportista ------------------------------------------------------------
create table if not exists public.clientes_acceso (
  deportista_id bigint primary key references public.clientes_deportivos (id) on delete cascade,
  user_id       uuid   not null unique references auth.users (id) on delete cascade,
  email         text   not null,
  creado        timestamptz not null default now()
);
alter table public.clientes_acceso enable row level security;
drop policy if exists "solo profesional" on public.clientes_acceso;
create policy "solo profesional" on public.clientes_acceso
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());
revoke all on public.clientes_acceso from anon;
grant select, insert, update, delete on public.clientes_acceso to authenticated;   -- la política de arriba limita el uso al profesional

-- Interna: deportista de la cuenta que hace la petición (null si no es un cliente vinculado).
create or replace function public.cliente_deportista_id()
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select deportista_id from public.clientes_acceso where user_id = auth.uid()
$$;
revoke all on function public.cliente_deportista_id() from public, anon, authenticated;

-- El profesional vincula el correo (ya invitado en Authentication → Users) con un deportista.
create or replace function public.vincular_acceso_cliente(p_deportista bigint, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid;
begin
  if not public.es_profesional() then raise exception 'no autorizado'; end if;
  select id into v_uid from auth.users where lower(email) = lower(trim(p_email)) limit 1;
  if v_uid is null then
    return jsonb_build_object('ok', false, 'motivo', 'usuario_no_existe');
  end if;
  if exists (select 1 from public.profesionales where user_id = v_uid) then
    return jsonb_build_object('ok', false, 'motivo', 'es_profesional');
  end if;
  if exists (select 1 from public.clientes_acceso where user_id = v_uid and deportista_id <> p_deportista) then
    return jsonb_build_object('ok', false, 'motivo', 'ya_vinculado');
  end if;
  insert into public.clientes_acceso (deportista_id, user_id, email)
  values (p_deportista, v_uid, lower(trim(p_email)))
  on conflict (deportista_id) do update set user_id = excluded.user_id, email = excluded.email, creado = now();
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.vincular_acceso_cliente(bigint, text) from public, anon;
grant execute on function public.vincular_acceso_cliente(bigint, text) to authenticated;

create or replace function public.desvincular_acceso_cliente(p_deportista bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.es_profesional() then raise exception 'no autorizado'; end if;
  delete from public.clientes_acceso where deportista_id = p_deportista;
end $$;
revoke all on function public.desvincular_acceso_cliente(bigint) from public, anon;
grant execute on function public.desvincular_acceso_cliente(bigint) to authenticated;

-- 3) Lo que ve el cliente (solo su fila y solo campos permitidos: NO incluye notas privadas) ---------------
create or replace function public.cliente_mi_ficha()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('nombre', d.nombre, 'deporte', d.deporte, 'objetivo', d.objetivo,
                            'plan_url', d.plan_url, 'proxima_revision', d.proxima_revision)
    from public.clientes_deportivos d
   where d.id = public.cliente_deportista_id()
$$;

create or replace function public.cliente_mis_valoraciones()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'fecha', v.fecha, 'resumen', v.resumen) order by v.fecha), '[]'::jsonb)
    from public.antropometria_valoraciones v
   where v.deportista_id = public.cliente_deportista_id()
$$;

-- Solo los archivos que el profesional ha marcado como visibles (`visible_cliente: true` en `archivos`).
create or replace function public.cliente_mis_archivos()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('nombre', a->>'nombre', 'fecha', a->>'fecha', 'path', a->>'path')), '[]'::jsonb)
    from public.clientes_deportivos d,
         jsonb_array_elements(case when jsonb_typeof(d.archivos) = 'array' then d.archivos else '[]'::jsonb end) a
   where d.id = public.cliente_deportista_id()
     and coalesce((a->>'visible_cliente')::boolean, false)
     and coalesce(a->>'path', '') <> ''
$$;

revoke all on function public.cliente_mi_ficha() from public, anon;
revoke all on function public.cliente_mis_valoraciones() from public, anon;
revoke all on function public.cliente_mis_archivos() from public, anon;
grant execute on function public.cliente_mi_ficha() to authenticated;
grant execute on function public.cliente_mis_valoraciones() to authenticated;
grant execute on function public.cliente_mis_archivos() to authenticated;

-- ¿Puede esta cuenta abrir este archivo? Profesional: todos. Cliente: solo los suyos marcados como visibles.
create or replace function public.puede_ver_archivo(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.es_profesional() or exists (
    select 1
      from public.clientes_deportivos d,
           jsonb_array_elements(case when jsonb_typeof(d.archivos) = 'array' then d.archivos else '[]'::jsonb end) a
     where d.id = public.cliente_deportista_id()
       and a->>'path' = p_name
       and coalesce((a->>'visible_cliente')::boolean, false)
  )
$$;
revoke all on function public.puede_ver_archivo(text) from public, anon;
grant execute on function public.puede_ver_archivo(text) to authenticated;

-- 4) Políticas: las tablas pasan de "cualquier usuario con sesión" a "solo profesional" ---------------------
do $$
declare
  t text;
  pol record;
  tablas text[] := array[
    'clientes', 'clientes_deportivos', 'citas', 'recordatorios', 'historial_deportista', 'progresion_cargas',
    'antropometria_perfil', 'antropometria_valoraciones', 'tests_sudoracion', 'planes_competicion'
  ];
begin
  foreach t in array tablas loop
    if to_regclass('public.' || t) is null then
      raise notice 'La tabla % no existe: se omite', t;
      continue;
    end if;
    execute format('alter table public.%I enable row level security', t);
    for pol in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', pol.policyname, t);
    end loop;
    execute format(
      'create policy "solo profesional" on public.%I for all to authenticated using (public.es_profesional()) with check (public.es_profesional())', t);
  end loop;
end $$;

-- Archivos (bucket privado): el profesional lo gestiona todo; el cliente solo puede FIRMAR/ver los suyos visibles.
do $$
declare pol record;
begin
  for pol in
    select policyname from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and (coalesce(qual, '') ilike '%deportistas-docs%' or coalesce(with_check, '') ilike '%deportistas-docs%')
  loop
    execute format('drop policy %I on storage.objects', pol.policyname);
  end loop;
end $$;

create policy "deportistas-docs: leer" on storage.objects
  for select to authenticated
  using (bucket_id = 'deportistas-docs' and public.puede_ver_archivo(name));
create policy "deportistas-docs: subir" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'deportistas-docs' and public.es_profesional());
create policy "deportistas-docs: modificar" on storage.objects
  for update to authenticated
  using (bucket_id = 'deportistas-docs' and public.es_profesional())
  with check (bucket_id = 'deportistas-docs' and public.es_profesional());
create policy "deportistas-docs: borrar" on storage.objects
  for delete to authenticated
  using (bucket_id = 'deportistas-docs' and public.es_profesional());

-- ============================================================
-- COMPROBACIONES (ejecútalas una a una y revisa el resultado)
-- ============================================================
-- a) Debe salir 1 fila con tu correo:
--    select p.user_id, u.email from public.profesionales p join auth.users u on u.id = p.user_id;
--
-- b) Cada tabla debe tener SOLO la política "solo profesional":
--    select tablename, policyname, roles from pg_policies where schemaname = 'public' order by 1;
--
-- c) Storage: solo las 4 políticas "deportistas-docs: ...":
--    select policyname, cmd, roles from pg_policies where schemaname = 'storage' and tablename = 'objects';
--
-- d) Entra en el panel: debe seguir cargando todo y abriendo archivos. Si no entra, usa la MARCHA ATRÁS.
--
-- ============================================================
-- MARCHA ATRÁS (vuelve a "cualquier usuario con sesión"; úsala solo si te quedas sin acceso al panel)
-- ============================================================
-- do $$ declare t text; pol record; begin
--   foreach t in array array['clientes','clientes_deportivos','citas','recordatorios','historial_deportista','progresion_cargas','antropometria_perfil','antropometria_valoraciones','tests_sudoracion','planes_competicion'] loop
--     for pol in select policyname from pg_policies where schemaname='public' and tablename=t loop
--       execute format('drop policy %I on public.%I', pol.policyname, t);
--     end loop;
--     execute format('create policy "solo usuarios autenticados" on public.%I for all to authenticated using (true) with check (true)', t);
--   end loop;
--   for pol in select policyname from pg_policies where schemaname='storage' and tablename='objects' and policyname like 'deportistas-docs:%' loop
--     execute format('drop policy %I on storage.objects', pol.policyname);
--   end loop;
--   create policy "deportistas-docs: solo autenticados" on storage.objects for all to authenticated
--     using (bucket_id='deportistas-docs') with check (bucket_id='deportistas-docs');
-- end $$;
