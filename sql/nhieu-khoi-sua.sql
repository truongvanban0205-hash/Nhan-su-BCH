-- SỬA: Quản lý chung báo "Chưa cài tính năng nhiều khối" dù đã chạy nhieu-khoi.sql
-- Nguyên nhân: hàm admin_lay_danh_sach_khoi khai báo "stable" (chỉ đọc) nhưng bên trong gọi admin_dang_nhap
-- (hàm kiểm tra mật khẩu có ghi nhật ký đăng nhập) → Postgres báo lỗi → trang tưởng là chưa cài.
-- Chỉ thay lại 1 hàm, không đụng dữ liệu. Chạy trong Supabase → SQL Editor.
create or replace function public.admin_lay_danh_sach_khoi(p_pass text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  return (select coalesce(jsonb_agg(t order by t.thu_tu, t.ten), '[]'::jsonb)
          from (select k.id, k.ten, k.thu_tu, k.an, (select count(*) from don_vi d where d.khoi_id = k.id) as so_don_vi from khoi k) t);
end $$;
revoke execute on function public.admin_lay_danh_sach_khoi(text) from public;
grant execute on function public.admin_lay_danh_sach_khoi(text) to anon, authenticated;

select 'OK: đã sửa' as ket_qua, (select count(*) from public.khoi) as so_khoi;
