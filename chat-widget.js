// ============================================================
// CHAT WIDGET BCH — file độc lập, không phụ thuộc index.html
// Yêu cầu trang nhúng file này đã có sẵn:
//   - biến toàn cục `sc` (Supabase client)
//   - window.BCH_USER = {ten, msnv} SAU KHI đăng nhập xong (bchAuthGate)
//     báo sẵn sàng qua sự kiện document 'bch-auth-ready'
// Bảng dữ liệu dùng chung: chat_messages (id, nguoi_gui, noi_dung, created_at, reply_to_id)
// RPC dùng thêm: lay_danh_sach_ten_da_duyet() — trả về TÊN người đã duyệt (không cần mật khẩu)
// ============================================================
(function(){

  var chatUser=null;        // {ten, msnv} lấy từ tài khoản đã đăng nhập
  var chatMsgs=[];
  var chatKnownNames={};    // {tên: true} — gộp từ lịch sử chat + danh sách đã duyệt, dùng gợi ý @ nhắc tên
  var chatRealtimeCh=null;
  var chatOpen=false;
  var chatBooted=false;
  var replyingTo=null;      // {id, nguoi_gui, noi_dung} — tin đang được trả lời, null nếu không trả lời gì
  var LASTREAD_PREFIX='bch_chat_lastread_'; // + tên người dùng

  function esc(s){
    return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }
  function p2(n){ return n<10?'0'+n:''+n; }
  function fmtTime(ts){
    var d=new Date(ts);
    return p2(d.getHours())+':'+p2(d.getMinutes());
  }
  function truncate(s,n){
    s=String(s||'');
    return s.length>n ? s.slice(0,n)+'…' : s;
  }

  // ---------- "Đã đọc tới đâu" — lưu riêng theo từng tài khoản trên máy ----------
  function getLastRead(){
    if(!chatUser)return null;
    var v=localStorage.getItem(LASTREAD_PREFIX+chatUser.ten);
    return v||null;
  }
  function setLastReadNow(){
    if(!chatUser)return;
    localStorage.setItem(LASTREAD_PREFIX+chatUser.ten, new Date().toISOString());
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
      +'#cw-atbadge{position:absolute;bottom:-3px;right:-3px;background:#1565c0;color:#fff;font-size:11px;font-weight:900;'
      +'width:18px;height:18px;border-radius:9px;display:none;align-items:center;justify-content:center;}'
      +'#cw-panel{position:fixed;right:16px;bottom:82px;width:330px;max-width:calc(100vw - 32px);height:460px;'
      +'max-height:calc(100vh - 120px);background:#fff;border-radius:14px;box-shadow:0 8px 30px rgba(0,0,0,0.25);'
      +'display:none;flex-direction:column;overflow:hidden;z-index:9999;font-family:Arial,sans-serif;}'
      +'#cw-head{background:#0F2A5C;color:#F7C31E;font-weight:800;font-size:14px;padding:12px 14px;display:flex;justify-content:space-between;align-items:center;}'
      +'#cw-head span.cw-close{cursor:pointer;color:#fff;font-weight:400;font-size:18px;}'
      +'#cw-msgs{flex:1;overflow-y:auto;padding:10px;display:flex;flex-direction:column;gap:8px;background:#f7f8fa;}'
      +'#cw-replybar{display:none;padding:7px 10px;background:#eef1f5;border-top:1px solid #e0e0e0;font-size:11px;'
      +'align-items:center;gap:8px;}'
      +'#cw-replybar .cw-rb-text{flex:1;color:#555;border-left:3px solid #0F2A5C;padding-left:7px;overflow:hidden;'
      +'text-overflow:ellipsis;white-space:nowrap;}'
      +'#cw-replybar .cw-rb-x{cursor:pointer;color:#888;font-weight:800;padding:0 4px;}'
      +'#cw-inputrow{display:flex;gap:6px;padding:8px;border-top:1px solid #eee;position:relative;background:#fff;}'
      +'#cw-input{flex:1;padding:8px 10px;border:1.5px solid #ccc;border-radius:8px;font-size:13px;}'
      +'#cw-send{background:#0F2A5C;color:#fff;font-weight:800;border:none;border-radius:8px;padding:8px 14px;cursor:pointer;font-size:13px;}'
      +'#cw-mention{display:none;position:absolute;bottom:100%;left:8px;right:8px;background:#fff;border:1.5px solid #d4af37;'
      +'border-radius:10px;box-shadow:0 -4px 14px rgba(0,0,0,0.12);max-height:150px;overflow-y:auto;margin-bottom:4px;}'
      +'.cw-mention-item{padding:8px 12px;font-size:13px;cursor:pointer;border-bottom:1px solid #f0f0f0;}'
      +'.cw-msg-row{display:flex;flex-direction:column;max-width:85%;}'
      +'.cw-msg-meta{font-size:10px;color:#888;margin-bottom:2px;}'
      +'.cw-msg-bubble{padding:7px 11px;border-radius:11px;font-size:13px;word-break:break-word;white-space:pre-wrap;'
      +'max-width:100%;cursor:pointer;}'
      +'.cw-quote{font-size:10.5px;opacity:0.85;border-left:2.5px solid currentColor;padding-left:6px;margin-bottom:4px;'
      +'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:100%;}';
    document.head.appendChild(style);

    var bubble=document.createElement('div');
    bubble.id='cw-bubble';
    bubble.innerHTML='💬<span id="cw-badge"></span><span id="cw-atbadge">@</span>';
    bubble.onclick=toggleOpen;
    document.body.appendChild(bubble);

    var panel=document.createElement('div');
    panel.id='cw-panel';
    panel.innerHTML=
      '<div id="cw-head">💬 Chat BCH <span class="cw-close" id="cw-closebtn">✕</span></div>'
      +'<div id="cw-msgs"><div style="font-size:12px;color:#aaa;text-align:center;">Đang tải tin nhắn...</div></div>'
      +'<div id="cw-replybar"><div class="cw-rb-text" id="cw-rb-text"></div><div class="cw-rb-x" id="cw-rb-x">✕</div></div>'
      +'<div id="cw-inputrow">'
        +'<div id="cw-mention"></div>'
        +'<input id="cw-input" type="text" placeholder="Nhập tin nhắn... (@ để nhắc tên)">'
        +'<button id="cw-send">Gửi</button>'
      +'</div>';
    document.body.appendChild(panel);

    document.getElementById('cw-closebtn').onclick=toggleOpen;
    document.getElementById('cw-rb-x').onclick=cancelReply;
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
      setLastReadNow();
      updateBadges();
      setTimeout(function(){ document.getElementById('cw-input').focus(); },50);
      scrollToBottom(true);
    }
  }

  // ---------- Badge số chưa đọc (đỏ) + @ (xanh) kiểu Zalo ----------
  function updateBadges(){
    var badge=document.getElementById('cw-badge');
    var atBadge=document.getElementById('cw-atbadge');
    if(!badge||!atBadge)return;
    if(chatOpen){
      badge.style.display='none';
      atBadge.style.display='none';
      return;
    }
    var lastRead=getLastRead();
    var unread=chatMsgs.filter(function(m){
      if(chatUser && m.nguoi_gui===chatUser.ten) return false; // tin của chính mình không tính
      if(!lastRead) return true; // chưa từng đọc lần nào -> toàn bộ tính là chưa đọc
      return new Date(m.created_at) > new Date(lastRead);
    });
    var hasMention = chatUser && unread.some(function(m){ return mentionsName(m.noi_dung, chatUser.ten); });
    if(unread.length>0){
      badge.textContent = unread.length>99?'99+':String(unread.length);
      badge.style.display='flex';
    }else{
      badge.style.display='none';
    }
    atBadge.style.display = hasMention ? 'flex' : 'none';
  }

  // ---------- Dữ liệu: lịch sử chat + danh sách tên đã duyệt (làm mới định kỳ) ----------
  async function loadHistory(){
    try{
      var r=await sc.from('chat_messages').select('*').order('created_at',{ascending:false}).limit(100);
      chatMsgs=(r.data||[]).slice().reverse();
      chatMsgs.forEach(function(m){ chatKnownNames[m.nguoi_gui]=true; });
      renderMsgs();
      updateBadges();
    }catch(e){
      var el=document.getElementById('cw-msgs');
      if(el) el.innerHTML='<div style="font-size:12px;color:#e53935;text-align:center;">Lỗi tải tin nhắn</div>';
    }
  }

  async function loadApprovedNames(){
    try{
      var r=await sc.rpc('lay_danh_sach_ten_da_duyet');
      (r.data||[]).forEach(function(row){ if(row.ten) chatKnownNames[row.ten]=true; });
    }catch(e){ /* im lặng bỏ qua, vẫn còn danh sách từ lịch sử chat */ }
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
        if(chatOpen){
          setLastReadNow(); // đang mở sẵn -> coi như đọc luôn tin mới tới
        }
        updateBadges();
        if(fromOther && mentionsMe && !chatOpen) bumpBubble();
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

  function findMsgById(id){
    return chatMsgs.find(function(m){ return m.id===id; });
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
      var quoteHtml='';
      if(m.reply_to_id){
        var orig=findMsgById(m.reply_to_id);
        var quoteText = orig ? (orig.nguoi_gui+': '+truncate(orig.noi_dung,40)) : 'Tin nhắn trước đó';
        quoteHtml='<div class="cw-quote">'+esc(quoteText)+'</div>';
      }
      return '<div class="cw-msg-row" style="align-self:'+(mine?'flex-end':'flex-start')+';">'
        +'<div class="cw-msg-meta" style="'+(mine?'text-align:right;':'')+'">'+esc(m.nguoi_gui)+' · '+fmtTime(m.created_at)+'</div>'
        +'<div class="cw-msg-bubble" data-id="'+m.id+'" style="background:'+(mine?'#0F2A5C':'#eef1f5')+';color:'+(mine?'#fff':'#1a1a1a')+';" title="Bấm để trả lời">'
          +quoteHtml+highlightMentions(m.noi_dung)
        +'</div>'
        +'</div>';
    }).join('');
    el.querySelectorAll('.cw-msg-bubble').forEach(function(b){
      b.onclick=function(){ startReply(parseInt(b.getAttribute('data-id'))); };
    });
    if(wasAtBottom) el.scrollTop=el.scrollHeight;
  }

  // ---------- Trả lời trích dẫn ----------
  function startReply(id){
    var m=findMsgById(id);
    if(!m)return;
    replyingTo=m;
    var bar=document.getElementById('cw-replybar');
    document.getElementById('cw-rb-text').textContent='Trả lời '+m.nguoi_gui+': '+truncate(m.noi_dung,50);
    bar.style.display='flex';
    document.getElementById('cw-input').focus();
  }
  function cancelReply(){
    replyingTo=null;
    document.getElementById('cw-replybar').style.display='none';
  }

  async function sendMsg(){
    var inp=document.getElementById('cw-input');
    var v=(inp.value||'').trim();
    if(!v)return;
    if(!chatUser){ alert('Chưa xác định được tài khoản đăng nhập, thử tải lại trang.'); return; }
    inp.value='';
    document.getElementById('cw-mention').style.display='none';
    var payload={nguoi_gui:chatUser.ten, noi_dung:v};
    if(replyingTo) payload.reply_to_id=replyingTo.id;
    try{
      await sc.from('chat_messages').insert(payload);
      cancelReply();
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
    var names=Object.keys(chatKnownNames).filter(function(n){return n.toLowerCase().indexOf(typed)===0;}).sort();
    if(!names.length){ box.style.display='none'; return; }
    box.innerHTML=names.map(function(n){
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
    loadApprovedNames();
    loadHistory();
    subscribeRealtime();
    // Danh sách người đã duyệt hay được bổ sung/sửa -> làm mới định kỳ, không cần tải lại trang
    setInterval(loadApprovedNames, 60000);
  }

  document.addEventListener('bch-auth-ready', function(e){ boot(e.detail); });
  // Phòng trường hợp sự kiện bắn ra TRƯỚC khi file này kịp tải (thứ tự script) — kiểm tra lại luôn 1 lần.
  if(window.BCH_USER){ boot(window.BCH_USER); }

})();
