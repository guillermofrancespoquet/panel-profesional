// ============================================================
// EDGE FUNCTION «eliminar-cuenta-cliente» — borra la cuenta de acceso (Supabase Auth) de un cliente al eliminarlo del panel
// ============================================================
// Por qué hace falta: borrar un usuario de Supabase Auth exige la clave de administrador (service_role), que NUNCA puede estar en
// el HTML. Esta función corre en Supabase, donde esa clave es secreta y ya viene incluida sola.
//
// Seguridad: solo actúa si quien la llama es el profesional (comprueba `es_profesional()` con la sesión de quien llama).
// Solo borra cuentas vinculadas a ESE deportista en `clientes_acceso` y se niega a borrar la cuenta de un profesional.
// Hay que llamarla ANTES de eliminar al deportista (al eliminarlo desaparece el vínculo que dice qué cuenta es suya).
//
// CÓMO INSTALARLA (una sola vez, ~3 min):
//   1) Supabase → Edge Functions → «Deploy a new function» → «Via Editor».
//   2) Nombre: eliminar-cuenta-cliente   (exactamente así, con guiones).
//   3) Borra el código de ejemplo, pega TODO este archivo y pulsa «Deploy function».
//   4) Déjala con «Verify JWT» activado (viene así por defecto).
// Si no está instalada, el panel sigue funcionando: al eliminar a un cliente te dice el correo de su cuenta para que la borres a
// mano en Authentication → Users.
// ============================================================

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

export async function manejar(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const base = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!, service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const auth = req.headers.get("Authorization") ?? "";
    const comoUsuario = (ruta: string, init: RequestInit = {}) =>
      fetch(`${base}/rest/v1/${ruta}`, { ...init, headers: { apikey: anon, Authorization: auth, "Content-Type": "application/json", ...(init.headers ?? {}) } });
    const comoAdmin = (ruta: string, init: RequestInit = {}) =>
      fetch(`${base}/${ruta}`, { ...init, headers: { apikey: service, Authorization: `Bearer ${service}`, "Content-Type": "application/json", ...(init.headers ?? {}) } });

    // 1) ¿Quién llama? Con SU sesión: si no es profesional, se corta aquí.
    const rp = await comoUsuario("rpc/es_profesional", { method: "POST", body: "{}" });
    if ((await rp.json().catch(() => null)) !== true) return json({ ok: false, motivo: "no_autorizado" }, 403);

    const { deportista } = await req.json().catch(() => ({}));
    const dep = Number(deportista);
    if (!Number.isInteger(dep) || dep <= 0) return json({ ok: false, motivo: "datos_no_validos" }, 400);

    // 2) Cuentas vinculadas a ese deportista (con la sesión del profesional).
    const rv = await comoUsuario(`clientes_acceso?deportista_id=eq.${dep}&select=user_id,email`);
    const vinculos = await rv.json().catch(() => null);
    if (!Array.isArray(vinculos)) return json({ ok: false, motivo: "error", detalle: "no se pudo leer el vínculo" }, 500);

    let eliminadas = 0;
    for (const v of vinculos) {
      const uid = String(v?.user_id ?? "");
      if (!/^[0-9a-f-]{36}$/i.test(uid)) continue;
      // Nunca se borra la cuenta de un profesional.
      const rpf = await comoAdmin(`rest/v1/profesionales?user_id=eq.${uid}&select=user_id`);
      const esPro = await rpf.json().catch(() => null);
      if (!Array.isArray(esPro) || esPro.length) return json({ ok: false, motivo: "cuenta_profesional", eliminadas }, 409);
      const rd = await comoAdmin(`auth/v1/admin/users/${uid}`, { method: "DELETE" });
      if (rd.ok || rd.status === 404) eliminadas++;
      else return json({ ok: false, motivo: "borrado_fallido", detalle: String(rd.status), eliminadas }, 502);
    }
    return json({ ok: true, eliminadas });
  } catch (e) {
    return json({ ok: false, motivo: "error", detalle: String(e) }, 500);
  }
}

if (typeof Deno !== "undefined" && typeof Deno.serve === "function") Deno.serve(manejar);
