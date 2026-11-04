-- =====================================================================
-- ẨN / HIỆN CA RIÊNG CHO TỪNG DỰ ÁN (Quản lý tài khoản → Cấu hình nhân sự → bảng "Tên ca riêng theo từng dự án")
-- VD: dự án hỗ trợ chỉ cần 1 hàng số lượng → ẩn các ca còn lại của riêng dự án đó.
-- Chỉ THÊM 1 bảng + 2 hàm. Không xoá / sửa dữ liệu cũ. Ẩn chỉ là không hiện dòng, số đã nhập vẫn giữ.
-- Chạy 1 lần trong Supabase → SQL Editor.
-- =====================================================================
begin;

create table if not exists public.ns_ca_an (
  don_vi_id text   not null,
  du_an_id  bigint not null,   -- id dự án (trên app là 'duan_' || id)
  ma_ca     text   not null,   -- mã loại ca (hc, ca1, nghi...)
  primary key (don_vi_id, du_an_id, ma_ca)
);
alter table public.ns_ca_an enable row level security;
revoke all on public.ns_ca_an from anon, authenticated; -- chỉ đọc / ghi qua 2 hàm dưới

-- Đọc danh sách ca đang ẩn của đơn vị (giống cauhinh_lay_ten_ca_rieng: cấu hình hiển thị, không có dữ liệu nhạy cảm)
create or replace function public.cauhinh_lay_ca_an(p_don_vi_id text default 'khanh_hoa')
returns table(du_an_id bigint, ma_ca text) language sql stable security definer set search_path = public as $$
  select du_an_id, ma_ca from public.ns_ca_an where don_vi_id = coalesce(p_don_vi_id, 'khanh_hoa');
$$;

-- Ẩn / hiện 1 ca của 1 dự án (mật khẩu quản trị)
create or replace function public.admin_an_hien_ca_du_an(p_pass text, p_don_vi_id text, p_du_an_id bigint, p_ma_ca text, p_an boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  if p_an then
    insert into public.ns_ca_an (don_vi_id, du_an_id, ma_ca) values (coalesce(p_don_vi_id, 'khanh_hoa'), p_du_an_id, p_ma_ca)
    on conflict do nothing;
  else
    delete from public.ns_ca_an where don_vi_id = coalesce(p_don_vi_id, 'khanh_hoa') and du_an_id = p_du_an_id and ma_ca = p_ma_ca;
  end if;
end $$;

revoke execute on function public.cauhinh_lay_ca_an(text) from public;
revoke execute on function public.admin_an_hien_ca_du_an(text, text, bigint, text, boolean) from public;
grant execute on function public.cauhinh_lay_ca_an(text) to anon, authenticated;
grant execute on function public.admin_an_hien_ca_du_an(text, text, bigint, text, boolean) to anon, authenticated;

commit;

select 'OK: đã thêm ẩn / hiện ca theo dự án' as ket_qua;
