-- ============================================================
-- PROTECCIÓN DE DATOS (RGPD): consentimientos con versiones, datos del responsable, baja del cliente y registro de eliminaciones
-- ============================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run. Es seguro ejecutarlo más de una vez.
-- Requiere haber ejecutado antes `supabase_clientes_acceso.sql` (usa es_profesional() y cliente_deportista_id()) y, para que el
-- permiso de fotos se exija de verdad, `supabase_registro_cliente.sql` y `supabase_diario_comidas.sql`.
-- Ejecutar DESPUÉS de `supabase_seguridad_3_endurecer.sql` (no cambia ninguna función de ese archivo: usa disparadores).
--
-- Qué añade:
--  · `ajustes_app` (clave → jsonb, «solo profesional»): `responsable` {nombre, nif, direccion, contacto} y `retencion` {anios}.
--    **El consentimiento no se activa hasta que `responsable` tiene nombre y contacto** (así puedes revisar los textos antes).
--  · `consentimiento_textos`: los textos legales por tipo y versión (`tratamiento` = obligatorio para usar el área; `fotos` = opcional).
--    Solo se puede leer e insertar (nunca modificar ni borrar): cada versión queda como prueba. Una versión nueva con
--    `cambio_sustancial` obliga a volver a aceptar; sin él (corrección de una errata), no. Los marcadores {{responsable}},
--    {{nif}}, {{direccion}}, {{contacto}} y {{anios}} se sustituyen por tus datos al mostrar y al guardar la aceptación.
--    **Los dos textos que se insertan aquí son un BORRADOR: revísalos con un profesional del derecho antes de activarlos.**
--  · `consentimientos`: una fila por aceptación (cliente, tipo, versión, **copia del texto exacto aceptado**, fecha y quién la
--    registró: el cliente en la app o el profesional en papel). Retirar = rellenar `retirado_en`. Tabla «solo profesional».
--  · `clientes_deportivos.fecha_baja`: fecha de alta (fin) del proceso asistencial; de ella cuenta el plazo de conservación.
--  · `registro_eliminaciones`: qué se eliminó, cuándo y si fue antes del plazo, **sin datos de salud** (solo iniciales). Solo
--    se puede leer e insertar.
--  · Funciones del cliente: `cliente_consentimientos()` (qué textos hay y si los ha aceptado), `cliente_aceptar_consentimiento`
--    y `cliente_retirar_consentimiento` (solo el de fotos; el de tratamiento se retira escribiendo al responsable).
--  · Disparadores: con el consentimiento activo, no se puede añadir una foto de progreso ni de comida si el cliente no ha
--    aceptado el consentimiento de fotos (se exige en el servidor, no solo en la pantalla).
-- ============================================================

-- ── Ajustes de la aplicación (datos del responsable y plazo de conservación) ──────────────
create table if not exists public.ajustes_app (
  clave       text primary key check (char_length(clave) between 1 and 60),
  valor       jsonb not null check (jsonb_typeof(valor) = 'object' and pg_column_size(valor) < 20000),
  actualizado timestamptz not null default now()
);
alter table public.ajustes_app enable row level security;
drop policy if exists "solo profesional" on public.ajustes_app;
create policy "solo profesional" on public.ajustes_app
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());
revoke all on public.ajustes_app from anon;

-- ── Textos legales, por tipo y versión (solo se añaden versiones nuevas) ───────────────────
create table if not exists public.consentimiento_textos (
  id                bigint generated always as identity primary key,
  tipo              text    not null check (tipo in ('tratamiento', 'fotos')),
  version           int     not null check (version > 0),
  titulo            text    not null check (char_length(titulo) between 1 and 200),
  texto             text    not null check (char_length(texto) between 1 and 20000),
  cambio_sustancial boolean not null default true,
  creado            timestamptz not null default now(),
  unique (tipo, version)
);
alter table public.consentimiento_textos enable row level security;
drop policy if exists "profesional lee" on public.consentimiento_textos;
create policy "profesional lee" on public.consentimiento_textos for select to authenticated using (public.es_profesional());
drop policy if exists "profesional añade" on public.consentimiento_textos;
create policy "profesional añade" on public.consentimiento_textos for insert to authenticated with check (public.es_profesional());
revoke all on public.consentimiento_textos from anon;
revoke update, delete, truncate on public.consentimiento_textos from authenticated;

