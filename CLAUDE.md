# NutriLogos — Panel Profesional (contexto para Claude Code)

Apps web de gestión para Guillermo Frances (nutrición deportiva, Valencia). Todo se sirve con **GitHub Pages** desde este repo. Idioma de la interfaz y de la conversación: **español**.

## Archivos y qué hace cada uno

| Archivo | Qué es |
|---|---|
| `panel-profesional.html` | App principal (login con PIN, dashboard, agenda, facturación, Método 3M, Nutrición Deportiva, herramientas). |
| `calculadora_antropometria.html` | Calculadora ISAK de antropometría. Se muestra **dentro del panel** en un iframe con `?embed=1` (`cargarAntropometria()` / `abrirAntropometria(depId)`, que pasa `&c=<id>` para dejar abierto a ese deportista) y también funciona sola en su propia URL. Guarda en Supabase. |
| `metodo-3-meses-final.html` | Programa Método 3 Meses (satélite, abierto desde el panel). **No revisado en la sesión donde se creó este archivo: léelo entero antes de tocarlo.** |
| `icon-192.png`, `icon-512.png` | Iconos PWA (los usan ambos manifests). |
| `manifest-panel.json` | Manifest PWA del panel (`start_url` → `panel-profesional.html`). |
| `manifest.json` | Manifest PWA del Método 3M (`start_url` → `metodo-3-meses-final.html`). |
| `Logo.png` | Logo original. Ningún HTML lo referencia porque el logo va embebido en base64; se conserva como archivo fuente para regenerar ese base64. **No borrar.** |
| `supabase_antropometria.sql` | Esquema de las tablas de antropometría (ya ejecutado en Supabase). |
| `supabase_sudoracion.sql` | Tabla `tests_sudoracion` (test de sudoración por deportista). |
| `supabase_plan_competicion.sql` | Tabla `planes_competicion` (plan de competición por deportista). |

## Reglas de arquitectura (importantes)

- **Cada app es UN solo `.html`** con CSS y JS inline, JS vanilla, sin build, sin framework. Decisión tomada a propósito: **no partir el panel en más archivos** (se valoró y se descartó por ahora).
- Los enlaces entre apps se calculan con `window.location.origin + pathname.replace('panel-profesional.html', '<otro>.html')`. **Nunca escribir el nombre del repo a mano** (el repo se renombró antes a `panel-profesional`; URL: `https://guillermofrancespoquet.github.io/panel-profesional/`).
- Nombres de archivo **sin acentos ni espacios** (`calculadora_antropometria.html`, no `antropometría`).
- Las tres apps comparten el mismo proyecto Supabase y la tabla de deportistas.

## Supabase

- URL: `https://knmucvrbxpzmrjwxyksj.supabase.co`. Se llama con `fetch` a la API REST de PostgREST mediante un helper `sb(path, opts)` (no se usa la librería cliente). La anon key está en el propio HTML (`SKEY`); no la muestres ni la copies en mensajes.
- Acceso protegido solo por el PIN de la app + RLS permisiva (`for all using (true)`). No hay Supabase Auth.
- El PIN **no aparece en claro en ningún sitio público** (ni en el código ni en Notion): el panel solo guarda su huella SHA-256 con sal (`PASS_SALT`, `PASS_HASH`). Ojo: con 4 dígitos la huella se puede fuerza-brutar al instante, así que esto solo evita el texto en claro; la protección real llegará con el rediseño de seguridad. El PIN antiguo sigue en el historial de git, por eso conviene cambiarlo. Para cambiarlo: en la consola del navegador ejecutar `(async()=>{const b=await crypto.subtle.digest('SHA-256',new TextEncoder().encode('nutrilogos-panel:'+'NUEVO_PIN'));console.log([...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,'0')).join(''))})()` y pegar el resultado en `PASS_HASH`. No escribas el PIN en chats, commits ni Notion.
- Tablas que usa el panel: `clientes` (Método 3M), `clientes_deportivos`, `citas`, `recordatorios`, `historial_deportista`, `progresion_cargas`, además de `antropometria_perfil` y `antropometria_valoraciones`.
- `clientes_deportivos`: `id` (bigint), `nombre` (nombre completo en una sola casilla), `deporte`, `objetivo`, `foto_url`, `descripcion`, `plan_url`, `proxima_revision`, `ultima_actividad`, `notas`, `archivos`, `proxima_accion`.
- Antropometría: `antropometria_perfil` (1:1 con `clientes_deportivos` por `deportista_id`, con `talla`, `talla_sentado`, `envergadura` y `diametros_oseos` jsonb como medidas fijas del cliente) y `antropometria_valoraciones` (una fila por sesión; `medidas` jsonb). Borrar un cliente en la calculadora solo quita su perfil y valoraciones, **nunca** el registro de `clientes_deportivos`.
- `antropometria_valoraciones.resumen` (jsonb: `peso`, `pct_grasa`, `masa_grasa_kg`, `modelo`) lo escribe la calculadora al guardar y al cargar (`sincronizarResumenes()`, solo PATCH si cambia) y lo lee el panel en la ficha del deportista ("Mediciones"). El % de grasa es el primario del informe: Durnin & Womersley si hay edad, Yuhász / Ross-Kerr si no. Si el perfil está incompleto queda en `null`.
- `tests_sudoracion` (una fila por test, `deportista_id` → `clientes_deportivos`, `resultados` jsonb con tasa, % de peso perdido, sodio y reposición). Se rellena en Calculadora → Hidratación y se lista en la ficha del deportista. Los umbrales (2 % del peso) son de adultos: con menores de 18 años (fecha de nacimiento de `antropometria_perfil`) se muestra un aviso.
- `planes_competicion` (una fila por plan: fecha, hora, evento, deporte, duración, intensidad, peso y `parametros` jsonb). Lo escribe la pestaña "Plan de competición" y se lista en la ficha del deportista; el plan se recalcula al abrirlo. Pautas de adultos (ISSN 2017, Burke 2011, Jeukendrup 2014, ACSM 2007): sin carga de hidratos para menores de 18. La tabla de alimentos (`PLAN_ALIM`, `PLAN_PROT`) es aproximada y editable.
- Los ids llegan a veces como string (atributos `data-*`) y otras como número: comparar con `==`, no `===`.
- Para actualizaciones parciales se usa upsert con `Prefer: resolution=merge-duplicates`.
- Cualquier cambio de esquema: dar el SQL al usuario para que lo ejecute en el SQL Editor de Supabase (Claude Code no tiene acceso directo) y dejarlo también en `supabase_antropometria.sql` (o un nuevo `.sql`) para que el repo refleje la base real.

