-- ============================================================
-- ANALÍTICAS (informes de laboratorio) — resultados por deportista
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere haber ejecutado antes `supabase_clientes_acceso.sql` (usa es_profesional()).
--
-- Una fila por analítica (por informe). `valores` (jsonb) es una LISTA con una entrada por prueba:
--   { k, n, sec, v, op, u, min, max, e, rtxt }
--   k = clave interna de la prueba (para compararla entre analíticas), n = nombre, sec = sección (Hemograma, Hierro…),
--   v = resultado, op = '<' o '>' si el laboratorio pone «<7», u = unidades, min/max = rango de referencia del
--   PROPIO laboratorio, e = estado (ok / alto / bajo / sin) y rtxt = el rango tal como venía impreso.
-- El informe original (PDF o foto) se sube al bucket privado `deportistas-docs` y su ruta queda en `archivo_path`.
-- Solo la ve el profesional: no hay función para el cliente (se puede añadir más adelante si se quiere compartir).
-- ============================================================

create table if not exists public.analiticas (
  id            bigint generated always as identity primary key,
  deportista_id bigint not null references public.clientes_deportivos (id) on delete cascade,
  fecha         date   not null,
  laboratorio   text,
  valores       jsonb  not null default '[]'::jsonb,
  archivo_path  text,
  notas         text,
  creado        timestamptz not null default now(),
  constraint analiticas_valores_lista check (jsonb_typeof(valores) = 'array' and jsonb_array_length(valores) <= 400)
);
create index if not exists analiticas_deportista_fecha on public.analiticas (deportista_id, fecha desc);

-- Solo el profesional lee y escribe la tabla (como el resto de tablas del panel).
alter table public.analiticas enable row level security;
drop policy if exists "solo profesional" on public.analiticas;
create policy "solo profesional" on public.analiticas
  for all to authenticated
  using (public.es_profesional()) with check (public.es_profesional());

-- Nada de acceso anónimo (igual que el resto, tras `supabase_seguridad_3_endurecer.sql`).
revoke all on public.analiticas from anon;

-- ============================================================
-- COMPROBACIONES (opcionales, una a una)
-- ============================================================
-- select count(*) from public.analiticas;                                              -- 0 al principio
-- select tablename, rowsecurity from pg_tables where tablename = 'analiticas';        -- rowsecurity = true
-- Después ejecuta `supabase_diagnostico_seguridad.sql`: debe salir todo «OK».
