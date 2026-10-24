-- =====================================================================
-- KIỂM TRA BẢO MẬT — CHỈ ĐỌC, không sửa gì. Chạy trong SQL Editor (chọn "No limit"), gửi lại bảng kết quả.
-- Mỗi dòng: muc (hạng mục) · chi_tiet · danh_gia (OK / NGUY_HIEM / CAN_XEM)
-- =====================================================================
select * from (
  -- 1. Bảng mà NGƯỜI NGOÀI (anon) có quyền ghi / đọc trực tiếp
  select 1 as nhom, 'Quyền anon trên bảng' as muc,
         table_name || ': ' || string_agg(privilege_type, ', ' order by privilege_type) as chi_tiet,
         case when bool_or(privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE')) then 'NGUY_HIEM' else 'CAN_XEM' end as danh_gia
  from information_schema.role_table_grants
  where grantee = 'anon' and table_schema = 'public' and privilege_type <> 'REFERENCES' and privilege_type <> 'TRIGGER'
  group by table_name
  union all
  -- 2. Policy mở toang (điều kiện = true)
  select 2, 'Policy mở cho mọi người', tablename || ' · ' || policyname || ' (' || cmd || ')',
         case when cmd in ('INSERT','UPDATE','DELETE','ALL') then 'NGUY_HIEM' else 'CAN_XEM' end
  from pg_policies
  where schemaname = 'public' and (coalesce(qual, '') = 'true' or coalesce(with_check, '') = 'true')
  union all
  -- 3. Bảng KHÔNG bật RLS
  select 3, 'Bảng chưa bật RLS', c.relname, 'NGUY_HIEM'
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
  union all
  -- 4. Bảng đang phát realtime (ai nghe được thì thấy dữ liệu nếu RLS cho phép)
  select 4, 'Bảng phát realtime', tablename, 'CAN_XEM'
  from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'
  union all
  -- 5. Hàm SECURITY DEFINER anon gọi được mà KHÔNG có tham số xác thực (p_token / p_pass / p_pin)
  select 5, 'Hàm gọi tự do (không cần đăng nhập)',
         p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         case when p.proname ~ '(xoa|luu|sua|them|dat|doi|gan|dang|cap_nhat|import)' then 'NGUY_HIEM' else 'CAN_XEM' end
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef and has_function_privilege('anon', p.oid, 'execute')
    and pg_get_function_identity_arguments(p.oid) !~ '(p_token|p_pass|p_pin)'
  union all
  -- 6. Hàm SECURITY DEFINER thiếu search_path cố định
  select 6, 'Hàm thiếu search_path', p.proname, 'CAN_XEM'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef and p.proconfig is null
  union all
  -- 7. Kho file công khai
  select 7, 'Kho Storage', id || ' · công khai=' || public::text || ' · giới hạn=' || coalesce((file_size_limit/1024/1024)::text || 'MB', 'không'), case when public then 'CAN_XEM' else 'OK' end
  from storage.buckets
  union all
  -- 8. PIN yếu
  select 8, 'PIN mặc định 0000 / ngắn hơn 6 số',
         count(*) filter (where trim(pin) = '0000') || ' người PIN 0000 · ' || count(*) filter (where length(trim(pin)) < 6) || ' người PIN < 6 ký tự · tổng ' || count(*),
         case when count(*) filter (where trim(pin) = '0000') > 0 then 'NGUY_HIEM' else 'CAN_XEM' end
  from public.employees where pin is not null and trim(pin) <> ''
  union all
  -- 9. Cách lấy địa chỉ IP để chống dò mật khẩu (xem có bị giả mạo được không)
  select 9, 'Hàm bm_ip (chống dò mật khẩu)', left(regexp_replace(pg_get_functiondef(p.oid), '\s+', ' ', 'g'), 400), 'CAN_XEM'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'bm_ip'
  union all
  -- 10. Phiên đăng nhập
  select 10, 'Phiên đăng nhập', (select count(*) from public.phien_dang_nhap)::text || ' phiên 1-máy · '
         || coalesce((select count(*) from public.phien_nhieu_may)::text, '0') || ' phiên nhiều-máy', 'OK'
) t
order by nhom, danh_gia desc, chi_tiet;