## Diseño (calculadora y panel comparten estilo)

- Paleta: verdes `--t900:#04342C`, `--t600:#0F6E56`, `--t400:#1D9E75`, dorado `--gold:#B8956A`, neutros `--g*`. Fuente Inter. Botones primarios verdes (`--t400`), radios 10–16 px, bordes `.5px`.
- Modo oscuro: clase `dark-mode` en `body`, clave de localStorage `nutrilogos_dark` (compartida entre las dos apps). En la calculadora el informe A4 se mantiene siempre claro.
- El informe de la calculadora está maquetado para A4 real (`@page{size:A4;margin:0}`, `.rep-page` 210×297 mm con el mismo padding en pantalla e impresión): la vista previa debe ser 1:1 con el PDF.
- Móvil: el panel usa barra superior + menú lateral deslizante (≤860 px); la calculadora usa barra superior fija con menú horizontal (≤760 px). Hay que revisar ambos tamaños tras cualquier cambio visual.

## Cómo trabajar aquí

1. Lee el archivo relevante antes de editar; son grandes (el panel ronda los 550 KB y la calculadora 1,6 MB por el pdf.js y el logo embebidos). Usa Grep/lecturas parciales y **no leas ni imprimas líneas con base64**.
2. Ediciones con reemplazos exactos y pequeños; no reescribas archivos enteros.
3. Tras editar JS, comprobar sintaxis: extraer el bloque `<script>` principal a un archivo temporal y `node --check`. Para el panel el script principal empieza en `const SURL=`; en la calculadora es el último `<script>` del archivo.
4. Si es un cambio visual, abrirlo con Playwright (Chromium ya instalado) a 1400 px y a 390 px, con las llamadas a Supabase simuladas, y mirar capturas antes de dar el cambio por bueno.
5. Commits pequeños y en español, un tema por commit, mensaje que explique el porqué. Push a la rama principal solo cuando el usuario lo pida o lo apruebe.

## Decisiones ya tomadas (no reabrir sin que el usuario lo pida)

- Calculadora de antropometría: el menú tiene solo **Clientes, Informe y Ajustes**. Nueva valoración y Resultados son pantallas a las que se llega desde la ficha desplegable de cada cliente (con "← Volver"), y cada valoración del historial tiene un botón Informe. En modo `?embed=1` se oculta su cabecera y su menú lateral y el menú pasa a pestañas arriba; el modo oscuro lo decide el panel (`syncAntroDark()`). Ojo: iframe y panel solo se pueden comunicar si se sirven desde el mismo origen (en Pages sí; en local hace falta un servidor, no `file://`).
- La calculadora **ya no funciona offline** (depende de Supabase); no se ha querido añadir cola local.
- Talla, talla sentado y envergadura son medidas **fijas por cliente**, igual que los diámetros óseos.
- En el historial de sesiones de un deportista se muestran, solo lectura y con etiqueta "Auto", las valoraciones antropométricas.
- En el dashboard, "Revisiones próximas" muestra solo de hoy a 7 días (las atrasadas no se listan; ese aviso lo cubre Pagos).
- En Nutrición Deportiva la "próxima acción" es una píldora discreta; en Método 3M mantiene el estilo original.
- Calculadora nutricional (energía y macros): Mifflin sigue siendo la fórmula principal; con % de grasa se muestran MLG, Katch y Cunningham como alternativas y un rango ±13 %. Los cálculos **no se guardan** (sin tabla). Con deportista seleccionado se usa su última valoración antropométrica y se avisa si tiene más de 90 días. Menores de 18: solo orientativo y sin déficits. Semáforo de disponibilidad energética (<30 kcal/kg MLG/día) solo si se indica el gasto de entrenamiento. No hay Schofield ni rangos de hidratos por carga (sin verificar).
- Referencias clínicas y Suplementación van en tarjetas (`.ref-section` en columnas, `.sup-card` en rejilla). Cada valor debe tener fuente; las de OMS/EFSA/IOM se contrastaron con resúmenes de búsqueda y PubMed (los sitios oficiales están bloqueados por la red del entorno de Claude Code), así que conviene verificar los valores nuevos contra el documento original. Proteína: 0.8 g/kg es la recomendación general; en deportistas sin déficit ≈1.2–1.6 g/kg (no hay ventaja demostrada por encima de ≈1.6–2.0) y en déficit 1.6–2.4 g/kg (≈2.3–3.1 g/kg de masa libre de grasa). Ojo: 2.3–3.1 de Helms es por kg de **masa libre de grasa**, no de peso.
