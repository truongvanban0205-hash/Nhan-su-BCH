-- =====================================================================
-- NHIỀU KHỐI + SAO CHÉP CẤU HÌNH KHI TẠO ĐƠN VỊ / KHỐI MỚI
--  1. Bảng khoi (danh sách khối). Đơn vị hiện có được gán vào "khối 03".
--  2. don_vi thêm cột khoi_id (đơn vị thuộc khối nào).
--  3. Hàm quản trị: thêm / sửa / ẩn khối, gán đơn vị vào khối, thêm đơn vị kèm khối.
--  4. Hàm sao chép cấu hình từ đơn vị A sang đơn vị B (chỉ CẤU HÌNH, không chép số liệu hằng ngày):
--     dự án, loại ca, loại máy, định biên nhân sự (bộ phận, chức danh, mốc, số), định biên MMTB,
--     cấu hình hư hỏng (mục II), tên & màu báo cáo + trạng thái MMTB.
--     Mục nào đơn vị đích ĐÃ CÓ dữ liệu thì bỏ qua (không ghi đè, không nhân đôi).
-- Không xoá / sửa dữ liệu cũ. Chạy 1 lần trong Supabase → SQL Editor (chạy SAU ten-mau-bao-cao.sql).
-- =====================================================================
begin;

-- 1. Khối
create table if not exists public.khoi (
  id      text primary key,
  ten     text not null,
  thu_tu  integer not null default 0,
  an      boolean not null default false,
  tao_luc timestamptz not null default now()
);
alter table public.khoi enable row level security;
revoke all on public.khoi from anon, authenticated; -- chỉ đọc / ghi qua hàm

insert into public.khoi (id, ten, thu_tu)
values ('khoi_03',
        coalesce((select nullif(trim(cau_hinh -> 'khoi_ten' ->> 't'), '') from public.bc_ten_mau where pham_vi = '__chung'),
                 'KHỐI SAN LẤP - XÂY DỰNG HẠ TẦNG 3'),
        3)
on conflict (id) do nothing;

-- 2. Đơn vị thuộc khối
alter table public.don_vi add column if not exists khoi_id text;
update public.don_vi set khoi_id = 'khoi_03' where khoi_id is null;

-- 3a. Danh sách đơn vị (giữ nguyên cách dùng, thêm khoi_id)
create or replace function public.lay_danh_sach_don_vi()
returns jsonb language sql security definer set search_path to 'public', 'extensions' as $$
  select coalesce(jsonb_agg(t order by t.thu_tu, t.ten), '[]'::jsonb)
  from (select id, ten, thu_tu, an, modules, khoi_id from don_vi where coalesce(an, false) = false order by thu_tu, ten) t;
$$;

create or replace function public.admin_lay_danh_sach_don_vi(p_pass text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  return (select coalesce(jsonb_agg(t order by t.thu_tu, t.ten), '[]'::jsonb)
          from (select id, ten, thu_tu, an, modules, khoi_id from don_vi order by thu_tu, ten) t);
end $$;

-- 3b. Danh sách khối (ai cũng đọc được: chỉ là tên hiển thị)
create or replace function public.lay_danh_sach_khoi()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(t order by t.thu_tu, t.ten), '[]'::jsonb)
  from (select id, ten, thu_tu from khoi where not an) t;
$$;

