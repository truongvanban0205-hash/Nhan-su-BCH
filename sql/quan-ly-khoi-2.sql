-- =====================================================================
-- QUẢN LÝ CHUNG gom về 1 chỗ: thứ tự khối, thứ tự đơn vị trong khối, tên & màu báo cáo bằng mật khẩu quản lý chung
-- Tên & màu: thêm mức "chung theo khối" (pham_vi = '__k:<mã khối>'), đè lên mức '__chung' cũ; riêng đơn vị đè lên tất cả.
-- Chỉ thay / thêm hàm. Không xoá, không sửa dữ liệu. Chạy SAU nhieu-khoi.sql.
-- =====================================================================
begin;

-- Đổi thứ tự khối (lên / xuống)
create or replace function public.admin_doi_thu_tu_khoi(p_pass text, p_id text, p_huong text)
returns void language plpgsql security definer set search_path = public as $$
declare a record; b record;
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  update khoi set thu_tu = s.rn from (select id, row_number() over (order by thu_tu, ten) as rn from khoi) s where s.id = khoi.id; -- đánh lại số liên tục
  select * into a from khoi where id = p_id;
  if p_huong = 'up' then select * into b from khoi where thu_tu < a.thu_tu order by thu_tu desc limit 1;
  else select * into b from khoi where thu_tu > a.thu_tu order by thu_tu limit 1; end if;
  if b.id is null then return; end if;
  update khoi set thu_tu = b.thu_tu where id = a.id;
  update khoi set thu_tu = a.thu_tu where id = b.id;
end $$;

-- Đổi thứ tự đơn vị TRONG cùng khối (đổi chỗ với đơn vị liền kề của khối đó)
create or replace function public.admin_doi_thu_tu_dv_khoi(p_pass text, p_id text, p_huong text)
returns void language plpgsql security definer set search_path = public as $$
declare a record; b record;
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  update don_vi set thu_tu = s.rn from (select id, row_number() over (order by thu_tu, ten) as rn from don_vi) s where s.id = don_vi.id;
  select * into a from don_vi where id = p_id;
  if p_huong = 'up' then select * into b from don_vi where coalesce(khoi_id, 'khoi_03') = coalesce(a.khoi_id, 'khoi_03') and thu_tu < a.thu_tu order by thu_tu desc limit 1;
  else select * into b from don_vi where coalesce(khoi_id, 'khoi_03') = coalesce(a.khoi_id, 'khoi_03') and thu_tu > a.thu_tu order by thu_tu limit 1; end if;
  if b.id is null then return; end if;
  update don_vi set thu_tu = b.thu_tu where id = a.id;
  update don_vi set thu_tu = a.thu_tu where id = b.id;
end $$;

-- Đọc tên & màu: chung = '__chung' (cũ) đè bởi chung theo khối của đơn vị; riêng = đơn vị
create or replace function public.bc_lay_ten_mau(p_don_vi_id text default 'khanh_hoa')
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'chung', coalesce((select cau_hinh from bc_ten_mau where pham_vi = '__chung'), '{}'::jsonb)
             || coalesce((select t.cau_hinh from bc_ten_mau t join don_vi d on t.pham_vi = '__k:' || coalesce(d.khoi_id, 'khoi_03')
                          where d.id = coalesce(p_don_vi_id, 'khanh_hoa')), '{}'::jsonb),
    'rieng', coalesce((select cau_hinh from bc_ten_mau where pham_vi = coalesce(p_don_vi_id, 'khanh_hoa')), '{}'::jsonb));
$$;

-- Admin đọc / lưu 1 mức tên & màu: p_pham_vi = mã đơn vị hoặc '__k:<mã khối>'
create or replace function public.admin_lay_ten_mau(p_pass text, p_pham_vi text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  return coalesce((select cau_hinh from bc_ten_mau where pham_vi = p_pham_vi), '{}'::jsonb);
end $$;

create or replace function public.admin_luu_ten_mau(p_pass text, p_pham_vi text, p_cau_hinh jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  if jsonb_typeof(p_cau_hinh) <> 'object' then raise exception 'CAU_HINH_KHONG_HOP_LE'; end if;
  if not (exists (select 1 from don_vi where id = p_pham_vi) or (p_pham_vi like '__k:%' and exists (select 1 from khoi where '__k:' || id = p_pham_vi))) then
    raise exception 'PHAM_VI_KHONG_HOP_LE';
  end if;
  insert into bc_ten_mau (pham_vi, cau_hinh) values (p_pham_vi, p_cau_hinh)
  on conflict (pham_vi) do update set cau_hinh = excluded.cau_hinh, cap_nhat = now();
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('admin_doi_thu_tu_khoi', 'admin_doi_thu_tu_dv_khoi', 'bc_lay_ten_mau', 'admin_lay_ten_mau', 'admin_luu_ten_mau')
  loop
    execute format('revoke execute on function %s from public', f.sig);
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;

commit;

select 'OK: quản lý khối gom 1 chỗ' as ket_qua;
