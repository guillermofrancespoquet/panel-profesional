-- ============================================================
-- ANTROPOMETRÍA — tablas nuevas en el mismo proyecto Supabase
-- que ya usa panel-profesional.html.
--
-- Los deportistas NO se duplican: siguen viviendo en la tabla
-- existente clientes_deportivos. Estas dos tablas solo añaden,
-- vinculado por deportista_id, lo que la calculadora necesita:
-- el perfil antropométrico (sexo, fecha de nacimiento, diámetros
-- óseos...) y el historial de valoraciones ISAK.
--
-- Ejecuta esto en Supabase → SQL Editor → New query → Run.
-- ============================================================

-- Perfil antropométrico: una fila por deportista (1:1 con clientes_deportivos)
create table if not exists antropometria_perfil (
  deportista_id     bigint primary key references clientes_deportivos(id) on delete cascade,
  apellidos         text default '',
  sexo              text default 'Hombre',
  fecha_nacimiento  date,
  nacionalidad      text default '',
  raza              text default 'Caucásica',
  posicion          text default '',
  actividad         text default 'Activo',
  frecuencia_semanal text default '',
  compite           text default 'No',
  lesiones          text default '',
  notas             text default '',
  diametros_oseos   jsonb default '{}'::jsonb,
  updated_at        timestamptz default now()
);

-- Valoraciones: una fila por sesión de medición ISAK
create table if not exists antropometria_valoraciones (
  id             bigint generated always as identity primary key,
  deportista_id  bigint not null references clientes_deportivos(id) on delete cascade,
  fecha          date not null,
  medidas        jsonb not null,
  objetivo       jsonb,
  created_at     timestamptz default now()
);

create index if not exists idx_antropometria_valoraciones_deportista
  on antropometria_valoraciones(deportista_id);

-- RLS: mismo patrón permisivo que el resto de tablas del panel (solo protegidas por
-- el PIN de la app y la anon key, sin auth de Supabase por usuario).
alter table antropometria_perfil enable row level security;
alter table antropometria_valoraciones enable row level security;

create policy "anon full access perfil" on antropometria_perfil
  for all using (true) with check (true);
create policy "anon full access valoraciones" on antropometria_valoraciones
  for all using (true) with check (true);

-- ------------------------------------------------------------
-- Medidas estructurales fijas por cliente (se miden una sola vez,
-- igual que los diámetros óseos). Ejecutar si aún no existen.
-- ------------------------------------------------------------
alter table antropometria_perfil add column if not exists talla         numeric;
alter table antropometria_perfil add column if not exists talla_sentado numeric;
alter table antropometria_perfil add column if not exists envergadura   numeric;

-- ------------------------------------------------------------
-- Resumen de cada valoración (peso y % de grasa calculado con Durnin & Womersley,
-- o Yuhász / Ross-Kerr si no hay edad). Lo escribe la calculadora al guardar
-- y lo lee el Panel Profesional en la ficha del deportista. Ejecutar antes de
-- publicar los cambios.
-- ------------------------------------------------------------
alter table antropometria_valoraciones add column if not exists resumen jsonb;
