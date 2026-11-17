-- ============================================================
-- NOVEDADES Y AVISOS AL MÓVIL DEL PROFESIONAL
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere `supabase_clientes_acceso.sql` (usa es_profesional()), `supabase_proteccion_datos.sql` (tabla `ajustes_app`) y las tablas
-- de lo que avisa: `supabase_seguimiento.sql`, `supabase_registro_cliente.sql`, `supabase_diario_comidas.sql` y `supabase_ficha_inicial.sql`.
--
-- Cuando un cliente envía el seguimiento semanal, anota un peso, sube una foto de progreso o de comida, envía la ficha inicial o retira un
-- consentimiento, se apunta una fila en `avisos_profesional` (solo «tipo» y a qué cliente: ningún dato de salud). El panel las muestra en la
-- tarjeta «Novedades» del dashboard. Si el profesional tiene los avisos al móvil activados, una Edge Function (`avisos-profesional`) manda UN aviso
-- genérico («Tienes novedades») cuando pasa un minuto sin más novedades (así tres fotos seguidas son un solo aviso) y respeta las horas de silencio.
--  · Lo que hace el propio profesional no avisa (si `es_profesional()`, el disparador no apunta nada).
--  · El disparador NUNCA falla: si algo va mal dentro, el cliente sigue guardando lo suyo con normalidad.
--  · Las funciones `avisos_prof_*` son SOLO para la Edge Function y la tarea de pg_cron (service_role / postgres).
--  · Ajustes (`ajustes_app`, clave `avisos_prof`): {"push": {"seguimiento": true, "comida": true, ...}, "silencio": true}. Sin nada guardado:
--    avisan al móvil seguimiento, comida, ficha y consentimiento; peso, foto y reacción solo salen en Novedades; silencio de 22:00 a 8:00.
-- Marcha atrás:  drop table public.avisos_profesional cascade; drop table public.push_profesional cascade;  (y quitar la tarea de pg_cron, ver al final).
-- ============================================================

create table if not exists public.avisos_profesional (
  id             bigint generated always as identity primary key,
  deportista_id  bigint references public.clientes_deportivos (id) on delete cascade,   -- null solo en el aviso de prueba
  tipo           text not null check (tipo in ('seguimiento','comida','peso','foto','ficha','consentimiento','reaccion','prueba')),
  creado         timestamptz not null default now(),
  visto          boolean not null default false,
  push_pendiente boolean not null default false     -- falta mandarlo al móvil
);
create index if not exists avisos_profesional_creado on public.avisos_profesional (creado desc);
create index if not exists avisos_profesional_push on public.avisos_profesional (creado) where push_pendiente;

alter table public.avisos_profesional enable row level security;
drop policy if exists "solo profesional" on public.avisos_profesional;
create policy "solo profesional" on public.avisos_profesional
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());

-- Móviles del profesional que reciben los avisos (el `endpoint` que da el navegador). Solo servicios de notificaciones de navegadores.
create table if not exists public.push_profesional (
  id       bigint generated always as identity primary key,
  user_id  uuid not null default auth.uid(),
  endpoint text not null unique check (
    char_length(endpoint) between 20 and 1000
    and endpoint ~ '^https://(fcm\.googleapis\.com|(updates\.)?push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+(\.[a-z0-9-]+)*\.notify\.windows\.com)/[^\s]+$'),
  creada   timestamptz not null default now()
);
alter table public.push_profesional enable row level security;
drop policy if exists "solo profesional" on public.push_profesional;
create policy "solo profesional" on public.push_profesional
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());

-- Disparador común: el tipo va como argumento. Nunca falla (el bloque interior se traga cualquier error).
create or replace function public.avisos_prof_trg()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tipo text := tg_argv[0];
  j      jsonb := to_jsonb(new);                                      -- (se lee como json: cada tabla tiene sus columnas)
  jo     jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end;
  v_dep  bigint;
  cfg    jsonb;
  v_push boolean;
begin
  begin
    if public.es_profesional() then return new; end if;
    if tg_table_name = 'fichas_iniciales' and not (j->>'enviado_en' is not null and (tg_op = 'INSERT' or jo->>'enviado_en' is null)) then return new; end if;
    if tg_table_name = 'consentimientos' and not (j->>'retirado_en' is not null and jo->>'retirado_en' is null) then return new; end if;
    if tg_table_name = 'reacciones_comidas' and not (j->>'reaccion' in ('no_gusta','no_puedo') and (tg_op = 'INSERT' or jo->>'reaccion' is distinct from j->>'reaccion')) then return new; end if;
    v_dep := (j->>'deportista_id')::bigint;
    if v_dep is null then return new; end if;
    select valor into cfg from public.ajustes_app where clave = 'avisos_prof';
    v_push := coalesce(case when jsonb_typeof(cfg->'push'->v_tipo) = 'boolean' then (cfg->'push'->>v_tipo)::boolean end,
                       v_tipo in ('seguimiento','comida','ficha','consentimiento'))
              and exists (select 1 from public.push_profesional);
    insert into public.avisos_profesional (deportista_id, tipo, push_pendiente) values (v_dep, v_tipo, v_push);
    delete from public.avisos_profesional where creado < now() - interval '30 days';
  exception when others then
    null;
  end;
  return new;
end $$;
revoke all on function public.avisos_prof_trg() from public, anon, authenticated;

