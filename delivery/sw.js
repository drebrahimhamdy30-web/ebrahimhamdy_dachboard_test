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
    icon: data.icon || './icon.png',
    badge: './icon.png',
    vibrate: [300, 100, 300, 100, 300, 100, 300],
    requireInteraction: true,
    renotify: true,
    tag: 'order-' + Date.now() + '-' + Math.random().toString(36).slice(2, 7),
    silent: false,
    timestamp: Date.now(),
    data: { url: data.url || './driver.html' }
  };
  e.waitUntil(self.registration.showNotification(title, options));
});

// لما الطيار يضغط على الـ notification
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const targetUrl = e.notification.data?.url || './driver.html';
  e.waitUntil(
    clients.matchAll({type:'window', includeUncontrolled:true}).then(list => {
      for(const c of list){
        if(c.url.includes('driver.html') && 'focus' in c) return c.focus();
      }
      return clients.openWindow(targetUrl);
    })
  );
});
