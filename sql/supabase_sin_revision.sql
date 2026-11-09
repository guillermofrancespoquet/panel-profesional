-- ============================================================
-- «SIN REVISIÓN PREVISTA»: el profesional decide que un cliente no tiene próxima revisión
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Una sola columna en `clientes_deportivos` (tabla «solo profesional»: el cliente no la lee nunca; `cliente_mi_ficha` no la incluye):
--   sin_revision jsonb = {"desde": "YYYY-MM-DD" (día en que se decidió), "nota": "texto opcional, máx. 120"}
-- Mientras esté marcada, la Cartera no avisa de «sin revisión programada» y «Estado del cliente» lo muestra sin aviso.
-- El panel la quita solo al poner una fecha de revisión. Sin esta columna el panel funciona igual y avisa al intentar marcarla.
-- ============================================================
alter table public.clientes_deportivos add column if not exists sin_revision jsonb;
alter table public.clientes_deportivos drop constraint if exists clientes_deportivos_sin_revision_chk;
alter table public.clientes_deportivos add constraint clientes_deportivos_sin_revision_chk
  check (sin_revision is null or (jsonb_typeof(sin_revision) = 'object' and pg_column_size(sin_revision) < 400));
-- Marcha atrás: alter table public.clientes_deportivos drop column sin_revision;