-- BORRADOR de la versión 1 (revisar con un profesional del derecho antes de activar el consentimiento).
insert into public.consentimiento_textos (tipo, version, titulo, texto, cambio_sustancial)
select 'tratamiento', 1, 'Protección de tus datos personales', $t$Responsable del tratamiento: {{responsable}} (NIF/DNI: {{nif}}). Dirección: {{direccion}}. Contacto: {{contacto}}.

Para qué usamos tus datos: para prestarte el servicio de asesoramiento nutricional: valorar tu situación, elaborar y ajustar tu plan, hacer tu seguimiento y gestionar las citas y los cobros.

Qué datos tratamos: datos identificativos y de contacto; datos de salud, hábitos y composición corporal (cuestionarios, medidas, peso, informes, bioimpedancia); lo que anotas en tu área (peso, diario de comidas, seguimiento semanal) y, solo si lo autorizas aparte, tus fotos.

Base legal: la relación profesional contigo y, para los datos de salud, tu consentimiento explícito, que das al aceptar este texto.

Quién los ve: solo {{responsable}}. No se ceden a terceros salvo obligación legal. Usamos proveedores tecnológicos (alojamiento de la aplicación y envío de correos) que tratan los datos por encargo nuestro y con las garantías que exige la ley.

Cuánto tiempo los conservamos: la documentación clínica se conserva, como mínimo, {{anios}} años desde el alta de cada proceso asistencial (artículo 17 de la Ley 41/2002). Pasado ese plazo, se elimina.

Tus derechos: puedes pedir acceso, rectificación, supresión (con el límite de ese plazo legal de conservación), oposición, limitación del tratamiento y portabilidad, y retirar tu consentimiento en cualquier momento, sin efecto retroactivo, escribiendo a {{contacto}}. Si no te atendemos bien, puedes reclamar ante la Agencia Española de Protección de Datos (www.aepd.es).

Si eres menor de 14 años, debe aceptar este texto tu madre, padre o tutor legal.$t$, true
where not exists (select 1 from public.consentimiento_textos where tipo = 'tratamiento' and version = 1);

insert into public.consentimiento_textos (tipo, version, titulo, texto, cambio_sustancial)
select 'fotos', 1, 'Tus fotos de seguimiento', $t$Si quieres, puedes subir fotos (de progreso o de tus comidas) a tu área. Las usamos solo para seguir tu evolución y comentar tu alimentación.

Quién las ve: solo tú y {{responsable}}. No se publican, no se comparten con nadie y no se usan para nada más.

Puedes retirar este permiso cuando quieras desde «Privacidad» en tu área (dejarás de poder subir fotos nuevas) y pedir que se borren las que ya subiste escribiendo a {{contacto}}; se eliminan salvo que exista obligación legal de conservarlas.$t$, true
where not exists (select 1 from public.consentimiento_textos where tipo = 'fotos' and version = 1);

-- ── Aceptaciones (una fila por aceptación; la copia del texto es la prueba) ───────────────
create table if not exists public.consentimientos (
  id            bigint generated always as identity primary key,
  deportista_id bigint not null references public.clientes_deportivos (id) on delete cascade,
  tipo          text   not null check (tipo in ('tratamiento', 'fotos')),
  version       int    not null check (version > 0),
  texto         text   not null,
  origen        text   not null default 'cliente' check (origen in ('cliente', 'profesional')),
  aceptado_en   timestamptz not null default now(),
  retirado_en   timestamptz
);
create index if not exists consentimientos_dep on public.consentimientos (deportista_id, tipo, aceptado_en desc);
alter table public.consentimientos enable row level security;
drop policy if exists "solo profesional" on public.consentimientos;
create policy "solo profesional" on public.consentimientos
  for all to authenticated using (public.es_profesional()) with check (public.es_profesional());
