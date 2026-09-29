-- ============================================================
-- TEST DE SUDORACIÓN — tabla nueva en el mismo proyecto Supabase
-- que ya usa panel-profesional.html.
--
-- Un test por fila, ligado al deportista (clientes_deportivos).
-- Lo escribe Calculadora → Hidratación y lo lee la ficha del
-- deportista ("Test de sudoración").
--
-- Ejecuta esto en Supabase → SQL Editor → New query → Run.
-- Es seguro ejecutarlo más de una vez.
-- ============================================================

create table if not exists tests_sudoracion (
  id               bigint generated always as identity primary key,
  deportista_id    bigint not null references clientes_deportivos(id) on delete cascade,
  fecha            date not null,
  actividad        text,
  duracion_min     numeric not null,
  intensidad       text,            -- baja / media / alta / competicion
  temperatura_c    numeric,
  humedad_pct      numeric,
  ambiente         text,            -- interior / exterior-sombra / exterior-sol
  ropa             text,
  peso_antes       numeric not null,
  peso_despues     numeric not null,
  liquido_ml       numeric default 0,
  orina_ml         numeric default 0,
  sodio_mmol_l     numeric,         -- medido (si se midió)
  sodio_categoria  text,            -- bajo / medio / salado (si no se midió)
  notas            text,
  resultados       jsonb,           -- tasa, pérdida %, sodio, reposición... calculados al guardar
  created_at       timestamptz default now()
);

create index if not exists idx_tests_sudoracion_deportista
  on tests_sudoracion(deportista_id, fecha);

-- RLS: mismo patrón permisivo que el resto de tablas del panel.
alter table tests_sudoracion enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'tests_sudoracion' and policyname = 'anon full access sudoracion') then
    create policy "anon full access sudoracion" on tests_sudoracion
      for all using (true) with check (true);
  end if;
end $$;
