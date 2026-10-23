-- =====================================================================
-- CHAT NỘI BỘ — PHẦN 3: gửi ảnh + ảnh đại diện + tự xoá ảnh chat sau 30 ngày
-- Chạy 1 lần trong Supabase → SQL Editor (cần đã chạy chat-1.sql). Không gửi file, chỉ ảnh.
--
-- Cách tải ảnh an toàn mà không cần máy chủ riêng:
--   1) App xin "vé" (ht_xin_ve) → server cấp 1 đường dẫn ngẫu nhiên, hạn 10 phút, gắn với người xin.
--   2) App tải ảnh lên đúng đường dẫn đó. Kho chỉ cho tải lên đường dẫn đang có vé hợp lệ.
--   3) App gửi tin / đặt ảnh đại diện kèm đường dẫn; server kiểm vé là của chính người đó.
-- Ảnh xem bằng đường dẫn ngẫu nhiên (không đoán được), giống link ảnh của Zalo.
-- =====================================================================
begin;

-- 1. Kho ảnh: tối đa 5 MB/ảnh, chỉ nhận ảnh (app tự nén trước, thường ~200 KB)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ht-anh', 'ht-anh', true, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- 2. Vé tải lên + hàng đợi xoá
create table if not exists public.ht_ve (
  path        text primary key,
  employee_id bigint not null references public.employees(id) on delete cascade,
  muc_dich    text   not null check (muc_dich in ('anh', 'av')),
  hoi_thoai_id bigint,
  het_han     timestamptz not null default now() + interval '10 minutes',
  da_dung     boolean not null default false
);
create table if not exists public.ht_xoa_tep (path text primary key, them_luc timestamptz not null default now());
create table if not exists public.ht_cai_dat (khoa text primary key, gia_tri text);
alter table public.ht_nguoi add column if not exists anh text;   -- đường dẫn ảnh đại diện

do $$
declare t text;
begin
  foreach t in array array['ht_ve','ht_xoa_tep','ht_cai_dat'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- 3. Hàm cho quy tắc của kho (chỉ trả đúng/sai, không lộ dữ liệu)
create or replace function public._ht_ve_ok(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ht_ve where path = p_path and not da_dung and het_han > now());
$$;
create or replace function public._ht_xoa_ok(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ht_xoa_tep where path = p_path);
$$;
revoke execute on function public._ht_ve_ok(text) from public;
revoke execute on function public._ht_xoa_ok(text) from public;
grant execute on function public._ht_ve_ok(text) to anon, authenticated;
grant execute on function public._ht_xoa_ok(text) to anon, authenticated;

drop policy if exists "ht_anh_tai_len" on storage.objects;
create policy "ht_anh_tai_len" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'ht-anh' and public._ht_ve_ok(name));
drop policy if exists "ht_anh_xoa_doc" on storage.objects;
create policy "ht_anh_xoa_doc" on storage.objects for select to anon, authenticated
  using (bucket_id = 'ht-anh' and public._ht_xoa_ok(name));
drop policy if exists "ht_anh_xoa" on storage.objects;
create policy "ht_anh_xoa" on storage.objects for delete to anon, authenticated
  using (bucket_id = 'ht-anh' and public._ht_xoa_ok(name));

-- 4. Xin vé tải ảnh. p_muc_dich: 'anh' (gửi trong hội thoại p_ht) | 'av' (ảnh đại diện)
create or replace function public.ht_xin_ve(p_token text, p_muc_dich text, p_ht bigint default null, p_duoi text default 'jpg')
returns text language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_path text;
begin
  if p_muc_dich = 'anh' then
    if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  elsif p_muc_dich <> 'av' then raise exception 'MUC_DICH_KHONG_HOP_LE'; end if;
  if (select count(*) from public.ht_ve where employee_id = v_me and het_han > now() - interval '1 hour') > 200 then
    raise exception 'GUI_QUA_NHIEU';
  end if;
  v_path := case when p_muc_dich = 'av' then 'av/' || v_me else 'ht/' || p_ht end
            || '/' || replace(gen_random_uuid()::text, '-', '')
            || '.' || case when p_duoi in ('png', 'webp', 'gif') then p_duoi else 'jpg' end;
  insert into public.ht_ve (path, employee_id, muc_dich, hoi_thoai_id) values (v_path, v_me, p_muc_dich, p_ht);
  delete from public.ht_ve where het_han < now() - interval '1 day';
  return v_path;
end $$;

