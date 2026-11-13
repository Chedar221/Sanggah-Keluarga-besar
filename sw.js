self.addEventListener('push', event => {
  let payload = {};
  try { payload = event.data ? event.data.json() : {}; }
  catch (_) { payload = { title: 'Informasi Keluarga', body: event.data ? event.data.text() : '' }; }

  const title = payload.title || 'SANGGAH GEDE PAN RENGEN';
  const options = {
    body: payload.body || 'Ada informasi terbaru dari keluarga besar.',
    icon: '/logo-sanggah.svg',
    badge: '/logo-sanggah.svg',
    tag: 'sanggah-family-' + (payload.category || 'info'),
    renotify: true,
    data: { url: payload.url || '/' }
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const target = new URL(event.notification.data && event.notification.data.url || '/', self.location.origin).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if (client.url.startsWith(self.location.origin) && 'focus' in client) {
        await client.focus();
        if ('navigate' in client) await client.navigate(target);
        return;
      }
    }
    if (self.clients.openWindow) await self.clients.openWindow(target);
  })());
});
