# SQL de Supabase

Todos se ejecutan a mano en Supabase → SQL Editor → New query → Run. Son seguros de repetir **salvo lo indicado** (ver «Ojo»).

## Orden de ejecución en una base nueva

1. `supabase_antropometria.sql`
2. `supabase_sudoracion.sql` y `supabase_plan_competicion.sql`
3. `supabase_seguridad_1_tokens.sql`
4. `supabase_seguridad_2_cerrar.sql` (solo cuando se cumplan las condiciones de su cabecera; **va antes del siguiente**: si `supabase_clientes_acceso.sql` ya está ejecutado, se niega a ejecutarse, porque dejaría las tablas abiertas a los clientes)
5. `supabase_clientes_acceso.sql` (cambiar antes `TU_CORREO@EJEMPLO.COM` por el correo del profesional)
6. Cadena de `cliente_mi_ficha`, **en este orden**: `supabase_formularios.sql` → `supabase_revision_hora.sql` → `supabase_seguimiento.sql` → `supabase_nota_cliente.sql`
7. El resto, en cualquier orden, respetando los requisitos:
   - `supabase_plan_compartir.sql` (necesita `supabase_plan_competicion.sql`)
   - `supabase_sudoracion_compartir.sql` (necesita `supabase_sudoracion.sql`)
   - `supabase_bioimpedancia.sql`
   - `supabase_registro_cliente.sql`
   - `supabase_diario_comidas.sql` (necesita `supabase_registro_cliente.sql`)
   - `supabase_suplementacion.sql`
   - `supabase_citas_hecha.sql`
   - `supabase_menu_semanal.sql` (menú semanal: catálogo de alimentos, menús, publicar)
   - `supabase_biblioteca_platos.sql` (ya opcional desde nov 2026: la lista de comidas es `comidas_banco`; esta tabla solo sirve para pasar los platos antiguos con «Pasarlos a mis comidas»)
   - `supabase_banco_recetas.sql` (plan nutricional: banco compartido de recetas y comidas guardadas; requiere solo `supabase_clientes_acceso.sql`)
   - `supabase_objetivos.sql` (objetivos del cliente con seguimiento, opcional, y peso reciente para reajustar las kcal del plan; requiere `supabase_clientes_acceso.sql`, `supabase_seguimiento.sql`, `supabase_bioimpedancia.sql` y `supabase_registro_cliente.sql`)
   - `supabase_notificaciones.sql` (avisos al móvil del cliente: seguimiento semanal; requiere `supabase_seguimiento.sql`; **además hay que crear la Edge Function y programarla**, ver «Avisos al móvil» más abajo)
8. `supabase_seguridad_3_endurecer.sql`, **el último** (endurecimiento tras la revisión de seguridad del 26 oct 2026: rutas de archivos, límites, direcciones de avisos, privilegios; sustituye tres funciones por su versión endurecida, que ya llevan también sus archivos originales). Después, `supabase_diagnostico_seguridad.sql` (solo lectura): todo debe salir «OK».
9. `supabase_proteccion_datos.sql` (protección de datos: consentimientos, baja del cliente y registro de eliminaciones; **después del paso 8**, no cambia sus funciones; ver «Protección de datos» más abajo)

## Ojo

- Cada archivo de la cadena del punto 6 **sustituye** a la función `cliente_mi_ficha` del anterior. Volver a ejecutar uno anterior después de uno posterior deshace los campos que añadió el posterior (por ejemplo, ejecutar `supabase_formularios.sql` tras `supabase_nota_cliente.sql` quitaría la nota). Si hay que repetir uno, ejecutar otra vez los siguientes en orden.
- En la base real de producción ya están ejecutados todos, salvo los que se vayan añadiendo (se avisa en cada PR).

## No es SQL

- `supabase_funcion_invitar_cliente.ts` es la Edge Function `invitar-cliente`: se pega en Supabase → Edge Functions → Via Editor.
- `supabase_funcion_eliminar_cuenta_cliente.ts` es la Edge Function `eliminar-cuenta-cliente` (ver «Protección de datos» más abajo).

