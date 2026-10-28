-- ============================================================
-- DIAGNÓSTICO DE SEGURIDAD (solo lectura: no cambia nada)
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run, cuando quieras (por ejemplo, tras cada cambio de esquema o cada pocos meses).
-- Devuelve una fila por comprobación con su estado: «OK» o «REVISAR» (con el detalle). Debe salir todo «OK».
-- No sustituye a lo que hay que mirar a mano en el panel de Supabase (ver «Revisión de seguridad» en Notion): registros públicos
-- desactivados, longitud mínima de contraseña, correos de invitación y redirecciones.
-- ============================================================
with
tablas_sin_rls as (
  select string_agg(c.relname, ', ' order by c.relname) as d
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
),
pol_no_profesional as (
  select string_agg(p.tablename || ' («' || p.policyname || '»)', ', ' order by p.tablename) as d
    from pg_policies p
   where p.schemaname = 'public'
     and not (   (p.cmd = 'ALL'    and coalesce(p.qual, '') like '%es_profesional()%' and coalesce(p.with_check, '') like '%es_profesional()%')
              or (p.cmd = 'SELECT' and coalesce(p.qual, '') like '%es_profesional()%')
              or (p.cmd = 'INSERT' and coalesce(p.with_check, '') like '%es_profesional()%'))   -- las tablas de solo lectura/solo alta (textos legales, registro de eliminaciones) usan una política por acción
),
anon_tablas as (
  select string_agg(distinct g.table_name, ', ') as d
    from information_schema.role_table_grants g
   where g.table_schema = 'public' and g.grantee = 'anon'
),
fn_anon as (
  select string_agg(p.proname, ', ' order by p.proname) as d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.proname not like 'm3m\_%'
     and has_function_privilege('anon', p.oid, 'execute')
),
fn_internas_auth as (
  select string_agg(p.proname, ', ' order by p.proname) as d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and (p.proname like 'objetivos\_%' or p.proname like 'push\_%' or p.proname like 'consent\_%' or p.proname like 'trg\_consent\_%' or p.proname = 'cliente_deportista_id' or p.proname = 'cliente_ruta_valida' or p.proname = 'comidas_cliente_comentario')
     and has_function_privilege('authenticated', p.oid, 'execute')
),
fn_sin_search_path as (
  select string_agg(p.proname, ', ' order by p.proname) as d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef and not coalesce(p.proconfig::text, '') like '%search_path%'
),
buckets as (
  select string_agg(b.id || ' (público=' || b.public || ')', ', ') as d from storage.buckets b where b.public
),
bucket_fotos as (
  select b.file_size_limit, b.allowed_mime_types from storage.buckets b where b.id = 'fotos-clientes'
),
pol_storage as (
  select string_agg(p.policyname || ' → ' || p.roles::text, ', ') as d
    from pg_policies p
   where p.schemaname = 'storage' and p.tablename = 'objects'
     and (p.roles::text ~ '(anon|public)' or not (coalesce(p.qual, '') || coalesce(p.with_check, '') ~ '(es_profesional|puede_ver_archivo|puede_usar_foto)'))
),
pros as (select count(*) as n, string_agg(u.email, ', ') as d from public.profesionales p join auth.users u on u.id = p.user_id),
sin_vincular as (
  select count(*) as n, string_agg(u.email, ', ') as d
    from auth.users u
   where u.id not in (select user_id from public.profesionales) and u.id not in (select user_id from public.clientes_acceso)
)
select 'Tablas sin RLS' as comprobacion, case when d is null then 'OK' else 'REVISAR' end as estado, coalesce(d, 'todas con RLS') as detalle from tablas_sin_rls
union all select 'Políticas que no son «solo profesional»', case when d is null then 'OK' else 'REVISAR' end, coalesce(d, 'ninguna') from pol_no_profesional
union all select 'Tablas con acceso directo para anon', case when d is null then 'OK' else 'REVISAR' end, coalesce(d, 'ninguna') from anon_tablas
union all select 'Funciones que anon puede ejecutar (salvo m3m_*)', case when d is null then 'OK' else 'REVISAR' end, coalesce(d, 'ninguna') from fn_anon
union all select 'Funciones internas ejecutables por cuentas con sesión', case when d is null then 'OK' else 'REVISAR' end, coalesce(d, 'ninguna') from fn_internas_auth
union all select 'Funciones SECURITY DEFINER sin search_path fijo', case when d is null then 'OK' else 'REVISAR' end, coalesce(d, 'ninguna') from fn_sin_search_path
union all select 'Buckets públicos', case when d is null then 'OK' else 'REVISAR' end, coalesce(d, 'ninguno') from buckets
union all select 'Bucket fotos-clientes: tamaño y tipos', case when file_size_limit is not null and allowed_mime_types is not null then 'OK' else 'REVISAR' end,
       coalesce(file_size_limit::text, 'sin límite de tamaño') || ' bytes · ' || coalesce(allowed_mime_types::text, 'cualquier tipo de archivo') from bucket_fotos
union all select 'Políticas de Storage abiertas a anon o sin comprobar quién es', case when d is null then 'OK' else 'REVISAR' end, coalesce(d, 'ninguna') from pol_storage
union all select 'Cuentas profesional (debe ser solo la tuya)', case when n = 1 then 'OK' else 'REVISAR' end, n || ': ' || coalesce(d, '') from pros
union all select 'Cuentas de acceso sin vincular a ningún cliente', case when n = 0 then 'OK' else 'REVISAR' end, case when n = 0 then 'ninguna' else n || ': ' || d end from sin_vincular;
