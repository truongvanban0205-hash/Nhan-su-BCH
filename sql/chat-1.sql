-- =====================================================================
-- CHAT NỘI BỘ — PHẦN 1: thẻ phiên cho mọi người + bảng + hàm chat
-- Chạy 1 lần trong Supabase → SQL Editor (cần đã chạy giai-doan-1.sql).
-- Toàn bộ trong 1 transaction. KHÔNG đụng chat cũ (chat_messages) — phần 5 mới gỡ.
--
-- Nguyên tắc bảo mật: mọi bảng ht_* bật RLS, KHÔNG có policy → người ngoài không đọc/ghi
-- trực tiếp được. Mọi thao tác qua hàm ht_* nhận p_token (thẻ phiên cấp lúc đăng nhập);
-- server tự biết người gọi là ai và chỉ trả tin của hội thoại người đó là thành viên.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. THẺ PHIÊN CHO NGƯỜI "DÙNG NHIỀU MÁY"
--    Trước đây người có quyền nhieu_may KHÔNG được cấp thẻ → không chat được.
--    Giờ: người 1 máy vẫn như cũ (phien_dang_nhap, máy sau đá máy trước);
--         người nhiều máy được cấp thẻ riêng cho từng máy (phien_nhieu_may).
-- ---------------------------------------------------------------------
create table if not exists public.phien_nhieu_may (
  token         text primary key,
  employee_id   bigint not null references public.employees(id) on delete cascade,
  thiet_bi      text,
  tao_luc       timestamptz not null default now(),
  hoat_dong_luc timestamptz not null default now()
);
alter table public.phien_nhieu_may enable row level security;
revoke all on public.phien_nhieu_may from anon, authenticated;
create index if not exists phien_dang_nhap_token_idx on public.phien_dang_nhap (token);

