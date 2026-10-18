-- ============================================================
-- SUPLEMENTACIÓN PERSONALIZADA POR CLIENTE
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere haber ejecutado antes `supabase_clientes_acceso.sql` (usa es_profesional() y cliente_deportista_id()).
--
-- El profesional asigna suplementos desde la ficha del deportista (pestaña Plan → «Suplementación»): elige el suplemento y
-- la app calcula la dosis según el peso y la edad del cliente, con las referencias científicas SOLO para el profesional.
--  · `suplementos_cliente`: una fila por suplemento asignado. Tabla «solo profesional».
--      - `dosis`, `momento` y `nota_cliente` son lo que ve el cliente (texto corto).
--      - `nota_privada` y `calculo` (cifras, referencias y avisos del cálculo) NO llegan nunca al cliente.
--      - `activo` = en uso (si se pausa, el cliente deja de verlo) y `visible_cliente` = se muestra en su área.
--  · `cliente_mi_suplementacion()`: lo único que lee el cliente. Si no tiene nada asignado devuelve [] y su área
--    no muestra la opción.
-- ============================================================

create table if not exists public.suplementos_cliente (
  id              bigint generated always as identity primary key,
  deportista_id   bigint not null references public.clientes_deportivos (id) on delete cascade,
  clave           text   not null default 'otro',
  nombre          text   not null check (char_length(nombre) between 1 and 80),
  dosis           text   not null check (char_length(dosis) between 1 and 120),
  momento         text   check (momento is null or char_length(momento) <= 160),
  nota_cliente    text   check (nota_cliente is null or char_length(nota_cliente) <= 240),
  nota_privada    text   check (nota_privada is null or char_length(nota_privada) <= 600),
  calculo         jsonb,
  activo          boolean not null default true,
  visible_cliente boolean not null default true,
  creado          timestamptz not null default now(),
  actualizado     timestamptz not null default now()
);
create index if not exists suplementos_cliente_dep on public.suplementos_cliente (deportista_id, creado);

alter table public.suplementos_cliente enable row level security;
drop policy if exists "solo profesional" on public.suplementos_cliente;
create policy "solo profesional" on public.suplementos_cliente
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());

create or replace function public.cliente_mi_suplementacion()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'nombre', s.nombre, 'dosis', s.dosis, 'momento', s.momento, 'nota', s.nota_cliente)
         order by s.creado, s.id), '[]'::jsonb)
    from public.suplementos_cliente s
   where s.deportista_id = public.cliente_deportista_id()
     and s.activo
     and s.visible_cliente
$$;

revoke all on function public.cliente_mi_suplementacion() from public, anon;
grant execute on function public.cliente_mi_suplementacion() to authenticated;

-- Comprobación (opcional):  select id, deportista_id, nombre, dosis, activo, visible_cliente from public.suplementos_cliente order by creado desc;
-- Marcha atrás: drop function public.cliente_mi_suplementacion(); drop table public.suplementos_cliente;
