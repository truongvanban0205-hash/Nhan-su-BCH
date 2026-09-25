const CACHE_NAME = 'bch-app-v4';
const urlsToCache = ['./index.html', './manifest.json', './icon.png'];

self.addEventListener('install', function(e){
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE_NAME).then(function(c){return c.addAll(urlsToCache);}));
});

self.addEventListener('activate', function(e){
  e.waitUntil(
    caches.keys().then(function(keys){
      return Promise.all(keys.filter(function(k){return k!==CACHE_NAME;}).map(function(k){return caches.delete(k);}));
    }).then(function(){return self.clients.claim();})
  );
});

self.addEventListener('fetch', function(e){
  if(e.request.method !== 'GET') return; // Không cache POST (vd: gọi Supabase) — tránh lỗi Console vô hại
  e.respondWith(
    fetch(e.request).then(function(r){
      var copy=r.clone();
      caches.open(CACHE_NAME).then(function(c){c.put(e.request,copy);});
      return r;
    }).catch(function(){
      return caches.match(e.request);
    })
  );
});

// ============ THÔNG BÁO ĐẨY (PUSH) — Chat BCH, chỉ khi bị @ nhắc tên ============
self.addEventListener('push', function(e){
  var data={};
  try{ data=e.data ? e.data.json() : {}; }catch(err){ data={title:'Chat BCH', body:'Có tin nhắn mới'}; }
  var title=data.title || 'Chat BCH';
  var options={
    body: data.body || '',
    icon: './icon.png',
    badge: './icon.png',
    data: { url: './index.html' }
  };
  e.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', function(e){
  e.notification.close();
  var targetUrl = (e.notification.data && e.notification.data.url) || './index.html';
  e.waitUntil(
    self.clients.matchAll({type:'window', includeUncontrolled:true}).then(function(list){
      for(var i=0;i<list.length;i++){
        if('focus' in list[i]) return list[i].focus();
      }
      if(self.clients.openWindow) return self.clients.openWindow(targetUrl);
    })
  );
});
