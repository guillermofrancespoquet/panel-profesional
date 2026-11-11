-- ============================================================
-- ANALÍTICAS VISIBLES PARA EL CLIENTE
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere `supabase_analiticas.sql` y `supabase_clientes_acceso.sql` (usa cliente_deportista_id()).
--
-- Desde la ficha (Mediciones → Analíticas) el profesional pulsa «Compartir con el cliente» en cada analítica y, si quiere,
-- escribe un mensaje corto para el cliente. El cliente la ve en «Composición corporal» → «Mis analíticas»: fecha,
-- laboratorio, su mensaje y cada prueba con su resultado, el rango del laboratorio y el estado.
-- NUNCA recibe las notas privadas (`notas`) ni el archivo original (`archivo_path`). Nada se comparte solo.
-- ============================================================

alter table public.analiticas add column if not exists visible_cliente boolean not null default false;
alter table public.analiticas add column if not exists nota_cliente text;

do $$ begin
  alter table public.analiticas add constraint analiticas_nota_cliente_len check (nota_cliente is null or char_length(nota_cliente) <= 500);
exception when duplicate_object then null; end $$;

create or replace function public.cliente_mis_analiticas()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'fecha', a.fecha, 'laboratorio', a.laboratorio, 'nota', a.nota_cliente,
           'valores', (select coalesce(jsonb_agg(jsonb_build_object(
                          'n', x->'n', 'sec', x->'sec', 'v', x->'v', 'op', x->'op', 'u', x->'u',
                          'min', x->'min', 'max', x->'max', 'e', x->'e')), '[]'::jsonb)
                         from jsonb_array_elements(case when jsonb_typeof(a.valores) = 'array' then a.valores else '[]'::jsonb end) x))
         order by a.fecha, a.id), '[]'::jsonb)
    from public.analiticas a
   where a.deportista_id = public.cliente_deportista_id()
     and a.visible_cliente
$$;

revoke all on function public.cliente_mis_analiticas() from public, anon;
grant execute on function public.cliente_mis_analiticas() to authenticated;

-- Comprobación (opcional):  select id, fecha, visible_cliente from public.analiticas order by fecha desc;
-- Marcha atrás: drop function public.cliente_mis_analiticas();
--               alter table public.analiticas drop column visible_cliente, drop column nota_cliente;
