/* Nút "Tin nhắn" nổi ở trang chủ: bấm mở chat.html, hiện số tin chưa đọc (cập nhật ngay khi có tin mới).
   Thay cho khung chat cũ (chat-widget.js). */
(function(){
  if(window.__chatNut) return; window.__chatNut = true;
  var URL_ = 'https://jqwjzvucwvlwbcgxhath.supabase.co', KEY = 'sb_publishable_hI0g6zHtG2aWOkmMCm8d5g_t1wspsgv';
  var st = document.createElement('style');
  st.textContent = '#cn-nut{position:fixed;right:16px;bottom:16px;width:56px;height:56px;border-radius:50%;background:#0068ff;color:#fff;'
    + 'display:flex;align-items:center;justify-content:center;font-size:26px;box-shadow:0 4px 14px rgba(0,104,255,.45);z-index:900;cursor:pointer;'
    + 'text-decoration:none;bottom:calc(16px + env(safe-area-inset-bottom))}'
    + '#cn-so{display:none;position:absolute;top:-4px;right:-4px;background:#e53935;color:#fff;font-size:11px;font-weight:800;'
    + 'min-width:20px;height:20px;border-radius:10px;padding:0 5px;align-items:center;justify-content:center;border:2px solid #fff;font-family:sans-serif}';
  document.head.appendChild(st);
  var a = document.createElement('a');
  a.id = 'cn-nut'; a.href = 'chat.html'; a.title = 'Tin nhắn'; a.innerHTML = '💬<span id="cn-so"></span>';
  document.body.appendChild(a);

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
        .on('broadcast', { event: 'goi' }, function(m){ if(m.payload && m.payload.nguoi_nghe === toiId) goiDen(m.payload); })
        .on('broadcast', { event: 'goi_kt' }, function(m){ if(m.payload && dangDo && m.payload.id === dangDo.id) dongGoi(); })
        .subscribe();
    }catch(e){}
  }
  // Cuộc gọi đến khi đang ở trang chủ: hiện khung đổ chuông → Nghe thì mở trang chat để bắt máy
  var dangDo = null, chuong = null;
  function esc(s){ return String(s == null ? '' : s).replace(/[&<>"']/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
  function goiDen(g){
    if(dangDo) return;
    dangDo = g;
    var d = document.createElement('div');
    d.id = 'cn-goi';
    d.style.cssText = 'position:fixed;left:50%;top:16px;transform:translateX(-50%);z-index:9999;background:#081c36;color:#fff;border-radius:16px;'
      + 'padding:14px 16px;box-shadow:0 8px 30px rgba(0,0,0,.4);width:min(360px,calc(100vw - 24px));font-family:sans-serif';
    d.innerHTML = '<div style="font-size:13px;opacity:.8">📞 Cuộc gọi ' + (g.loai === 'video' ? 'video' : 'thoại') + ' đến</div>'
      + '<div style="font-size:18px;font-weight:700;margin:4px 0 12px">' + esc(g.ten_goi) + '</div>'
      + '<div style="display:flex;gap:10px"><button id="cn-tc" style="flex:1;border:none;border-radius:10px;padding:10px;background:#e53935;color:#fff;font-weight:700;font-size:14px">Từ chối</button>'
      + '<button id="cn-ng" style="flex:1;border:none;border-radius:10px;padding:10px;background:#2dc653;color:#fff;font-weight:700;font-size:14px">Nghe</button></div>';
    document.body.appendChild(d);
    document.getElementById('cn-ng').onclick = function(){ location.href = 'chat.html#ht=' + g.ht + '&goi=' + g.id; };
    document.getElementById('cn-tc').onclick = function(){ sb.rpc('ht_tra_loi_goi', { p_token: the(), p_goi: g.id, p_nghe: false }); dongGoi(); };
    try{
      var ac = new (window.AudioContext || window.webkitAudioContext)();
      var keu = function(){ var t = ac.currentTime; [0, 0.5].forEach(function(x){ var o = ac.createOscillator(), gn = ac.createGain(); o.frequency.value = 880;
        gn.gain.setValueAtTime(0, t + x); gn.gain.linearRampToValueAtTime(0.3, t + x + 0.05); gn.gain.linearRampToValueAtTime(0, t + x + 0.4);
        o.connect(gn); gn.connect(ac.destination); o.start(t + x); o.stop(t + x + 0.45); }); };
      keu(); chuong = { ac: ac, h: setInterval(keu, 2000) };
    }catch(e){}
    if(navigator.vibrate) navigator.vibrate([500, 300, 500, 300, 500]);
    setTimeout(function(){ if(dangDo && dangDo.id === g.id) dongGoi(); }, 60000);
  }
  function dongGoi(){
    dangDo = null;
    if(chuong){ clearInterval(chuong.h); try{ chuong.ac.close(); }catch(e){} chuong = null; }
    var d = document.getElementById('cn-goi'); if(d) d.remove();
  }

  demChuaDoc(); nghe();
  setInterval(function(){ if(!document.hidden) demChuaDoc(); }, 60000);
  document.addEventListener('visibilitychange', function(){ if(!document.hidden) demChuaDoc(); });
})();
