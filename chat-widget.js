// ============================================================
// CHAT WIDGET BCH — file độc lập, không phụ thuộc index.html
// Yêu cầu trang nhúng file này đã có sẵn:
//   - biến toàn cục `sc` (Supabase client)
//   - window.BCH_USER = {ten, msnv} SAU KHI đăng nhập xong (bchAuthGate)
//     báo sẵn sàng qua sự kiện document 'bch-auth-ready'
// Bảng dữ liệu dùng chung: chat_messages (id, nguoi_gui, noi_dung, created_at, reply_to_id, anh_url)
// RPC: lay_danh_sach_ten_da_duyet(), admin_xoa_chat_message(p_pass, p_id)
// Storage bucket (tuỳ chọn): chat-images — để gửi ảnh
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
  var VAPID_PUBLIC_KEY='BCCz7LRK3h3WSSHLTp_JbGY8B-Qvpg8JW_2P8yWj02noNhaD9Z0iJ4_0MIvCL_SVTaCUWgtvwWuK6oGSYDBoMPM';
  var pushSubscribed=false;
  var CHAT_EMOJIS=['😀','😂','😅','😊','😍','🥰','😎','🤔','👍','👎','👏','🙏','🔥','✅','❌','⚠️','❤️','💪','🎉','📌','📷','🫡','🤝','💯'];
  var chatUploading=false;

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
      +'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:100%;}'
      +'#cw-tools{display:flex;align-items:center;gap:4px;padding:4px 8px 0;background:#fff;border-top:1px solid #eee;flex-wrap:wrap;}'
      +'#cw-emoji-panel{display:none;padding:6px 8px;background:#fafafa;border-top:1px solid #eee;flex-wrap:wrap;gap:4px;}'
      +'#cw-emoji-panel button{border:none;background:transparent;font-size:20px;cursor:pointer;padding:2px 4px;line-height:1.2;border-radius:6px;}'
      +'#cw-emoji-panel button:hover{background:#eee;}'
      +'.cw-toolbtn{border:1px solid #ddd;background:#f7f8fa;border-radius:8px;padding:5px 8px;cursor:pointer;font-size:15px;line-height:1;}'
      +'.cw-toolbtn:hover{border-color:#0F2A5C;}'
      +'.cw-msg-img{max-width:100%;max-height:220px;border-radius:8px;margin-top:4px;display:block;cursor:zoom-in;}'
      +'.cw-msg-actions{display:flex;gap:6px;margin-top:2px;}'
      +'.cw-msg-actions button{border:none;background:transparent;font-size:11px;color:#888;cursor:pointer;padding:0;}'
      +'.cw-msg-actions button:hover{color:#e53935;}'
      +'#cw-img-preview{display:none;padding:6px 10px;background:#f5f5f5;border-top:1px solid #eee;font-size:12px;align-items:center;gap:8px;}'
      +'#cw-img-preview img{height:48px;width:auto;border-radius:6px;}'
      +'#cw-img-preview .cw-rb-x{cursor:pointer;color:#888;font-weight:800;}';
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
      +'<div id="cw-img-preview"><img id="cw-img-thumb" alt=""><span id="cw-img-name" style="flex:1;color:#555;"></span><span class="cw-rb-x" id="cw-img-clear">✕</span></div>'
      +'<div id="cw-emoji-panel"></div>'
      +'<div id="cw-tools">'
        +'<button type="button" class="cw-toolbtn" id="cw-btn-emoji" title="Cảm xúc">😊</button>'
        +'<button type="button" class="cw-toolbtn" id="cw-btn-img" title="Gửi ảnh">🖼️</button>'
        +'<input type="file" id="cw-file" accept="image/*" style="display:none">'
      +'</div>'
      +'<div id="cw-inputrow">'
        +'<div id="cw-mention"></div>'
        +'<input id="cw-input" type="text" placeholder="Nhập tin nhắn... (@ để nhắc tên)">'
        +'<button id="cw-send">Gửi</button>'
      +'</div>';
    document.body.appendChild(panel);

    document.getElementById('cw-closebtn').onclick=toggleOpen;
    document.getElementById('cw-rb-x').onclick=cancelReply;
    document.getElementById('cw-send').onclick=sendMsg;
    document.getElementById('cw-btn-emoji').onclick=toggleEmojiPanel;
    document.getElementById('cw-btn-img').onclick=function(){ document.getElementById('cw-file').click(); };
    document.getElementById('cw-file').onchange=onPickImage;
    document.getElementById('cw-img-clear').onclick=clearPendingImage;
    var emoPanel=document.getElementById('cw-emoji-panel');
    emoPanel.innerHTML=CHAT_EMOJIS.map(function(e){
      return '<button type="button" data-emo="'+e+'">'+e+'</button>';
    }).join('');
    emoPanel.querySelectorAll('button').forEach(function(b){
      b.onclick=function(){ insertEmoji(b.getAttribute('data-emo')); };
    });
    var inp=document.getElementById('cw-input');
    inp.addEventListener('keydown',function(e){
      if(e.key==='Enter' && !e.shiftKey){ e.preventDefault(); sendMsg(); }
    });
    inp.addEventListener('input',onInput);
  }

  var pendingImageFile=null;

  function toggleEmojiPanel(){
    var p=document.getElementById('cw-emoji-panel');
    if(!p)return;
    p.style.display = p.style.display==='flex' ? 'none' : 'flex';
  }
  function insertEmoji(emo){
    var inp=document.getElementById('cw-input');
    if(!inp)return;
    var start=inp.selectionStart||inp.value.length;
    var end=inp.selectionEnd||inp.value.length;
    var v=inp.value;
    inp.value=v.slice(0,start)+emo+v.slice(end);
    var pos=start+emo.length;
    inp.focus();
    try{ inp.setSelectionRange(pos,pos); }catch(e){}
  }
  function onPickImage(e){
    var f=(e.target.files&&e.target.files[0])||null;
    e.target.value='';
    if(!f)return;
    if(!/^image\//.test(f.type)){ alert('Chỉ chọn file ảnh.'); return; }
    if(f.size > 5*1024*1024){ alert('Ảnh tối đa 5MB.'); return; }
    pendingImageFile=f;
    var box=document.getElementById('cw-img-preview');
    var thumb=document.getElementById('cw-img-thumb');
    var nameEl=document.getElementById('cw-img-name');
    if(thumb) thumb.src=URL.createObjectURL(f);
    if(nameEl) nameEl.textContent=f.name+' ('+Math.round(f.size/1024)+' KB)';
    if(box) box.style.display='flex';
  }
  function clearPendingImage(){
    pendingImageFile=null;
    var box=document.getElementById('cw-img-preview');
    var thumb=document.getElementById('cw-img-thumb');
    if(thumb) thumb.src='';
    if(box) box.style.display='none';
  }

  function toggleOpen(){
    chatOpen=!chatOpen;
    document.getElementById('cw-panel').style.display=chatOpen?'flex':'none';
    if(chatOpen){
      setLastReadNow();
      updateBadges();
      setTimeout(function(){ document.getElementById('cw-input').focus(); },50);
      scrollToBottom(true);
      subscribeToPush(); // hỏi quyền + đăng ký nhận thông báo, chỉ hỏi 1 lần (trình duyệt tự nhớ)
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
        var mentionsMe = chatUser && mentionsName(payload.new.noi_dung||'', chatUser.ten);
        var fromOther = !chatUser || payload.new.nguoi_gui!==chatUser.ten;
        if(chatOpen){
          setLastReadNow();
        }
        updateBadges();
        // Rung icon khi có tin mới từ người khác (kể cả không @)
        if(fromOther && !chatOpen) bumpBubble();
      })
      .on('postgres_changes',{event:'DELETE',schema:'public',table:'chat_messages'},function(payload){
        var id=payload.old && payload.old.id;
        if(id==null)return;
        chatMsgs=chatMsgs.filter(function(m){ return m.id!==id; });
        renderMsgs();
        updateBadges();
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

  // So trực tiếp với đúng danh sách tên đã biết (ưu tiên tên DÀI hơn trước, tránh khớp nhầm 1 phần tên)
  // — thay cho cách đoán "tối đa 3 từ sau @" cũ, vốn bị nuốt nhầm chữ phía sau với tên có 1-2 từ.
  function findMentionsInText(text){
    var names=Object.keys(chatKnownNames).sort(function(a,b){return b.length-a.length;});
    var found=[]; // {name, start, end}
    var idx=0;
    while((idx=text.indexOf('@',idx))>=0){
      var rest=text.slice(idx+1);
      for(var i=0;i<names.length;i++){
        if(rest.indexOf(names[i])===0){
          var after=rest.charAt(names[i].length);
          if(!after || !/[\p{L}0-9_.]/u.test(after)){
            found.push({name:names[i], start:idx, end:idx+1+names[i].length});
            break;
          }
        }
      }
      idx+=1;
    }
    return found;
  }

  function highlightMentions(text){
    var hits=findMentionsInText(text);
    if(!hits.length) return esc(text);
    var out=''; var pos=0;
    hits.forEach(function(h){
      out+=esc(text.slice(pos,h.start));
      out+='<b style="color:#0F2A5C;background:#FCF3D9;padding:0 3px;border-radius:4px;">@'+esc(h.name)+'</b>';
      pos=h.end;
    });
    out+=esc(text.slice(pos));
    return out;
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
        var qBody = orig ? (orig.anh_url && !orig.noi_dung ? '[Ảnh]' : truncate(orig.noi_dung,40)) : '';
        var quoteText = orig ? (orig.nguoi_gui+': '+qBody) : 'Tin nhắn trước đó';
        quoteHtml='<div class="cw-quote">'+esc(quoteText)+'</div>';
      }
      var bodyHtml = (m.noi_dung ? highlightMentions(m.noi_dung) : '');
      var imgHtml = m.anh_url
        ? '<img class="cw-msg-img" src="'+esc(m.anh_url)+'" alt="ảnh" loading="lazy" data-full="'+esc(m.anh_url)+'">'
        : '';
      return '<div class="cw-msg-row" style="align-self:'+(mine?'flex-end':'flex-start')+';">'
        +'<div class="cw-msg-meta" style="'+(mine?'text-align:right;':'')+'">'+esc(m.nguoi_gui)+' · '+fmtTime(m.created_at)+'</div>'
        +'<div class="cw-msg-bubble" data-id="'+m.id+'" style="background:'+(mine?'#0F2A5C':'#eef1f5')+';color:'+(mine?'#fff':'#1a1a1a')+';" title="Bấm để trả lời">'
          +quoteHtml+bodyHtml+imgHtml
        +'</div>'
        +'<div class="cw-msg-actions" style="'+(mine?'justify-content:flex-end;':'')+'">'
          +'<button type="button" data-reply="'+m.id+'">Trả lời</button>'
          +'<button type="button" data-del="'+m.id+'" title="Chỉ Quản lý (admin) được xóa">Xóa</button>'
        +'</div>'
        +'</div>';
    }).join('');
    el.querySelectorAll('.cw-msg-bubble').forEach(function(b){
      b.onclick=function(ev){
        if(ev.target && ev.target.tagName==='IMG'){
          window.open(ev.target.getAttribute('data-full')||ev.target.src, '_blank');
          return;
        }
        startReply(parseInt(b.getAttribute('data-id')));
      };
    });
    el.querySelectorAll('[data-reply]').forEach(function(btn){
      btn.onclick=function(ev){ ev.stopPropagation(); startReply(parseInt(btn.getAttribute('data-reply'))); };
    });
    el.querySelectorAll('[data-del]').forEach(function(btn){
      btn.onclick=function(ev){ ev.stopPropagation(); deleteMsg(parseInt(btn.getAttribute('data-del'))); };
    });
    if(wasAtBottom) el.scrollTop=el.scrollHeight;
  }

  async function deleteMsg(id){
    if(!id)return;
    var m=findMsgById(id);
    if(!m)return;
    if(!confirm('Xóa tin nhắn này?\n(Chỉ Quản lý / admin mới xóa được)')) return;
    var pass=prompt('Nhập mật khẩu Quản lý chung để xóa tin:');
    if(pass==null || !String(pass).trim()) return;
    try{
      var r=await sc.rpc('admin_xoa_chat_message', { p_pass: String(pass).trim(), p_id: id });
      if(r.error){ alert('Không xóa được: '+(r.error.message||'Sai mật khẩu hoặc chưa cấu hình SQL.')); return; }
      chatMsgs=chatMsgs.filter(function(x){ return x.id!==id; });
      renderMsgs();
      updateBadges();
    }catch(e){
      alert('Không xóa được: '+(e.message||e));
    }
  }

  // ---------- Trả lời trích dẫn ----------
  function startReply(id){
    var m=findMsgById(id);
    if(!m)return;
    replyingTo=m;
    var bar=document.getElementById('cw-replybar');
    var preview = m.noi_dung ? truncate(m.noi_dung,50) : (m.anh_url ? '[Ảnh]' : '');
    document.getElementById('cw-rb-text').textContent='Trả lời '+m.nguoi_gui+': '+preview;
    bar.style.display='flex';
    document.getElementById('cw-input').focus();
  }
  function cancelReply(){
    replyingTo=null;
    document.getElementById('cw-replybar').style.display='none';
  }

  async function uploadChatImage(file){
    var ext=(file.name.split('.').pop()||'jpg').toLowerCase().replace(/[^a-z0-9]/g,'');
    if(!ext) ext='jpg';
    var path='chat/'+Date.now()+'_'+Math.floor(Math.random()*1e6)+'.'+ext;
    var up=await sc.storage.from('chat-images').upload(path, file, { contentType: file.type, upsert:false });
    if(up.error) throw up.error;
    var pub=sc.storage.from('chat-images').getPublicUrl(path);
    return (pub && pub.data && pub.data.publicUrl) ? pub.data.publicUrl : null;
  }

  async function sendMsg(){
    var inp=document.getElementById('cw-input');
    var v=(inp.value||'').trim();
    if(!v && !pendingImageFile)return;
    if(!chatUser){ alert('Chưa xác định được tài khoản đăng nhập, thử tải lại trang.'); return; }
    if(chatUploading)return;
    var payload={nguoi_gui:chatUser.ten, noi_dung:v||''};
    if(replyingTo) payload.reply_to_id=replyingTo.id;
    try{
      chatUploading=true;
      document.getElementById('cw-send').disabled=true;
      if(pendingImageFile){
        try{
          var url=await uploadChatImage(pendingImageFile);
          if(url) payload.anh_url=url;
        }catch(imgErr){
          alert('Gửi ảnh lỗi: '+(imgErr.message||imgErr)+'\nCần tạo bucket Storage tên "chat-images" (public) trên Supabase.');
          return;
        }
      }
      inp.value='';
      document.getElementById('cw-mention').style.display='none';
      clearPendingImage();
      var emo=document.getElementById('cw-emoji-panel');
      if(emo) emo.style.display='none';
      await sc.from('chat_messages').insert(payload);
      cancelReply();
      // Thông báo ra ngoài: @mention + mọi người đã đăng ký push (trừ người gửi)
      notifyChatPush(v||(payload.anh_url?'[Ảnh]':''), chatUser.ten);
    }catch(e){
      alert('Gửi tin nhắn lỗi: '+e.message);
    }finally{
      chatUploading=false;
      var btn=document.getElementById('cw-send');
      if(btn) btn.disabled=false;
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

  // ---------- Đăng ký nhận thông báo đẩy (push) ----------
  function urlBase64ToUint8Array(base64String){
    var padding='='.repeat((4 - base64String.length % 4) % 4);
    var base64=(base64String+padding).replace(/-/g,'+').replace(/_/g,'/');
    var rawData=atob(base64);
    var outputArray=new Uint8Array(rawData.length);
    for(var i=0;i<rawData.length;++i) outputArray[i]=rawData.charCodeAt(i);
    return outputArray;
  }

  async function subscribeToPush(){
    if(pushSubscribed)return;
    if(!('serviceWorker' in navigator) || !('PushManager' in window))return; // trình duyệt không hỗ trợ (vd Safari cũ)
    try{
      var perm=Notification.permission;
      if(perm==='default') perm=await Notification.requestPermission();
      if(perm!=='granted')return; // người dùng từ chối, không ép
      var reg=await navigator.serviceWorker.ready;
      var sub=await reg.pushManager.getSubscription();
      if(!sub){
        sub=await reg.pushManager.subscribe({
          userVisibleOnly:true,
          applicationServerKey:urlBase64ToUint8Array(VAPID_PUBLIC_KEY)
        });
      }
      var json=sub.toJSON();
      await sc.from('push_subscriptions').upsert({
        ten: chatUser.ten,
        endpoint: json.endpoint,
        p256dh: json.keys.p256dh,
        auth: json.keys.auth
      }, {onConflict:'endpoint'});
      pushSubscribed=true;
    }catch(e){ /* im lặng bỏ qua — không có thông báo cũng không chặn dùng chat bình thường */ }
  }

  // ---------- Thông báo đẩy ra ngoài (kiểu Zalo) ----------
  function extractMentionNames(text){
    var found=[];
    findMentionsInText(text||'').forEach(function(h){
      if(found.indexOf(h.name)<0) found.push(h.name);
    });
    return found;
  }
  async function pushToName(ten, tinNhan, nguoiGui){
    try{
      await fetch(SURL+'/functions/v1/send-mention-push', {
        method:'POST',
        headers:{
          'Content-Type':'application/json',
          'Authorization':'Bearer '+SKEY,
          'apikey':SKEY
        },
        body:JSON.stringify({ten:ten, tin_nhan:tinNhan, nguoi_gui:nguoiGui})
      });
    }catch(e){}
  }
  async function notifyChatPush(text, senderName){
    var targets={};
    extractMentionNames(text).forEach(function(n){ if(n!==senderName) targets[n]=true; });
    Object.keys(chatKnownNames).forEach(function(n){
      if(n && n!==senderName) targets[n]=true;
    });
    var list=Object.keys(targets);
    var preview = text ? String(text).slice(0,120) : 'Có tin nhắn mới';
    for(var i=0;i<list.length;i++){
      await pushToName(list[i], preview, senderName);
    }
  }


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
