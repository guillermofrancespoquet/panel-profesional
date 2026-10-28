// ============================================================
// EDGE FUNCTION «calendario-google» — copia las citas del panel a tu Google Calendar (solo en un sentido: panel → Google)
// ============================================================
// Qué hace: cuando creas, mueves o borras una cita o revisión en el panel, el panel llama a esta función y ella crea,
// mueve o borra el evento en tu Google Calendar. Título: «REVISIÓN - ANA» (en mayúsculas, solo el
// primer nombre). Color «Tomate». Dura 60 min (si la cita no tiene hora, es un evento de todo el día).
// En el evento NO van notas, importes ni datos de salud: solo el título y el nombre del servicio.
//
// Seguridad: solo actúa si quien la llama es el profesional (comprueba `es_profesional()` con la sesión de quien llama),
// igual que «invitar-cliente». No usa la clave de administrador de Supabase: lee y actualiza las citas con la sesión
// del propio profesional. La clave de Google vive solo como secreto de Supabase (nunca en el HTML ni en el repositorio).
//
// CÓMO INSTALARLA (una sola vez; pasos completos con capturas de dónde pulsar en sql/LEEME.md, «Calendario de Google»):
//   1) Google Cloud → proyecto nuevo → activar «Google Calendar API» → crear una «cuenta de servicio» → crear una clave JSON.
//   2) En Google Calendar: tu calendario → «Configuración y uso compartido» → «Compartir con determinadas personas»
//      → añade el correo de la cuenta de servicio con el permiso «Hacer cambios en eventos».
//   3) Supabase → Edge Functions → Secrets (o «Manage secrets»): crea
//        GOOGLE_SA_JSON       = todo el contenido del archivo JSON de la clave (en una línea)
//        GOOGLE_CALENDAR_ID   = tu correo de Google (el id del calendario donde quieres las citas)
//   4) Supabase → Edge Functions → «Deploy a new function» → «Via Editor» → nombre: calendario-google → pega TODO este
//      archivo → «Deploy function». Déjala con «Verify JWT» ACTIVADO.
//   5) Ejecuta sql/supabase_calendario_google.sql (una columna nueva en `citas`).
//   6) En el panel: Ajustes → Calendario de Google → «Probar conexión».
// Si la función no está instalada, el panel sigue funcionando igual y no envía nada a Google.
// ============================================================

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const TZ = "Europe/Madrid";
const COLOR_TOMATE = "11"; // colorId de Google Calendar: 11 = «Tomate»
const DURACION_MIN = 60;
const API = "https://www.googleapis.com/calendar/v3";

// ── Utilidades puras (se prueban fuera de Deno) ──────────────────────────────────────────────
// Revisión y consulta son lo mismo: el título es siempre «REVISIÓN» (el parámetro se conserva por compatibilidad).
export function tipoTitulo(_servicio?: unknown): string {
  return "REVISIÓN";
}
export function primerNombre(cliente: unknown): string {
  const p = String(cliente ?? "").trim().split(/\s+/)[0] ?? "";
  return p ? p.toLocaleUpperCase("es-ES") : "CLIENTE";
}
const dosD = (n: number) => String(n).padStart(2, "0");
function sumarMin(fecha: string, hora: string, min: number): string {
  const [y, m, d] = fecha.split("-").map(Number);
  const [hh, mm] = hora.split(":").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d, hh, mm + min));
  return `${t.getUTCFullYear()}-${dosD(t.getUTCMonth() + 1)}-${dosD(t.getUTCDate())}T${dosD(t.getUTCHours())}:${dosD(t.getUTCMinutes())}:00`;
}
function sumarDias(fecha: string, dias: number): string {
  const [y, m, d] = fecha.split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d + dias));
  return `${t.getUTCFullYear()}-${dosD(t.getUTCMonth() + 1)}-${dosD(t.getUTCDate())}`;
}
// Evento de Google a partir de una fila de `citas`. Con `null` se borran los campos del otro formato (hora ↔ todo el día) al actualizar.
export function construirEvento(cita: { id: unknown; cliente?: unknown; servicio?: unknown; fecha: string; hora?: unknown }) {
  const hora = /^\d{2}:\d{2}/.test(String(cita.hora ?? "")) ? String(cita.hora).slice(0, 5) : null;
  const servicio = String(cita.servicio ?? "").trim();
  const base = {
    summary: `${tipoTitulo(cita.servicio)} - ${primerNombre(cita.cliente)}`,
    description: "Creado desde el panel NutriLogos." + (servicio ? `\nServicio: ${servicio}` : ""),
    colorId: COLOR_TOMATE,
    extendedProperties: { private: { nutrilogos_cita: String(cita.id) } },
  };
  if (hora) {
    return {
      ...base,
      start: { dateTime: `${cita.fecha}T${hora}:00`, timeZone: TZ, date: null },
      end: { dateTime: sumarMin(cita.fecha, hora, DURACION_MIN), timeZone: TZ, date: null },
    };
  }
  return {
    ...base,
    start: { date: cita.fecha, dateTime: null, timeZone: null },
    end: { date: sumarDias(cita.fecha, 1), dateTime: null, timeZone: null },
  };
}
const hoyMadrid = () => new Date().toLocaleDateString("en-CA", { timeZone: TZ });

