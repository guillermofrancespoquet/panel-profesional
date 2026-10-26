-- ============================================================
-- OBJETIVOS DEL CLIENTE CON SEGUIMIENTO (opcional) + peso reciente para reajustar el plan
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere haber ejecutado antes `supabase_clientes_acceso.sql` (usa es_profesional() y cliente_deportista_id()),
-- `supabase_seguimiento.sql`, `supabase_bioimpedancia.sql` y `supabase_registro_cliente.sql` (de ahí salen los pesos y el % de grasa).
--
-- Es una función OPCIONAL: mientras no haya un objetivo activo, el cliente no ve nada. El objetivo lo propone el profesional
-- (o acepta una sugerencia de la app) desde la ficha del deportista → Resumen → «Objetivo». Cada cliente tiene como mucho UN
-- objetivo activo; los anteriores quedan como historial (cumplido, cancelado o sustituido).
--
--  · `objetivos_cliente`: una fila por objetivo. Tabla «solo profesional».
--      - `tipo`: peso, pct_grasa (% de grasa) o rendimiento (valor que anota el profesional a mano, `valor_actual`).
--      - `fuente`: de dónde sale la medición: cualquiera (peso: la medición más reciente de antropometría, báscula, seguimiento
--        o peso que anota el cliente), antropometria o bascula (% de grasa; no se mezclan nunca) o manual.
--      - `visible_cliente`: si el cliente lo ve (por defecto sí; el profesional puede dejarlo solo para él).
--      - `nota` es privada y no llega nunca al cliente.
--  · `objetivo_progreso(p_dep)`: el objetivo activo de un deportista con su valor actual y el avance (solo profesional).
--  · `peso_reciente(p_dep)`: el peso más reciente y la media de la última semana (solo profesional; lo usa el planificador
--    nutricional para proponer reajustar las kcal cuando el peso cambia).
--  · `cliente_mi_objetivo()`: lo único que lee el cliente: su objetivo activo y visible (o el último cumplido, 14 días);
--    si no hay, devuelve null y su área no muestra nada.
-- ============================================================

create table if not exists public.objetivos_cliente (
  id              bigint generated always as identity primary key,
  deportista_id   bigint not null references public.clientes_deportivos (id) on delete cascade,
  tipo            text   not null check (tipo in ('peso', 'pct_grasa', 'rendimiento')),
  titulo          text   check (titulo is null or char_length(titulo) <= 80),
  unidad          text   not null default '' check (char_length(unidad) <= 16),
  valor_inicial   numeric not null,
  valor_objetivo  numeric not null,
  valor_actual    numeric,
  fuente          text   not null default 'cualquiera' check (fuente in ('cualquiera', 'antropometria', 'bascula', 'manual')),
  fecha_inicio    date   not null default ((now() at time zone 'Europe/Madrid')::date),
  fecha_limite    date,
  estado          text   not null default 'activo' check (estado in ('activo', 'cumplido', 'cancelado', 'sustituido')),
  origen          text   not null default 'profesional' check (origen in ('profesional', 'sugerido')),
  visible_cliente boolean not null default true,
  nota            text   check (nota is null or char_length(nota) <= 300),
  cerrado_en      date,
  valor_final     numeric,
  creado          timestamptz not null default now(),
  actualizado     timestamptz not null default now(),
  check (valor_inicial <> valor_objetivo),
  check (fecha_limite is null or fecha_limite >= fecha_inicio)
);
create index if not exists objetivos_cliente_dep on public.objetivos_cliente (deportista_id, creado desc);
-- Como mucho un objetivo activo por deportista.
create unique index if not exists objetivos_cliente_un_activo on public.objetivos_cliente (deportista_id) where estado = 'activo';

alter table public.objetivos_cliente enable row level security;
drop policy if exists "solo profesional" on public.objetivos_cliente;
create policy "solo profesional" on public.objetivos_cliente
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());

-- ── Utilidades internas (nadie las llama desde fuera) ──────────────────────────────────────────────────────────────
create or replace function public.objetivos_num(t text)
returns numeric
language sql
immutable
as $$
  select case when t ~ '^ *[0-9]+([.,][0-9]+)? *$' then replace(btrim(t), ',', '.')::numeric end
$$;