revoke all on public.consentimientos from anon;

-- ── Baja del cliente (fin del proceso asistencial: de aquí cuenta la conservación) ─────────
alter table public.clientes_deportivos add column if not exists fecha_baja date;

-- ── Registro de eliminaciones (sin datos de salud) ────────────────────────────────────────
create table if not exists public.registro_eliminaciones (
  id               bigint generated always as identity primary key,
  eliminado_en     timestamptz not null default now(),
  deportista_id    bigint,
  iniciales        text check (iniciales is null or char_length(iniciales) <= 8),
  fecha_baja       date,
  ultima_actividad date,
  conservar_hasta  date,
  antes_de_plazo   boolean not null default false,
  motivo           text check (motivo is null or char_length(motivo) <= 300),
  resumen          jsonb check (resumen is null or (jsonb_typeof(resumen) = 'object' and pg_column_size(resumen) < 20000))
);
alter table public.registro_eliminaciones enable row level security;
drop policy if exists "profesional lee" on public.registro_eliminaciones;
create policy "profesional lee" on public.registro_eliminaciones for select to authenticated using (public.es_profesional());
drop policy if exists "profesional añade" on public.registro_eliminaciones;
create policy "profesional añade" on public.registro_eliminaciones for insert to authenticated with check (public.es_profesional());
revoke all on public.registro_eliminaciones from anon;
revoke update, delete, truncate on public.registro_eliminaciones from authenticated;

-- ── Utilidades internas (las usan las funciones de abajo; nadie las llama desde fuera) ─────
create or replace function public.consent_activo()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select coalesce(valor->>'nombre', '') <> '' and coalesce(valor->>'contacto', '') <> ''
                   from public.ajustes_app where clave = 'responsable'), false)
$$;

create or replace function public.consent_texto(p_tipo text, p_version int)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select replace(replace(replace(replace(replace(t.texto,
           '{{responsable}}', coalesce((select valor->>'nombre'    from public.ajustes_app where clave = 'responsable'), '')),
           '{{nif}}',         coalesce((select valor->>'nif'       from public.ajustes_app where clave = 'responsable'), '')),
           '{{direccion}}',   coalesce((select valor->>'direccion' from public.ajustes_app where clave = 'responsable'), '')),
           '{{contacto}}',    coalesce((select valor->>'contacto'  from public.ajustes_app where clave = 'responsable'), '')),
           '{{anios}}',       coalesce((select valor->>'anios'     from public.ajustes_app where clave = 'retencion'), '5'))
  from public.consentimiento_textos t where t.tipo = p_tipo and t.version = p_version
$$;

create or replace function public.consent_version_requerida(p_tipo text)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(max(version), 0)::int from public.consentimiento_textos where tipo = p_tipo and cambio_sustancial
$$;

-- ¿Tiene el cliente un consentimiento vigente de ese tipo? (si no hay ningún texto de ese tipo, no se exige)
create or replace function public.consent_vigente(p_dep bigint, p_tipo text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.consent_version_requerida(p_tipo) = 0
      or exists (select 1 from public.consentimientos c
                 where c.deportista_id = p_dep and c.tipo = p_tipo and c.retirado_en is null
                   and c.version >= public.consent_version_requerida(p_tipo))
$$;

revoke all on function public.consent_activo() from public, anon, authenticated;
revoke all on function public.consent_texto(text, int) from public, anon, authenticated;
revoke all on function public.consent_version_requerida(text) from public, anon, authenticated;
revoke all on function public.consent_vigente(bigint, text) from public, anon, authenticated;

-- ── Lo que ve el cliente ──────────────────────────────────────────────────────────────────
create or replace function public.cliente_consentimientos()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  dep bigint := public.cliente_deportista_id();
  r   jsonb;
begin
  if dep is null then raise exception 'sin acceso'; end if;
  if not public.consent_activo() then return jsonb_build_object('activo', false); end if;
  select valor into r from public.ajustes_app where clave = 'responsable';
  return jsonb_build_object(
    'activo', true,
    'responsable', r->>'nombre',
    'contacto', r->>'contacto',
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tipo', t.tipo, 'version', t.version, 'titulo', t.titulo,
               'texto', public.consent_texto(t.tipo, t.version),
               'aceptado', public.consent_vigente(dep, t.tipo),
               'aceptado_en', (select max(c.aceptado_en) from public.consentimientos c
                               where c.deportista_id = dep and c.tipo = t.tipo and c.retirado_en is null)
             ) order by t.tipo)
      from public.consentimiento_textos t
      where t.version = (select max(x.version) from public.consentimiento_textos x where x.tipo = t.tipo)), '[]'::jsonb));
