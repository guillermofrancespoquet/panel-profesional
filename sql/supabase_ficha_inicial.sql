-- ============================================================
-- FICHA INICIAL PROPIA (sustituye a los dos Google Forms: Cuestionario inicial y Anamnesis nutricional)
-- ============================================================
-- Ejecutar en Supabase → SQL Editor DESPUÉS de supabase_formularios.sql y supabase_clientes_acceso.sql.
-- Es ADITIVO: crea una tabla y dos funciones; no cambia ninguna función existente.
--
-- Cómo funciona: el cliente rellena en su área una ficha por pasos (sobre él, salud, historia de peso, hábitos, actividad,
-- objetivos, preferencias, cocina, un día típico de comidas con hora/alimentos/lugar, un cribado breve de la relación con la
-- comida y comentarios). Se guarda UNA fila por deportista (`fichas_iniciales`): `respuestas` (jsonb) es el borrador mientras
-- `enviado_en` es null y la ficha definitiva cuando no lo es. Al enviarla se marcan solas como hechos `inicial` y `anamnesis`
-- en `clientes_deportivos.formularios` (así siguen funcionando el «Estado del cliente», la frase del día y «Por atender»).
-- Una vez enviada, el cliente ya no la puede cambiar (el profesional puede reabrirla desde la ficha).
--
-- Los campos permitidos y sus valores están AQUÍ (lista blanca) y en la constante FI_DEF de cliente.html: **si se cambian
-- preguntas hay que tocar los dos sitios** (y la hoja de la ficha del panel, `fiHoja`). Lo que no esté en la lista se ignora.
-- El cribado (`scoff`) lo ve solo el profesional.
-- ============================================================

create table if not exists public.fichas_iniciales (
  deportista_id bigint primary key references public.clientes_deportivos (id) on delete cascade,
  version       int    not null default 1,
  respuestas    jsonb  not null default '{}'::jsonb,
  enviado_en    timestamptz,                      -- null = borrador
  creado        timestamptz not null default now(),
  actualizado   timestamptz not null default now()
);

alter table public.fichas_iniciales enable row level security;
drop policy if exists "solo profesional" on public.fichas_iniciales;
create policy "solo profesional" on public.fichas_iniciales
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());
revoke all on public.fichas_iniciales from anon;
grant select, insert, update, delete on public.fichas_iniciales to authenticated;   -- la política limita el uso al profesional

-- El cliente lee su propia ficha (borrador o enviada). null si aún no ha empezado.
create or replace function public.cliente_mi_ficha_inicial()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id bigint := public.cliente_deportista_id();
begin
  if v_id is null then raise exception 'no autorizado'; end if;
  return (select jsonb_build_object('version', f.version, 'respuestas', f.respuestas, 'enviado_en', f.enviado_en)
            from public.fichas_iniciales f where f.deportista_id = v_id);
end $$;

