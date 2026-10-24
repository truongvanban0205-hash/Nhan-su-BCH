const CACHE_NAME = 'bch-app-v10';
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
    var tb = {
      body: data.body || '',
      icon: data.icon || './icon.png',     // ảnh đại diện người gửi / người gọi
      badge: './icon.png',
      tag: data.tag || undefined,          // cùng hội thoại → gộp thành 1 thông báo, tin mới thay tin cũ
      renotify: !!data.tag,                // nhưng vẫn rung/kêu lại
      requireInteraction: !!data.goi,      // cuộc gọi: giữ trên màn hình tới khi bấm
      vibrate: data.goi ? [700,400,700,400,700,400,700] : [200,100,200],
      data: { url: data.url || './chat.html', goi: data.goi ? goiId(data.url) : null }
    };
    if(!data.goi) return self.registration.showNotification(data.title || 'Tin nhắn', tb);
    tb.actions = [{action:'nghe', title:'Nghe'}, {action:'tu_choi', title:'Từ chối'}];
    // Cuộc gọi: hỏi lại server trước — thông báo đến trễ (máy vừa có mạng lại) mà cuộc gọi đã xong thì KHÔNG đổ chuông
    return goiRpc('ht_xem_goi', { p_goi: tb.data.goi }).then(function(g){
      if(g && g.trang_thai && g.trang_thai !== 'do_chuong'){
        return self.registration.showNotification('Cuộc gọi đã kết thúc', { tag: tb.tag, silent: true, icon: tb.icon, badge: './icon.png', data: tb.data })
          .then(function(){ return new Promise(function(ok){ setTimeout(function(){
            self.registration.getNotifications({ tag: tb.tag }).then(function(ds){ ds.forEach(function(n){ n.close(); }); ok(); });
          }, 1500); }); });
      }
      return self.registration.showNotification(data.title || 'Cuộc gọi đến', tb).then(function(){
        return doChuongLap(data.title, tb); // kêu + rung lại mỗi 5 giây tới khi bắt máy / từ chối / hết giờ
      });
    });
  }));
});

/* ----- cuộc gọi khi app đang đóng ----- */
var SB_URL = 'https://jqwjzvucwvlwbcgxhath.supabase.co', SB_KEY = 'sb_publishable_hI0g6zHtG2aWOkmMCm8d5g_t1wspsgv';
function goiId(url){ var m = String(url || '').match(/goi=(\d+)/); return m ? Number(m[1]) : null; }
function layThe(){ // thẻ phiên do trang chat lưu vào IndexedDB
  return new Promise(function(ok){
    try{
      var rq = indexedDB.open('bch-chat', 1);
      rq.onupgradeneeded = function(){ rq.result.createObjectStore('kv'); };
      rq.onsuccess = function(){ try{ var g = rq.result.transaction('kv').objectStore('kv').get('token'); g.onsuccess = function(){ ok(g.result || ''); }; g.onerror = function(){ ok(''); }; }catch(e){ ok(''); } };
      rq.onerror = function(){ ok(''); };
    }catch(e){ ok(''); }
  });
}
function goiRpc(ten, p){
  return layThe().then(function(t){
    if(!t) return null;
    p.p_token = t;
    return fetch(SB_URL + '/rest/v1/rpc/' + ten, { method:'POST', headers:{ 'Content-Type':'application/json', apikey:SB_KEY }, body:JSON.stringify(p) })
      .then(function(r){ return r.ok ? r.json() : null; }).catch(function(){ return null; });
  });
}
function doChuongLap(title, tb){
  var id = tb.data.goi, lan = 0;
  return new Promise(function(xong){
    function vong(){
      if(++lan > 8) return xong();
      setTimeout(function(){
        goiRpc('ht_xem_goi', { p_goi:id }).then(function(g){
          if(!g || g.trang_thai !== 'do_chuong'){ // đã nghe / từ chối / nhỡ → bỏ thông báo đổ chuông
            self.registration.getNotifications({ tag:tb.tag }).then(function(ds){ ds.forEach(function(n){ n.close(); }); });
            return xong();
          }
          self.registration.showNotification(title, tb).then(vong, vong);
        });
      }, 5000);
    }
    vong();
  });
}

self.addEventListener('notificationclick', function(e){
  e.notification.close();
  var d = e.notification.data || {};
  if(e.action === 'tu_choi' && d.goi){ // từ chối ngay trên thông báo, không cần mở app
    e.waitUntil(goiRpc('ht_tra_loi_goi', { p_goi:d.goi, p_nghe:false }));
    return;
  }
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
