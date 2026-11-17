-- ============================================================
-- REACCIONES DEL CLIENTE A LAS COMIDAS DEL PLAN («me gusta» / «no me gusta» / «no puedo»)
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere `supabase_clientes_acceso.sql` (usa es_profesional() y cliente_deportista_id()) y `supabase_avisos_profesional.sql`
-- (para que «no me gusta» y «no puedo» salgan en las Novedades del panel; sin él, solo falla ese aviso en silencio).
--
-- En «Planificación nutricional» el cliente marca cada comida con un toque. La reacción es a la comida en sí (su nombre y tipo), no al día:
-- si «Porridge de avena» sale el lunes y el jueves, es la misma reacción. Una fila por cliente y comida (la última reacción manda).
-- El profesional ve las reacciones en el planificador y puede añadir ingredientes a «No puede o no quiere comer».
--  · `reacciones_comidas` es «solo profesional»; el cliente solo entra por `cliente_reaccionar_comida` y `cliente_mis_reacciones`.
--  · Como mucho 500 comidas por cliente.
-- Marcha atrás:  drop table public.reacciones_comidas cascade;
-- ============================================================

create table if not exists public.reacciones_comidas (
  id            bigint generated always as identity primary key,
  deportista_id bigint not null references public.clientes_deportivos (id) on delete cascade,
  clave         text   not null check (char_length(clave) between 1 and 160),      -- nombre normalizado + '|' + tipo de comida
  nombre        text   not null check (char_length(nombre) between 1 and 160),     -- como lo ve el cliente
  momento       text   check (momento is null or char_length(momento) <= 40),
  reaccion      text   not null check (reaccion in ('gusta', 'no_gusta', 'no_puedo')),
  actualizado   timestamptz not null default now(),
  unique (deportista_id, clave)
);
create index if not exists reacciones_comidas_dep on public.reacciones_comidas (deportista_id);

alter table public.reacciones_comidas enable row level security;
drop policy if exists "solo profesional" on public.reacciones_comidas;
create policy "solo profesional" on public.reacciones_comidas
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());

-- El cliente marca (o quita, con reacción vacía) lo que le parece una comida.
create or replace function public.cliente_reaccionar_comida(p_clave text, p_nombre text, p_momento text, p_reaccion text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_dep bigint := public.cliente_deportista_id();
begin
  if v_dep is null then raise exception 'sin acceso'; end if;
  p_clave := left(btrim(coalesce(p_clave, '')), 160);
  if p_clave = '' then raise exception 'comida no válida'; end if;
  if coalesce(p_reaccion, '') = '' then
    delete from public.reacciones_comidas where deportista_id = v_dep and clave = p_clave;
    return;
  end if;
  if p_reaccion not in ('gusta', 'no_gusta', 'no_puedo') then raise exception 'reacción no válida'; end if;
  p_nombre := left(btrim(coalesce(p_nombre, '')), 160);
  if p_nombre = '' then raise exception 'comida no válida'; end if;
  if not exists (select 1 from public.reacciones_comidas where deportista_id = v_dep and clave = p_clave)
     and (select count(*) from public.reacciones_comidas where deportista_id = v_dep) >= 500 then
    raise exception 'demasiadas reacciones';
  end if;
  insert into public.reacciones_comidas (deportista_id, clave, nombre, momento, reaccion)
  values (v_dep, p_clave, p_nombre, left(nullif(btrim(coalesce(p_momento, '')), ''), 40), p_reaccion)
  on conflict (deportista_id, clave) do update
     set reaccion = excluded.reaccion, nombre = excluded.nombre, momento = excluded.momento, actualizado = now();
end $$;

-- Lo que ya ha marcado: { "<clave>": "gusta" | "no_gusta" | "no_puedo" }
create or replace function public.cliente_mis_reacciones()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_object_agg(clave, reaccion), '{}'::jsonb)
    from public.reacciones_comidas where deportista_id = public.cliente_deportista_id()
$$;

revoke all on function public.cliente_reaccionar_comida(text, text, text, text) from public, anon;
revoke all on function public.cliente_mis_reacciones() from public, anon;
grant execute on function public.cliente_reaccionar_comida(text, text, text, text) to authenticated;
grant execute on function public.cliente_mis_reacciones() to authenticated;

-- Aviso en Novedades (solo «no me gusta» y «no puedo», y solo cuando cambia la reacción)
drop trigger if exists avisos_prof_reaccion on public.reacciones_comidas;
create trigger avisos_prof_reaccion after insert or update of reaccion on public.reacciones_comidas
  for each row execute function public.avisos_prof_trg('reaccion');