-- Todas las mediciones de peso de un deportista desde una fecha: prio 1 antropometría, 2 báscula, 3 seguimiento, 4 el cliente.
create or replace function public.objetivos_pesos(p_dep bigint, p_fuente text, p_desde date)
returns table (valor numeric, fecha date, prio int)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if coalesce(p_fuente, 'cualquiera') in ('cualquiera', 'antropometria') then
    return query
      select v.p, v.f, 1 from (
        select public.objetivos_num(coalesce(a.resumen->>'peso',
                 case when jsonb_typeof(a.medidas->'peso') = 'object' then a.medidas->'peso'->>'value' else a.medidas->>'peso' end)) as p,
               a.fecha::date as f
          from public.antropometria_valoraciones a
         where a.deportista_id = p_dep and a.fecha::date >= p_desde) v
       where v.p between 20 and 400;
  end if;
  if coalesce(p_fuente, 'cualquiera') in ('cualquiera', 'bascula') then
    return query
      select v.p, v.f, 2 from (
        select public.objetivos_num(b.valores->>'peso') as p, b.fecha::date as f
          from public.bioimpedancias b
         where b.deportista_id = p_dep and b.fecha::date >= p_desde) v
       where v.p between 20 and 400;
  end if;
  if coalesce(p_fuente, 'cualquiera') = 'cualquiera' then
    return query
      select v.p, v.f, 3 from (
        select public.objetivos_num(s.respuestas->>'peso') as p, s.semana::date as f
          from public.seguimientos s
         where s.deportista_id = p_dep and s.semana::date >= p_desde) v
       where v.p between 20 and 400;
    return query
      select c.peso, c.fecha::date, 4
        from public.pesos_cliente c
       where c.deportista_id = p_dep and c.fecha::date >= p_desde and c.peso between 20 and 400;
  end if;
end
$$;

-- % de grasa: antropometría o báscula, nunca mezclados. Con fuente «cualquiera» manda la antropometría si hay alguna.
create or replace function public.objetivos_grasas(p_dep bigint, p_fuente text, p_desde date)
returns table (valor numeric, fecha date, prio int)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare f text := coalesce(p_fuente, 'cualquiera');
begin
  if f = 'cualquiera' then
    f := case when exists (select 1 from public.antropometria_valoraciones a
                            where a.deportista_id = p_dep and public.objetivos_num(a.resumen->>'pct_grasa') is not null)
              then 'antropometria' else 'bascula' end;
  end if;
  if f = 'antropometria' then
    return query
      select v.p, v.f, 1 from (
        select public.objetivos_num(a.resumen->>'pct_grasa') as p, a.fecha::date as f
          from public.antropometria_valoraciones a
         where a.deportista_id = p_dep and a.fecha::date >= p_desde) v
       where v.p between 3 and 60;
  elsif f = 'bascula' then
    return query
      select v.p, v.f, 2 from (
        select public.objetivos_num(b.valores->>'pct_grasa') as p, b.fecha::date as f
          from public.bioimpedancias b
         where b.deportista_id = p_dep and b.fecha::date >= p_desde) v
       where v.p between 3 and 60;
  end if;
end
$$;