end $$;

create or replace function public.cliente_aceptar_consentimiento(p_tipo text, p_version int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  dep bigint := public.cliente_deportista_id();
  v   int;
begin
  if dep is null then raise exception 'sin acceso'; end if;
  if not public.consent_activo() then raise exception 'consentimiento no activado'; end if;
  select max(version) into v from public.consentimiento_textos where tipo = p_tipo;
  if v is null or p_version is distinct from v then raise exception 'texto no vigente'; end if;
  if not public.consent_vigente(dep, p_tipo)
     or not exists (select 1 from public.consentimientos where deportista_id = dep and tipo = p_tipo and retirado_en is null and version = v) then
    insert into public.consentimientos (deportista_id, tipo, version, texto, origen)
    values (dep, p_tipo, v, public.consent_texto(p_tipo, v), 'cliente');
  end if;
  return jsonb_build_object('ok', true, 'tipo', p_tipo, 'version', v);
end $$;

create or replace function public.cliente_retirar_consentimiento(p_tipo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare dep bigint := public.cliente_deportista_id();
begin
  if dep is null then raise exception 'sin acceso'; end if;
  if p_tipo <> 'fotos' then return jsonb_build_object('ok', false, 'motivo', 'contacta'); end if;
  update public.consentimientos set retirado_en = now()
  where deportista_id = dep and tipo = 'fotos' and retirado_en is null;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.cliente_consentimientos() from public, anon;
grant execute on function public.cliente_consentimientos() to authenticated;
revoke all on function public.cliente_aceptar_consentimiento(text, int) from public, anon;
grant execute on function public.cliente_aceptar_consentimiento(text, int) to authenticated;
revoke all on function public.cliente_retirar_consentimiento(text) from public, anon;
grant execute on function public.cliente_retirar_consentimiento(text) to authenticated;

-- ── El permiso de fotos se exige en el servidor ───────────────────────────────────────────
create or replace function public.trg_consent_fotos()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.consent_activo() and not public.consent_vigente(new.deportista_id, 'fotos') then
    raise exception 'falta el consentimiento para subir fotos';
  end if;
  return new;
end $$;
revoke all on function public.trg_consent_fotos() from public, anon, authenticated;

create or replace function public.trg_consent_fotos_comida()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.foto_path is not null and public.consent_activo() and not public.consent_vigente(new.deportista_id, 'fotos') then
    raise exception 'falta el consentimiento para subir fotos';
  end if;
  return new;
end $$;
revoke all on function public.trg_consent_fotos_comida() from public, anon, authenticated;

do $$
begin
  if to_regclass('public.fotos_cliente') is not null then
    drop trigger if exists fotos_cliente_consent on public.fotos_cliente;
    create trigger fotos_cliente_consent before insert on public.fotos_cliente
      for each row execute function public.trg_consent_fotos();
  end if;
  if to_regclass('public.comidas_cliente') is not null then
    drop trigger if exists comidas_cliente_consent on public.comidas_cliente;
    create trigger comidas_cliente_consent before insert on public.comidas_cliente
      for each row execute function public.trg_consent_fotos_comida();
  end if;
end $$;

-- ── Marcha atrás (si hiciera falta): ─────────────────────────────────────────────────────
--   drop trigger if exists fotos_cliente_consent on public.fotos_cliente;
--   drop trigger if exists comidas_cliente_consent on public.comidas_cliente;
--   (las tablas y las funciones no estorban si se dejan; sin `responsable` en `ajustes_app` el consentimiento no se exige)