## Avisos al móvil (notificaciones del seguimiento semanal)

Pasos, una sola vez y en este orden (hasta el paso 5 el cliente no ve nada nuevo):

1. Ejecutar `supabase_notificaciones.sql`.
2. **Generar las claves VAPID** (las crea tu navegador; la privada no sale de ahí). En cualquier pestaña, consola de desarrollador, pega esto:
   ```js
   (async()=>{const k=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
   const b=a=>btoa(String.fromCharCode(...new Uint8Array(a))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
   console.log('PUBLICA:',b(await crypto.subtle.exportKey('raw',k.publicKey)));
   console.log('PRIVADA_JWK:',JSON.stringify(await crypto.subtle.exportKey('jwk',k.privateKey)));})()
   ```
   La **pública** se pega en la constante `VAPID_PUBLICA` de `cliente.html` (no es secreta). La **privada** (JWK) solo va a los secretos de Supabase; no la pegues en chats ni en el repo.
3. Supabase → Edge Functions → nueva función `avisos-seguimiento` → «Via Editor» → pegar `supabase_funcion_avisos_seguimiento.ts` → **desactivar «Verify JWT»** → Deploy.
4. Edge Functions → Secrets: `AVISOS_SECRET` (una clave larga cualquiera), `VAPID_PRIVADA_JWK` (el JSON de la privada), `VAPID_PUBLICA` (la pública) y `VAPID_CONTACTO` (`mailto:tu@correo`).
5. Database → Extensions: activar `pg_cron` y `pg_net`; después ejecutar en el SQL Editor el bloque «PROGRAMACIÓN» del final de `supabase_notificaciones.sql` (con tu `AVISOS_SECRET`).
6. Prueba: con un cliente de pruebas con el seguimiento activo y el aviso activado, llamar a la función con `?forzar=1` (salta la comprobación de lunes) y la cabecera `x-cron-secret`; debe llegar el aviso al móvil.

## Protección de datos (consentimiento, baja y eliminación de clientes)

1. Ejecuta `supabase_proteccion_datos.sql` (después de `supabase_seguridad_3_endurecer.sql`). Es seguro repetirlo. Luego ejecuta `supabase_diagnostico_seguridad.sql`: debe seguir todo «OK».
2. Instala la Edge Function `eliminar-cuenta-cliente` (Supabase → Edge Functions → «Deploy a new function» → «Via Editor» → nombre `eliminar-cuenta-cliente` → pega `supabase_funcion_eliminar_cuenta_cliente.ts` → «Deploy function», con «Verify JWT» activado; no necesita secretos). Sin ella, al eliminar a un cliente el panel te dice el correo de su cuenta para que la borres a mano en Authentication → Users.
3. En el panel → Ajustes → **Protección de datos**: rellena tu nombre o razón social, NIF, dirección y un correo de contacto, y los años de conservación (mínimo 5; art. 17 de la Ley 41/2002). **Antes de activar, revisa los dos textos con un profesional del derecho** («Ver y editar los textos»; lo que traen es un borrador). Al guardar con nombre y contacto, el consentimiento queda activado: cada cliente lo verá al entrar en su área.
4. Clientes sin acceso al área (o que firmaron en papel): en la ficha → Archivos → Datos y privacidad → «Registrar aceptación en papel».

Qué se hace con la conservación: **dar de baja** al cliente (ficha → Archivos → Datos y privacidad) fija la fecha de alta del proceso asistencial; el panel te dice hasta cuándo conservarlo. **Eliminar** antes de esa fecha es posible (escribiendo ELIMINAR y con un motivo), pero queda anotado como «antes del plazo» en el registro y en el justificante.

## Convención

Un archivo nuevo por cambio de esquema, aquí en `sql/`, con su cabecera (qué hace, qué requiere, marcha atrás) y una línea nueva en este orden.
