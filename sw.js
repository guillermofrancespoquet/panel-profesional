// Service worker del panel profesional (NutriLogos).
// Solo guarda la CÁSCARA de la app (el HTML del panel y los iconos): nunca datos de clientes, que llegan de Supabase por otro dominio.
// - panel-profesional.html: «red primero»; si la red falla o tarda más de 3,5 s, se usa la última copia. Así siempre se abre la versión
//   más reciente cuando hay conexión y, sin conexión, la app abre y avisa en lugar de dar un error del navegador.
// - iconos y manifest: copia en caché que se refresca en segundo plano.
// - Avisos de novedades: la Edge Function `avisos-profesional` manda un aviso SIN contenido (nunca nombres ni datos de clientes); el texto es siempre el de abajo.
// Todo lo demás (calculadora, área de clientes, Método 3M, Supabase, fuentes) pasa de largo: este archivo no lo toca.
// Si se cambia esta lógica, subir el número de CACHE.
const CACHE = 'nl-panel-v4';
const PAGINA = 'panel-profesional.html';
const ESTATICOS = ['icon-192.png', 'icon-512.png', 'icon-rounded-192.png', 'icon-rounded-512.png', 'manifests/manifest-panel.json'];
const SIN_CONEXION = '<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Sin conexión</title>'
  + '<body style="margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#04342C;color:#fff;font-family:system-ui,sans-serif;text-align:center;padding:24px">'
  + '<div><h1 style="font-size:20px;margin:0 0 8px">Sin conexión</h1><p style="margin:0;color:#9FE1CB;font-size:15px">Conéctate a internet y vuelve a abrir el panel.</p></div></body></html>';

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => c.addAll([PAGINA, ...ESTATICOS].map(u => new Request(u, { cache: 'reload' })))).catch(() => {}));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k.startsWith('nl-panel-') && k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

async function paginaRedPrimero(req) {
  const cache = await caches.open(CACHE);
  const copia = await cache.match(PAGINA);
  const red = fetch(req.url, { cache: 'no-cache', credentials: 'same-origin' }).then(r => { if (r && r.ok) cache.put(PAGINA, r.clone()); return r; });
  if (!copia) return red.catch(() => new Response(SIN_CONEXION, { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } }));
  return Promise.race([red, new Promise(ok => setTimeout(() => ok(copia), 3500))]).catch(() => copia);
}
async function estaticoYRefresco(req, nombre) {
  const cache = await caches.open(CACHE);
  const copia = await cache.match(nombre);
  const red = fetch(req).then(r => { if (r && r.ok) cache.put(nombre, r.clone()); return r; });
  if (copia) { red.catch(() => {}); return copia; }
  return red;
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  const archivo = url.pathname.split('/').pop();
  if (req.mode === 'navigate' && archivo === PAGINA) { e.respondWith(paginaRedPrimero(req)); return; }
  if (ESTATICOS.includes(archivo)) e.respondWith(estaticoYRefresco(req, archivo).catch(() => fetch(req)));
});

// Aviso de novedades (sin contenido): se agrupa con `tag`, así dos avisos seguidos son uno solo.
self.addEventListener('push', e => {
  e.waitUntil(self.registration.showNotification('Tienes novedades', {
    body: 'Alguno de tus clientes ha enviado algo. Ábrelo para verlo.',
    icon: 'icon-192.png', badge: 'icon-192.png', tag: 'novedades', renotify: false,
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const destino = new URL(PAGINA, self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(lista => {
    const abierta = lista.find(c => c.url.split('?')[0].split('#')[0] === destino);
    if (abierta && 'focus' in abierta) { abierta.postMessage({ novedades: true }); return abierta.focus(); }
    return self.clients.openWindow(destino);
  }));
});
