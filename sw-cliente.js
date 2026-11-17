// Service worker del área de clientes (NutriLogos). Hace dos cosas:
//  1. Recibe el aviso del lunes y lo muestra (el aviso llega sin contenido: el texto es siempre el de abajo).
//  2. Guarda la CÁSCARA de la app (cliente.html e iconos; nunca datos del cliente) para que, si el cliente ha activado «Tener este plan sin conexión»,
//     la app abra sin cobertura. Red primero: si la red falla o tarda más de 3,5 s, se usa la última copia. El plan guardado vive en el móvil del
//     cliente (localStorage), no aquí.
// Se registra con alcance `cliente.html` (el service worker del panel, `sw.js`, usa el resto de la carpeta). Si se cambia esta lógica, subir CACHE.
const CACHE = 'nl-cliente-v1';
const PAGINA = 'cliente.html';
const ESTATICOS = ['icon-192.png', 'icon-rounded-192.png', 'manifests/manifest-cliente.json'];
self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => c.addAll([PAGINA, ...ESTATICOS].map(u => new Request(u, { cache: 'reload' })))).catch(() => {}));
});
self.addEventListener('activate', e => e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k.startsWith('nl-cliente-') && k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())));

async function paginaRedPrimero(req) {
  const cache = await caches.open(CACHE), copia = await cache.match(PAGINA);
  const red = fetch(req.url, { cache: 'no-cache', credentials: 'same-origin' }).then(r => { if (r && r.ok) cache.put(PAGINA, r.clone()); return r; });
  if (!copia) return red;
  return Promise.race([red, new Promise(ok => setTimeout(() => ok(copia), 3500))]).catch(() => copia);
}
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  const archivo = url.pathname.split('/').pop();
  if (req.mode === 'navigate' && archivo === PAGINA) { e.respondWith(paginaRedPrimero(req)); return; }
  if (ESTATICOS.includes(archivo)) e.respondWith(caches.match(archivo).then(c => c || fetch(req)).catch(() => fetch(req)));
});

self.addEventListener('push', e => {
  e.waitUntil(self.registration.showNotification('Seguimiento semanal', {
    body: 'Cuéntanos cómo ha ido tu semana. Te lleva un par de minutos.',
    icon: 'icon-192.png',
    badge: 'icon-192.png',
    tag: 'seguimiento-semanal',     // si llegan dos, solo se ve una
    data: { abrir: 'seguimiento' },
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const destino = new URL('cliente.html?abrir=seguimiento', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(lista => {
    const abierta = lista.find(c => c.url.split('?')[0].split('#')[0] === destino.split('?')[0]);
    if (abierta && 'focus' in abierta) {
      abierta.postMessage({ abrir: 'seguimiento' });
      return abierta.focus();
    }
    return self.clients.openWindow(destino);
  }));
});
