-- ============================================================
-- OBJETIVOS DEL CLIENTE, 2.ª parte: hasta DOS objetivos activos por cliente y objetivo por Σ de 6 pliegues
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere haber ejecutado antes `supabase_objetivos.sql` (y lo que ese pide). No cambia ningún dato existente: los objetivos que ya
-- hay quedan como «objetivo 1».
--
--  · `objetivos_cliente.posicion` (1 o 2): como mucho un objetivo ACTIVO por posición, es decir, hasta dos por deportista.
--  · `tipo` admite ahora `sum6` (suma de 6 pliegues en mm, de la antropometría: `resumen.sum6`). Solo antropometría; nunca se mezcla
--    con nada más. Bajar el sumatorio es lo habitual, pero la dirección la marca el valor de partida y el objetivo.
--  · `objetivos_progreso(p_dep)` (solo profesional) devuelve la LISTA de objetivos activos con su avance, y `cliente_mis_objetivos()`
--    la lista que ve el cliente (activos y visibles, más los cumplidos en los últimos 14 días). Las funciones de la primera parte
--    (`objetivo_progreso`, `cliente_mi_objetivo`) siguen existiendo y devuelven el de la posición 1 (compatibilidad).
-- ============================================================

alter table public.objetivos_cliente add column if not exists posicion smallint not null default 1;
alter table public.objetivos_cliente drop constraint if exists objetivos_cliente_posicion_check;
alter table public.objetivos_cliente add constraint objetivos_cliente_posicion_check check (posicion in (1, 2));

alter table public.objetivos_cliente drop constraint if exists objetivos_cliente_tipo_check;
alter table public.objetivos_cliente add constraint objetivos_cliente_tipo_check check (tipo in ('peso', 'pct_grasa', 'sum6', 'rendimiento'));

-- Como mucho un activo por deportista y posición (antes: uno por deportista).
drop index if exists public.objetivos_cliente_un_activo;
create unique index if not exists objetivos_cliente_un_activo_pos on public.objetivos_cliente (deportista_id, posicion) where estado = 'activo';

-- ── Σ de 6 pliegues (antropometría) ─────────────────────────────────────────────────────────────────────────────
create or replace function public.objetivos_sum6(p_dep bigint, p_desde date)
returns table (valor numeric, fecha date, prio int)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  return query
    select v.p, v.f, 1 from (
      select public.objetivos_num(a.resumen->>'sum6') as p, a.fecha::date as f
        from public.antropometria_valoraciones a
       where a.deportista_id = p_dep and a.fecha::date >= p_desde) v
     where v.p between 15 and 400;
end
$$;
revoke all on function public.objetivos_sum6(bigint, date) from public, anon, authenticated;

-- ── El objetivo con su valor actual y su avance (misma función de la primera parte + sum6 + posición) ─────────────
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
  elsif o.tipo = 'sum6' then
    select x.valor, x.fecha, 'antropometría'
      into v_valor, v_fecha, v_origen
      from public.objetivos_sum6(o.deportista_id, o.fecha_inicio) x
     order by x.fecha desc limit 1;
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
    'id', o.id, 'posicion', o.posicion, 'tipo', o.tipo, 'titulo', o.titulo, 'unidad', o.unidad, 'estado', o.estado,
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
revoke all on function public.objetivos_json(public.objetivos_cliente, boolean) from public, anon, authenticated;

-- ── Profesional: todos los objetivos activos (lista, por posición) ─────────────────────────────────────────────────
create or replace function public.objetivos_progreso(p_dep bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare r jsonb;
begin
  if not public.es_profesional() then return null; end if;
  select coalesce(jsonb_agg(public.objetivos_json(o, true) order by o.posicion), '[]'::jsonb) into r
    from public.objetivos_cliente o
   where o.deportista_id = p_dep and o.estado = 'activo';
  return r;
end
$$;
revoke all on function public.objetivos_progreso(bigint) from public, anon;
grant execute on function public.objetivos_progreso(bigint) to authenticated;

-- Compatibilidad: el de la posición 1 (o el primero que haya).
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
  select * into o from public.objetivos_cliente where deportista_id = p_dep and estado = 'activo' order by posicion limit 1;
  if not found then return null; end if;
  return public.objetivos_json(o, true);
end
$$;
revoke all on function public.objetivo_progreso(bigint) from public, anon;
grant execute on function public.objetivo_progreso(bigint) to authenticated;

-- ── Cliente: sus objetivos (solo los que el profesional ha dejado visibles) ────────────────────────────────────
create or replace function public.cliente_mis_objetivos()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  dep bigint := public.cliente_deportista_id();
  hoy date := (now() at time zone 'Europe/Madrid')::date;
  r jsonb;
begin
  if dep is null then return null; end if;
  select coalesce(jsonb_agg(public.objetivos_json(o, false) order by (o.estado = 'activo') desc, o.posicion, o.id desc), '[]'::jsonb) into r
    from (
      select * from public.objetivos_cliente
       where deportista_id = dep and visible_cliente
         and (estado = 'activo' or (estado = 'cumplido' and cerrado_en >= hoy - 14))
       order by (estado = 'activo') desc, posicion, id desc
       limit 3) o;
  return r;
end
$$;
revoke all on function public.cliente_mis_objetivos() from public, anon;
grant execute on function public.cliente_mis_objetivos() to authenticated;

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
  select * into o from public.objetivos_cliente where deportista_id = dep and estado = 'activo' and visible_cliente order by posicion limit 1;
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

-- Comprobación (opcional):  select deportista_id, posicion, tipo, estado from public.objetivos_cliente order by creado desc;
-- Marcha atrás: drop function public.cliente_mis_objetivos(); drop function public.objetivos_progreso(bigint); drop function public.objetivos_sum6(bigint, date);
--               (y volver a ejecutar supabase_objetivos.sql; las filas con posicion 2 o tipo sum6 habría que quitarlas antes).
