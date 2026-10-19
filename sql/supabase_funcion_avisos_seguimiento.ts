// Edge Function `avisos-seguimiento` (se pega en Supabase → Edge Functions → Deploy a new function → Via Editor).
// Desactiva «Verify JWT» en esta función: la llama pg_cron con la cabecera `x-cron-secret`, no con un usuario.
//
// Cada lunes a las 9:00 (Madrid) avisa al móvil de los clientes con el seguimiento semanal pendiente
// (la lista la da `push_pendientes_seguimiento()` de `supabase_notificaciones.sql`). El aviso NO lleva datos:
// es un «toque» sin contenido (el texto está fijo en `sw-cliente.js`), así no hace falta cifrar nada.
//
// Secretos (Edge Functions → Secrets), uno por uno; NO los pegues en chats ni en el repo:
//   AVISOS_SECRET       una clave larga cualquiera; la misma que va en la tarea de pg_cron.
//   VAPID_PRIVADA_JWK   la clave privada VAPID en formato JWK (la da el fragmento de la consola, ver LEEME).
//   VAPID_PUBLICA       la clave pública VAPID (b64url); la misma que la constante VAPID_PUBLICA de cliente.html.
//   VAPID_CONTACTO      mailto:tu@correo (lo piden los servicios push para poder avisarte si algo falla).
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los inyecta Supabase solos.

const b64u = (b: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(b as ArrayBuffer))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const txt = (s: string) => b64u(new TextEncoder().encode(s));

// ¿Es lunes y ya son las 9:00 o más en Madrid? (La tarea se lanza a las 07:00 y 08:00 UTC para cubrir el cambio de hora.)
export function esHoraDeAviso(ahora = new Date()): boolean {
  const p = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Madrid', weekday: 'short', hour: '2-digit', hourCycle: 'h23' })
    .formatToParts(ahora);
  const dia = p.find(x => x.type === 'weekday')?.value, hora = Number(p.find(x => x.type === 'hour')?.value);
  return dia === 'Mon' && hora >= 9;
}

// Cabecera Authorization VAPID (RFC 8292) para un servicio push: JWT ES256 firmado con la clave privada.
export async function cabeceraVapid(endpoint: string, jwk: JsonWebKey, publica: string, contacto: string, ahora = Date.now()) {
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const cuerpo = txt(JSON.stringify({ typ: 'JWT', alg: 'ES256' })) + '.' +
    txt(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(ahora / 1000) + 12 * 3600, sub: contacto }));
  const firma = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(cuerpo));   // ya es r||s
  return `vapid t=${cuerpo}.${b64u(firma)}, k=${publica}`;
}

async function enviar(endpoint: string, jwk: JsonWebKey, publica: string, contacto: string): Promise<number> {
  const r = await fetch(endpoint, {
    method: 'POST',
    headers: { Authorization: await cabeceraVapid(endpoint, jwk, publica, contacto), TTL: '172800', Urgency: 'normal', 'Content-Length': '0' },
  });
  return r.status;
}

async function handler(req: Request): Promise<Response> {
  const env = (k: string) => Deno.env.get(k) || '';
  if (!env('AVISOS_SECRET') || req.headers.get('x-cron-secret') !== env('AVISOS_SECRET')) return new Response('no autorizado', { status: 401 });
  const forzar = new URL(req.url).searchParams.get('forzar') === '1';   // prueba manual: salta la comprobación de lunes 9:00
  if (!forzar && !esHoraDeAviso()) return Response.json({ enviados: 0, motivo: 'no es lunes a las 9:00 en Madrid' });

  const base = env('SUPABASE_URL') + '/rest/v1/rpc/', sk = env('SUPABASE_SERVICE_ROLE_KEY');
  const rpc = (fn: string, args: unknown) => fetch(base + fn, {
    method: 'POST', headers: { apikey: sk, Authorization: 'Bearer ' + sk, 'Content-Type': 'application/json' }, body: JSON.stringify(args ?? {}),
  });
  const pend = await rpc('push_pendientes_seguimiento', {});
  if (!pend.ok) return Response.json({ error: 'push_pendientes_seguimiento ' + pend.status }, { status: 500 });
  const lista: { id: number; endpoint: string }[] = await pend.json();

  const jwk = JSON.parse(env('VAPID_PRIVADA_JWK')), publica = env('VAPID_PUBLICA'), contacto = env('VAPID_CONTACTO') || 'mailto:admin@example.com';
  const ok: number[] = [], caducados: number[] = [], fallos: number[] = [];
  for (const s of lista) {
    try {
      const st = await enviar(s.endpoint, jwk, publica, contacto);
      if (st >= 200 && st < 300) ok.push(s.id); else if (st === 404 || st === 410) caducados.push(s.id); else fallos.push(st);
    } catch (_e) { fallos.push(0); }
  }
  if (ok.length) await rpc('push_marcar_avisados', { p_ids: ok });
  if (caducados.length) await rpc('push_borrar', { p_ids: caducados });
  return Response.json({ enviados: ok.length, caducados: caducados.length, fallos });
}

// @ts-ignore Deno solo existe en Supabase
if (typeof Deno !== 'undefined' && (import.meta as any).main !== false) Deno.serve(handler);
