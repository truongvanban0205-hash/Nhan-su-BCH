-- =====================================================================
-- KIỂM TRA TRƯỚC KHI LÀM "BẢNG THEO DÕI BỘ PHẬN" — CHỈ ĐỌC, không sửa gì.
-- Chạy từng khối (bôi đen 1 khối → Run), chụp/copy kết quả gửi lại.
-- =====================================================================

-- [1] Các đơn vị đang có
select id, ten, an from public.don_vi order by thu_tu, ten;

-- [2] Chức danh Định biên Nhân sự từng đơn vị (để ghép chức danh → bộ phận)
select don_vi_id, id, ten, ten_tat, an
from public.dinh_bien_chuc_danh
order by don_vi_id, thu_tu, id;

-- [3] Chức vụ đang gõ trong tài khoản, theo đơn vị (để ghép tài khoản → bộ phận)
select m.don_vi_id, coalesce(nullif(trim(e.chuc_vu), ''), '(trống)') as chuc_vu, count(*) as so_nguoi
from public.employees e
join public.employee_don_vi m on m.employee_id = e.id
where m.trang_thai = 'da_duyet'
group by 1, 2
order by 1, 3 desc, 2;

-- [4] Đã có sẵn bảng/cột "bộ phận" nào chưa (tránh tạo trùng)
select table_name, column_name
from information_schema.columns
where table_schema = 'public' and (table_name ilike '%bo_phan%' or column_name ilike '%bo_phan%');

-- [5] Các hàm nhansu_* đang có trên server (tài liệu nhắc nhansu_gop_o — kiểm tra có thật không)
select p.proname, pg_get_function_identity_arguments(p.oid) as tham_so
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname ilike 'nhansu%'
order by 1;

-- [6] Một bản ghi Nhân sự gần nhất: xem dữ liệu ngày đang có những mục gì (chỉ tên mục, không lộ số)
select don_vi_id, ngay, (select array_agg(k order by k) from jsonb_object_keys(data) k) as cac_muc
from public.nhansu
order by ngay desc
limit 4;
