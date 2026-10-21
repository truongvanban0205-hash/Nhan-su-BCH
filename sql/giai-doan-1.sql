-- =====================================================================
-- GIAI ĐOẠN 1 — Vá bảo mật an toàn (không đổi cấu trúc dữ liệu báo cáo)
-- Chạy trong Supabase → SQL Editor, MỘT LẦN, SAU KHI đã sao lưu.
-- Toàn bộ nằm trong 1 transaction: lỗi ở đâu thì không có gì bị đổi.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Khoá đăng nhập bằng Họ tên + MSNV (không cần PIN, không giới hạn thử)
--    Client mới đã bỏ hẳn 2 hàm này.
-- ---------------------------------------------------------------------
revoke execute on function public.tra_cuu(text, text)          from public, anon, authenticated;
revoke execute on function public.dangky_tai_khoan(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Hàm xác thực nhân viên bằng Họ tên + PIN (dùng lại tra_cuu_pin, có chống dò)
--    Trả về data của tra_cuu_pin + 'quyen_dv' (quyền ở đơn vị p_don_vi_id).
-- ---------------------------------------------------------------------
create or replace function public._nv_xac_thuc(p_ten text, p_pin text, p_don_vi_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r jsonb; d jsonb; v_dv text := coalesce(nullif(trim(p_don_vi_id), ''), '');
begin
  r := public.tra_cuu_pin(coalesce(p_ten, ''), coalesce(p_pin, ''));
  if coalesce(r ->> 'status', '') <> 'da_duyet' then raise exception 'CHUA_DANG_NHAP'; end if;
  d := r -> 'data';
  if v_dv = '' then raise exception 'THIEU_DON_VI'; end if;
  if d ? 'don_vi_ids' then
    if not (d -> 'don_vi_ids') ? v_dv then raise exception 'KHONG_THUOC_DON_VI'; end if;
    d := d || jsonb_build_object('quyen_dv', coalesce(d -> 'quyen_theo_don_vi' -> v_dv, '{}'::jsonb));
  else
    d := d || jsonb_build_object('quyen_dv', coalesce(d -> 'quyen', '{}'::jsonb));
  end if;
  return d;
end $$;
revoke execute on function public._nv_xac_thuc(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Bản tin: đăng / xoá phải có PIN. Hàm cũ bị khoá.
-- ---------------------------------------------------------------------
create or replace function public.ban_tin_dang_v2(
  p_ten text, p_pin text, p_tieu_de text default null, p_noi_dung text default null,
  p_mau text default null, p_icon text default null, p_don_vi_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare d jsonb;
begin
  d := public._nv_xac_thuc(p_ten, p_pin, p_don_vi_id);
  if coalesce((d -> 'quyen_dv' ->> 'ban_tin'), '') <> 'true' then raise exception 'KHONG_CO_QUYEN'; end if;
  -- tên / MSNV lấy từ server, không tin tham số client
  return public.ban_tin_dang(d ->> 'ten', d ->> 'msnv', p_tieu_de, p_noi_dung, p_mau, p_icon, p_don_vi_id);
end $$;

create or replace function public.ban_tin_xoa_v2(p_id bigint, p_ten text, p_pin text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_dv text; d jsonb;
begin
  select don_vi_id into v_dv from public.ban_tin where id = p_id;
  if v_dv is null then raise exception 'KHONG_TIM_THAY'; end if;
  d := public._nv_xac_thuc(p_ten, p_pin, v_dv);
  perform public.ban_tin_xoa(p_id, d ->> 'ten'); -- giữ quy tắc cũ: chủ bài hoặc ban_tin_admin
end $$;

grant execute on function public.ban_tin_dang_v2(text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.ban_tin_xoa_v2(bigint, text, text) to anon, authenticated;
revoke execute on function public.ban_tin_dang(text, text, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.ban_tin_xoa(bigint, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Danh bạ: phải đăng nhập (PIN) và thuộc đơn vị đó mới xem được.
-- ---------------------------------------------------------------------
create or replace function public.danh_ba_lay_danh_sach_v2(p_ten text, p_pin text, p_don_vi_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._nv_xac_thuc(p_ten, p_pin, p_don_vi_id);
  return public.danh_ba_lay_danh_sach(p_don_vi_id);
end $$;
grant execute on function public.danh_ba_lay_danh_sach_v2(text, text, text) to anon, authenticated;
revoke execute on function public.danh_ba_lay_danh_sach(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Sửa lỗi: đặt "loại Nghỉ" chỉ trong đơn vị của ca đó (trước đây reset mọi đơn vị)
-- ---------------------------------------------------------------------
create or replace function public.admin_dat_loai_nghi(p_pass text, p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_dv text;
begin
  if not public.admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  select don_vi_id into v_dv from public.cauhinh_loai_ca where id = p_id;
  if v_dv is null then raise exception 'KHONG_TIM_THAY'; end if;
  update public.cauhinh_loai_ca set la_nghi = (id = p_id) where don_vi_id = v_dv;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 6. Thu hồi quyền thừa TRUNCATE / TRIGGER / REFERENCES của anon, authenticated
-- ---------------------------------------------------------------------
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('revoke truncate, trigger, references on public.%I from anon, authenticated', t.tablename);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 7. Cố định search_path cho mọi hàm SECURITY DEFINER còn thiếu
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef and p.proconfig is null
  loop
    execute format('alter function %s set search_path = public, extensions', f.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 8. Chống báo cáo trùng ngày: UNIQUE (don_vi_id, ngay)
--    Nếu đã có bản ghi trùng thì BỎ QUA bảng đó và báo NOTICE (không xoá gì).
-- ---------------------------------------------------------------------
do $$
declare b text; n int;
begin
  foreach b in array array['nhansu', 'mmtb', 'ldt'] loop
    execute format('select count(*) from (select 1 from public.%I group by don_vi_id, ngay having count(*) > 1) x', b) into n;
    if n > 0 then
      raise notice 'BANG % CO % NGAY BI TRUNG -> chua tao UNIQUE, can xu ly tay', b, n;
    else
      execute format('create unique index if not exists %I on public.%I (don_vi_id, ngay)', b || '_dv_ngay_uq', b);
    end if;
  end loop;
end $$;

commit;
