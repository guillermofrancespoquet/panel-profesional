-- ============================================================
-- SEGUIMIENTO SEMANAL PROPIO (sustituye al Google Form de seguimiento)
-- ============================================================
-- Ejecutar en Supabase → SQL Editor DESPUÉS de supabase_formularios.sql y supabase_revision_hora.sql.
-- Es ADITIVO salvo por una cosa: vuelve a definir `cliente_mi_ficha` (misma que antes + datos del seguimiento propio;
-- esta versión sustituye a la anterior).
--
-- Cómo funciona: el cliente (con el seguimiento activado en su ficha) rellena cada semana un cuestionario corto dentro de su área:
-- 5 valoraciones de 1 a 5 (adherencia, energía, sueño, digestión, ánimo), entrenamientos de la semana, peso (opcional),
-- molestias y comentario (opcionales). Se guarda UNA fila por deportista y semana (lunes, hora de Madrid); si lo reenvía esa
-- semana, se actualiza. El cliente ve su evolución y el profesional la ve en la ficha. Los datos viven en `respuestas` (jsonb).
-- ============================================================

create table if not exists public.seguimientos (
  id            bigint generated always as identity primary key,
  deportista_id bigint not null references public.clientes_deportivos (id) on delete cascade,
  semana        date   not null,                       -- lunes de esa semana (hora de Madrid)
  respuestas    jsonb  not null default '{}'::jsonb,
  creado        timestamptz not null default now(),
  actualizado   timestamptz not null default now(),
  unique (deportista_id, semana)
);
create index if not exists seguimientos_deportista_semana on public.seguimientos (deportista_id, semana desc);

alter table public.seguimientos enable row level security;
drop policy if exists "solo profesional" on public.seguimientos;
create policy "solo profesional" on public.seguimientos
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());
revoke all on public.seguimientos from anon;
grant select, insert, update, delete on public.seguimientos to authenticated;   -- la política limita el uso al profesional

-- El cliente guarda (o actualiza) el seguimiento de ESTA semana. Valida todo en el servidor.
create or replace function public.cliente_guardar_seguimiento(p_respuestas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id  bigint := public.cliente_deportista_id();
  lunes date   := date_trunc('week', now() at time zone 'Europe/Madrid')::date;
  r     jsonb  := '{}'::jsonb;
  k     text;
  n     numeric;
  t     text;
begin
  if v_id is null then raise exception 'no autorizado'; end if;
  if not coalesce((select (formularios->'seguimiento'->>'activo')::boolean from public.clientes_deportivos where id = v_id), false) then
    raise exception 'seguimiento no activo';
  end if;
  if jsonb_typeof(p_respuestas) is distinct from 'object' then raise exception 'datos no validos'; end if;

  -- cinco valoraciones de 1 a 5 (todas obligatorias)
  foreach k in array array['adherencia', 'energia', 'sueno', 'digestion', 'animo'] loop
    if not (p_respuestas ? k) then raise exception 'falta: %', k; end if;
    n := (p_respuestas->>k)::numeric;
    if n <> trunc(n) or n < 1 or n > 5 then raise exception 'valor no valido: %', k; end if;
    r := r || jsonb_build_object(k, n::int);
  end loop;
  -- entrenamientos de la semana (0–21, entero) y peso (20–300 kg), opcionales
  if nullif(p_respuestas->>'entrenos', '') is not null then
    n := (p_respuestas->>'entrenos')::numeric;
    if n <> trunc(n) or n < 0 or n > 21 then raise exception 'valor no valido: entrenos'; end if;
    r := r || jsonb_build_object('entrenos', n::int);
  end if;
  if nullif(p_respuestas->>'peso', '') is not null then
    n := (p_respuestas->>'peso')::numeric;
    if n < 20 or n > 300 then raise exception 'valor no valido: peso'; end if;
    r := r || jsonb_build_object('peso', round(n, 1));
  end if;
  -- textos opcionales, máximo 600 caracteres
  foreach k in array array['molestias', 'comentario'] loop
    t := left(btrim(coalesce(p_respuestas->>k, '')), 600);
    if t <> '' then r := r || jsonb_build_object(k, t); end if;
  end loop;

  insert into public.seguimientos (deportista_id, semana, respuestas)
  values (v_id, lunes, r)
  on conflict (deportista_id, semana) do update set respuestas = excluded.respuestas, actualizado = now();
  return jsonb_build_object('ok', true, 'semana', lunes);
end $$;

-- El cliente lee su propio historial (las últimas 52 semanas), de más antigua a más reciente.
create or replace function public.cliente_mis_seguimientos()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('semana', s.semana, 'respuestas', s.respuestas) order by s.semana), '[]'::jsonb)
    from (select semana, respuestas from public.seguimientos
           where deportista_id = public.cliente_deportista_id()
           order by semana desc limit 52) s
$$;

-- Ficha del cliente: la misma de siempre; el seguimiento pasa a calcularse con la tabla nueva
-- (`seguimiento_propio` avisa a la app de que debe usar el cuestionario propio y no el Google Form).
create or replace function public.cliente_mi_ficha()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'nombre', d.nombre, 'deporte', d.deporte, 'objetivo', d.objetivo,
           'plan_url', d.plan_url, 'proxima_revision', d.proxima_revision,
           'proxima_revision_hora', left(d.proxima_revision_hora, 5),
           'forms', jsonb_build_object(
             'inicial_hecho',   d.formularios->'inicial'->>'hecho',
             'anamnesis_hecho', d.formularios->'anamnesis'->>'hecho',
             'seguimiento_activo', coalesce((d.formularios->'seguimiento'->>'activo')::boolean, false),
             'seguimiento_propio', true,
             'seguimiento_ultimo', coalesce((select max(s.semana)::text from public.seguimientos s where s.deportista_id = d.id),
                                            d.formularios->'seguimiento'->>'ultimo'),
             -- pendiente = activo y aún sin enviar el de esta semana (lunes a domingo, hora de Madrid)
             'seguimiento_pendiente',
               coalesce((d.formularios->'seguimiento'->>'activo')::boolean, false)
               and not exists (select 1 from public.seguimientos s
                                where s.deportista_id = d.id
                                  and s.semana = date_trunc('week', now() at time zone 'Europe/Madrid')::date)
           ))
    from public.clientes_deportivos d
   where d.id = public.cliente_deportista_id()
$$;

revoke all on function public.cliente_guardar_seguimiento(jsonb) from public, anon;
revoke all on function public.cliente_mis_seguimientos() from public, anon;
revoke all on function public.cliente_mi_ficha() from public, anon;
grant execute on function public.cliente_guardar_seguimiento(jsonb) to authenticated;
grant execute on function public.cliente_mis_seguimientos() to authenticated;
grant execute on function public.cliente_mi_ficha() to authenticated;

-- Comprobación (opcional):  select * from public.seguimientos order by semana desc;
-- Marcha atrás: drop table public.seguimientos cascade; drop function public.cliente_guardar_seguimiento(jsonb);
--   drop function public.cliente_mis_seguimientos();  (y volver a ejecutar el bloque de cliente_mi_ficha de supabase_revision_hora.sql)
