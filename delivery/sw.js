const CACHE_NAME = 'driver-portal-v1';

self.addEventListener('install', e => {
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(clients.claim());
});

// استقبال Push Notification
self.addEventListener('push', e => {
  const data = e.data?.json() || {};
  const title = data.title || '📦 طلب جديد';
  const options = {
    body: data.body || 'وصلك طلب جديد',
    icon: data.icon || '/ebrahimhamdy_dachboard_test/delivery/icon.png',
    badge: '/ebrahimhamdy_dachboard_test/delivery/icon.png',
    vibrate: [300, 100, 300, 100, 300],
    requireInteraction: true,
    data: { url: data.url || '/ebrahimhamdy_dachboard_test/delivery/driver.html' }
  };
  e.waitUntil(self.registration.showNotification(title, options));
});

// لما الطيار يضغط على الـ notification
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(
    clients.matchAll({type:'window'}).then(list => {
      for(const c of list){
        if(c.url.includes('driver.html') && 'focus' in c) return c.focus();
      }
      return clients.openWindow(e.notification.data?.url || '/ebrahimhamdy_dachboard_test/delivery/driver.html');
    })
  );
});
