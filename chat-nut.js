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
      var tre = null;
      sb.channel('u:' + r.data.kenh, { config: { broadcast: { self: false } } })
        .on('broadcast', { event: 'tin' }, function(){ clearTimeout(tre); tre = setTimeout(demChuaDoc, 500); })
        .on('broadcast', { event: 'xem' }, function(){ clearTimeout(tre); tre = setTimeout(demChuaDoc, 500); })
        .subscribe();
    }catch(e){}
  }
  demChuaDoc(); nghe();
  setInterval(function(){ if(!document.hidden) demChuaDoc(); }, 60000);
  document.addEventListener('visibilitychange', function(){ if(!document.hidden) demChuaDoc(); });
})();
