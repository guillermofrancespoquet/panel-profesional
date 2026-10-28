-- ============================================================
-- «PLAN POR PREPARAR»: recordatorio, tras una consulta, de que hay que preparar el plan nutricional del cliente
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Una sola columna en `clientes_deportivos` (tabla «solo profesional»: el cliente no la lee nunca; `cliente_mi_ficha` no la incluye):
--   plan_pendiente jsonb = {"desde": "YYYY-MM-DD" (día de la consulta), "para": "YYYY-MM-DD" (fecha en que quieres tenerlo)}
-- El panel lo marca al registrar una consulta («Plan por preparar») y lo muestra en «Por atender» y en «Estado del cliente» hasta
-- que publicas un plan nuevo (se comprueba con `menus_cliente.publicado_en` ≥ `desde`) o lo quitas a mano.
-- Sin esta columna el panel funciona igual: la opción no aparece en «Registrar consulta».
-- ============================================================
alter table public.clientes_deportivos add column if not exists plan_pendiente jsonb;
alter table public.clientes_deportivos drop constraint if exists clientes_deportivos_plan_pendiente_chk;
alter table public.clientes_deportivos add constraint clientes_deportivos_plan_pendiente_chk
  check (plan_pendiente is null or (jsonb_typeof(plan_pendiente) = 'object' and pg_column_size(plan_pendiente) < 300));
-- Marcha atrás: alter table public.clientes_deportivos drop column plan_pendiente;
