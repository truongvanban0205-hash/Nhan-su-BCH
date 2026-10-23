const CACHE_NAME = 'bch-app-v8';
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
  // Chỉ cache file của chính app (cùng domain). Dữ liệu Supabase (báo cáo, chat, ảnh) không lưu vào máy.
  if(new URL(e.request.url).origin !== self.location.origin) return;
  // Luôn hỏi lại máy chủ (no-cache) để vừa up GitHub là máy người dùng nhận bản mới, không kẹt bản cũ
  e.respondWith(
    fetch(e.request.url, {cache:'no-cache', credentials:'same-origin'}).then(function(r){
      if(r.ok){
        var copy=r.clone();
        caches.open(CACHE_NAME).then(function(c){c.put(e.request,copy);});
      }
      return r;
    }).catch(function(){
      return caches.match(e.request);
    })
  );
});

// ============ THÔNG BÁO ĐẨY (PUSH) — Tin nhắn nội bộ & cuộc gọi ============
// Dữ liệu từ Edge Function gui-push: {title, body, url, tag, goi, ht}
self.addEventListener('push', function(e){
  var data={};
  try{ data=e.data ? e.data.json() : {}; }catch(err){ data={title:'Tin nhắn', body:'Có tin nhắn mới'}; }
  e.waitUntil(self.clients.matchAll({type:'window', includeUncontrolled:true}).then(function(list){
    // Đang mở đúng hội thoại đó trên màn hình → không cần báo (tin đã hiện ngay trong app)
    if(!data.goi && data.ht){
      for(var i=0;i<list.length;i++){
        var c=list[i], m=c.url.match(/[#&]ht=(\d+)/);
        if(c.visibilityState==='visible' && c.url.indexOf('chat.html')>=0 && m && Number(m[1])===Number(data.ht)) return;
      }
    }
    return self.registration.showNotification(data.title || 'Tin nhắn', {
      body: data.body || '',
      icon: './icon.png',
      badge: './icon.png',
      tag: data.tag || undefined,          // cùng hội thoại → gộp thành 1 thông báo, tin mới thay tin cũ
      renotify: !!data.tag,                // nhưng vẫn rung/kêu lại
      requireInteraction: !!data.goi,      // cuộc gọi: giữ trên màn hình tới khi bấm
      vibrate: data.goi ? [400,200,400,200,400,200,400] : [200,100,200],
      data: { url: data.url || './chat.html' }
    });
  }));
});

self.addEventListener('notificationclick', function(e){
  e.notification.close();
  var targetUrl = new URL((e.notification.data && e.notification.data.url) || './chat.html', self.registration.scope).href;
  e.waitUntil(
    self.clients.matchAll({type:'window', includeUncontrolled:true}).then(function(list){
      // Ưu tiên tab chat đang mở: chuyển nó tới đúng hội thoại / cuộc gọi
      for(var i=0;i<list.length;i++){
        if(list[i].url.indexOf('chat.html')>=0 && 'navigate' in list[i]){
          return list[i].navigate(targetUrl).then(function(c){ return c && c.focus(); });
        }
      }
      if(self.clients.openWindow) return self.clients.openWindow(targetUrl);
    })
  );
});
