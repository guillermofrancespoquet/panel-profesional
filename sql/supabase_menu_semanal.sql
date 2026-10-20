-- ============================================================
-- MENÚ SEMANAL POR CLIENTE (fase 1: catálogo de alimentos + menú + publicar)
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere haber ejecutado antes `supabase_clientes_acceso.sql` (usa es_profesional() y cliente_deportista_id()).
--
-- El profesional escribe el menú de cada cliente en la página de pruebas `planificador-nutricional.html` (más adelante, desde la ficha del
-- cliente) y lo PUBLICA; el cliente solo verá la copia publicada en «Mi menú semanal» cuando se integre en su área. Cada plan empieza en blanco: la estructura (días, comidas, horas,
-- nombres) vive en un jsonb libre.
--  · `alimentos`: catálogo propio del profesional, compartido entre clientes y que crece con el uso (se alimenta desde
--    USDA / Open Food Facts o a mano). Tabla «solo profesional»: el cliente nunca la lee.
--  · `menus_cliente`: una fila por cliente.
--      - `contenido`: borrador de trabajo (semanas → días → comidas → ingredientes, recetas, comidas reutilizables).
--      - `publicado`: copia ya resuelta de lo que ve el cliente (nombres y cantidades en texto, recetas, objetivo e
--        impresiones). Se escribe al pulsar «Publicar»; hasta entonces el cliente no ve cambios.
--      - `semana_actual`: id de la semana que toca (semana típica / semana alterna). Se cambia sin volver a publicar.
--  · `clientes_deportivos.objetivo_impresiones`: «Objetivo» e «Impresiones del profesional» del cliente (jsonb). Solo el
--    profesional lo lee; al publicar el menú se copia dentro de `publicado`. No toca `cliente_mi_ficha`.
--  · `cliente_mi_menu()`: lo único que lee el cliente. Si no hay menú publicado devuelve null y su área no muestra la tarjeta.
-- Las fotos de recetas van al bucket `fotos-clientes` en `<id>/menu/…`: NO hace falta tocar Storage.
-- ============================================================

alter table public.clientes_deportivos add column if not exists objetivo_impresiones jsonb;

create table if not exists public.alimentos (
  id         bigint generated always as identity primary key,
  nombre     text   not null check (char_length(nombre) between 1 and 80),
  categoria  text   check (categoria is null or char_length(categoria) <= 40),
  estado     text   check (estado is null or estado in ('crudo', 'cocinado', 'precocinado')),
  medidas    jsonb  not null default '[]'::jsonb check (jsonb_typeof(medidas) = 'array' and jsonb_array_length(medidas) <= 20),
  nutri      jsonb  check (nutri is null or jsonb_typeof(nutri) = 'object'),
  fuente     text   check (fuente is null or fuente in ('usda', 'off', 'manual')),
  fuente_ref text   check (fuente_ref is null or char_length(fuente_ref) <= 120),
  creado     timestamptz not null default now()
);
create unique index if not exists alimentos_nombre_estado on public.alimentos (lower(nombre), coalesce(estado, ''));

create table if not exists public.menus_cliente (
  id            bigint generated always as identity primary key,
  deportista_id bigint not null references public.clientes_deportivos (id) on delete cascade,
  titulo        text   check (titulo is null or char_length(titulo) <= 120),
  contenido     jsonb  not null default '{}'::jsonb check (jsonb_typeof(contenido) = 'object' and pg_column_size(contenido) < 1500000),
  publicado     jsonb  check (publicado is null or (jsonb_typeof(publicado) = 'object' and pg_column_size(publicado) < 1500000)),
  publicado_en  timestamptz,
  semana_actual text   check (semana_actual is null or char_length(semana_actual) <= 40),
  creado        timestamptz not null default now(),
  actualizado   timestamptz not null default now()
);
-- Fase 1: un menú por cliente. Cuando haya versiones (fase 3) este índice se sustituye por otro.
create unique index if not exists menus_cliente_dep on public.menus_cliente (deportista_id);

alter table public.alimentos     enable row level security;
alter table public.menus_cliente enable row level security;
drop policy if exists "solo profesional" on public.alimentos;
create policy "solo profesional" on public.alimentos
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());
drop policy if exists "solo profesional" on public.menus_cliente;
create policy "solo profesional" on public.menus_cliente
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());

-- Lo que ve el cliente: solo la copia publicada de SU menú (nunca el borrador ni el catálogo).
create or replace function public.cliente_mi_menu()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'dep', public.cliente_deportista_id(),
           'titulo', m.titulo,
           'semana_actual', m.semana_actual,
           'publicado_en', m.publicado_en,
           'menu', m.publicado)
    from public.menus_cliente m
   where m.deportista_id = public.cliente_deportista_id()
     and m.publicado is not null
$$;

revoke all on function public.cliente_mi_menu() from public, anon;
grant execute on function public.cliente_mi_menu() to authenticated;

-- Comprobación (opcional):  select id, deportista_id, publicado is not null as publicado, publicado_en from public.menus_cliente;
-- Marcha atrás: drop function public.cliente_mi_menu(); drop table public.menus_cliente; drop table public.alimentos;
--   alter table public.clientes_deportivos drop column objetivo_impresiones;
