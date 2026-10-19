-- ============================================================
-- AVISOS AL MÓVIL DEL CLIENTE (notificaciones push): seguimiento semanal
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere `supabase_clientes_acceso.sql` y `supabase_seguimiento.sql` (usa es_profesional(),
-- cliente_deportista_id() y la tabla `seguimientos`).
--
-- Cada lunes a las 9:00 (hora de Madrid) la Edge Function `avisos-seguimiento` avisa al móvil de los clientes que
-- tienen el seguimiento semanal activado y aún no han enviado el de esta semana (misma regla que `seguimiento_pendiente`
-- de `cliente_mi_ficha`). Solo un aviso por semana y dispositivo. El aviso no lleva datos del cliente: el texto es fijo.
--  · `push_suscripciones`: un dispositivo del cliente (el `endpoint` que da el navegador). Tabla «solo profesional»
--    (el panel la lee para saber quién tiene los avisos activos); el cliente solo entra por `cliente_guardar_push`
--    y `cliente_borrar_push`.
--  · Las funciones `push_*` son SOLO para la Edge Function (service_role): ni `anon` ni un cliente pueden llamarlas.
-- Marcha atrás:  drop table public.push_suscripciones cascade;  (y quitar la tarea de pg_cron, ver al final).
-- ============================================================

create table if not exists public.push_suscripciones (
  id            bigint generated always as identity primary key,
  deportista_id bigint not null references public.clientes_deportivos (id) on delete cascade,
  endpoint      text   not null unique check (char_length(endpoint) between 20 and 1000),
  creada        timestamptz not null default now(),
  ultimo_aviso  date            -- lunes (Madrid) de la semana del último aviso enviado
);
create index if not exists push_suscripciones_dep on public.push_suscripciones (deportista_id);

alter table public.push_suscripciones enable row level security;
drop policy if exists "solo profesional" on public.push_suscripciones;
create policy "solo profesional" on public.push_suscripciones
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());

-- El cliente activa los avisos en este dispositivo.
create or replace function public.cliente_guardar_push(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_dep bigint := public.cliente_deportista_id();
begin
  if v_dep is null then raise exception 'sin acceso'; end if;
  if p_endpoint is null or p_endpoint !~ '^https://' or char_length(p_endpoint) not between 20 and 1000 then
    raise exception 'endpoint no válido';
  end if;
  -- Si el mismo dispositivo cambia de cuenta, el aviso pasa a la última que lo activó.
  insert into public.push_suscripciones (deportista_id, endpoint) values (v_dep, p_endpoint)
  on conflict (endpoint) do update set deportista_id = excluded.deportista_id;
end $$;

-- El cliente desactiva los avisos en este dispositivo.
create or replace function public.cliente_borrar_push(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_dep bigint := public.cliente_deportista_id();
begin
  if v_dep is null then raise exception 'sin acceso'; end if;
  delete from public.push_suscripciones where endpoint = p_endpoint and deportista_id = v_dep;
end $$;

-- Solo para la Edge Function: dispositivos a los que toca avisar esta semana.
create or replace function public.push_pendientes_seguimiento()
returns table (id bigint, endpoint text)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.endpoint
    from public.push_suscripciones p
    join public.clientes_deportivos d on d.id = p.deportista_id
   where coalesce((d.formularios->'seguimiento'->>'activo')::boolean, false)
     and not exists (select 1 from public.seguimientos s
                      where s.deportista_id = d.id
                        and s.semana = date_trunc('week', now() at time zone 'Europe/Madrid')::date)
     and (p.ultimo_aviso is null or p.ultimo_aviso < date_trunc('week', now() at time zone 'Europe/Madrid')::date)
$$;

-- Solo para la Edge Function: anota que ya se avisó esta semana.
create or replace function public.push_marcar_avisados(p_ids bigint[])
returns void
language sql
security definer
set search_path = public
as $$
  update public.push_suscripciones
     set ultimo_aviso = date_trunc('week', now() at time zone 'Europe/Madrid')::date
   where id = any(p_ids)
$$;

-- Solo para la Edge Function: quita dispositivos que el navegador ya no reconoce (404/410).
create or replace function public.push_borrar(p_ids bigint[])
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.push_suscripciones where id = any(p_ids)
$$;

revoke all on function public.cliente_guardar_push(text) from public, anon;
revoke all on function public.cliente_borrar_push(text) from public, anon;
revoke all on function public.push_pendientes_seguimiento() from public, anon, authenticated;
revoke all on function public.push_marcar_avisados(bigint[]) from public, anon, authenticated;
revoke all on function public.push_borrar(bigint[]) from public, anon, authenticated;
grant execute on function public.cliente_guardar_push(text) to authenticated;
grant execute on function public.cliente_borrar_push(text) to authenticated;
grant execute on function public.push_pendientes_seguimiento() to service_role;
grant execute on function public.push_marcar_avisados(bigint[]) to service_role;
grant execute on function public.push_borrar(bigint[]) to service_role;

-- ------------------------------------------------------------
-- PROGRAMACIÓN (se hace UNA vez, DESPUÉS de crear la Edge Function y sus secretos; ver sql/LEEME.md)
-- Requiere activar las extensiones pg_cron y pg_net (Database → Extensions). Sustituye los dos valores entre <>.
-- Dos horas (07:00 y 08:00 UTC) para cubrir el cambio de hora; la función solo envía si en Madrid es lunes y
-- ya son las 9:00, y nunca repite en la misma semana.
--
-- select cron.schedule('avisos-seguimiento', '0 7,8 * * 1', $job$
--   select net.http_post(
--     url := 'https://knmucvrbxpzmrjwxyksj.supabase.co/functions/v1/avisos-seguimiento',
--     headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', '<AVISOS_SECRET>'),
--     body := '{}'::jsonb);
-- $job$);
--
-- Quitarla:  select cron.unschedule('avisos-seguimiento');
-- ------------------------------------------------------------
