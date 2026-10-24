-- =====================================================================
-- BẢO MẬT ĐỢT 3 — chạy SAU bao-mat-dot-2.sql (dựa trên kết quả kiem-tra-bao-mat.sql)
--  1. Khoá hàm thừa: nhansu_gop_o (ghi thẳng báo cáo, KHÔNG kiểm tra gì — app không dùng)
--     và lay_danh_sach_ten_da_duyet (lộ tên toàn bộ nhân viên — chỉ chat cũ dùng).
--  2. Chống dò PIN/mật khẩu chắc hơn: trước đây lấy IP từ header X-Forwarded-For mà kẻ tấn công
--     tự đặt được → đổi IP giả liên tục là né được khoá. Nay: ưu tiên IP do Cloudflare ghi
--     (cf-connecting-ip, không giả được) + thêm khoá CHUNG theo tài khoản bất kể IP
--     (sai 20 lần / 10 phút từ mọi nơi → khoá 15 phút).
--  3. Hàm tạo báo cáo hôm nay chỉ chạy cho người thuộc đơn vị đó.
-- =====================================================================
begin;

-- 1. Khoá hàm thừa (không xoá, để có thể mở lại nếu cần)
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('nhansu_gop_o', 'lay_danh_sach_ten_da_duyet', 'handle_new_user')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

-- 2. Chống dò mật khẩu
create or replace function public.bm_ip()
returns text language plpgsql stable security definer set search_path = public as $$
declare h json; v text;
begin
  h := nullif(current_setting('request.headers', true), '')::json;
  v := nullif(trim(h ->> 'cf-connecting-ip'), '');                       -- Cloudflare tự ghi, không giả được
  if v is null then                                                       -- dự phòng: lấy IP CUỐI cùng (do máy chủ thêm), không lấy IP đầu (ai cũng tự điền được)
    v := nullif(trim(regexp_replace(coalesce(h ->> 'x-forwarded-for', ''), '^.*,', '')), '');
  end if;
  return coalesce(v, '?');
exception when others then return '?';
end $$;

-- 1 lần sai: tăng đếm cho khoá theo IP (6 lần → khoá 10 phút) VÀ khoá chung theo tài khoản (20 lần → khoá 15 phút)
create or replace function public._bm_dem(k text, p_nguong int, p_khoa interval)
returns void language plpgsql security definer set search_path = public as $$
declare r public.bm_thu_sai%rowtype;
begin
  select * into r from public.bm_thu_sai where khoa = k for update;
  if not found then
    insert into public.bm_thu_sai (khoa, so_lan, lan_dau) values (k, 1, now()) on conflict (khoa) do nothing;
  elsif r.lan_dau < now() - interval '10 minutes' then
    update public.bm_thu_sai set so_lan = 1, lan_dau = now(), khoa_den = null where khoa = k;
  elsif r.so_lan + 1 >= p_nguong then
    update public.bm_thu_sai set so_lan = 0, lan_dau = now(), khoa_den = now() + p_khoa where khoa = k;
  else
    update public.bm_thu_sai set so_lan = so_lan + 1 where khoa = k;
  end if;
end $$;

create or replace function public.bm_sai(p_loai text, p_muc_tieu text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._bm_dem(p_loai || '|' || public.bm_ip() || '|' || coalesce(p_muc_tieu, ''), 6, interval '10 minutes');
  perform public._bm_dem(p_loai || '|*|' || coalesce(p_muc_tieu, ''), 20, interval '15 minutes');
  delete from public.bm_thu_sai where lan_dau < now() - interval '1 day' and (khoa_den is null or khoa_den < now());
end $$;

create or replace function public.bm_chan(p_loai text, p_muc_tieu text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bm_thu_sai
                 where khoa in (p_loai || '|' || public.bm_ip() || '|' || coalesce(p_muc_tieu, ''),
                                p_loai || '|*|' || coalesce(p_muc_tieu, ''))
                   and khoa_den is not null and khoa_den > now());
$$;

create or replace function public.bm_dung(p_loai text, p_muc_tieu text)
returns void language sql security definer set search_path = public as $$
  delete from public.bm_thu_sai where khoa = p_loai || '|' || public.bm_ip() || '|' || coalesce(p_muc_tieu, '');
$$;

revoke execute on function public._bm_dem(text, int, interval) from public, anon, authenticated;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('bm_ip', 'bm_sai', 'bm_chan', 'bm_dung')
  loop execute format('revoke execute on function %s from public, anon, authenticated', f.sig); end loop;
end $$;

-- 3. Tạo bản báo cáo hôm nay (copy từ hôm qua): chỉ người thuộc đơn vị
do $$
declare b text; v_def text;
begin
  foreach b in array array['nhansu', 'mmtb'] loop
    select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'dam_bao_du_lieu_hom_nay_' || b;
    if v_def is not null and v_def !~ '_duoc_vao_dv' then
      -- chèn 1 dòng kiểm tra ngay sau "begin" đầu tiên của thân hàm
      v_def := regexp_replace(v_def, '(\$function\$\s*declare.*?\mbegin\M)',
               E'\\1\n  if not public._duoc_vao_dv(p_don_vi_id) then return jsonb_build_object(''status'', ''khong_co_quyen''); end if;', 's');
      execute v_def;
    end if;
  end loop;
end $$;

commit;

-- Kiểm tra: hai hàm thừa phải ra anon_goi_duoc = false
select p.proname, has_function_privilege('anon', p.oid, 'execute') as anon_goi_duoc
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('nhansu_gop_o', 'lay_danh_sach_ten_da_duyet', 'bm_ip', 'dam_bao_du_lieu_hom_nay_nhansu');
