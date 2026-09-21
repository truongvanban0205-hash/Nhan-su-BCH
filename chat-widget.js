// ============================================================
// CHAT WIDGET BCH — file độc lập, không phụ thuộc index.html
// Yêu cầu trang nhúng file này đã có sẵn:
//   - biến toàn cục `sc` (Supabase client)
//   - window.BCH_USER = {ten, msnv} SAU KHI đăng nhập xong (bchAuthGate)
//     báo sẵn sàng qua sự kiện document 'bch-auth-ready'
// Bảng dữ liệu dùng chung: chat_messages (id, nguoi_gui, noi_dung, created_at)
// ============================================================
(function(){

  var chatUser=null;        // {ten, msnv} lấy từ tài khoản đã đăng nhập
  var chatMsgs=[];
  var chatKnownNames={};    // {tên: true} — gom từ lịch sử tin nhắn, dùng gợi ý @ nhắc tên
  var chatRealtimeCh=null;
  var chatUnread=0;
  var chatOpen=false;
  var chatBooted=false;

  function esc(s){
    return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }
  function p2(n){ return n<10?'0'+n:''+n; }
  function fmtTime(ts){
    var d=new Date(ts);
    return p2(d.getHours())+':'+p2(d.getMinutes());
  }

  // ---------- Dựng giao diện (tự chèn vào <body>, không cần sửa HTML trang chủ) ----------
  function buildDom(){
    var style=document.createElement('style');
    style.textContent=
      '#cw-bubble{position:fixed;right:16px;bottom:16px;width:56px;height:56px;border-radius:50%;'
      +'background:#0F2A5C;box-shadow:0 4px 14px rgba(0,0,0,0.25);display:flex;align-items:center;justify-content:center;'
      +'font-size:26px;cursor:pointer;z-index:9998;user-select:none;}'
      +'#cw-badge{position:absolute;top:-4px;right:-4px;background:#e53935;color:#fff;font-size:11px;font-weight:800;'
      +'min-width:18px;height:18px;border-radius:9px;display:none;align-items:center;justify-content:center;padding:0 4px;}'
      +'#cw-panel{position:fixed;right:16px;bottom:82px;width:320px;max-width:calc(100vw - 32px);height:440px;'
      +'max-height:calc(100vh - 120px);background:#fff;border-radius:14px;box-shadow:0 8px 30px rgba(0,0,0,0.25);'
      +'display:none;flex-direction:column;overflow:hidden;z-index:9999;font-family:Arial,sans-serif;}'
      +'#cw-head{background:#0F2A5C;color:#F7C31E;font-weight:800;font-size:14px;padding:12px 14px;display:flex;justify-content:space-between;align-items:center;}'
      +'#cw-head span.cw-close{cursor:pointer;color:#fff;font-weight:400;font-size:18px;}'
      +'#cw-msgs{flex:1;overflow-y:auto;padding:10px;display:flex;flex-direction:column;gap:8px;background:#f7f8fa;}'
      +'#cw-inputrow{display:flex;gap:6px;padding:8px;border-top:1px solid #eee;position:relative;background:#fff;}'
      +'#cw-input{flex:1;padding:8px 10px;border:1.5px solid #ccc;border-radius:8px;font-size:13px;}'
      +'#cw-send{background:#0F2A5C;color:#fff;font-weight:800;border:none;border-radius:8px;padding:8px 14px;cursor:pointer;font-size:13px;}'
      +'#cw-mention{display:none;position:absolute;bottom:100%;left:8px;right:8px;background:#fff;border:1.5px solid #d4af37;'
      +'border-radius:10px;box-shadow:0 -4px 14px rgba(0,0,0,0.12);max-height:150px;overflow-y:auto;margin-bottom:4px;}'
      +'.cw-mention-item{padding:8px 12px;font-size:13px;cursor:pointer;border-bottom:1px solid #f0f0f0;}'
      +'.cw-msg-meta{font-size:10px;color:#888;margin-bottom:2px;}'
      +'.cw-msg-bubble{padding:7px 11px;border-radius:11px;font-size:13px;word-break:break-word;white-space:pre-wrap;max-width:100%;}';
    document.head.appendChild(style);

    var bubble=document.createElement('div');
    bubble.id='cw-bubble';
    bubble.innerHTML='💬<span id="cw-badge"></span>';
    bubble.onclick=toggleOpen;
    document.body.appendChild(bubble);

    var panel=document.createElement('div');
    panel.id='cw-panel';
    panel.innerHTML=
      '<div id="cw-head">💬 Chat BCH <span class="cw-close" onclick="window.__cwToggle()">✕</span></div>'
      +'<div id="cw-msgs"><div style="font-size:12px;color:#aaa;text-align:center;">Đang tải tin nhắn...</div></div>'
      +'<div id="cw-inputrow">'
        +'<div id="cw-mention"></div>'
        +'<input id="cw-input" type="text" placeholder="Nhập tin nhắn... (@ để nhắc tên)">'
        +'<button id="cw-send">Gửi</button>'
      +'</div>';
    document.body.appendChild(panel);

    window.__cwToggle=toggleOpen; // để nút ✕ trong innerHTML gọi được (viết kiểu này để không cần sửa HTML trang)

    document.getElementById('cw-send').onclick=sendMsg;
    var inp=document.getElementById('cw-input');
    inp.addEventListener('keydown',function(e){
      if(e.key==='Enter' && !e.shiftKey){ e.preventDefault(); sendMsg(); }
    });
    inp.addEventListener('input',onInput);
  }

  function toggleOpen(){
    chatOpen=!chatOpen;
    document.getElementById('cw-panel').style.display=chatOpen?'flex':'none';
    if(chatOpen){
      chatUnread=0;
      updateBadge();
      setTimeout(function(){ document.getElementById('cw-input').focus(); },50);
      scrollToBottom(true);
    }
  }

  function updateBadge(){
    var b=document.getElementById('cw-badge');
    if(chatUnread>0){ b.textContent=chatUnread>9?'9+':chatUnread; b.style.display='flex'; }
    else{ b.style.display='none'; }
  }

  // ---------- Dữ liệu ----------
  async function loadHistory(){
    try{
      var r=await sc.from('chat_messages').select('*').order('created_at',{ascending:false}).limit(100);
      chatMsgs=(r.data||[]).slice().reverse();
      chatMsgs.forEach(function(m){ chatKnownNames[m.nguoi_gui]=true; });
      renderMsgs();
    }catch(e){
      var el=document.getElementById('cw-msgs');
      if(el) el.innerHTML='<div style="font-size:12px;color:#e53935;text-align:center;">Lỗi tải tin nhắn</div>';
    }
  }

  function subscribeRealtime(){
    if(chatRealtimeCh)return;
    chatRealtimeCh=sc.channel('chat_messages_widget_rt')
      .on('postgres_changes',{event:'INSERT',schema:'public',table:'chat_messages'},function(payload){
        chatMsgs.push(payload.new);
        chatKnownNames[payload.new.nguoi_gui]=true;
        renderMsgs();
        var mentionsMe = chatUser && mentionsName(payload.new.noi_dung, chatUser.ten);
        var fromOther = !chatUser || payload.new.nguoi_gui!==chatUser.ten;
        if(fromOther && (!chatOpen || mentionsMe)){
          if(mentionsMe || !chatOpen) chatUnread++;
          updateBadge();
          if(mentionsMe) bumpBubble();
        }
      })
      .subscribe();
  }

  function bumpBubble(){
    var b=document.getElementById('cw-bubble');
    if(!b)return;
    b.style.transition='transform .15s';
    b.style.transform='scale(1.15)';
    setTimeout(function(){ b.style.transform='scale(1)'; },200);
  }

  function mentionsName(text, name){
    if(!name)return false;
    return text.indexOf('@'+name)>=0;
  }

  function highlightMentions(text){
    var e=esc(text);
    return e.replace(/@([\p{L}0-9_.]+(?:\s[\p{L}0-9_.]+){0,2})/gu,function(full,name){
      if(chatKnownNames[name]) return '<b style="color:#0F2A5C;background:#FCF3D9;padding:0 3px;border-radius:4px;">@'+name+'</b>';
      return full;
    });
  }

  function scrollToBottom(force){
    var el=document.getElementById('cw-msgs');
    if(!el)return;
    var atBottom = force || (el.scrollTop + el.clientHeight >= el.scrollHeight - 60);
    if(atBottom) el.scrollTop=el.scrollHeight;
  }

  function renderMsgs(){
    var el=document.getElementById('cw-msgs');
    if(!el)return;
    if(!chatMsgs.length){
      el.innerHTML='<div style="font-size:12px;color:#aaa;text-align:center;">Chưa có tin nhắn nào. Nhắn đầu tiên đi!</div>';
      return;
    }
    var wasAtBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 60;
    el.innerHTML=chatMsgs.map(function(m){
      var mine = chatUser && m.nguoi_gui===chatUser.ten;
      return '<div style="align-self:'+(mine?'flex-end':'flex-start')+';max-width:85%;">'
        +'<div class="cw-msg-meta" style="'+(mine?'text-align:right;':'')+'">'+esc(m.nguoi_gui)+' · '+fmtTime(m.created_at)+'</div>'
        +'<div class="cw-msg-bubble" style="background:'+(mine?'#0F2A5C':'#eef1f5')+';color:'+(mine?'#fff':'#1a1a1a')+';">'+highlightMentions(m.noi_dung)+'</div>'
        +'</div>';
    }).join('');
    if(wasAtBottom) el.scrollTop=el.scrollHeight;
  }

  async function sendMsg(){
    var inp=document.getElementById('cw-input');
    var v=(inp.value||'').trim();
    if(!v)return;
    if(!chatUser){ alert('Chưa xác định được tài khoản đăng nhập, thử tải lại trang.'); return; }
    inp.value='';
    document.getElementById('cw-mention').style.display='none';
    try{
      await sc.from('chat_messages').insert({nguoi_gui:chatUser.ten, noi_dung:v});
    }catch(e){
      alert('Gửi tin nhắn lỗi: '+e.message);
    }
  }

  function onInput(){
    var inp=document.getElementById('cw-input');
    var box=document.getElementById('cw-mention');
    var v=inp.value;
    var caret=inp.selectionStart;
    var beforeCaret=v.slice(0,caret);
    var m=beforeCaret.match(/@([\p{L}0-9_.]*)$/u);
    if(!m){ box.style.display='none'; return; }
    var typed=m[1].toLowerCase();
    var names=Object.keys(chatKnownNames).filter(function(n){return n.toLowerCase().indexOf(typed)===0;});
    if(!names.length){ box.style.display='none'; return; }
    box.innerHTML=names.slice(0,8).map(function(n){
      return '<div class="cw-mention-item" data-name="'+esc(n)+'">👤 '+esc(n)+'</div>';
    }).join('');
    box.style.display='block';
    box.querySelectorAll('.cw-mention-item').forEach(function(item){
      item.onclick=function(){ pickMention(item.getAttribute('data-name')); };
    });
  }

  function pickMention(name){
    var inp=document.getElementById('cw-input');
    var v=inp.value;
    var caret=inp.selectionStart;
    var beforeCaret=v.slice(0,caret);
    var afterCaret=v.slice(caret);
    var newBefore=beforeCaret.replace(/@([\p{L}0-9_.]*)$/u,'@'+name+' ');
    inp.value=newBefore+afterCaret;
    document.getElementById('cw-mention').style.display='none';
    inp.focus();
  }

  // ---------- Khởi động: chờ có tài khoản đã đăng nhập rồi mới bật widget ----------
  function boot(user){
    if(chatBooted)return; // tránh khởi động 2 lần nếu sự kiện bắn nhiều hơn 1 lần
    chatBooted=true;
    chatUser=user;
    buildDom();
    loadHistory();
    subscribeRealtime();
  }

  document.addEventListener('bch-auth-ready', function(e){ boot(e.detail); });
  // Phòng trường hợp sự kiện bắn ra TRƯỚC khi file này kịp tải (thứ tự script) — kiểm tra lại luôn 1 lần.
  if(window.BCH_USER){ boot(window.BCH_USER); }

})();
