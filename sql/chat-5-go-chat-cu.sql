-- =====================================================================
-- CHAT NỘI BỘ — PHẦN 5: gỡ chat cũ (chat_messages) — đóng lỗ hổng "ai cũng đọc/ghi được"
-- Chạy SAU khi đã up code mới (trang chủ không còn dùng chat-widget.js).
-- Tin nhắn cũ: bạn đã chọn bỏ → xoá hẳn bảng. Ảnh cũ (kho chat-images) xoá tay ở Storage (xem hướng dẫn).
-- =====================================================================
begin;

-- 1. Bỏ bảng chat cũ khỏi realtime rồi xoá bảng (kéo theo mọi policy của nó)
do $$
begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_messages') then
    execute 'alter publication supabase_realtime drop table public.chat_messages';
  end if;
end $$;
drop table if exists public.chat_messages cascade;

-- 2. Hàm của chat cũ
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('chat_xoa_het', 'chat_xoa_tin', 'admin_xoa_chat_message')
  loop
    execute format('drop function %s', f.sig);
  end loop;
end $$;

-- 3. Bảng đăng ký thông báo cũ (ai cũng ghi được, gắn tên tuỳ ý) → xoá; chat mới dùng ht_dang_ky_push
drop table if exists public.push_subscriptions cascade;

commit;

-- Kiểm tra: phải ra 0 dòng
select tablename from pg_tables where schemaname = 'public' and tablename in ('chat_messages', 'push_subscriptions');
