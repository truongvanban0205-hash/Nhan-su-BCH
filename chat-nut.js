/* Tin nhắn nổi ở trang chủ:
   - Bong bóng kéo thả tới bất cứ đâu trên màn hình (tự bám mép, nhớ vị trí), hiện số tin chưa đọc.
   - Bấm → mở khung chat NỔI ngay trên trang (không rời trang) → vừa nhắn tin vừa làm báo cáo.
     Thu nhỏ lại bong bóng thì khung chat vẫn chạy ngầm (vẫn nhận tin, cuộc gọi vẫn tiếp tục).
   - Có cuộc gọi đến khi chưa mở khung chat: hiện khung đổ chuông, bấm Nghe là mở khung chat để bắt máy. */
(function(){
  if(window.__chatNut) return; window.__chatNut = true;
  var URL_ = 'https://jqwjzvucwvlwbcgxhath.supabase.co', KEY = 'sb_publishable_hI0g6zHtG2aWOkmMCm8d5g_t1wspsgv';
  var LS_VT = 'bch_chat_nut_vt';
  var ICON = '<svg viewBox="0 0 24 24" width="26" height="26" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/></svg>';

  var st = document.createElement('style');
  st.textContent =
    '#cn-nut{position:fixed;width:54px;height:54px;border-radius:50%;background:#0068ff;color:#fff;display:flex;align-items:center;justify-content:center;'
    + 'box-shadow:0 4px 14px rgba(0,104,255,.45);z-index:9000;cursor:grab;touch-action:none;user-select:none;-webkit-user-select:none;transition:left .2s,top .2s,opacity .2s}'
    + '#cn-nut.keo{transition:none;cursor:grabbing;opacity:.85}'
    + '#cn-so{display:none;position:absolute;top:-4px;right:-4px;background:#e53935;color:#fff;font-size:11px;font-weight:800;'
    + 'min-width:20px;height:20px;border-radius:10px;padding:0 5px;align-items:center;justify-content:center;border:2px solid #fff;font-family:sans-serif}'
    + '#cn-khung{position:fixed;z-index:9001;background:#fff;border-radius:14px;box-shadow:0 10px 40px rgba(0,0,0,.3);overflow:hidden;display:none;'
    + 'width:380px;height:min(620px,calc(100vh - 32px))}'
    + '#cn-khung iframe{width:100%;height:100%;border:0;display:block}'
    + '@media (max-width:767px){#cn-khung{left:0!important;top:0!important;width:100vw;height:100vh;height:100dvh;border-radius:0}}';
  document.head.appendChild(st);

  var nut = document.createElement('div');
  nut.id = 'cn-nut'; nut.title = 'Tin nhắn (kéo để di chuyển)'; nut.innerHTML = ICON + '<span id="cn-so"></span>';
  document.body.appendChild(nut);

  /* ---------- vị trí + kéo thả ---------- */
  function datViTri(x, y){
    var w = window.innerWidth, h = window.innerHeight, s = 54;
    x = Math.max(6, Math.min(w - s - 6, x)); y = Math.max(6, Math.min(h - s - 6, y));
    nut.style.left = x + 'px'; nut.style.top = y + 'px';
  }
  function bamMep(){ // thả ra → tự bám mép trái/phải gần nhất
    var r = nut.getBoundingClientRect(), w = window.innerWidth;
    datViTri(r.left + 27 < w / 2 ? 6 : w - 60, r.top);
    try{ localStorage.setItem(LS_VT, JSON.stringify({ phai: r.left + 27 >= w / 2, y: r.top / window.innerHeight })); }catch(e){}
  }
  (function khoiTao(){
    var vt = null; try{ vt = JSON.parse(localStorage.getItem(LS_VT) || 'null'); }catch(e){}
    var w = window.innerWidth, h = window.innerHeight;
    if(vt) datViTri(vt.phai ? w - 60 : 6, vt.y * h); else datViTri(w - 70, h - 140);
  })();
  window.addEventListener('resize', function(){ var r = nut.getBoundingClientRect(); datViTri(r.left, r.top); bamMep(); });
  var keo = null;
  nut.addEventListener('pointerdown', function(e){
    var r = nut.getBoundingClientRect();
    keo = { x: e.clientX, y: e.clientY, dx: e.clientX - r.left, dy: e.clientY - r.top, di: false };
    nut.setPointerCapture(e.pointerId);
  });
  nut.addEventListener('pointermove', function(e){
    if(!keo) return;
    if(!keo.di && Math.abs(e.clientX - keo.x) + Math.abs(e.clientY - keo.y) < 8) return;
    keo.di = true; nut.classList.add('keo');
    datViTri(e.clientX - keo.dx, e.clientY - keo.dy);
  });
  nut.addEventListener('pointerup', function(){
    if(!keo) return;
    var di = keo.di; keo = null; nut.classList.remove('keo');
    if(di) bamMep(); else moKhung();
  });
  nut.addEventListener('pointercancel', function(){ if(keo){ keo = null; nut.classList.remove('keo'); bamMep(); } });

  /* ---------- khung chat nổi ---------- */
  var khung = null, ifr = null;
  function taoKhung(hash){
    khung = document.createElement('div'); khung.id = 'cn-khung';
    ifr = document.createElement('iframe'); // nút thu nhỏ nằm sẵn ở góc trái trên của trang chat
    ifr.src = 'chat.html' + (hash || '');
    ifr.allow = 'camera; microphone; autoplay; clipboard-write';
    khung.appendChild(ifr);
    document.body.appendChild(khung);
  }
  function moKhung(hash){
    if(!khung) taoKhung(hash);
    else if(hash){ try{ ifr.contentWindow.location.hash = hash.replace(/^#/, ''); }catch(e){ ifr.src = 'chat.html' + hash; } }
    // máy tính: đặt khung cạnh bong bóng
    var r = nut.getBoundingClientRect(), w = window.innerWidth, h = window.innerHeight, kw = 380, kh = Math.min(620, h - 32);
    var x = r.left + 27 < w / 2 ? r.right + 10 : r.left - kw - 10;
    x = Math.max(8, Math.min(w - kw - 8, x));
    var y = Math.max(8, Math.min(h - kh - 8, r.top - kh / 2));
    khung.style.left = x + 'px'; khung.style.top = y + 'px';
    khung.style.display = 'block';
    if(window.innerWidth < 768) nut.style.display = 'none';
    dongGoi(); // khung chat tự lo cuộc gọi
  }
  function thuNho(){
    if(khung) khung.style.display = 'none';
    nut.style.display = 'flex';
    demChuaDoc();
  }
  window.addEventListener('message', function(e){
    if(e.origin !== location.origin || !e.data) return;
    if(e.data.chat === 'thu_nho') thuNho();
    if(e.data.chat === 'mo') moKhung();          // khung đang thu nhỏ mà có cuộc gọi đến → bung ra
    if(e.data.chat === 'chua_doc') demChuaDoc();
  });

  /* ---------- số tin chưa đọc + nghe cuộc gọi ---------- */
  function the(){ try{ return (JSON.parse(localStorage.getItem('bch_nv_login_v2') || '{}') || {}).token || ''; }catch(e){ return ''; } }
  var sb = window.sc || (window.supabase && window.supabase.createClient(URL_, KEY));
  if(!sb) return;
  async function demChuaDoc(){
    var t = the(); if(!t) return;
    try{
      var r = await sb.rpc('ht_tong_chua_doc', { p_token: t });
      var el = document.getElementById('cn-so');
      if(r.error || !r.data){ el.style.display = 'none'; return; }
      el.textContent = r.data > 99 ? '99+' : r.data; el.style.display = 'flex';
    }catch(e){}
  }
  async function nghe(){
    var t = the(); if(!t) return;
    try{
      var r = await sb.rpc('ht_toi', { p_token: t });
      if(r.error || !r.data || !r.data.kenh) return;
      var tre = null, toiId = r.data.id;
      sb.channel('u:' + r.data.kenh, { config: { broadcast: { self: false } } })
        .on('broadcast', { event: 'tin' }, function(){ clearTimeout(tre); tre = setTimeout(demChuaDoc, 500); })
        .on('broadcast', { event: 'xem' }, function(){ clearTimeout(tre); tre = setTimeout(demChuaDoc, 500); })
        .on('broadcast', { event: 'goi' }, function(m){ if(m.payload && m.payload.nguoi_nghe === toiId && !khung) goiDen(m.payload); })
        .on('broadcast', { event: 'goi_kt' }, function(m){ if(m.payload && dangDo && m.payload.id === dangDo.id) dongGoi(); })
        .subscribe();
    }catch(e){}
  }

  var dangDo = null, chuong = null, AC = null;
  ['pointerdown', 'keydown', 'touchstart'].forEach(function(ev){
    document.addEventListener(ev, function(){ try{ if(!AC) AC = new (window.AudioContext || window.webkitAudioContext)(); if(AC.state === 'suspended') AC.resume(); }catch(e){} }, { passive: true });
  });
  function esc(s){ return String(s == null ? '' : s).replace(/[&<>"']/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
  function goiDen(g){
    if(dangDo) return;
    dangDo = g;
    var d = document.createElement('div');
    d.id = 'cn-goi';
    d.style.cssText = 'position:fixed;left:50%;top:16px;transform:translateX(-50%);z-index:9999;background:#081c36;color:#fff;border-radius:16px;'
      + 'padding:14px 16px;box-shadow:0 8px 30px rgba(0,0,0,.4);width:min(360px,calc(100vw - 24px));font-family:sans-serif';
    d.innerHTML = '<div style="font-size:13px;opacity:.8">Cuộc gọi ' + (g.loai === 'video' ? 'video' : 'thoại') + ' đến</div>'
      + '<div style="font-size:18px;font-weight:700;margin:4px 0 12px">' + esc(g.ten_goi) + '</div>'
      + '<div style="display:flex;gap:10px"><button id="cn-tc" style="flex:1;border:none;border-radius:10px;padding:11px;background:#e53935;color:#fff;font-weight:700;font-size:14px">Từ chối</button>'
      + '<button id="cn-ng" style="flex:1;border:none;border-radius:10px;padding:11px;background:#2dc653;color:#fff;font-weight:700;font-size:14px">Nghe</button></div>';
    document.body.appendChild(d);
    document.getElementById('cn-ng').onclick = function(){ var h = '#ht=' + g.ht + '&goi=' + g.id; dongGoi(); moKhung(h); };
    document.getElementById('cn-tc').onclick = function(){ sb.rpc('ht_tra_loi_goi', { p_token: the(), p_goi: g.id, p_nghe: false }); dongGoi(); };
    var keu = function(){
      try{
        if(!AC) return; if(AC.state === 'suspended') AC.resume();
        var t = AC.currentTime;
        [0, 0.18, 0.36, 0.54, 1.0, 1.18, 1.36, 1.54].forEach(function(x){
          var o = AC.createOscillator(), o2 = AC.createOscillator(), gn = AC.createGain();
          o.frequency.value = 1046; o2.frequency.value = 1318;
          gn.gain.setValueAtTime(0, t + x); gn.gain.linearRampToValueAtTime(0.25, t + x + 0.02); gn.gain.linearRampToValueAtTime(0, t + x + 0.15);
          o.connect(gn); o2.connect(gn); gn.connect(AC.destination); o.start(t + x); o2.start(t + x); o.stop(t + x + 0.15); o2.stop(t + x + 0.15);
        });
      }catch(e){}
      try{ if(navigator.vibrate) navigator.vibrate([700, 400, 700]); }catch(e){}
    };
    keu(); chuong = setInterval(keu, 2500);
    setTimeout(function(){ if(dangDo && dangDo.id === g.id) dongGoi(); }, 60000);
  }
  function dongGoi(){
    dangDo = null;
    if(chuong){ clearInterval(chuong); chuong = null; }
    try{ if(navigator.vibrate) navigator.vibrate(0); }catch(e){}
    var d = document.getElementById('cn-goi'); if(d) d.remove();
  }

  demChuaDoc(); nghe();
  setInterval(function(){ if(!document.hidden) demChuaDoc(); }, 60000);
  document.addEventListener('visibilitychange', function(){ if(!document.hidden) demChuaDoc(); });
})();