-- 5. Gửi tin: chỉ chữ hoặc ảnh. Ảnh phải là vé của chính người gửi, đúng hội thoại, đã tải lên.
create or replace function public.ht_gui(p_token text, p_ht bigint, p_noi_dung text,
  p_loai text default 'chu', p_tep jsonb default null, p_tra_loi bigint default null, p_nhac bigint[] default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_id bigint; v_path text;
begin
  if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  if p_loai not in ('chu', 'anh') then raise exception 'LOAI_KHONG_HOP_LE'; end if;
  if p_loai = 'chu' then
    if trim(coalesce(p_noi_dung, '')) = '' then raise exception 'NOI_DUNG_RONG'; end if;
    p_tep := null;
  else
    v_path := p_tep ->> 'path';
    if not exists (select 1 from public.ht_ve where path = v_path and employee_id = v_me and muc_dich = 'anh'
                     and hoi_thoai_id = p_ht and not da_dung and het_han > now() - interval '50 minutes') then
      raise exception 'ANH_KHONG_HOP_LE';
    end if;
    if not exists (select 1 from storage.objects where bucket_id = 'ht-anh' and name = v_path) then raise exception 'ANH_CHUA_TAI_LEN'; end if;
    update public.ht_ve set da_dung = true where path = v_path;
    p_tep := jsonb_build_object('path', v_path,
               'rong', least(greatest(coalesce((p_tep ->> 'rong')::int, 0), 0), 10000),
               'cao',  least(greatest(coalesce((p_tep ->> 'cao')::int, 0), 0), 10000));
  end if;
  if length(coalesce(p_noi_dung, '')) > 4000 then raise exception 'TIN_QUA_DAI'; end if;
  if p_tra_loi is not null and not exists (select 1 from public.ht_tin_nhan where id = p_tra_loi and hoi_thoai_id = p_ht) then
    p_tra_loi := null;
  end if;
  insert into public.ht_tin_nhan (hoi_thoai_id, nguoi_gui, loai, noi_dung, tep, tra_loi_id, nhac)
  values (p_ht, v_me, p_loai, nullif(p_noi_dung, ''), p_tep, p_tra_loi,
          coalesce((select array_agg(x) from unnest(coalesce(p_nhac, '{}')) x where public._ht_la_tv(p_ht, x)), '{}'))
  returning id into v_id;
  update public.ht_hoi_thoai set tin_cuoi_id = v_id, tin_cuoi_luc = now() where id = p_ht;
  update public.ht_thanh_vien set doc_den = v_id where hoi_thoai_id = p_ht and employee_id = v_me;
  update public.ht_thanh_vien set an = false where hoi_thoai_id = p_ht and an;
  update public.ht_nguoi set online_luc = now() where employee_id = v_me;
  perform public._ht_bao_tv(p_ht, 'tin', jsonb_build_object('ht', p_ht, 'tin', v_id, 'tu', v_me));
  return jsonb_build_object('id', v_id);
end $$;

-- 6. Đổi ảnh đại diện (ảnh cũ đưa vào hàng đợi xoá)
create or replace function public.ht_doi_anh_dai_dien(p_token text, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_cu text;
begin
  if p_path is not null then
    if not exists (select 1 from public.ht_ve where path = p_path and employee_id = v_me and muc_dich = 'av'
                     and not da_dung and het_han > now() - interval '50 minutes') then raise exception 'ANH_KHONG_HOP_LE'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'ht-anh' and name = p_path) then raise exception 'ANH_CHUA_TAI_LEN'; end if;
    update public.ht_ve set da_dung = true where path = p_path;
  end if;
  perform public._ht_kenh(v_me);
  select anh into v_cu from public.ht_nguoi where employee_id = v_me;
  update public.ht_nguoi set anh = p_path where employee_id = v_me;
  if v_cu is not null then insert into public.ht_xoa_tep (path) values (v_cu) on conflict do nothing; end if;
end $$;

-- 7. Ảnh đại diện của nhiều người một lượt: {id: path}
create or replace function public.ht_anh_dai_dien(p_token text, p_ids bigint[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  return (select coalesce(jsonb_object_agg(employee_id::text, anh), '{}'::jsonb)
          from public.ht_nguoi where anh is not null and employee_id = any(coalesce(p_ids, '{}') || v_me));
end $$;

-- 8. Dọn ảnh: ảnh chat quá 30 ngày → đánh dấu hết hạn + đưa vào hàng đợi.
--    App (bất kỳ ai đang mở chat, tối đa 1 lần/giờ) nhận danh sách rồi xoá khỏi kho.
create or replace function public.ht_don_tep(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_lan timestamptz;
begin
  select gia_tri::timestamptz into v_lan from public.ht_cai_dat where khoa = 'don_tep_luc';
  if v_lan is not null and v_lan > now() - interval '1 hour' then return '[]'::jsonb; end if;
  insert into public.ht_cai_dat (khoa, gia_tri) values ('don_tep_luc', now()::text)
  on conflict (khoa) do update set gia_tri = excluded.gia_tri;
  with het as (
    update public.ht_tin_nhan set tep_het_han = true
     where loai = 'anh' and not tep_het_han and tao_luc < now() - interval '30 days'
    returning tep ->> 'path' as path)
  insert into public.ht_xoa_tep (path) select path from het where path is not null on conflict do nothing;
  -- ảnh tải lên nhưng không gửi (vé hết hạn, chưa dùng)
  insert into public.ht_xoa_tep (path)
  select v.path from public.ht_ve v
   where not v.da_dung and v.het_han < now() - interval '1 hour'
     and exists (select 1 from storage.objects o where o.bucket_id = 'ht-anh' and o.name = v.path)
  on conflict do nothing;
  return (select coalesce(jsonb_agg(path), '[]'::jsonb) from (select path from public.ht_xoa_tep order by them_luc limit 200) x);
end $$;

-- Sau khi xoá khỏi kho: bỏ khỏi hàng đợi những ảnh thật sự đã mất
create or replace function public.ht_don_tep_xong(p_token text, p_paths text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  delete from public.ht_xoa_tep x where x.path = any(coalesce(p_paths, '{}'))
     and not exists (select 1 from storage.objects o where o.bucket_id = 'ht-anh' and o.name = x.path);
end $$;

-- 9. Quyền gọi hàm mới
do $$
declare f text;
begin
  foreach f in array array['ht_xin_ve(text,text,bigint,text)', 'ht_gui(text,bigint,text,text,jsonb,bigint,bigint[])',
    'ht_doi_anh_dai_dien(text,text)', 'ht_anh_dai_dien(text,bigint[])', 'ht_don_tep(text)', 'ht_don_tep_xong(text,text[])']
  loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

commit;