-- El objetivo con su valor actual y su avance. `p_privado` añade lo que solo ve el profesional.
create or replace function public.objetivos_json(o public.objetivos_cliente, p_privado boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  hoy date := (now() at time zone 'Europe/Madrid')::date;
  v_valor numeric; v_fecha date; v_origen text;
  actual numeric; bruto numeric; esperado numeric; res jsonb;
begin
  if o.tipo = 'peso' then
    select x.valor, x.fecha, case x.prio when 1 then 'antropometría' when 2 then 'báscula' when 3 then 'seguimiento' else 'cliente' end
      into v_valor, v_fecha, v_origen
      from public.objetivos_pesos(o.deportista_id, o.fuente, o.fecha_inicio) x
     order by x.fecha desc, x.prio limit 1;
  elsif o.tipo = 'pct_grasa' then
    select x.valor, x.fecha, case x.prio when 1 then 'antropometría' else 'báscula' end
      into v_valor, v_fecha, v_origen
      from public.objetivos_grasas(o.deportista_id, o.fuente, o.fecha_inicio) x
     order by x.fecha desc, x.prio limit 1;
  else
    v_valor := o.valor_actual; v_origen := 'manual';
  end if;

  if o.estado = 'cumplido' and o.valor_final is not null then actual := o.valor_final;
  else actual := coalesce(v_valor, o.valor_inicial);
  end if;
  bruto := (actual - o.valor_inicial) / (o.valor_objetivo - o.valor_inicial);
  if o.fecha_limite is not null and o.fecha_limite > o.fecha_inicio then
    esperado := greatest(0, least(1, (hoy - o.fecha_inicio)::numeric / (o.fecha_limite - o.fecha_inicio)));
  end if;

  res := jsonb_build_object(
    'id', o.id, 'tipo', o.tipo, 'titulo', o.titulo, 'unidad', o.unidad, 'estado', o.estado,
    'inicial', o.valor_inicial, 'objetivo', o.valor_objetivo, 'actual', actual,
    'actual_fecha', case when o.estado = 'cumplido' then o.cerrado_en else v_fecha end, 'actual_origen', v_origen,
    'sin_datos', (v_valor is null),
    'progreso', round(greatest(0, least(1, bruto)), 4), 'progreso_bruto', round(bruto, 4), 'esperado', round(esperado, 4),
    'fecha_inicio', o.fecha_inicio, 'fecha_limite', o.fecha_limite,
    'dias', case when o.fecha_limite is null then null else (o.fecha_limite - hoy) end);
  if p_privado then
    res := res || jsonb_build_object('fuente', o.fuente, 'origen', o.origen, 'visible_cliente', o.visible_cliente,
                                     'nota', o.nota, 'cerrado_en', o.cerrado_en, 'valor_final', o.valor_final);
  end if;
  return res;
end
$$;

revoke all on function public.objetivos_num(text) from public, anon, authenticated;
revoke all on function public.objetivos_pesos(bigint, text, date) from public, anon, authenticated;
revoke all on function public.objetivos_grasas(bigint, text, date) from public, anon, authenticated;
revoke all on function public.objetivos_json(public.objetivos_cliente, boolean) from public, anon, authenticated;

-- ── Profesional: el objetivo activo con su avance ────────────────────────────────────────────────────────────────
create or replace function public.objetivo_progreso(p_dep bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare o public.objetivos_cliente;
begin
  if not public.es_profesional() then return null; end if;
  select * into o from public.objetivos_cliente where deportista_id = p_dep and estado = 'activo';
  if not found then return null; end if;
  return public.objetivos_json(o, true);
end
$$;
revoke all on function public.objetivo_progreso(bigint) from public, anon;
grant execute on function public.objetivo_progreso(bigint) to authenticated;

-- ── Profesional: peso más reciente y media de la última semana (para reajustar el plan) ───────────────────────────
create or replace function public.peso_reciente(p_dep bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare ult record; media numeric; n int;
begin
  if not public.es_profesional() then return null; end if;
  select x.valor, x.fecha, x.prio into ult
    from public.objetivos_pesos(p_dep, 'cualquiera', date '1900-01-01') x
   order by x.fecha desc, x.prio limit 1;
  if not found then return null; end if;
  select round(avg(x.valor), 2), count(*) into media, n
    from public.objetivos_pesos(p_dep, 'cualquiera', date '1900-01-01') x
   where x.fecha > ult.fecha - 7;
  return jsonb_build_object('valor', ult.valor, 'fecha', ult.fecha, 'media7', media, 'n7', n,
    'origen', case ult.prio when 1 then 'antropometría' when 2 then 'báscula' when 3 then 'seguimiento' else 'cliente' end);
end
$$;
revoke all on function public.peso_reciente(bigint) from public, anon;
grant execute on function public.peso_reciente(bigint) to authenticated;

-- ── Cliente: su objetivo (solo si el profesional lo ha puesto y lo ha dejado visible) ─────────────────────────────
create or replace function public.cliente_mi_objetivo()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  dep bigint := public.cliente_deportista_id();
  hoy date := (now() at time zone 'Europe/Madrid')::date;
  o public.objetivos_cliente;
begin
  if dep is null then return null; end if;
  select * into o from public.objetivos_cliente where deportista_id = dep and estado = 'activo' and visible_cliente;
  if not found then
    select * into o from public.objetivos_cliente
     where deportista_id = dep and estado = 'cumplido' and visible_cliente and cerrado_en >= hoy - 14
     order by cerrado_en desc, id desc limit 1;
    if not found then return null; end if;
  end if;
  return public.objetivos_json(o, false);
end
$$;
revoke all on function public.cliente_mi_objetivo() from public, anon;
grant execute on function public.cliente_mi_objetivo() to authenticated;

-- Comprobación (opcional):  select id, deportista_id, tipo, valor_inicial, valor_objetivo, estado, fecha_limite from public.objetivos_cliente order by creado desc;
-- Marcha atrás: drop function public.cliente_mi_objetivo(); drop function public.peso_reciente(bigint); drop function public.objetivo_progreso(bigint);
--               drop function public.objetivos_json(public.objetivos_cliente, boolean); drop function public.objetivos_grasas(bigint, text, date);
--               drop function public.objetivos_pesos(bigint, text, date); drop function public.objetivos_num(text); drop table public.objetivos_cliente;
