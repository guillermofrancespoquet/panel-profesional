-- ============================================================
-- SEGURIDAD · PASO 1 de 2 — Enlaces personales del Método 3M
-- ============================================================
-- Es ADITIVO: no quita ningún acceso, así que se puede ejecutar sin riesgo.
-- Ejecutar en Supabase → SQL Editor, ANTES de fusionar la PR de seguridad.
--
-- Qué hace:
--   1) Añade a `clientes` una clave secreta larga (`token`) por cliente.
--   2) Crea tres funciones (RPC) que reciben ese token y solo permiten a cada cliente
--      leer SU fila y escribir SUS marcas (`checks`) y SUS notas (`client_notes`).
--      No pueden tocar la semana desbloqueada ni ningún otro campo: eso lo hace el
--      profesional desde el Panel.
--   3) Con esto, la página del cliente ya no necesita acceso directo a la tabla, y el
--      paso 2 podrá cerrarla.
-- ============================================================

-- 0) Comprobar que las columnas son las esperadas (si no, se detiene con un aviso claro).
do $$
declare t text;
begin
  select data_type into t from information_schema.columns
    where table_schema = 'public' and table_name = 'clientes' and column_name = 'checks';
  if t is distinct from 'jsonb' then
    raise exception 'clientes.checks no es jsonb (es %). No sigas y avisa.', coalesce(t, 'inexistente');
  end if;

  select data_type into t from information_schema.columns
    where table_schema = 'public' and table_name = 'clientes' and column_name = 'client_notes';
  if t is distinct from 'jsonb' then
    raise exception 'clientes.client_notes no es jsonb (es %). No sigas y avisa.', coalesce(t, 'inexistente');
  end if;

  select data_type into t from information_schema.columns
    where table_schema = 'public' and table_name = 'clientes' and column_name = 'semana';
  if t is null or t not in ('integer', 'smallint', 'bigint') then
    raise exception 'clientes.semana no es un entero (es %). No sigas y avisa.', coalesce(t, 'inexistente');
  end if;
end $$;

-- 1) Token secreto por cliente: 64 caracteres hexadecimales (dos UUID aleatorios, ~240 bits).
alter table public.clientes add column if not exists token text;

update public.clientes
   set token = replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
 where token is null;

alter table public.clientes
  alter column token set default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));
alter table public.clientes alter column token set not null;

create unique index if not exists clientes_token_key on public.clientes (token);

-- 2) Funciones de acceso del cliente. SECURITY DEFINER = se ejecutan con permisos del propietario,
--    por eso el cliente no necesita acceso directo a la tabla.

-- Lectura: devuelve solo semana, marcas y notas de SU fila (o null si el token no existe).
create or replace function public.m3m_cliente(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('semana', c.semana, 'checks', c.checks, 'client_notes', c.client_notes)
    from public.clientes c
   where length(coalesce(p_token, '')) >= 32
     and c.token = p_token
$$;

-- Escritura de las marcas de la semana (solo `checks`).
create or replace function public.m3m_guardar_checks(p_token text, p_checks jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if length(coalesce(p_token, '')) < 32 then return; end if;
  if jsonb_typeof(p_checks) is distinct from 'object' or length(p_checks::text) > 20000 then
    raise exception 'datos no validos';
  end if;
  update public.clientes set checks = p_checks where token = p_token;
end $$;

-- Escritura de la nota de una semana (solo esa clave de `client_notes`).
create or replace function public.m3m_guardar_nota(p_token text, p_semana int, p_texto text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if length(coalesce(p_token, '')) < 32 then return; end if;
  if p_semana is null or p_semana < 1 or p_semana > 12 then raise exception 'semana no valida'; end if;
  if length(coalesce(p_texto, '')) > 8000 then raise exception 'nota demasiado larga'; end if;
  update public.clientes
     set client_notes = coalesce(client_notes, '{}'::jsonb) || jsonb_build_object(p_semana::text, coalesce(p_texto, ''))
   where token = p_token;
end $$;

-- Permisos: por defecto Postgres da EXECUTE a todos; se deja explícito quién puede llamarlas.
revoke all on function public.m3m_cliente(text) from public;
revoke all on function public.m3m_guardar_checks(text, jsonb) from public;
revoke all on function public.m3m_guardar_nota(text, int, text) from public;
grant execute on function public.m3m_cliente(text) to anon, authenticated;
grant execute on function public.m3m_guardar_checks(text, jsonb) to anon, authenticated;
grant execute on function public.m3m_guardar_nota(text, int, text) to anon, authenticated;

-- ============================================================
-- Comprobación (opcional): cada cliente debe tener su token y la función debe devolver su fila.
--   select id, nombre, left(token, 8) as token_inicio from public.clientes order by id;
--   select public.m3m_cliente((select token from public.clientes limit 1));
-- ============================================================
