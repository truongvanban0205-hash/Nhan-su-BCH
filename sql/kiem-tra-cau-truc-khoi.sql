-- KIỂM TRA CẤU TRÚC để làm "Nhiều khối" + "Sao chép cấu hình khi tạo đơn vị / khối mới"
-- CHỈ ĐỌC, không sửa gì. Chạy trong Supabase → SQL Editor, rồi bấm nút tải kết quả (Export → CSV)
-- hoặc copy toàn bộ bảng kết quả gửi lại.
select 'BANG' as loai, c.table_name as ten,
       string_agg(c.column_name || ':' || c.data_type, ', ' order by c.ordinal_position) as chi_tiet
from information_schema.columns c
where c.table_schema = 'public'
  and c.table_name in (select table_name from information_schema.columns where table_schema = 'public' and column_name = 'don_vi_id'
                       union select 'don_vi' union select 'dinh_bien_gia_tri' union select 'dinh_bien_cot')
group by c.table_name
union all
select 'KHOA_NGOAI', tc.table_name, string_agg(kcu.column_name || ' -> ' || ccu.table_name || '.' || ccu.column_name, ', ')
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu on kcu.constraint_name = tc.constraint_name and kcu.table_schema = tc.table_schema
join information_schema.constraint_column_usage ccu on ccu.constraint_name = tc.constraint_name and ccu.table_schema = tc.table_schema
where tc.table_schema = 'public' and tc.constraint_type = 'FOREIGN KEY'
group by tc.table_name
union all
select 'HAM', p.proname, left(pg_get_functiondef(p.oid), 1500)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('lay_danh_sach_don_vi', 'admin_them_don_vi', 'admin_lay_danh_sach_don_vi')
order by 1, 2;
