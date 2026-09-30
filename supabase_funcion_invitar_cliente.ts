// ============================================================
// EDGE FUNCTION «invitar-cliente» — invita al cliente por correo Y lo vincula, todo desde el panel
// ============================================================
// Por qué hace falta: invitar a un usuario por correo exige la clave de administrador de Supabase
// (service_role), que NUNCA puede estar en el HTML. Esta función corre en Supabase, donde esa clave es
// secreta y ya viene incluida sola (no tienes que copiarla ni pegarla en ningún sitio).
//
// Seguridad: solo actúa si quien la llama es el profesional (comprueba `es_profesional()` con la sesión
// de quien llama). Un cliente, o cualquiera con la clave pública, recibe «no autorizado».
//
// CÓMO INSTALARLA (una sola vez, ~3 min, sin instalar nada):
//   1) Supabase → Edge Functions → «Deploy a new function» → «Via Editor».
//   2) Nombre de la función: invitar-cliente   (exactamente así, con guion).
//   3) Borra el código de ejemplo, pega TODO este archivo y pulsa «Deploy function».
//   4) Déjala con «Verify JWT» activado (viene así por defecto).
// Si el panel no encuentra la función, sigue funcionando el método antiguo (invitar en Authentication →
// Users y vincular después en la ficha).
// ============================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // 1) ¿Quién llama? Se ejecuta con SU sesión: si no es profesional, se corta aquí.
    const asUser = createClient(url, anon, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: esPro } = await asUser.rpc("es_profesional");
    if (esPro !== true) return json({ ok: false, motivo: "no_autorizado" }, 403);

    // 2) Datos
    const { deportista, email, redirectTo } = await req.json();
    const correo = String(email ?? "").trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(correo) || !Number.isFinite(Number(deportista))) {
      return json({ ok: false, motivo: "datos_no_validos" }, 400);
    }
    const destino = /^https:\/\//.test(String(redirectTo ?? "")) ? String(redirectTo) : undefined;

    // 3) Invitación por correo (con la plantilla «Invite user» que ya configuraste).
    //    Si el correo ya tiene cuenta, no se envía nada y se sigue con la vinculación.
    const admin = createClient(url, service, { auth: { persistSession: false } });
    let invitado = true;
    const { error } = await admin.auth.admin.inviteUserByEmail(correo, { redirectTo: destino });
    if (error) {
      if (/already|registered|exists/i.test(error.message)) invitado = false;
      else return json({ ok: false, motivo: "invitacion_fallida", detalle: error.message }, 400);
    }

    // 4) Vinculación con el deportista (la misma función SQL de siempre, con la sesión del profesional).
    const { data: v, error: e2 } = await asUser.rpc("vincular_acceso_cliente", {
      p_deportista: Number(deportista),
      p_email: correo,
    });
    if (e2) return json({ ok: false, motivo: "vinculacion_fallida", detalle: e2.message }, 400);
    if (!v?.ok) return json({ ok: false, motivo: v?.motivo ?? "vinculacion_fallida" }, 200);

    return json({ ok: true, invitado });
  } catch (e) {
    return json({ ok: false, motivo: "error", detalle: String(e) }, 500);
  }
});
