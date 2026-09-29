-- ============================================================
-- SEGURIDAD · PASO 2 de 2 — Cerrar el acceso público a los datos
-- ============================================================
-- ¡OJO! Este paso QUITA el acceso abierto. Ejecútalo SOLO cuando se cumplan las cuatro cosas:
--   1) Has creado tu usuario en Supabase → Authentication → Users → "Add user" (correo + contraseña larga,
--      marcando "Auto confirm user").
--   2) Has DESACTIVADO los registros públicos: Authentication → Sign In / Providers → "Allow new users to
--      sign up" desactivado (y "Allow anonymous sign-ins" desactivado). Si no, cualquiera podría crearse
--      una cuenta y pasar como "autenticado".
--   3) Has fusionado la PR de seguridad, has entrado en el panel con tu correo y todo carga bien.
--   4) Has enviado a cada cliente del Método 3M su enlace nuevo (Panel → Método 3M → cliente → Copiar).
--      Los enlaces antiguos (?c=...) dejarán de funcionar.
--
-- Si algo sale mal, se puede reabrir temporalmente con el bloque "MARCHA ATRÁS" del final.
-- ============================================================

-- 1) Tablas: RLS activada, se eliminan TODAS las políticas existentes (las abiertas) y se deja una sola
--    que solo permite a usuarios autenticados. Los clientes del Método 3M siguen funcionando porque sus
--    funciones (paso 1) son SECURITY DEFINER.
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
      'create policy "solo usuarios autenticados" on public.%I for all to authenticated using (true) with check (true)', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- 2) Archivos de los deportistas (analíticas, bioimpedancias...): el bucket pasa a PRIVADO y solo se
--    accede con sesión iniciada (el panel pide URLs firmadas de 5 minutos).
update storage.buckets set public = false where id = 'deportistas-docs';

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

create policy "deportistas-docs: solo autenticados" on storage.objects
  for all to authenticated
  using (bucket_id = 'deportistas-docs')
  with check (bucket_id = 'deportistas-docs');

-- ============================================================
-- COMPROBACIONES (ejecútalas y revisa el resultado)
-- ============================================================
-- a) Políticas de las tablas: cada una debe tener solo "solo usuarios autenticados".
--    select tablename, policyname, roles from pg_policies where schemaname = 'public' order by 1;
--
-- b) Políticas de storage: NO debe quedar ninguna que permita a `anon` o a `public` sobre este bucket.
--    Si aparece alguna otra con `true` o sin bucket, revísala y bórrala.
--    select policyname, roles, cmd, qual from pg_policies where schemaname = 'storage' and tablename = 'objects';
--
-- c) Desde la consola del navegador con el panel abierto, la clave pública ya no debe leer nada:
--    fetch(SURL+'/rest/v1/clientes?select=id',{headers:{apikey:SKEY,Authorization:'Bearer '+SKEY}}).then(r=>r.json()).then(console.log)
--    → debe mostrar [] (lista vacía).
--
-- ============================================================
-- MARCHA ATRÁS (solo si necesitas reabrir de golpe mientras arreglas algo; después vuelve a cerrar)
-- ============================================================
-- do $$ declare t text; begin
--   foreach t in array array['clientes','clientes_deportivos','citas','recordatorios','historial_deportista','progresion_cargas','antropometria_perfil','antropometria_valoraciones','tests_sudoracion','planes_competicion'] loop
--     execute format('create policy "reabrir temporal" on public.%I for all using (true) with check (true)', t);
--     execute format('grant all on public.%I to anon', t);
--   end loop; end $$;
