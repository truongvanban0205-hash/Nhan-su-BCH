-- =====================================================================
-- BẢNG THEO DÕI BỘ PHẬN (báo cáo Nhân sự)
-- Chạy 1 lần trong Supabase → SQL Editor. Cần đã chạy giai-doan-1.sql trước
-- (dùng hàm _nv_xac_thuc). Toàn bộ nằm trong 1 transaction.
--
-- KHÔNG đụng dữ liệu báo cáo: trạng thái bộ phận lưu ở bảng RIÊNG
-- nhansu_bo_phan, không nằm trong nhansu.data → lưu báo cáo không thể xoá mất.
-- Chỉ thêm 1 cột bo_phan_id (để trống) vào dinh_bien_chuc_danh và employee_don_vi.
-- =====================================================================
begin;

-- 1. Danh sách bộ phận — riêng từng đơn vị
create table if not exists public.bo_phan (
  id        bigserial primary key,
  don_vi_id text not null,
  ten       text not null,
  thu_tu    int  not null default 0,
  tao_luc   timestamptz not null default now(),
  unique (don_vi_id, ten)
);
alter table public.bo_phan enable row level security;
revoke all on public.bo_phan from anon, authenticated;

-- 2. Gán bộ phận: chức danh (Định biên) và tài khoản (theo đơn vị). Để trống = chưa gán.
alter table public.dinh_bien_chuc_danh add column if not exists bo_phan_id bigint references public.bo_phan(id) on delete set null;
alter table public.employee_don_vi     add column if not exists bo_phan_id bigint references public.bo_phan(id) on delete set null;

-- 3. Trạng thái bộ phận theo ngày
create table if not exists public.nhansu_bo_phan (
  don_vi_id  text   not null,
  ngay       text   not null,             -- 'YYYY-MM-DD', giống nhansu.ngay
  bo_phan_id bigint not null references public.bo_phan(id) on delete cascade,
  dn         boolean not null default false, -- người của bộ phận đã vào báo cáo
  sua        boolean not null default false, -- người của bộ phận đã sửa / bấm "Không đổi"
  thay       boolean not null default false, -- người KHÁC bộ phận đã sửa cột của bộ phận
  thay_boi   text,
  cap_nhat   timestamptz not null default now(),
  primary key (don_vi_id, ngay, bo_phan_id)
);
alter table public.nhansu_bo_phan enable row level security;
revoke all on public.nhansu_bo_phan from anon, authenticated;

-- 4. 10 bộ phận mặc định cho mọi đơn vị đang có (chạy lại không tạo trùng)
insert into public.bo_phan (don_vi_id, ten, thu_tu)
select d.id, x.ten, x.tt
from public.don_vi d
cross join (values ('Nội nghiệp',1),('Hành chính',2),('QS',3),('QC/QA',4),('Shop',5),
                   ('Kho',6),('Hiện trường',7),('Trắc đạc',8),('ATLĐ',9),('MMTB',10)) as x(ten, tt)
on conflict (don_vi_id, ten) do nothing;

-- ---------------------------------------------------------------------
-- 5. Đọc danh sách bộ phận (kèm số chức danh / tài khoản đang gán)
-- ---------------------------------------------------------------------
create or replace function public.bo_phan_lay_danh_sach(p_don_vi_id text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'ten', b.ten, 'thu_tu', b.thu_tu,
           'so_chuc_danh', (select count(*) from public.dinh_bien_chuc_danh c where c.bo_phan_id = b.id),
           'so_tai_khoan', (select count(*) from public.employee_don_vi m where m.bo_phan_id = b.id))
         order by b.thu_tu, b.id), '[]'::jsonb)
  from public.bo_phan b where b.don_vi_id = p_don_vi_id;
$$;