create or replace function public.admin_lay_danh_sach_khoi(p_pass text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  return (select coalesce(jsonb_agg(t order by t.thu_tu, t.ten), '[]'::jsonb)
          from (select k.id, k.ten, k.thu_tu, k.an, (select count(*) from don_vi d where d.khoi_id = k.id) as so_don_vi from khoi k) t);
end $$;

-- p_id null = thêm khối mới
create or replace function public.admin_luu_khoi(p_pass text, p_id text, p_ten text, p_an boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id text := p_id;
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  if trim(coalesce(p_ten, '')) = '' then raise exception 'TEN_RONG'; end if;
  if v_id is null or v_id = '' then
    v_id := 'khoi_' || extract(epoch from clock_timestamp())::bigint;
    insert into khoi (id, ten, thu_tu) values (v_id, trim(p_ten), (select coalesce(max(thu_tu), 0) + 1 from khoi));
  else
    update khoi set ten = trim(p_ten), an = coalesce(p_an, false) where id = v_id;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.admin_gan_khoi(p_pass text, p_don_vi_id text, p_khoi_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  if not exists (select 1 from khoi where id = p_khoi_id) then raise exception 'KHONG_CO_KHOI'; end if;
  update don_vi set khoi_id = p_khoi_id where id = p_don_vi_id;
end $$;

-- 3c. Thêm đơn vị (thêm tham số khối; gọi kiểu cũ 2 tham số vẫn chạy → vào khối 03)
drop function if exists public.admin_them_don_vi(text, text);
create or replace function public.admin_them_don_vi(p_pass text, p_ten text, p_khoi_id text default null)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v_id text; v_row don_vi%rowtype;
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  if trim(coalesce(p_ten, '')) = '' then raise exception 'TEN_RONG'; end if;
  v_id := 'dv_' || extract(epoch from clock_timestamp())::bigint || '_' || floor(random() * 1000)::int;
  insert into don_vi (id, ten, thu_tu, an, modules, khoi_id)
  values (v_id, trim(p_ten), (select coalesce(max(thu_tu), 0) + 1 from don_vi), false,
          '{"bao_cao_nhan_su":true,"bao_cao_mmtb":true,"dinh_bien":true}'::jsonb,
          coalesce((select id from khoi where id = p_khoi_id), 'khoi_03'))
  returning * into v_row;
  return row_to_json(v_row)::jsonb;
end $$;

-- 4. Sao chép cấu hình đơn vị p_tu → p_den. p_muc: mảng các mục cần chép
--    'du_an','loai_ca','loai_may','dinh_bien_ns','dinh_bien_mmtb','hu_hong','ten_mau'
create or replace function public.admin_sao_chep_cau_hinh(p_pass text, p_tu text, p_den text, p_muc text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  kq jsonb := '{}'::jsonb; n int; r record; v bigint;
  m_bp jsonb := '{}'; m_cd jsonb := '{}'; m_cot jsonb := '{}'; m_loai jsonb := '{}'; m_mcot jsonb := '{}';
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  if p_tu = p_den then raise exception 'TRUNG_DON_VI'; end if;
  if not exists (select 1 from don_vi where id = p_tu) or not exists (select 1 from don_vi where id = p_den) then raise exception 'KHONG_CO_DON_VI'; end if;

  -- Dự án (+ ca ẩn theo dự án + tên ca riêng)
  if 'du_an' = any(p_muc) then begin
    if exists (select 1 from cauhinh_du_an where don_vi_id = p_den) then kq := kq || jsonb_build_object('du_an', 'bỏ qua: đơn vị đích đã có dự án');
    else
      insert into cauhinh_du_an (ten, thu_tu, an, mac_dinh, an_nhansu, an_mmtb, ho_tro, don_vi_id)
      select ten, thu_tu, an, mac_dinh, an_nhansu, an_mmtb, ho_tro, p_den from cauhinh_du_an where don_vi_id = p_tu order by id;
      get diagnostics n = row_count;
      insert into ns_ca_an (don_vi_id, du_an_id, ma_ca)
      select p_den, d2.id, a.ma_ca from ns_ca_an a
        join cauhinh_du_an d1 on d1.id = a.du_an_id and d1.don_vi_id = p_tu
        join cauhinh_du_an d2 on d2.don_vi_id = p_den and d2.ten = d1.ten
       where a.don_vi_id = p_tu on conflict do nothing;
      insert into cauhinh_ten_ca_rieng (du_an, ma_ca, ten_rieng, don_vi_id)
      select du_an, ma_ca, ten_rieng, p_den from cauhinh_ten_ca_rieng where don_vi_id = p_tu;
      kq := kq || jsonb_build_object('du_an', 'đã chép ' || n || ' dự án');
    end if;
  exception when others then kq := kq || jsonb_build_object('du_an', 'lỗi: ' || sqlerrm); end; end if;

  -- Loại ca
  if 'loai_ca' = any(p_muc) then begin
    if exists (select 1 from cauhinh_loai_ca where don_vi_id = p_den) then kq := kq || jsonb_build_object('loai_ca', 'bỏ qua: đơn vị đích đã có loại ca');
    else
      insert into cauhinh_loai_ca (ma, ten_mac_dinh, thu_tu, la_nghi, an, mac_dinh, don_vi_id)
      select ma, ten_mac_dinh, thu_tu, la_nghi, an, mac_dinh, p_den from cauhinh_loai_ca where don_vi_id = p_tu order by id;
      get diagnostics n = row_count; kq := kq || jsonb_build_object('loai_ca', 'đã chép ' || n || ' loại ca');
    end if;
  exception when others then kq := kq || jsonb_build_object('loai_ca', 'lỗi: ' || sqlerrm); end; end if;

  -- Loại máy (+ tên nhóm máy)
  if 'loai_may' = any(p_muc) then begin
    if exists (select 1 from cauhinh_mmtb_may where don_vi_id = p_den) then kq := kq || jsonb_build_object('loai_may', 'bỏ qua: đơn vị đích đã có loại máy');
    else
      insert into cauhinh_mmtb_may (ma, ten, thu_tu, mac_dinh, an, nhom, don_vi_id)
      select ma, ten, thu_tu, mac_dinh, an, nhom, p_den from cauhinh_mmtb_may where don_vi_id = p_tu order by id;
      get diagnostics n = row_count;
      if not exists (select 1 from cauhinh_nhom_may where don_vi_id = p_den) then
        insert into cauhinh_nhom_may (ma, ten, thu_tu, don_vi_id) select ma, ten, thu_tu, p_den from cauhinh_nhom_may where don_vi_id = p_tu;
      end if;
      kq := kq || jsonb_build_object('loai_may', 'đã chép ' || n || ' loại máy');
    end if;
  exception when others then kq := kq || jsonb_build_object('loai_may', 'lỗi: ' || sqlerrm); end; end if;

  -- Định biên nhân sự: bộ phận → chức danh → mốc → số (đổi id theo đơn vị mới)
  if 'dinh_bien_ns' = any(p_muc) then begin
    if exists (select 1 from dinh_bien_chuc_danh where don_vi_id = p_den) then kq := kq || jsonb_build_object('dinh_bien_ns', 'bỏ qua: đơn vị đích đã có chức danh');
    else
      if not exists (select 1 from bo_phan where don_vi_id = p_den) then
        for r in select * from bo_phan where don_vi_id = p_tu order by id loop
          insert into bo_phan (don_vi_id, ten, thu_tu) values (p_den, r.ten, r.thu_tu) returning id into v;
          m_bp := m_bp || jsonb_build_object(r.id::text, v);
        end loop;
      end if;
      for r in select * from dinh_bien_chuc_danh where don_vi_id = p_tu order by id loop
        insert into dinh_bien_chuc_danh (ten, ten_tat, thu_tu, an, don_vi_id, bo_phan_id)
        values (r.ten, r.ten_tat, r.thu_tu, r.an, p_den, (m_bp ->> r.bo_phan_id::text)::bigint) returning id into v;
        m_cd := m_cd || jsonb_build_object(r.id::text, v);
      end loop;
      for r in select * from dinh_bien_cot where don_vi_id = p_tu order by id loop
        insert into dinh_bien_cot (nhan, nam, thu_tu, don_vi_id) values (r.nhan, r.nam, r.thu_tu, p_den) returning id into v;
        m_cot := m_cot || jsonb_build_object(r.id::text, v);
      end loop;
      insert into dinh_bien_gia_tri (chuc_danh_id, cot_id, so_luong, don_vi_id)
      select (m_cd ->> g.chuc_danh_id::text)::bigint, (m_cot ->> g.cot_id::text)::bigint, g.so_luong, p_den
        from dinh_bien_gia_tri g
       where g.don_vi_id = p_tu and m_cd ? g.chuc_danh_id::text and m_cot ? g.cot_id::text;
      get diagnostics n = row_count;
      kq := kq || jsonb_build_object('dinh_bien_ns', 'đã chép ' || (select count(*) from jsonb_object_keys(m_cd)) || ' chức danh, '
                                     || (select count(*) from jsonb_object_keys(m_cot)) || ' mốc, ' || n || ' ô số');
    end if;
  exception when others then kq := kq || jsonb_build_object('dinh_bien_ns', 'lỗi: ' || sqlerrm); end; end if;

  -- Định biên MMTB: loại → mốc → số (+ công tắc so sánh)
  if 'dinh_bien_mmtb' = any(p_muc) then begin
    if exists (select 1 from dinh_bien_mmtb_loai where don_vi_id = p_den) then kq := kq || jsonb_build_object('dinh_bien_mmtb', 'bỏ qua: đơn vị đích đã có định biên MMTB');
    else
      for r in select * from dinh_bien_mmtb_loai where don_vi_id = p_tu order by id loop
        insert into dinh_bien_mmtb_loai (don_vi_id, tab, ten, ten_tat, thu_tu, an, ma) values (p_den, r.tab, r.ten, r.ten_tat, r.thu_tu, r.an, r.ma) returning id into v;
        m_loai := m_loai || jsonb_build_object(r.id::text, v);
      end loop;
      for r in select * from dinh_bien_mmtb_cot where don_vi_id = p_tu order by id loop
        insert into dinh_bien_mmtb_cot (don_vi_id, tab, nam, nhan, thu_tu) values (p_den, r.tab, r.nam, r.nhan, r.thu_tu) returning id into v;
        m_mcot := m_mcot || jsonb_build_object(r.id::text, v);
      end loop;
      insert into dinh_bien_mmtb_gia_tri (don_vi_id, tab, loai_may_id, cot_id, so_luong)
      select p_den, g.tab, (m_loai ->> g.loai_may_id::text)::bigint, (m_mcot ->> g.cot_id::text)::bigint, g.so_luong
        from dinh_bien_mmtb_gia_tri g
       where g.don_vi_id = p_tu and m_loai ? g.loai_may_id::text and m_mcot ? g.cot_id::text;
      get diagnostics n = row_count;
      if not exists (select 1 from dinhbien_mmtb_cai_dat where don_vi_id = p_den) then
        insert into dinhbien_mmtb_cai_dat (don_vi_id, so_sanh, so_sanh_ns) select p_den, so_sanh, so_sanh_ns from dinhbien_mmtb_cai_dat where don_vi_id = p_tu;
      end if;
      kq := kq || jsonb_build_object('dinh_bien_mmtb', 'đã chép ' || (select count(*) from jsonb_object_keys(m_loai)) || ' loại máy, '
                                     || (select count(*) from jsonb_object_keys(m_mcot)) || ' mốc, ' || n || ' ô số');
    end if;
  exception when others then kq := kq || jsonb_build_object('dinh_bien_mmtb', 'lỗi: ' || sqlerrm); end; end if;

  -- Cấu hình hư hỏng (mục II)
  if 'hu_hong' = any(p_muc) then begin
    if exists (select 1 from mmtb_hh_cau_hinh where don_vi_id = p_den) then kq := kq || jsonb_build_object('hu_hong', 'bỏ qua: đơn vị đích đã có cấu hình');
    elsif not exists (select 1 from mmtb_hh_cau_hinh where don_vi_id = p_tu) then kq := kq || jsonb_build_object('hu_hong', 'bỏ qua: đơn vị nguồn dùng mặc định');
    else
      insert into mmtb_hh_cau_hinh (don_vi_id, cau_hinh) select p_den, cau_hinh from mmtb_hh_cau_hinh where don_vi_id = p_tu;
      kq := kq || jsonb_build_object('hu_hong', 'đã chép');
    end if;
  exception when others then kq := kq || jsonb_build_object('hu_hong', 'lỗi: ' || sqlerrm); end; end if;

  -- Tên & màu báo cáo riêng + trạng thái MMTB (không chép vị trí thời tiết)
  if 'ten_mau' = any(p_muc) then begin
    if exists (select 1 from bc_ten_mau where pham_vi = p_den) then kq := kq || jsonb_build_object('ten_mau', 'bỏ qua: đơn vị đích đã có');
    elsif not exists (select 1 from bc_ten_mau where pham_vi = p_tu) then kq := kq || jsonb_build_object('ten_mau', 'bỏ qua: đơn vị nguồn dùng mặc định');
    else
      insert into bc_ten_mau (pham_vi, cau_hinh) select p_den, cau_hinh - '__thoi_tiet' from bc_ten_mau where pham_vi = p_tu;
      kq := kq || jsonb_build_object('ten_mau', 'đã chép');
    end if;
  exception when others then kq := kq || jsonb_build_object('ten_mau', 'lỗi: ' || sqlerrm); end; end if;

  return kq;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('lay_danh_sach_don_vi', 'admin_lay_danh_sach_don_vi', 'lay_danh_sach_khoi', 'admin_lay_danh_sach_khoi',
                                                        'admin_luu_khoi', 'admin_gan_khoi', 'admin_them_don_vi', 'admin_sao_chep_cau_hinh')
  loop
    execute format('revoke execute on function %s from public', f.sig);
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;

commit;

select 'OK: đã thêm nhiều khối + sao chép cấu hình' as ket_qua, (select count(*) from public.don_vi where khoi_id = 'khoi_03') as so_don_vi_khoi_03;
