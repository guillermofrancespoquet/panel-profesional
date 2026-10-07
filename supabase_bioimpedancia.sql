-- ============================================================
-- BIOIMPEDANCIA (báscula) — mediciones de composición corporal por deportista
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere haber ejecutado antes `supabase_clientes_acceso.sql` (usa es_profesional() y cliente_deportista_id()).
--
-- Una fila por medición. `valores` (jsonb) guarda lo que lee la ficha del informe o de la captura de la báscula:
--   peso, pct_grasa, masa_grasa_kg, masa_libre_kg, musculo_kg, agua_l, agua_pct, proteina_kg, masa_osea_kg,
--   grasa_visceral, grasa_subcutanea_pct, imc, tmb_kcal, edad_metabolica, altura_cm
-- El archivo original (PDF o imagen) se sube al bucket privado `deportistas-docs` y su ruta queda en `archivo_path`.
-- `visible_cliente`: el profesional decide si el cliente ve la medición en «Mis datos» (por defecto, no).
-- ============================================================

create table if not exists public.bioimpedancias (
  id              bigint generated always as identity primary key,
  deportista_id   bigint not null references public.clientes_deportivos (id) on delete cascade,
  fecha           date   not null,
  aparato         text,
  valores         jsonb  not null default '{}'::jsonb,
  archivo_path    text,
  visible_cliente boolean not null default false,
  notas           text,
  creado          timestamptz not null default now()
);
create index if not exists bioimpedancias_deportista_fecha on public.bioimpedancias (deportista_id, fecha desc);

-- Solo el profesional lee y escribe la tabla (como el resto de tablas del panel).
alter table public.bioimpedancias enable row level security;
drop policy if exists "solo profesional" on public.bioimpedancias;
create policy "solo profesional" on public.bioimpedancias
  for all to authenticated
  using (public.es_profesional()) with check (public.es_profesional());

-- Lo que ve cada cliente: SOLO sus mediciones marcadas como visibles, y solo los valores (nunca el archivo ni las notas).
create or replace function public.cliente_mis_bioimpedancias()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object('id', b.id, 'fecha', b.fecha, 'aparato', b.aparato, 'valores', b.valores) order by b.fecha, b.id),
    '[]'::jsonb)
    from public.bioimpedancias b
   where b.deportista_id = public.cliente_deportista_id()
     and b.visible_cliente
$$;

revoke all on function public.cliente_mis_bioimpedancias() from public, anon;
grant execute on function public.cliente_mis_bioimpedancias() to authenticated;

-- ============================================================
-- COMPROBACIONES (opcionales, una a una)
-- ============================================================
-- select count(*) from public.bioimpedancias;                       -- 0 al principio
-- select public.cliente_mis_bioimpedancias();                        -- como cliente: [] hasta que compartas una
