-- =====================================================================
-- TÊN & MÀU BÁO CÁO: tự đổi chữ / màu chữ / màu nền các tiêu đề trong app và ảnh xuất
-- Lưu 2 mức: '__chung' (áp dụng mọi đơn vị trong khối) và riêng từng đơn vị (ghi đè mức chung).
-- Chỉ THÊM 1 bảng + 2 hàm. Không đụng dữ liệu cũ. Chạy 1 lần trong Supabase → SQL Editor.
-- =====================================================================
begin;

create table if not exists public.bc_ten_mau (
  pham_vi   text primary key,          -- '__chung' hoặc mã đơn vị (khanh_hoa, ...)
  cau_hinh  jsonb not null default '{}'::jsonb,   -- { khoa: {t: 'chữ', mau: '#...', nen: '#...'} }
  cap_nhat  timestamptz not null default now()
);
alter table public.bc_ten_mau enable row level security;
revoke all on public.bc_ten_mau from anon, authenticated; -- chỉ đọc / ghi qua 2 hàm dưới

-- Đọc: cấu hình hiển thị (không nhạy cảm) → ai mở app cũng đọc được, giống tên ca / tên dự án
create or replace function public.bc_lay_ten_mau(p_don_vi_id text default 'khanh_hoa')
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'chung', coalesce((select cau_hinh from public.bc_ten_mau where pham_vi = '__chung'), '{}'::jsonb),
    'rieng', coalesce((select cau_hinh from public.bc_ten_mau where pham_vi = coalesce(p_don_vi_id, 'khanh_hoa')), '{}'::jsonb));
$$;

-- Lưu: mật khẩu vận hành của đơn vị đang mở. p_pham_vi = 'chung' | 'rieng'
create or replace function public.bc_luu_ten_mau(p_pass text, p_don_vi_id text, p_pham_vi text, p_cau_hinh jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_khoa text := case when p_pham_vi = 'chung' then '__chung' else coalesce(p_don_vi_id, 'khanh_hoa') end;
begin
  perform public.dbmmtb_kiem_mat_khau(p_pass, coalesce(p_don_vi_id, 'khanh_hoa'));
  if jsonb_typeof(p_cau_hinh) <> 'object' then raise exception 'CAU_HINH_KHONG_HOP_LE'; end if;
  insert into public.bc_ten_mau (pham_vi, cau_hinh) values (v_khoa, p_cau_hinh)
  on conflict (pham_vi) do update set cau_hinh = excluded.cau_hinh, cap_nhat = now();
end $$;

revoke execute on function public.bc_lay_ten_mau(text) from public;
revoke execute on function public.bc_luu_ten_mau(text, text, text, jsonb) from public;
grant execute on function public.bc_lay_ten_mau(text) to anon, authenticated;
grant execute on function public.bc_luu_ten_mau(text, text, text, jsonb) to anon, authenticated;

commit;

select 'OK: đã thêm tên & màu báo cáo' as ket_qua;
