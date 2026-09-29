-- ============================================================
-- PLAN DE PARTIDO — tabla nueva en el mismo proyecto Supabase
-- que ya usa panel-profesional.html.
--
-- Un plan por fila, ligado al deportista (clientes_deportivos).
-- Lo escribe la pestaña "Plan de partido" y lo lista la ficha
-- del deportista ("Planes de partido"). El plan (hidratos, líquidos,
-- alimentos) se recalcula al abrirlo a partir de estos datos.
--
-- Ejecuta esto en Supabase → SQL Editor → New query → Run.
-- Es seguro ejecutarlo más de una vez.
-- ============================================================

create table if not exists planes_competicion (
  id             bigint generated always as identity primary key,
  deportista_id  bigint not null references clientes_deportivos(id) on delete cascade,
  fecha          date not null,
  hora_inicio    text,             -- HH:MM (opcional)
  evento         text,             -- rival o competición
  deporte        text,             -- futbol / baloncesto / running / ciclismo / triatlon / otro
  duracion_min   numeric not null,
  intensidad     text,             -- baja / media / alta / competicion
  peso_kg        numeric not null,
  parametros     jsonb,            -- p. ej. { "rapida": true } (recuperación rápida)
  created_at     timestamptz default now()
);

create index if not exists idx_planes_competicion_deportista
  on planes_competicion(deportista_id, fecha);

-- RLS: mismo patrón permisivo que el resto de tablas del panel.
alter table planes_competicion enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'planes_competicion' and policyname = 'anon full access planes') then
    create policy "anon full access planes" on planes_competicion
      for all using (true) with check (true);
  end if;
end $$;