-- El cliente guarda el borrador (p_enviar = false) o envía la ficha (p_enviar = true). Valida y limpia todo en el servidor.
create or replace function public.cliente_guardar_ficha_inicial(p_respuestas jsonb, p_enviar boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id  bigint := public.cliente_deportista_id();
  hoy   text   := to_char((now() at time zone 'Europe/Madrid')::date, 'YYYY-MM-DD');
  r     jsonb  := '{}'::jsonb;
  k     text;
  def   jsonb;
  t     text;
  n     numeric;
  a     jsonb;
  e     jsonb;
  c     jsonb;
  cm    jsonb;
  ok_v  boolean;
  -- textos libres (máx. 600 caracteres)
  textos constant text[] := array['ocupacion','enf_txt','med_txt','alerg_txt','dig_txt','les_txt','dieta_txt','ejer_txt','deporte',
    'horario','estilo_otro','obj_otro','electro_otro','evento_txt','reto','no_gusta','gusta','supl_txt','final_txt'];
  -- opciones cerradas
  opciones constant jsonb := jsonb_build_object(
    'sexo',        jsonb_build_array('Hombre','Mujer'),
    'enf',         jsonb_build_array('Sí','No'), 'med',  jsonb_build_array('Sí','No'), 'alerg', jsonb_build_array('Sí','No'),
    'dig',         jsonb_build_array('Sí','No'), 'anal', jsonb_build_array('Sí','No'), 'les',   jsonb_build_array('Sí','No'),
    'dieta',       jsonb_build_array('Sí','No'), 'ejer', jsonb_build_array('Sí','No'), 'evento',jsonb_build_array('Sí','No'),
    'supl',        jsonb_build_array('Sí','No'),
    'peso_cambio', jsonb_build_array('Se ha mantenido','Ha bajado','Ha subido'),
    'comidas_dia', jsonb_build_array('2','3','4','5 o más'),
    'entre',       jsonb_build_array('No','A veces','Frecuentemente'),
    'estilo',      jsonb_build_array('Omnívoro','Vegetariano','Vegano','Carnívoro','Otro'),
    'antojos',     jsonb_build_array('No','A veces','Sí'),
    'ejer_tiempo', jsonb_build_array('Menos de 1 mes','1-3 meses','Más de 3 meses'),
    'deporte_nivel', jsonb_build_array('Recreativo','Federado','Competición'),
    'quien',       jsonb_build_array('Yo','Pareja u otros'),
    'tiempo',      jsonb_build_array('Menos de 15 minutos','Entre 15 y 45 minutos','Más de 45 minutos'),
    'cocinar',     jsonb_build_array('Me gusta cocinar','Busco lo más práctico y rápido','Depende del día'));
  -- números: [mínimo, máximo, entero?]
  numeros constant jsonb := jsonb_build_object(
    'estatura', jsonb_build_array(100, 230, false), 'peso', jsonb_build_array(20, 300, false),
    'peso_hab', jsonb_build_array(20, 300, false), 'peso_cambio_kg', jsonb_build_array(0, 100, false),
    'entrenos_sem', jsonb_build_array(0, 21, true), 'entreno_dur', jsonb_build_array(5, 600, true),
    'sueno_h', jsonb_build_array(1, 16, false),
    'hidrat', jsonb_build_array(1, 10, true), 'nivel', jsonb_build_array(1, 5, true),
    'sueno_cal', jsonb_build_array(1, 5, true), 'estres', jsonb_build_array(1, 5, true));
  objs  constant text[] := array['Perder grasa','Ganar masa muscular','Mejorar rendimiento deportivo','Mejorar salud general','Mejorar digestión','Otro'];
  electros constant text[] := array['Horno','Microondas','Air Fryer','Fogones','Robot Thermomix','Otro'];
  comidas constant text[] := array['desayuno','almuerzo','comida','merienda','cena','otros'];
  obligatorias constant text[] := array['fnac','sexo','estatura','peso','ocupacion','enf','med','alerg','dig','anal','les','peso_cambio',
    'dieta','comidas_dia','entre','estilo','antojos','hidrat','ejer','nivel','sueno_h','sueno_cal','estres','obj','evento','no_gusta',
    'supl','quien','tiempo','electro','cocinar'];
begin
  if v_id is null then raise exception 'no autorizado'; end if;
  if jsonb_typeof(p_respuestas) is distinct from 'object' then raise exception 'datos no validos'; end if;
  if length(p_respuestas::text) > 40000 then raise exception 'datos demasiado grandes'; end if;
  if exists (select 1 from public.fichas_iniciales where deportista_id = v_id and enviado_en is not null) then
    raise exception 'ficha ya enviada';
  end if;

  -- fecha de nacimiento
  t := nullif(btrim(coalesce(p_respuestas->>'fnac', '')), '');
  if t is not null then
    if t !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'valor no valido: fnac'; end if;
    if t::date > (now() at time zone 'Europe/Madrid')::date or t::date < date '1900-01-01' then raise exception 'valor no valido: fnac'; end if;
    r := r || jsonb_build_object('fnac', t);
  end if;
  -- textos
  foreach k in array textos loop
    t := left(btrim(coalesce(p_respuestas->>k, '')), 600);
    if t <> '' then r := r || jsonb_build_object(k, t); end if;
  end loop;
  -- opciones cerradas
  for k, def in select * from jsonb_each(opciones) loop
    t := nullif(btrim(coalesce(p_respuestas->>k, '')), '');
    if t is not null then
      if not (def ? t) then raise exception 'valor no valido: %', k; end if;
      r := r || jsonb_build_object(k, t);
    end if;
  end loop;
  -- números
  for k, def in select * from jsonb_each(numeros) loop
    t := nullif(btrim(coalesce(p_respuestas->>k, '')), '');
    if t is not null then
      if t !~ '^-?\d+(\.\d+)?$' then raise exception 'valor no valido: %', k; end if;
      n := t::numeric;
      if n < (def->>0)::numeric or n > (def->>1)::numeric then raise exception 'valor no valido: %', k; end if;
      if (def->>2)::boolean and n <> trunc(n) then raise exception 'valor no valido: %', k; end if;
      r := r || jsonb_build_object(k, case when (def->>2)::boolean then to_jsonb(n::int) else to_jsonb(round(n, 1)) end);
    end if;
  end loop;
  -- listas cerradas (objetivos, electrodomésticos)
  for k, a in select 'obj', to_jsonb(objs) union all select 'electro', to_jsonb(electros) loop
    if p_respuestas ? k then
      if jsonb_typeof(p_respuestas->k) is distinct from 'array' then raise exception 'valor no valido: %', k; end if;
      c := '[]'::jsonb;
      for e in select * from jsonb_array_elements(p_respuestas->k) loop
        if jsonb_typeof(e) is distinct from 'string' or not (a ? (e #>> '{}')) then raise exception 'valor no valido: %', k; end if;
        if not (c ? (e #>> '{}')) then c := c || e; end if;
      end loop;
      if jsonb_array_length(c) > 0 then r := r || jsonb_build_object(k, c); end if;
    end if;
  end loop;
  -- un día típico: por comida, hora (HH:MM), alimentos y lugar
  if p_respuestas ? 'comidas' then
    if jsonb_typeof(p_respuestas->'comidas') is distinct from 'object' then raise exception 'valor no valido: comidas'; end if;
    cm := '{}'::jsonb;
    foreach k in array comidas loop
      e := p_respuestas->'comidas'->k;
      if e is not null and jsonb_typeof(e) = 'object' then
        c := '{}'::jsonb;
        t := nullif(btrim(coalesce(e->>'h', '')), '');
        if t is not null then
          if t !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'valor no valido: hora de %', k; end if;
          c := c || jsonb_build_object('h', t);
        end if;
        t := left(btrim(coalesce(e->>'a', '')), 400);
        if t <> '' then c := c || jsonb_build_object('a', t); end if;
        t := nullif(btrim(coalesce(e->>'l', '')), '');
        if t is not null then
          if t not in ('Casa','Trabajo o estudios','Restaurante','En la calle','Otro') then raise exception 'valor no valido: lugar de %', k; end if;
          c := c || jsonb_build_object('l', t);
        end if;
        if c <> '{}'::jsonb then cm := cm || jsonb_build_object(k, c); end if;
      end if;
    end loop;
    if cm <> '{}'::jsonb then r := r || jsonb_build_object('comidas', cm); end if;
  end if;
  -- cribado de la relación con la comida: 5 respuestas Sí/No (o ninguna si el cliente prefiere no contestar)
  if coalesce((p_respuestas->>'scoff_skip')::boolean, false) then
    r := r || jsonb_build_object('scoff_skip', true);
  elsif p_respuestas ? 'scoff' then
    if jsonb_typeof(p_respuestas->'scoff') is distinct from 'array' or jsonb_array_length(p_respuestas->'scoff') <> 5 then
      raise exception 'valor no valido: scoff';
    end if;
    c := '[]'::jsonb;
    for e in select * from jsonb_array_elements(p_respuestas->'scoff') loop
      if e is null or jsonb_typeof(e) = 'null' then c := c || 'null'::jsonb;
      elsif jsonb_typeof(e) = 'string' and (e #>> '{}') in ('Sí','No') then c := c || e;
      else raise exception 'valor no valido: scoff'; end if;
    end loop;
    r := r || jsonb_build_object('scoff', c);
  end if;

  if p_enviar then
    foreach k in array obligatorias loop
      if not (r ? k) then raise exception 'falta: %', k; end if;
    end loop;
    ok_v := exists (select 1 from jsonb_each(coalesce(r->'comidas', '{}'::jsonb)) x where nullif(x.value->>'a', '') is not null);
    if not ok_v then raise exception 'falta: comidas'; end if;
    if not (r ? 'scoff' or r ? 'scoff_skip') then raise exception 'falta: scoff'; end if;
  end if;

  insert into public.fichas_iniciales (deportista_id, respuestas, enviado_en)
  values (v_id, r, case when p_enviar then now() end)
  on conflict (deportista_id) do update
     set respuestas = excluded.respuestas, enviado_en = excluded.enviado_en, actualizado = now();

  if p_enviar then
    update public.clientes_deportivos
       set formularios = coalesce(formularios, '{}'::jsonb)
                         || jsonb_build_object('inicial', jsonb_build_object('hecho', hoy), 'anamnesis', jsonb_build_object('hecho', hoy))
     where id = v_id;
  end if;
  return jsonb_build_object('ok', true, 'enviado', p_enviar);
end $$;

revoke all on function public.cliente_mi_ficha_inicial() from public, anon;
revoke all on function public.cliente_guardar_ficha_inicial(jsonb, boolean) from public, anon;
grant execute on function public.cliente_mi_ficha_inicial() to authenticated;
grant execute on function public.cliente_guardar_ficha_inicial(jsonb, boolean) to authenticated;

-- ============================================================
-- Comprobación (opcional):
--   select deportista_id, enviado_en, jsonb_object_keys(respuestas) from public.fichas_iniciales limit 20;
-- Marcha atrás: drop function public.cliente_guardar_ficha_inicial(jsonb, boolean);
--               drop function public.cliente_mi_ficha_inicial();  drop table public.fichas_iniciales;
-- ============================================================
