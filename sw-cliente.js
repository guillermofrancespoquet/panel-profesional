// Service worker del área de clientes (NutriLogos): SOLO recibe el aviso del lunes y lo muestra. No guarda nada en caché
// ni toca la red. Se registra con alcance `cliente.html` (el service worker del panel, `sw.js`, usa el resto de la carpeta).
// El aviso llega sin contenido (la Edge Function `avisos-seguimiento` no manda datos del cliente): el texto es siempre este.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

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
