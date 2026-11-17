// Edge Function `avisos-profesional` (se pega en Supabase → Edge Functions → Deploy a new function → Via Editor).
// Desactiva «Verify JWT» en esta función: la llama pg_cron con la cabecera `x-cron-secret`, no con un usuario.
//
// Manda al móvil del profesional UN aviso genérico («Tienes novedades») cuando hay novedades de clientes sin ver (la lista la da
// `avisos_prof_listos()` de `supabase_avisos_profesional.sql`, que ya aplica el minuto sin novedades, las horas de silencio y lo que
// el profesional ya ha visto). El aviso NO lleva datos: es un «toque» sin contenido (el texto está fijo en `sw.js`), así que ni los
// servicios de notificaciones de Apple o Google ven nombres ni datos de salud.
//
// Usa los mismos secretos que `avisos-seguimiento` (AVISOS_SECRET, VAPID_PRIVADA_JWK, VAPID_PUBLICA, VAPID_CONTACTO); no hay secretos nuevos.
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los inyecta Supabase solos.

const b64u = (b: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(b as ArrayBuffer))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const txt = (s: string) => b64u(new TextEncoder().encode(s));

// Solo se envía a los servicios de notificaciones de los navegadores (la base ya lo exige al guardar el dispositivo; aquí se vuelve a comprobar
// por si hubiera uno antiguo): si no, esta función haría una petición a cualquier dirección que mandara un cliente.
export const hostPermitido = (endpoint: string): boolean =>
  /^https:\/\/(fcm\.googleapis\.com|(updates\.)?push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+(\.[a-z0-9-]+)*\.notify\.windows\.com)\/\S+$/.test(endpoint);

// Comparación de la clave sin cortar en la primera diferencia (no da pistas por el tiempo de respuesta).
export function igualesSeguro(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}

// Cabecera Authorization VAPID (RFC 8292) para un servicio push: JWT ES256 firmado con la clave privada.
export async function cabeceraVapid(endpoint: string, jwk: JsonWebKey, publica: string, contacto: string, ahora = Date.now()) {
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const cuerpo = txt(JSON.stringify({ typ: 'JWT', alg: 'ES256' })) + '.' +
    txt(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(ahora / 1000) + 12 * 3600, sub: contacto }));
  const firma = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(cuerpo));   // ya es r||s
  return `vapid t=${cuerpo}.${b64u(firma)}, k=${publica}`;
}


async function enviar(endpoint: string, jwk: JsonWebKey, publica: string, contacto: string): Promise<{ st: number; msg: string }> {
  const r = await fetch(endpoint, {
    method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(10000),
    headers: { Authorization: await cabeceraVapid(endpoint, jwk, publica, contacto), TTL: '14400', Urgency: 'normal', 'Content-Length': '0' },   // sin cabecera Topic: Apple la rechaza si no es un valor concreto (BadWebPushTopic)
  });
  return { st: r.status, msg: r.status >= 300 ? (await r.text().catch(() => '')).slice(0, 120) : '' };   // el motivo del rechazo (p. ej. BadJwtToken) ayuda a diagnosticar
}

async function handler(req: Request): Promise<Response> {
  const env = (k: string) => Deno.env.get(k) || '';
  if (!env('AVISOS_SECRET') || !igualesSeguro(req.headers.get('x-cron-secret') ?? '', env('AVISOS_SECRET'))) return new Response('no autorizado', { status: 401 });

  const base = env('SUPABASE_URL') + '/rest/v1/rpc/', sk = env('SUPABASE_SERVICE_ROLE_KEY');
  const rpc = (fn: string, args: unknown) => fetch(base + fn, {
    method: 'POST', headers: { apikey: sk, Authorization: 'Bearer ' + sk, 'Content-Type': 'application/json' }, body: JSON.stringify(args ?? {}),
  });
  const r = await rpc('avisos_prof_listos', {});
  if (!r.ok) return Response.json({ error: 'avisos_prof_listos ' + r.status }, { status: 500 });
  const { ids, subs }: { ids: number[]; subs: { id: number; endpoint: string }[] } = await r.json();
  if (!ids?.length || !subs?.length) return Response.json({ enviados: 0, motivo: 'nada que avisar ahora' });

  const jwk = JSON.parse(env('VAPID_PRIVADA_JWK')), publica = env('VAPID_PUBLICA'), contacto = env('VAPID_CONTACTO') || 'mailto:admin@example.com';
  let alguno = false; const caducados: number[] = [], fallos: (number | string)[] = [];
  for (const s of subs) {
    if (!hostPermitido(s.endpoint)) { caducados.push(s.id); continue; }   // dirección rara: se borra sin enviar nada
    try {
      const { st, msg } = await enviar(s.endpoint, jwk, publica, contacto);
      if (st >= 200 && st < 300) alguno = true; else if (st === 404 || st === 410) caducados.push(s.id); else fallos.push(st + (msg ? ' ' + msg : ''));
    } catch (_e) { fallos.push(0); }
  }
  if (alguno) await rpc('avisos_prof_enviado', { p_ids: ids });   // si falló todo (no por caducidad), se reintenta en el siguiente minuto
  if (caducados.length) await rpc('avisos_prof_borrar_subs', { p_ids: caducados });
  return Response.json({ enviados: alguno ? 1 : 0, caducados: caducados.length, fallos });
}

// @ts-ignore Deno solo existe en Supabase
if (typeof Deno !== 'undefined' && (import.meta as any).main !== false) Deno.serve(handler);
