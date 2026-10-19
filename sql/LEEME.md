# SQL de Supabase

Todos se ejecutan a mano en Supabase → SQL Editor → New query → Run. Son seguros de repetir **salvo lo indicado** (ver «Ojo»).

## Orden de ejecución en una base nueva

1. `supabase_antropometria.sql`
2. `supabase_sudoracion.sql` y `supabase_plan_competicion.sql`
3. `supabase_seguridad_1_tokens.sql`
4. `supabase_clientes_acceso.sql` (cambiar antes `TU_CORREO@EJEMPLO.COM` por el correo del profesional)
5. Cadena de `cliente_mi_ficha`, **en este orden**: `supabase_formularios.sql` → `supabase_revision_hora.sql` → `supabase_seguimiento.sql` → `supabase_nota_cliente.sql`
6. El resto, en cualquier orden, respetando los requisitos:
   - `supabase_plan_compartir.sql` (necesita `supabase_plan_competicion.sql`)
   - `supabase_sudoracion_compartir.sql` (necesita `supabase_sudoracion.sql`)
   - `supabase_bioimpedancia.sql`
   - `supabase_registro_cliente.sql`
   - `supabase_diario_comidas.sql` (necesita `supabase_registro_cliente.sql`)
   - `supabase_suplementacion.sql`
   - `supabase_citas_hecha.sql`
   - `supabase_menu_semanal.sql` (menú semanal: catálogo de alimentos, menús, publicar)
   - `supabase_biblioteca_platos.sql` (menú semanal: biblioteca de platos ampliable desde la app; requiere solo `supabase_clientes_acceso.sql`)
7. `supabase_seguridad_2_cerrar.sql`, **el último**, solo cuando se cumplan las condiciones de su cabecera.

## Ojo

- Cada archivo de la cadena del punto 5 **sustituye** a la función `cliente_mi_ficha` del anterior. Volver a ejecutar uno anterior después de uno posterior deshace los campos que añadió el posterior (por ejemplo, ejecutar `supabase_formularios.sql` tras `supabase_nota_cliente.sql` quitaría la nota). Si hay que repetir uno, ejecutar otra vez los siguientes en orden.
- En la base real de producción ya están ejecutados todos, salvo los que se vayan añadiendo (se avisa en cada PR).

## No es SQL

- `supabase_funcion_invitar_cliente.ts` es la Edge Function `invitar-cliente`: se pega en Supabase → Edge Functions → Via Editor.

## Convención

Un archivo nuevo por cambio de esquema, aquí en `sql/`, con su cabecera (qué hace, qué requiere, marcha atrás) y una línea nueva en este orden.