create or replace function public.dang_nhap_phien(p_ten text, p_pin text, p_thiet_bi text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; v_id bigint; v_tok text;
begin
  r := public.tra_cuu_pin(p_ten, p_pin);
  if coalesce(r ->> 'status', '') <> 'da_duyet' then return r; end if;
  select id into v_id from public.employees where lower(trim(ten)) = lower(trim(p_ten)) order by id limit 1;
  if v_id is null then return r; end if;
  v_tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  if public.ps_nhieu_may(v_id) then
    insert into public.phien_nhieu_may (token, employee_id, thiet_bi) values (v_tok, v_id, left(coalesce(p_thiet_bi, ''), 200));
    delete from public.phien_nhieu_may where employee_id = v_id and hoat_dong_luc < now() - interval '60 days';
  else
    insert into public.phien_dang_nhap (employee_id, token, thiet_bi)
    values (v_id, v_tok, left(coalesce(p_thiet_bi, ''), 200))
    on conflict (employee_id) do update
       set token = excluded.token, thiet_bi = excluded.thiet_bi, dang_nhap_luc = now(), hoat_dong_luc = now();
  end if;
  return jsonb_set(r, '{data,token}', to_jsonb(v_tok), true);
end $$;

-- Thẻ phiên → mã nhân viên (đã duyệt). Sai / hết hạn → lỗi CHUA_DANG_NHAP.
create or replace function public._ht_nv(p_token text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if coalesce(p_token, '') = '' then raise exception 'CHUA_DANG_NHAP'; end if;
  select employee_id into v_id from public.phien_dang_nhap where token = p_token;
  if v_id is null then
    select employee_id into v_id from public.phien_nhieu_may where token = p_token;
    if v_id is not null then
      update public.phien_nhieu_may set hoat_dong_luc = now() where token = p_token and hoat_dong_luc < now() - interval '5 minutes';
    end if;
  end if;
  if v_id is null then raise exception 'CHUA_DANG_NHAP'; end if;
  if not exists (select 1 from public.employee_don_vi where employee_id = v_id and trang_thai = 'da_duyet')
     and not exists (select 1 from public.employees where id = v_id and trang_thai = 'da_duyet') then
    raise exception 'CHUA_DUOC_DUYET';
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- 2. BẢNG
-- ---------------------------------------------------------------------
-- Mỗi người 1 kênh riêng (mã ngẫu nhiên) để nhận tín hiệu "có tin mới" + giờ online
create table if not exists public.ht_nguoi (
  employee_id bigint primary key references public.employees(id) on delete cascade,
  kenh        text not null unique default replace(gen_random_uuid()::text, '-', ''),
  online_luc  timestamptz
);

create table if not exists public.ht_hoi_thoai (
  id           bigserial primary key,
  loai         text not null check (loai in ('rieng', 'nhom')),
  ten          text,                       -- tên nhóm (1-1 để trống, hiện tên người kia)
  khoa_rieng   text unique,                -- 1-1: "idnhỏ_idlớn" → mỗi cặp chỉ 1 hội thoại
  kenh         text not null unique default replace(gen_random_uuid()::text, '-', ''), -- kênh "đang soạn tin"
  tao_boi      bigint references public.employees(id) on delete set null,
  tao_luc      timestamptz not null default now(),
  tin_cuoi_id  bigint,
  tin_cuoi_luc timestamptz,
  ghim_tin_id  bigint
);

create table if not exists public.ht_thanh_vien (
  hoi_thoai_id  bigint not null references public.ht_hoi_thoai(id) on delete cascade,
  employee_id   bigint not null references public.employees(id) on delete cascade,
  vai_tro       text   not null default 'tv' check (vai_tro in ('truong', 'tv')),
  doc_den       bigint not null default 0,  -- đã xem đến tin số mấy
  tat_tb        boolean not null default false,
  an            boolean not null default false, -- người dùng "xoá hội thoại" khỏi danh sách (có tin mới sẽ hiện lại)
  tham_gia_luc  timestamptz not null default now(),
  primary key (hoi_thoai_id, employee_id)
);
create index if not exists ht_thanh_vien_nv_idx on public.ht_thanh_vien (employee_id);

create table if not exists public.ht_tin_nhan (
  id           bigserial primary key,
  hoi_thoai_id bigint not null references public.ht_hoi_thoai(id) on delete cascade,
  nguoi_gui    bigint references public.employees(id) on delete set null,
  loai         text not null default 'chu' check (loai in ('chu', 'anh', 'tep', 'thoai', 'he_thong')),
  noi_dung     text,
  tep          jsonb,                       -- {path, ten, kich_thuoc, mime, rong, cao, giay} — phần 3
  tra_loi_id   bigint references public.ht_tin_nhan(id) on delete set null,
  nhac         bigint[] not null default '{}', -- @nhắc tên
  thu_hoi      boolean not null default false,
  tep_het_han  boolean not null default false, -- ảnh/file đã tự xoá sau 30 ngày
  tao_luc      timestamptz not null default now()
);
create index if not exists ht_tin_nhan_ht_idx on public.ht_tin_nhan (hoi_thoai_id, id desc);

create table if not exists public.ht_cam_xuc (
  tin_id      bigint not null references public.ht_tin_nhan(id) on delete cascade,
  employee_id bigint not null references public.employees(id) on delete cascade,
  cx          text   not null check (cx in ('❤️', '👍', '😆', '😮', '😢', '😡')),
  luc         timestamptz not null default now(),
  primary key (tin_id, employee_id)
);

-- Thiết bị nhận thông báo đẩy (dùng ở phần 4)
create table if not exists public.ht_dang_ky_push (
  endpoint    text primary key,
  employee_id bigint not null references public.employees(id) on delete cascade,
  p256dh      text not null,
  auth        text not null,
  thiet_bi    text,
  tao_luc     timestamptz not null default now()
);
create index if not exists ht_dang_ky_push_nv_idx on public.ht_dang_ky_push (employee_id);

do $$
declare t text;
begin
  foreach t in array array['ht_nguoi','ht_hoi_thoai','ht_thanh_vien','ht_tin_nhan','ht_cam_xuc','ht_dang_ky_push'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3. HÀM NỘI BỘ
-- ---------------------------------------------------------------------
create or replace function public._ht_kenh(p_emp bigint)
returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  insert into public.ht_nguoi (employee_id) values (p_emp) on conflict do nothing;
  select kenh into v from public.ht_nguoi where employee_id = p_emp;
  return v;
end $$;

create or replace function public._ht_la_tv(p_ht bigint, p_emp bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ht_thanh_vien where hoi_thoai_id = p_ht and employee_id = p_emp);
$$;

-- Gửi tín hiệu realtime (không kèm nội dung tin). Lỗi realtime không làm hỏng việc gửi tin.
create or replace function public._ht_bao(p_kenh text, p_su_kien text, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform realtime.send(p_data, p_su_kien, 'u:' || p_kenh, false);
exception when others then null;
end $$;

-- Báo cho mọi thành viên của hội thoại (danh sách + số chưa đọc tự cập nhật)
create or replace function public._ht_bao_tv(p_ht bigint, p_su_kien text, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare k text;
begin
  for k in select public._ht_kenh(t.employee_id) from public.ht_thanh_vien t where t.hoi_thoai_id = p_ht loop
    perform public._ht_bao(k, p_su_kien, p_data);
  end loop;
end $$;

-- Tin hệ thống trong nhóm ("A đã thêm B vào nhóm")
create or replace function public._ht_he_thong(p_ht bigint, p_nd text)
returns void language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  insert into public.ht_tin_nhan (hoi_thoai_id, loai, noi_dung) values (p_ht, 'he_thong', p_nd) returning id into v;
  update public.ht_hoi_thoai set tin_cuoi_id = v, tin_cuoi_luc = now() where id = p_ht;
  perform public._ht_bao_tv(p_ht, 'tin', jsonb_build_object('ht', p_ht, 'tin', v));
end $$;

create or replace function public._ht_ten(p_emp bigint)
returns text language sql stable security definer set search_path = public as $$
  select ten from public.employees where id = p_emp;
$$;

-- ---------------------------------------------------------------------
-- 4. HÀM CHO APP (đều nhận p_token)
-- ---------------------------------------------------------------------
-- Thông tin của tôi + kênh riêng
create or replace function public.ht_toi(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  perform public._ht_kenh(v_me);
  update public.ht_nguoi set online_luc = now() where employee_id = v_me;
  return (select jsonb_build_object('id', e.id, 'ten', e.ten, 'chuc_vu', e.chuc_vu, 'kenh', public._ht_kenh(e.id))
          from public.employees e where e.id = v_me);
end $$;

-- Báo đang online (app gọi mỗi ~60 giây khi đang mở)
create or replace function public.ht_online(p_token text)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  perform public._ht_kenh(v_me);
  update public.ht_nguoi set online_luc = now() where employee_id = v_me;
end $$;

-- Danh bạ chat: mọi người đã duyệt, mọi đơn vị
create or replace function public.ht_danh_ba(p_token text, p_tim text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_tim text := lower(trim(coalesce(p_tim, '')));
begin
  return (select coalesce(jsonb_agg(x order by x->>'ten'), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', e.id, 'ten', e.ten, 'chuc_vu', e.chuc_vu,
      'don_vi', (select string_agg(coalesce(d.ten, m2.don_vi_id), ', ') from public.employee_don_vi m2
                 left join public.don_vi d on d.id = m2.don_vi_id where m2.employee_id = e.id and m2.trang_thai = 'da_duyet'),
      'online_luc', (select online_luc from public.ht_nguoi n where n.employee_id = e.id)) as x
    from public.employees e
    where e.id <> v_me
      and exists (select 1 from public.employee_don_vi m where m.employee_id = e.id and m.trang_thai = 'da_duyet')
      and (v_tim = '' or lower(e.ten) like '%' || v_tim || '%' or lower(coalesce(e.chuc_vu, '')) like '%' || v_tim || '%')
    limit 300) q);
end $$;

-- Danh sách hội thoại của tôi
create or replace function public.ht_danh_sach(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  return (select coalesce(jsonb_agg(x order by (x->>'luc') desc nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', h.id, 'loai', h.loai, 'kenh', h.kenh,
      'ten', case when h.loai = 'rieng' then dp.ten else h.ten end,
      'doi_phuong', dp.id, 'doi_phuong_chuc_vu', dp.chuc_vu,
      'online_luc', case when h.loai = 'rieng' then (select online_luc from public.ht_nguoi n where n.employee_id = dp.id) end,
      'so_tv', (select count(*) from public.ht_thanh_vien t3 where t3.hoi_thoai_id = h.id),
      'luc', coalesce(h.tin_cuoi_luc, h.tao_luc),
      'tat_tb', tv.tat_tb,
      'chua_doc', (select count(*) from public.ht_tin_nhan m where m.hoi_thoai_id = h.id and m.id > tv.doc_den
                     and m.nguoi_gui is distinct from v_me and m.loai <> 'he_thong'),
      'tin_cuoi', (select jsonb_build_object('id', m.id, 'loai', m.loai, 'thu_hoi', m.thu_hoi,
                     'noi_dung', case when m.thu_hoi then null else left(m.noi_dung, 120) end,
                     'nguoi_gui', m.nguoi_gui, 'ten_gui', public._ht_ten(m.nguoi_gui))
                   from public.ht_tin_nhan m where m.id = h.tin_cuoi_id)) as x
    from public.ht_thanh_vien tv
    join public.ht_hoi_thoai h on h.id = tv.hoi_thoai_id
    left join lateral (select e.id, e.ten, e.chuc_vu from public.ht_thanh_vien t2 join public.employees e on e.id = t2.employee_id
                       where t2.hoi_thoai_id = h.id and t2.employee_id <> v_me limit 1) dp on h.loai = 'rieng'
    where tv.employee_id = v_me and not tv.an
      and (h.loai = 'nhom' or h.tin_cuoi_id is not null)
    limit 300) q);
end $$;

-- Mở (hoặc tạo) hội thoại 1-1 với một người
create or replace function public.ht_mo_rieng(p_token text, p_emp bigint)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_khoa text; v_id bigint;
begin
  if p_emp = v_me then raise exception 'KHONG_TU_CHAT'; end if;
  if not exists (select 1 from public.employee_don_vi where employee_id = p_emp and trang_thai = 'da_duyet') then raise exception 'NGUOI_NHAN_KHONG_HOP_LE'; end if;
  v_khoa := least(v_me, p_emp) || '_' || greatest(v_me, p_emp);
  select id into v_id from public.ht_hoi_thoai where khoa_rieng = v_khoa;
  if v_id is null then
    insert into public.ht_hoi_thoai (loai, khoa_rieng, tao_boi) values ('rieng', v_khoa, v_me)
    on conflict (khoa_rieng) do nothing returning id into v_id;
    if v_id is null then select id into v_id from public.ht_hoi_thoai where khoa_rieng = v_khoa; end if;
    insert into public.ht_thanh_vien (hoi_thoai_id, employee_id) values (v_id, v_me), (v_id, p_emp) on conflict do nothing;
  end if;
  update public.ht_thanh_vien set an = false where hoi_thoai_id = v_id and employee_id = v_me;
  return v_id;
end $$;

-- Tạo nhóm (ai đã duyệt cũng tạo được, như Zalo; người tạo là trưởng nhóm)
create or replace function public.ht_tao_nhom(p_token text, p_ten text, p_thanh_vien bigint[])
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_id bigint; e bigint;
begin
  if trim(coalesce(p_ten, '')) = '' then raise exception 'TEN_RONG'; end if;
  insert into public.ht_hoi_thoai (loai, ten, tao_boi) values ('nhom', left(trim(p_ten), 100), v_me) returning id into v_id;
  insert into public.ht_thanh_vien (hoi_thoai_id, employee_id, vai_tro) values (v_id, v_me, 'truong');
  foreach e in array coalesce(p_thanh_vien, '{}') loop
    if e <> v_me and exists (select 1 from public.employee_don_vi where employee_id = e and trang_thai = 'da_duyet') then
      insert into public.ht_thanh_vien (hoi_thoai_id, employee_id) values (v_id, e) on conflict do nothing;
    end if;
  end loop;
  perform public._ht_he_thong(v_id, public._ht_ten(v_me) || ' đã tạo nhóm');
  return v_id;
end $$;

-- Thêm người vào nhóm (thành viên nào cũng thêm được, như Zalo)
create or replace function public.ht_them_tv(p_token text, p_ht bigint, p_thanh_vien bigint[])
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); e bigint; v_ds text := '';
begin
  if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  if (select loai from public.ht_hoi_thoai where id = p_ht) <> 'nhom' then raise exception 'KHONG_PHAI_NHOM'; end if;
  foreach e in array coalesce(p_thanh_vien, '{}') loop
    if exists (select 1 from public.employee_don_vi where employee_id = e and trang_thai = 'da_duyet')
       and not public._ht_la_tv(p_ht, e) then
      insert into public.ht_thanh_vien (hoi_thoai_id, employee_id) values (p_ht, e);
      v_ds := v_ds || case when v_ds = '' then '' else ', ' end || public._ht_ten(e);
    end if;
  end loop;
  if v_ds <> '' then perform public._ht_he_thong(p_ht, public._ht_ten(v_me) || ' đã thêm ' || v_ds || ' vào nhóm'); end if;
end $$;

-- Rời nhóm (chính mình) hoặc mời ra (trưởng nhóm). Trưởng rời → chuyển trưởng cho người vào sớm nhất.
create or replace function public.ht_xoa_tv(p_token text, p_ht bigint, p_emp bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_truong boolean;
begin
  if (select loai from public.ht_hoi_thoai where id = p_ht) <> 'nhom' then raise exception 'KHONG_PHAI_NHOM'; end if;
  select vai_tro = 'truong' into v_truong from public.ht_thanh_vien where hoi_thoai_id = p_ht and employee_id = v_me;
  if v_truong is null then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  if p_emp <> v_me and not v_truong then raise exception 'CHI_TRUONG_NHOM'; end if;
  delete from public.ht_thanh_vien where hoi_thoai_id = p_ht and employee_id = p_emp;
  if not found then return; end if;
  if not exists (select 1 from public.ht_thanh_vien where hoi_thoai_id = p_ht and vai_tro = 'truong') then
    update public.ht_thanh_vien set vai_tro = 'truong'
     where (hoi_thoai_id, employee_id) = (select hoi_thoai_id, employee_id from public.ht_thanh_vien
                                          where hoi_thoai_id = p_ht order by tham_gia_luc limit 1);
  end if;
  perform public._ht_he_thong(p_ht, case when p_emp = v_me then public._ht_ten(v_me) || ' đã rời nhóm'
                                         else public._ht_ten(v_me) || ' đã mời ' || public._ht_ten(p_emp) || ' ra khỏi nhóm' end);
  perform public._ht_bao(public._ht_kenh(p_emp), 'tin', jsonb_build_object('ht', p_ht));
end $$;

create or replace function public.ht_doi_ten_nhom(p_token text, p_ht bigint, p_ten text)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  if trim(coalesce(p_ten, '')) = '' then raise exception 'TEN_RONG'; end if;
  update public.ht_hoi_thoai set ten = left(trim(p_ten), 100) where id = p_ht and loai = 'nhom';
  perform public._ht_he_thong(p_ht, public._ht_ten(v_me) || ' đã đổi tên nhóm thành "' || left(trim(p_ten), 100) || '"');
end $$;

-- Thông tin hội thoại: thành viên (kèm đã xem đến đâu, online), tin ghim, kênh
create or replace function public.ht_thong_tin(p_token text, p_ht bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  return (select jsonb_build_object(
    'id', h.id, 'loai', h.loai, 'ten', h.ten, 'kenh', h.kenh,
    'ghim', (select jsonb_build_object('id', m.id, 'noi_dung', case when m.thu_hoi then null else left(m.noi_dung, 200) end,
                                       'loai', m.loai, 'ten_gui', public._ht_ten(m.nguoi_gui))
             from public.ht_tin_nhan m where m.id = h.ghim_tin_id),
    'thanh_vien', (select jsonb_agg(jsonb_build_object('id', e.id, 'ten', e.ten, 'chuc_vu', e.chuc_vu, 'vai_tro', t.vai_tro,
                       'doc_den', t.doc_den, 'tat_tb', t.tat_tb,
                       'online_luc', (select online_luc from public.ht_nguoi n where n.employee_id = e.id))
                     order by t.vai_tro desc, e.ten)
                   from public.ht_thanh_vien t join public.employees e on e.id = t.employee_id where t.hoi_thoai_id = h.id))
    from public.ht_hoi_thoai h where h.id = p_ht);
end $$;

-- Lấy tin (mới nhất trước; p_truoc_id để cuộn lên xem tin cũ)
create or replace function public.ht_lay_tin(p_token text, p_ht bigint, p_truoc_id bigint default null, p_so int default 40)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  return (select coalesce(jsonb_agg(x order by (x->>'id')::bigint), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', m.id, 'loai', m.loai, 'nguoi_gui', m.nguoi_gui, 'ten_gui', public._ht_ten(m.nguoi_gui),
      'noi_dung', case when m.thu_hoi then null else m.noi_dung end,
      'tep', case when m.thu_hoi or m.tep_het_han then null else m.tep end,
      'tep_het_han', m.tep_het_han, 'thu_hoi', m.thu_hoi, 'nhac', to_jsonb(m.nhac), 'tao_luc', m.tao_luc,
      'tra_loi', (select jsonb_build_object('id', r.id, 'ten_gui', public._ht_ten(r.nguoi_gui), 'loai', r.loai,
                    'noi_dung', case when r.thu_hoi then null else left(r.noi_dung, 120) end)
                  from public.ht_tin_nhan r where r.id = m.tra_loi_id),
      'cam_xuc', (select jsonb_agg(jsonb_build_object('e', c.employee_id, 'cx', c.cx, 'ten', public._ht_ten(c.employee_id)))
                  from public.ht_cam_xuc c where c.tin_id = m.id)) as x
    from public.ht_tin_nhan m
    where m.hoi_thoai_id = p_ht and (p_truoc_id is null or m.id < p_truoc_id)
    order by m.id desc
    limit least(greatest(coalesce(p_so, 40), 1), 100)) q);
end $$;

-- Gửi tin (phần 1: chữ; ảnh/file/thoại dùng p_tep ở phần 3)
create or replace function public.ht_gui(p_token text, p_ht bigint, p_noi_dung text,
  p_loai text default 'chu', p_tep jsonb default null, p_tra_loi bigint default null, p_nhac bigint[] default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_id bigint;
begin
  if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  if p_loai not in ('chu', 'anh', 'tep', 'thoai') then raise exception 'LOAI_KHONG_HOP_LE'; end if;
  if p_loai = 'chu' and trim(coalesce(p_noi_dung, '')) = '' then raise exception 'NOI_DUNG_RONG'; end if;
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

-- Thu hồi tin của mình (trong 24 giờ)
create or replace function public.ht_thu_hoi(p_token text, p_tin bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_ht bigint;
begin
  update public.ht_tin_nhan set thu_hoi = true
   where id = p_tin and nguoi_gui = v_me and not thu_hoi and tao_luc > now() - interval '24 hours'
  returning hoi_thoai_id into v_ht;
  if v_ht is null then raise exception 'KHONG_THU_HOI_DUOC'; end if;
  perform public._ht_bao_tv(v_ht, 'sua', jsonb_build_object('ht', v_ht, 'tin', p_tin));
end $$;

-- Thả / đổi / bỏ cảm xúc (bấm lại cùng biểu tượng = bỏ)
create or replace function public.ht_cam_xuc(p_token text, p_tin bigint, p_cx text)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_ht bigint; v_cu text;
begin
  select hoi_thoai_id into v_ht from public.ht_tin_nhan where id = p_tin and not thu_hoi;
  if v_ht is null or not public._ht_la_tv(v_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  select cx into v_cu from public.ht_cam_xuc where tin_id = p_tin and employee_id = v_me;
  if v_cu = p_cx then
    delete from public.ht_cam_xuc where tin_id = p_tin and employee_id = v_me;
  else
    insert into public.ht_cam_xuc (tin_id, employee_id, cx) values (p_tin, v_me, p_cx)
    on conflict (tin_id, employee_id) do update set cx = excluded.cx, luc = now();
  end if;
  perform public._ht_bao_tv(v_ht, 'sua', jsonb_build_object('ht', v_ht, 'tin', p_tin));
end $$;

-- Đã xem đến tin số p_tin
create or replace function public.ht_da_xem(p_token text, p_ht bigint, p_tin bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  update public.ht_thanh_vien set doc_den = greatest(doc_den, coalesce(p_tin, 0))
   where hoi_thoai_id = p_ht and employee_id = v_me and doc_den < coalesce(p_tin, 0);
  if found then perform public._ht_bao_tv(p_ht, 'xem', jsonb_build_object('ht', p_ht, 'e', v_me, 'tin', p_tin)); end if;
end $$;

-- Ghim / bỏ ghim (p_tin = null)
create or replace function public.ht_ghim(p_token text, p_ht bigint, p_tin bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  if p_tin is not null and not exists (select 1 from public.ht_tin_nhan where id = p_tin and hoi_thoai_id = p_ht and not thu_hoi) then
    raise exception 'KHONG_TIM_THAY';
  end if;
  update public.ht_hoi_thoai set ghim_tin_id = p_tin where id = p_ht;
  perform public._ht_bao_tv(p_ht, 'ghim', jsonb_build_object('ht', p_ht, 'tin', p_tin));
end $$;

-- Tìm tin trong 1 hội thoại
create or replace function public.ht_tim(p_token text, p_ht bigint, p_tu text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  if length(trim(coalesce(p_tu, ''))) < 2 then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'ten_gui', public._ht_ten(m.nguoi_gui),
            'noi_dung', left(m.noi_dung, 200), 'tao_luc', m.tao_luc) order by m.id desc), '[]'::jsonb)
          from (select * from public.ht_tin_nhan m where m.hoi_thoai_id = p_ht and not m.thu_hoi and m.loai = 'chu'
                  and lower(m.noi_dung) like '%' || lower(trim(p_tu)) || '%' order by m.id desc limit 50) m);
end $$;

-- Tắt / bật thông báo của 1 hội thoại
create or replace function public.ht_tat_tb(p_token text, p_ht bigint, p_tat boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  update public.ht_thanh_vien set tat_tb = coalesce(p_tat, false) where hoi_thoai_id = p_ht and employee_id = v_me;
end $$;

-- "Xoá hội thoại" khỏi danh sách của tôi (không xoá tin của người khác; có tin mới sẽ hiện lại)
create or replace function public.ht_an_hoi_thoai(p_token text, p_ht bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  update public.ht_thanh_vien set an = true,
         doc_den = coalesce((select tin_cuoi_id from public.ht_hoi_thoai where id = p_ht), doc_den)
   where hoi_thoai_id = p_ht and employee_id = v_me;
end $$;

-- Tổng số tin chưa đọc (badge trên nút Chat)
create or replace function public.ht_tong_chua_doc(p_token text)
returns int language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  return (select count(*) from public.ht_thanh_vien tv join public.ht_tin_nhan m on m.hoi_thoai_id = tv.hoi_thoai_id
          where tv.employee_id = v_me and m.id > tv.doc_den and m.nguoi_gui is distinct from v_me and m.loai <> 'he_thong');
end $$;

-- ---------------------------------------------------------------------
-- 5. QUYỀN GỌI HÀM: hàm nội bộ (_ht_*) khoá; hàm ht_* cho app gọi
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and (p.proname like 'ht\_%' or p.proname like '\_ht\_%')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    if f.proname like 'ht\_%' then
      execute format('grant execute on function %s to anon, authenticated', f.sig);
    end if;
  end loop;
end $$;

commit;