// ── Acceso a Google con la cuenta de servicio ────────────────────────────────────────────────
const b64url = (x: string | Uint8Array) => {
  const bin = typeof x === "string" ? new TextEncoder().encode(x) : x;
  let s = ""; bin.forEach((b) => (s += String.fromCharCode(b)));
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
function leerCuenta(): { client_email: string; private_key: string } | null {
  try {
    const sa = JSON.parse(Deno.env.get("GOOGLE_SA_JSON") ?? "");
    return sa?.client_email && sa?.private_key ? sa : null;
  } catch (_e) { return null; }
}
let tokenCache: { t: string; exp: number } | null = null;
async function tokenGoogle(sa: { client_email: string; private_key: string }): Promise<string> {
  if (tokenCache && tokenCache.exp > Date.now() + 60_000) return tokenCache.t;
  const ahora = Math.floor(Date.now() / 1000);
  const cab = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const cuerpo = b64url(JSON.stringify({
    iss: sa.client_email, scope: "https://www.googleapis.com/auth/calendar.events",
    aud: "https://oauth2.googleapis.com/token", iat: ahora, exp: ahora + 3600,
  }));
  const pem = sa.private_key.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const clave = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const firma = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", clave, new TextEncoder().encode(`${cab}.${cuerpo}`)));
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${cab}.${cuerpo}.${b64url(firma)}` }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) throw new Error("credenciales: " + (j.error_description ?? j.error ?? r.status));
  tokenCache = { t: j.access_token, exp: Date.now() + (Number(j.expires_in) || 3600) * 1000 };
  return j.access_token;
}
async function google(sa: { client_email: string; private_key: string }, calId: string, metodo: string, ruta: string, cuerpo?: unknown) {
  const t = await tokenGoogle(sa);
  const r = await fetch(`${API}/calendars/${encodeURIComponent(calId)}/events${ruta}`, {
    method: metodo, headers: { Authorization: `Bearer ${t}`, "Content-Type": "application/json" },
    body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
  });
  const txt = await r.text();
  let j: any = null; try { j = txt ? JSON.parse(txt) : null; } catch (_e) { /* cuerpo vacío o no JSON */ }
  return { ok: r.ok, status: r.status, j };
}
const motivoGoogle = (status: number) => status === 404 ? "calendario_no_compartido" : status === 403 ? "sin_permiso" : status === 401 ? "credenciales" : "google_error";

// ── Manejador ────────────────────────────────────────────────────────────────────────────────
export async function manejar(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const base = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const auth = req.headers.get("Authorization") ?? "";
    const pg = (ruta: string, init: RequestInit = {}) =>
      fetch(`${base}/rest/v1/${ruta}`, { ...init, headers: { apikey: anon, Authorization: auth, "Content-Type": "application/json", ...(init.headers ?? {}) } });

    // 1) ¿Quién llama? Con SU sesión: si no es profesional, se corta aquí.
    const rp = await pg("rpc/es_profesional", { method: "POST", body: "{}" });
    if ((await rp.json().catch(() => null)) !== true) return json({ ok: false, motivo: "no_autorizado" }, 403);

    const { accion, cita_id, event_id } = await req.json().catch(() => ({}));
    const sa = leerCuenta(), calId = (Deno.env.get("GOOGLE_CALENDAR_ID") ?? "").trim();
    if (accion === "estado") return json({ ok: true, configurado: !!(sa && calId) });
    if (!sa || !calId) return json({ ok: false, motivo: "no_configurado" });

    if (accion === "probar") {
      let r;
      try { r = await google(sa, calId, "GET", "?maxResults=1&fields=summary,timeZone"); }
      catch (e) { return json({ ok: false, motivo: "credenciales", detalle: String(e) }); }
      return r.ok ? json({ ok: true, calendario: r.j?.summary ?? calId, zona: r.j?.timeZone ?? null })
        : json({ ok: false, motivo: motivoGoogle(r.status), detalle: r.j?.error?.message ?? null });
    }

    if (accion === "borrar") {
      const id = String(event_id ?? "");
      if (!/^[A-Za-z0-9_-]{5,100}$/.test(id)) return json({ ok: false, motivo: "datos_no_validos" }, 400);
      const r = await google(sa, calId, "DELETE", `/${id}?sendUpdates=none`);
      return r.ok || r.status === 404 || r.status === 410 ? json({ ok: true }) : json({ ok: false, motivo: motivoGoogle(r.status), detalle: r.j?.error?.message ?? null });
    }

    // Sube una cita (crea o actualiza su evento) y guarda el id del evento en la cita.
    const subir = async (cita: any) => {
      const evento = construirEvento(cita);
      let r = cita.google_event_id ? await google(sa, calId, "PATCH", `/${cita.google_event_id}?sendUpdates=none`, evento) : null;
      if (!r || r.status === 404 || r.status === 410) r = await google(sa, calId, "POST", "?sendUpdates=none", evento);
      if (!r.ok) return { ok: false, motivo: motivoGoogle(r.status), detalle: r.j?.error?.message ?? null };
      const eid = r.j?.id as string;
      let aviso: string | undefined;
      if (eid && eid !== cita.google_event_id) {
        const w = await pg(`citas?id=eq.${encodeURIComponent(String(cita.id))}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ google_event_id: eid }) });
        if (!w.ok) aviso = "sin_columna"; // falta ejecutar sql/supabase_calendario_google.sql: el evento existe, pero la próxima vez se duplicaría
      }
      return { ok: true, event_id: eid, aviso };
    };

    if (accion === "sync") {
      const id = Number(cita_id);
      if (!Number.isFinite(id)) return json({ ok: false, motivo: "datos_no_validos" }, 400);
      const filas = await (await pg(`citas?id=eq.${id}&select=*`)).json().catch(() => null);
      const cita = Array.isArray(filas) ? filas[0] : null;
      if (!cita) return json({ ok: false, motivo: "cita_no_existe" }, 404);
      return json(await subir(cita));
    }

    if (accion === "sync_proximas") {
      const filas = await (await pg(`citas?fecha=gte.${hoyMadrid()}&select=*&order=fecha.asc,hora.asc&limit=150`)).json().catch(() => null);
      if (!Array.isArray(filas)) return json({ ok: false, motivo: "error", detalle: "no se pudieron leer las citas" });
      let enviadas = 0, fallidas = 0, aviso: string | undefined, ultimo: unknown = null;
      for (const c of filas) {
        const r: any = await subir(c);
        if (r.ok) { enviadas++; aviso = aviso ?? r.aviso; } else { fallidas++; ultimo = r; }
      }
      return json({ ok: true, enviadas, fallidas, aviso, ultimo_error: ultimo });
    }

    return json({ ok: false, motivo: "accion_desconocida" }, 400);
  } catch (e) {
    return json({ ok: false, motivo: "error", detalle: String(e) }, 500);
  }
}

if (typeof Deno !== "undefined" && typeof Deno.serve === "function") Deno.serve(manejar);
