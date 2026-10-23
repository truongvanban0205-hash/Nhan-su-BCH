-- =====================================================================
-- CHAT NỘI BỘ — PHẦN 4 + 6: thông báo đẩy + gọi thoại/video 1-1
-- Chạy 1 lần trong Supabase → SQL Editor (cần đã chạy chat-1.sql, chat-3.sql).
-- Sau đó chạy đoạn SQL "cấu hình" do trang tools/tao-khoa-push.html tạo ra.
--
-- Luồng thông báo: có tin mới / cuộc gọi → trigger trong database tự gọi Edge Function
-- "gui-push" (kèm mã bí mật) → hàm gửi Web Push tới điện thoại các thành viên.
-- Trình duyệt KHÔNG gọi hàm gửi thông báo → không ai giả mạo được thông báo.
-- =====================================================================
create extension if not exists pg_net with schema extensions;

begin;

-- ---------------------------------------------------------------------
-- 1. Cấu hình cho app: khoá công khai VAPID + máy chủ hỗ trợ cuộc gọi (ICE)
--    (giá trị nằm trong ht_cai_dat, đặt bằng đoạn SQL cấu hình)
-- ---------------------------------------------------------------------
create or replace function public.ht_cau_hinh(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  return jsonb_build_object(
    'vapid_public', (select gia_tri from public.ht_cai_dat where khoa = 'vapid_public'),
    'ice', coalesce((select gia_tri::jsonb from public.ht_cai_dat where khoa = 'ice'),
                    '[{"urls":"stun:stun.l.google.com:19302"},{"urls":"stun:stun1.l.google.com:19302"}]'::jsonb));
end $$;

-- 2. Đăng ký / huỷ thiết bị nhận thông báo
create or replace function public.ht_dang_ky_push(p_token text, p_endpoint text, p_p256dh text, p_auth text, p_thiet_bi text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'DANG_KY_KHONG_HOP_LE'; end if;
  insert into public.ht_dang_ky_push (endpoint, employee_id, p256dh, auth, thiet_bi)
  values (p_endpoint, v_me, p_p256dh, p_auth, left(coalesce(p_thiet_bi, ''), 200))
  on conflict (endpoint) do update set employee_id = excluded.employee_id, p256dh = excluded.p256dh,
       auth = excluded.auth, thiet_bi = excluded.thiet_bi, tao_luc = now();
end $$;

create or replace function public.ht_huy_push(p_token text, p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token);
begin
  delete from public.ht_dang_ky_push where endpoint = p_endpoint and employee_id = v_me;
end $$;

-- 3. Gọi Edge Function gửi thông báo (bỏ qua nếu chưa cấu hình)
create or replace function public._ht_day(p_data jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_url text; v_bm text;
begin
  select gia_tri into v_url from public.ht_cai_dat where khoa = 'push_url';
  select gia_tri into v_bm  from public.ht_cai_dat where khoa = 'push_bi_mat';
  if v_url is null or v_bm is null then return; end if;
  perform net.http_post(url := v_url, body := p_data,
                        headers := jsonb_build_object('Content-Type', 'application/json', 'x-bi-mat', v_bm));
exception when others then null; -- lỗi gửi thông báo không được làm hỏng việc gửi tin
end $$;

create or replace function public._ht_trg_tin_moi()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.loai <> 'he_thong' then perform public._ht_day(jsonb_build_object('loai', 'tin', 'tin', new.id)); end if;
  return new;
end $$;
drop trigger if exists ht_tin_moi_day on public.ht_tin_nhan;
create trigger ht_tin_moi_day after insert on public.ht_tin_nhan for each row execute function public._ht_trg_tin_moi();

-- ---------------------------------------------------------------------
-- 4. CUỘC GỌI 1-1 (thoại / video). Tiếng & hình đi thẳng giữa 2 máy (WebRTC);
--    server chỉ báo "có cuộc gọi" và ghi lịch sử.
-- ---------------------------------------------------------------------
create table if not exists public.ht_cuoc_goi (
  id           bigserial primary key,
  hoi_thoai_id bigint not null references public.ht_hoi_thoai(id) on delete cascade,
  nguoi_goi    bigint not null references public.employees(id) on delete cascade,
  nguoi_nghe   bigint not null references public.employees(id) on delete cascade,
  loai         text not null check (loai in ('thoai', 'video')),
  trang_thai   text not null default 'do_chuong' check (trang_thai in ('do_chuong', 'dang_goi', 'ket_thuc', 'nho', 'tu_choi')),
  kenh         text not null default replace(gen_random_uuid()::text, '-', ''), -- kênh trao đổi kết nối của riêng cuộc gọi
  tao_luc      timestamptz not null default now(),
  bat_dau_luc  timestamptz,
  ket_thuc_luc timestamptz
);
alter table public.ht_cuoc_goi enable row level security;
revoke all on public.ht_cuoc_goi from anon, authenticated;

create or replace function public._ht_goi_json(g public.ht_cuoc_goi)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', g.id, 'ht', g.hoi_thoai_id, 'loai', g.loai, 'kenh', g.kenh,
    'trang_thai', case when g.trang_thai = 'do_chuong' and g.tao_luc < now() - interval '60 seconds' then 'nho' else g.trang_thai end,
    'nguoi_goi', g.nguoi_goi, 'ten_goi', public._ht_ten(g.nguoi_goi),
    'nguoi_nghe', g.nguoi_nghe, 'ten_nghe', public._ht_ten(g.nguoi_nghe), 'tao_luc', g.tao_luc);
$$;

-- Bắt đầu gọi
create or replace function public.ht_goi(p_token text, p_ht bigint, p_loai text default 'thoai')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_kia bigint; g public.ht_cuoc_goi;
begin
  if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  if (select loai from public.ht_hoi_thoai where id = p_ht) <> 'rieng' then raise exception 'CHI_GOI_1_1'; end if;
  select employee_id into v_kia from public.ht_thanh_vien where hoi_thoai_id = p_ht and employee_id <> v_me limit 1;
  -- cuộc gọi cũ còn treo của 2 người → kết thúc
  update public.ht_cuoc_goi set trang_thai = case when trang_thai = 'dang_goi' then 'ket_thuc' else 'nho' end, ket_thuc_luc = now()
   where hoi_thoai_id = p_ht and trang_thai in ('do_chuong', 'dang_goi') and tao_luc < now() - interval '2 hours';
  insert into public.ht_cuoc_goi (hoi_thoai_id, nguoi_goi, nguoi_nghe, loai)
  values (p_ht, v_me, v_kia, case when p_loai = 'video' then 'video' else 'thoai' end)
  returning * into g;
  perform public._ht_bao(public._ht_kenh(v_kia), 'goi', public._ht_goi_json(g));
  perform public._ht_day(jsonb_build_object('loai', 'goi', 'goi', g.id));
  return public._ht_goi_json(g);
end $$;

-- Xem 1 cuộc gọi (khi bấm thông báo mở app)
create or replace function public.ht_xem_goi(p_token text, p_goi bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); g public.ht_cuoc_goi;
begin
  select * into g from public.ht_cuoc_goi where id = p_goi and v_me in (nguoi_goi, nguoi_nghe);
  if g.id is null then raise exception 'KHONG_TIM_THAY'; end if;
  return public._ht_goi_json(g);
end $$;

-- Nghe / từ chối
create or replace function public.ht_tra_loi_goi(p_token text, p_goi bigint, p_nghe boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); g public.ht_cuoc_goi;
begin
  update public.ht_cuoc_goi
     set trang_thai = case when p_nghe then 'dang_goi' else 'tu_choi' end,
         bat_dau_luc = case when p_nghe then now() end,
         ket_thuc_luc = case when p_nghe then null else now() end
   where id = p_goi and nguoi_nghe = v_me and trang_thai = 'do_chuong' and tao_luc > now() - interval '60 seconds'
  returning * into g;
  if g.id is null then raise exception 'CUOC_GOI_DA_KET_THUC'; end if;
  perform public._ht_bao(public._ht_kenh(g.nguoi_goi), 'goi_tl', public._ht_goi_json(g));
  if not p_nghe then
    perform public._ht_he_thong(g.hoi_thoai_id, '📞 ' || public._ht_ten(g.nguoi_nghe) || ' đã từ chối cuộc gọi ' || case when g.loai = 'video' then 'video' else 'thoại' end);
  end if;
  return public._ht_goi_json(g);
end $$;

-- Kết thúc (ai cũng gọi được: tắt máy, huỷ khi đang đổ chuông, hết giờ chờ)
create or replace function public.ht_ket_thuc_goi(p_token text, p_goi bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); g public.ht_cuoc_goi; v_giay int; v_nd text;
begin
  update public.ht_cuoc_goi
     set trang_thai = case when trang_thai = 'dang_goi' then 'ket_thuc' else 'nho' end, ket_thuc_luc = now()
   where id = p_goi and v_me in (nguoi_goi, nguoi_nghe) and trang_thai in ('do_chuong', 'dang_goi')
  returning * into g;
  if g.id is null then
    select * into g from public.ht_cuoc_goi where id = p_goi and v_me in (nguoi_goi, nguoi_nghe);
    return public._ht_goi_json(g); -- đã kết thúc trước đó
  end if;
  if g.trang_thai = 'ket_thuc' then
    v_giay := extract(epoch from (g.ket_thuc_luc - g.bat_dau_luc))::int;
    v_nd := '📞 Cuộc gọi ' || case when g.loai = 'video' then 'video' else 'thoại' end || ' · '
            || case when v_giay >= 60 then (v_giay / 60) || ' phút ' else '' end || (v_giay % 60) || ' giây';
  else
    v_nd := '📞 ' || public._ht_ten(g.nguoi_nghe) || ' đã bỏ lỡ cuộc gọi ' || case when g.loai = 'video' then 'video' else 'thoại' end || ' từ ' || public._ht_ten(g.nguoi_goi);
  end if;
  perform public._ht_he_thong(g.hoi_thoai_id, v_nd);
  perform public._ht_bao(public._ht_kenh(g.nguoi_goi), 'goi_kt', public._ht_goi_json(g));
  perform public._ht_bao(public._ht_kenh(g.nguoi_nghe), 'goi_kt', public._ht_goi_json(g));
  return public._ht_goi_json(g);
end $$;

-- 5. Quyền gọi hàm
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('ht_cau_hinh', 'ht_dang_ky_push', 'ht_huy_push', 'ht_goi', 'ht_xem_goi', 'ht_tra_loi_goi', 'ht_ket_thuc_goi',
                        '_ht_day', '_ht_trg_tin_moi', '_ht_goi_json')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    if f.proname like 'ht\_%' then execute format('grant execute on function %s to anon, authenticated', f.sig); end if;
  end loop;
end $$;

commit;