drop trigger if exists avisos_prof_seguimiento on public.seguimientos;
create trigger avisos_prof_seguimiento after insert on public.seguimientos
  for each row execute function public.avisos_prof_trg('seguimiento');
drop trigger if exists avisos_prof_peso on public.pesos_cliente;
create trigger avisos_prof_peso after insert on public.pesos_cliente
  for each row execute function public.avisos_prof_trg('peso');
drop trigger if exists avisos_prof_comida on public.comidas_cliente;
create trigger avisos_prof_comida after insert on public.comidas_cliente
  for each row execute function public.avisos_prof_trg('comida');
drop trigger if exists avisos_prof_foto on public.fotos_cliente;
create trigger avisos_prof_foto after insert on public.fotos_cliente
  for each row execute function public.avisos_prof_trg('foto');
drop trigger if exists avisos_prof_ficha on public.fichas_iniciales;
create trigger avisos_prof_ficha after insert or update of enviado_en on public.fichas_iniciales
  for each row execute function public.avisos_prof_trg('ficha');
drop trigger if exists avisos_prof_consentimiento on public.consentimientos;
create trigger avisos_prof_consentimiento after update of retirado_en on public.consentimientos
  for each row execute function public.avisos_prof_trg('consentimiento');

-- Solo para la Edge Function y pg_cron: ¿hay algo que mandar ya? Devuelve {ids, subs}. Reglas: un minuto sin novedades (o 5 como mucho),
-- fuera de las horas de silencio (salvo el aviso de prueba) y sin avisar de lo que el profesional ya ha visto.
create or replace function public.avisos_prof_listos()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb; v_silencio boolean; h int; ids bigint[]; v_ult timestamptz; v_prim timestamptz; v_prueba boolean; subs jsonb;
  vacio constant jsonb := '{"ids":[],"subs":[]}'::jsonb;
begin
  update public.avisos_profesional set push_pendiente = false where push_pendiente and creado < now() - interval '16 hours';   -- no insistir eternamente
  select array_agg(id), max(creado), min(creado), coalesce(bool_or(tipo = 'prueba'), false)
    into ids, v_ult, v_prim, v_prueba
    from public.avisos_profesional where push_pendiente and not visto;
  if ids is null then return vacio; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'endpoint', endpoint)), '[]'::jsonb) into subs from public.push_profesional;
  if jsonb_array_length(subs) = 0 then
    update public.avisos_profesional set push_pendiente = false where push_pendiente;
    return vacio;
  end if;
  if not v_prueba then
    select valor into cfg from public.ajustes_app where clave = 'avisos_prof';
    v_silencio := coalesce(case when jsonb_typeof(cfg->'silencio') = 'boolean' then (cfg->>'silencio')::boolean end, true);
    h := extract(hour from (now() at time zone 'Europe/Madrid'))::int;
    if v_silencio and (h >= 22 or h < 8) then return vacio; end if;
    if v_ult > now() - interval '60 seconds' and v_prim > now() - interval '5 minutes' then return vacio; end if;
  end if;
  return jsonb_build_object('ids', to_jsonb(ids), 'subs', subs);
end $$;

create or replace function public.avisos_prof_hay()
returns boolean
language sql
security definer
set search_path = public
as $$ select jsonb_array_length(public.avisos_prof_listos()->'ids') > 0 $$;

create or replace function public.avisos_prof_enviado(p_ids bigint[])
returns void
language sql
security definer
set search_path = public
as $$ update public.avisos_profesional set push_pendiente = false where id = any(p_ids) $$;

create or replace function public.avisos_prof_borrar_subs(p_ids bigint[])
returns void
language sql
security definer
set search_path = public
as $$ delete from public.push_profesional where id = any(p_ids) $$;

revoke all on function public.avisos_prof_listos() from public, anon, authenticated;
revoke all on function public.avisos_prof_hay() from public, anon, authenticated;
revoke all on function public.avisos_prof_enviado(bigint[]) from public, anon, authenticated;
revoke all on function public.avisos_prof_borrar_subs(bigint[]) from public, anon, authenticated;
grant execute on function public.avisos_prof_listos() to service_role;
grant execute on function public.avisos_prof_hay() to service_role;
grant execute on function public.avisos_prof_enviado(bigint[]) to service_role;
grant execute on function public.avisos_prof_borrar_subs(bigint[]) to service_role;

-- ------------------------------------------------------------
-- PROGRAMACIÓN (UNA vez, DESPUÉS de crear la Edge Function `avisos-profesional`; ver sql/LEEME.md)
-- Cada minuto, pero solo llama a la función si de verdad hay algo que avisar (`avisos_prof_hay()`).
-- Usa la misma clave `AVISOS_SECRET` y los mismos secretos VAPID que `avisos-seguimiento`.
--
-- select cron.schedule('avisos-profesional', '* * * * *', $job$
--   do $d$ begin
--     if public.avisos_prof_hay() then
--       perform net.http_post(
--         url := 'https://knmucvrbxpzmrjwxyksj.supabase.co/functions/v1/avisos-profesional',
--         headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', '<AVISOS_SECRET>'),
--         body := '{}'::jsonb);
--     end if;
--   end $d$;
-- $job$);
--
-- Quitarla:  select cron.unschedule('avisos-profesional');
-- ------------------------------------------------------------