-- ---------------------------------------------------------------------
-- 6. Quản lý bộ phận — mật khẩu vận hành của đơn vị (giống Định biên)
-- ---------------------------------------------------------------------
create or replace function public.bo_phan_them(p_pass text, p_don_vi_id text, p_ten text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  perform public.dbmmtb_kiem_mat_khau(p_pass, p_don_vi_id);
  if trim(coalesce(p_ten, '')) = '' then raise exception 'TEN_RONG'; end if;
  insert into public.bo_phan (don_vi_id, ten, thu_tu)
  values (p_don_vi_id, trim(p_ten), (select coalesce(max(thu_tu), 0) + 1 from public.bo_phan where don_vi_id = p_don_vi_id))
  returning id into v_id;
  return v_id;
exception when unique_violation then raise exception 'TEN_DA_TON_TAI';
end $$;

create or replace function public.bo_phan_doi_ten(p_pass text, p_id bigint, p_ten text)
returns void language plpgsql security definer set search_path = public as $$
declare v_dv text;
begin
  select don_vi_id into v_dv from public.bo_phan where id = p_id;
  perform public.dbmmtb_kiem_mat_khau(p_pass, v_dv);
  if trim(coalesce(p_ten, '')) = '' then raise exception 'TEN_RONG'; end if;
  update public.bo_phan set ten = trim(p_ten) where id = p_id;
exception when unique_violation then raise exception 'TEN_DA_TON_TAI';
end $$;

-- Xoá: chức danh / tài khoản đang gán bộ phận này tự về "chưa gán"
create or replace function public.bo_phan_xoa(p_pass text, p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_dv text;
begin
  select don_vi_id into v_dv from public.bo_phan where id = p_id;
  perform public.dbmmtb_kiem_mat_khau(p_pass, v_dv);
  delete from public.bo_phan where id = p_id;
end $$;

create or replace function public.bo_phan_doi_thu_tu(p_pass text, p_id1 bigint, p_id2 bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_dv1 text; v_dv2 text; v_t1 int; v_t2 int;
begin
  select don_vi_id, thu_tu into v_dv1, v_t1 from public.bo_phan where id = p_id1;
  select don_vi_id, thu_tu into v_dv2, v_t2 from public.bo_phan where id = p_id2;
  if v_dv1 is distinct from v_dv2 then raise exception 'KHAC_DON_VI'; end if;
  perform public.dbmmtb_kiem_mat_khau(p_pass, v_dv1);
  update public.bo_phan set thu_tu = v_t2 where id = p_id1;
  update public.bo_phan set thu_tu = v_t1 where id = p_id2;
end $$;

-- Gán bộ phận cho chức danh Định biên (p_bo_phan_id = null → bỏ gán)
create or replace function public.dinhbien_gan_bo_phan(p_pass text, p_chuc_danh_id bigint, p_bo_phan_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_dv text;
begin
  select don_vi_id into v_dv from public.dinh_bien_chuc_danh where id = p_chuc_danh_id;
  if v_dv is null then raise exception 'KHONG_TIM_THAY'; end if;
  perform public.dbmmtb_kiem_mat_khau(p_pass, v_dv);
  if p_bo_phan_id is not null and not exists (select 1 from public.bo_phan where id = p_bo_phan_id and don_vi_id = v_dv) then
    raise exception 'BO_PHAN_KHAC_DON_VI';
  end if;
  update public.dinh_bien_chuc_danh set bo_phan_id = p_bo_phan_id where id = p_chuc_danh_id;
end $$;

-- ---------------------------------------------------------------------
-- 7. Gán bộ phận cho tài khoản — mật khẩu quản trị (trang Quản lý tài khoản)
-- ---------------------------------------------------------------------
create or replace function public.admin_lay_bo_phan_tai_khoan(p_pass text, p_don_vi_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  return (select coalesce(jsonb_object_agg(m.employee_id::text, m.bo_phan_id), '{}'::jsonb)
          from public.employee_don_vi m where m.don_vi_id = p_don_vi_id and m.bo_phan_id is not null);
end $$;

create or replace function public.admin_gan_bo_phan(p_pass text, p_employee_id bigint, p_don_vi_id text, p_bo_phan_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  if p_bo_phan_id is not null and not exists (select 1 from public.bo_phan where id = p_bo_phan_id and don_vi_id = p_don_vi_id) then
    raise exception 'BO_PHAN_KHAC_DON_VI';
  end if;
  update public.employee_don_vi set bo_phan_id = p_bo_phan_id
   where employee_id = p_employee_id and don_vi_id = p_don_vi_id;
  if not found then raise exception 'KHONG_THUOC_DON_VI'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 8. Ghi trạng thái trong ngày — server tự xác định người này thuộc bộ phận nào
--    p_loai: 'login' | 'edit' (kèm p_cot = ["cd_12","cd_15"]) | 'khong_doi'
-- ---------------------------------------------------------------------
create or replace function public.nhansu_ghi_bo_phan(
  p_ten text, p_pin text, p_ngay text, p_don_vi_id text, p_loai text, p_cot jsonb default '[]'::jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare d jsonb; v_emp bigint; v_bp bigint; v_ten text; c text; v_x bigint;
begin
  d := public._nv_xac_thuc(p_ten, p_pin, p_don_vi_id);
  v_ten := d ->> 'ten';
  select id into v_emp from public.employees where lower(trim(ten)) = lower(trim(v_ten)) order by id limit 1;
  select bo_phan_id into v_bp from public.employee_don_vi where employee_id = v_emp and don_vi_id = p_don_vi_id;

  if p_loai in ('login', 'khong_doi') then
    if v_bp is null then return false; end if;
    insert into public.nhansu_bo_phan as t (don_vi_id, ngay, bo_phan_id, dn, sua)
    values (p_don_vi_id, p_ngay, v_bp, true, p_loai = 'khong_doi')
    on conflict (don_vi_id, ngay, bo_phan_id) do update
      set dn = true, sua = t.sua or excluded.sua, cap_nhat = now();
    return true;
  end if;

  if p_loai = 'edit' then
    for c in select jsonb_array_elements_text(coalesce(p_cot, '[]'::jsonb)) loop
      if c !~ '^cd_[0-9]+$' then continue; end if;
      select bo_phan_id into v_x from public.dinh_bien_chuc_danh
       where id = substring(c from 4)::bigint and don_vi_id = p_don_vi_id;
      if v_x is null then continue; end if;          -- chức danh chưa gán bộ phận → không tính
      if v_x = v_bp then
        insert into public.nhansu_bo_phan as t (don_vi_id, ngay, bo_phan_id, dn, sua)
        values (p_don_vi_id, p_ngay, v_x, true, true)
        on conflict (don_vi_id, ngay, bo_phan_id) do update set dn = true, sua = true, cap_nhat = now();
      else
        insert into public.nhansu_bo_phan as t (don_vi_id, ngay, bo_phan_id, thay, thay_boi)
        values (p_don_vi_id, p_ngay, v_x, true, v_ten)
        on conflict (don_vi_id, ngay, bo_phan_id) do update set thay = true, thay_boi = excluded.thay_boi, cap_nhat = now();
      end if;
    end loop;
    return true;
  end if;
  raise exception 'LOAI_KHONG_HOP_LE';
end $$;

-- 9. Đọc bảng theo dõi của 1 ngày (phải đăng nhập)
create or replace function public.nhansu_lay_bo_phan(p_ten text, p_pin text, p_ngay text, p_don_vi_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d jsonb; v_emp bigint; v_bp bigint;
begin
  d := public._nv_xac_thuc(p_ten, p_pin, p_don_vi_id);
  select id into v_emp from public.employees where lower(trim(ten)) = lower(trim(d ->> 'ten')) order by id limit 1;
  select bo_phan_id into v_bp from public.employee_don_vi where employee_id = v_emp and don_vi_id = p_don_vi_id;
  return jsonb_build_object(
    'cua_toi', v_bp,
    'bo_phan', public.bo_phan_lay_danh_sach(p_don_vi_id),
    'trang_thai', (select coalesce(jsonb_object_agg(t.bo_phan_id::text, jsonb_build_object(
                      'dn', t.dn, 'sua', t.sua, 'thay', t.thay, 'thay_boi', t.thay_boi)), '{}'::jsonb)
                   from public.nhansu_bo_phan t where t.don_vi_id = p_don_vi_id and t.ngay = p_ngay));
end $$;

-- 10. Quyền gọi hàm
do $$
declare f text;
begin
  foreach f in array array[
    'bo_phan_lay_danh_sach(text)', 'bo_phan_them(text,text,text)', 'bo_phan_doi_ten(text,bigint,text)',
    'bo_phan_xoa(text,bigint)', 'bo_phan_doi_thu_tu(text,bigint,bigint)', 'dinhbien_gan_bo_phan(text,bigint,bigint)',
    'admin_lay_bo_phan_tai_khoan(text,text)', 'admin_gan_bo_phan(text,bigint,text,bigint)',
    'nhansu_ghi_bo_phan(text,text,text,text,text,jsonb)', 'nhansu_lay_bo_phan(text,text,text,text)']
  loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

-- 11. Kiểm tra nhanh: mỗi đơn vị phải có 10 bộ phận
select don_vi_id, count(*) as so_bo_phan from public.bo_phan group by don_vi_id order by 1;

commit;
