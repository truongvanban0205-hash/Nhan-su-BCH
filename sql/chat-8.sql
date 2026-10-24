-- =====================================================================
-- CHAT — hoàn thiện vòng đời cuộc gọi (chạy SAU chat-4.sql)
--  1. Cuộc gọi nhỡ = 1 tin "📞 Cuộc gọi … nhỡ" do NGƯỜI GỌI gửi → tính là tin chưa đọc (badge đỏ),
--     hiện trong danh sách hội thoại, và tự có thông báo đẩy "cuộc gọi nhỡ" (bấm vào mở đúng hội thoại).
--  2. Dọn cuộc gọi treo (người gọi mất mạng / tắt app giữa chừng) → không còn "cuộc gọi ma".
--  3. Nghe máy trên 1 thiết bị → báo các thiết bị khác của người nghe ngừng đổ chuông.
-- =====================================================================
begin;

create index if not exists ht_cuoc_goi_tt_idx on public.ht_cuoc_goi (trang_thai, tao_luc);

-- Ghi lịch sử khi cuộc gọi kết thúc (dùng chung cho: tắt máy, huỷ, hết giờ, dọn treo)
create or replace function public._ht_ghi_ket_thuc_goi(g public.ht_cuoc_goi)
returns void language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_giay int; v_kieu text := case when g.loai = 'video' then 'video' else 'thoại' end;
begin
  if g.trang_thai = 'nho' then
    -- tin thường từ người gọi → người nghe thấy chưa đọc + nhận thông báo đẩy (trigger ht_tin_moi_day)
    insert into public.ht_tin_nhan (hoi_thoai_id, nguoi_gui, loai, noi_dung)
    values (g.hoi_thoai_id, g.nguoi_goi, 'chu', '📞 Cuộc gọi ' || v_kieu || ' nhỡ') returning id into v_id;
    update public.ht_hoi_thoai set tin_cuoi_id = v_id, tin_cuoi_luc = now() where id = g.hoi_thoai_id;
    update public.ht_thanh_vien set doc_den = greatest(doc_den, v_id) where hoi_thoai_id = g.hoi_thoai_id and employee_id = g.nguoi_goi;
    update public.ht_thanh_vien set an = false where hoi_thoai_id = g.hoi_thoai_id and an;
    perform public._ht_bao_tv(g.hoi_thoai_id, 'tin', jsonb_build_object('ht', g.hoi_thoai_id, 'tin', v_id, 'tu', g.nguoi_goi));
  elsif g.trang_thai = 'ket_thuc' then
    v_giay := greatest(0, extract(epoch from (g.ket_thuc_luc - coalesce(g.bat_dau_luc, g.ket_thuc_luc)))::int);
    perform public._ht_he_thong(g.hoi_thoai_id, '📞 Cuộc gọi ' || v_kieu || ' · '
      || case when v_giay >= 60 then (v_giay / 60) || ' phút ' else '' end || (v_giay % 60) || ' giây');
  end if;
  perform public._ht_bao(public._ht_kenh(g.nguoi_goi), 'goi_kt', public._ht_goi_json(g));
  perform public._ht_bao(public._ht_kenh(g.nguoi_nghe), 'goi_kt', public._ht_goi_json(g));
end $$;

-- Dọn cuộc gọi treo: đổ chuông quá 70 giây → nhỡ; đang gọi quá 3 giờ (2 bên đều mất kết nối) → kết thúc
create or replace function public._ht_don_goi_treo()
returns void language plpgsql security definer set search_path = public as $$
declare g public.ht_cuoc_goi;
begin
  for g in
    update public.ht_cuoc_goi set trang_thai = 'nho', ket_thuc_luc = now()
     where trang_thai = 'do_chuong' and tao_luc < now() - interval '70 seconds'
    returning *
  loop perform public._ht_ghi_ket_thuc_goi(g); end loop;
  for g in
    update public.ht_cuoc_goi set trang_thai = 'ket_thuc', ket_thuc_luc = now()
     where trang_thai = 'dang_goi' and coalesce(bat_dau_luc, tao_luc) < now() - interval '3 hours'
    returning *
  loop perform public._ht_ghi_ket_thuc_goi(g); end loop;
end $$;

-- Bắt đầu gọi (giữ nguyên cách dùng; thêm dọn treo + chặn gọi khi người kia đang trong cuộc gọi khác)
create or replace function public.ht_goi(p_token text, p_ht bigint, p_loai text default 'thoai')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_kia bigint; g public.ht_cuoc_goi;
begin
  perform public._ht_don_goi_treo();
  if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  if (select loai from public.ht_hoi_thoai where id = p_ht) <> 'rieng' then raise exception 'CHI_GOI_1_1'; end if;
  select employee_id into v_kia from public.ht_thanh_vien where hoi_thoai_id = p_ht and employee_id <> v_me limit 1;
  if exists (select 1 from public.ht_cuoc_goi where trang_thai = 'dang_goi' and v_kia in (nguoi_goi, nguoi_nghe)) then
    raise exception 'NGUOI_NHAN_DANG_BAN';
  end if;
  -- cuộc gọi cũ của chính mình còn đổ chuông (bấm gọi 2 lần) → huỷ cái cũ
  for g in update public.ht_cuoc_goi set trang_thai = 'nho', ket_thuc_luc = now()
            where nguoi_goi = v_me and trang_thai = 'do_chuong' returning * loop
    perform public._ht_ghi_ket_thuc_goi(g);
  end loop;
  insert into public.ht_cuoc_goi (hoi_thoai_id, nguoi_goi, nguoi_nghe, loai)
  values (p_ht, v_me, v_kia, case when p_loai = 'video' then 'video' else 'thoai' end)
  returning * into g;
  perform public._ht_bao(public._ht_kenh(v_kia), 'goi', public._ht_goi_json(g));
  perform public._ht_day(jsonb_build_object('loai', 'goi', 'goi', g.id));
  return public._ht_goi_json(g);
end $$;

create or replace function public.ht_xem_goi(p_token text, p_goi bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); g public.ht_cuoc_goi;
begin
  perform public._ht_don_goi_treo();
  select * into g from public.ht_cuoc_goi where id = p_goi and v_me in (nguoi_goi, nguoi_nghe);
  if g.id is null then raise exception 'KHONG_TIM_THAY'; end if;
  return public._ht_goi_json(g);
end $$;

-- Nghe / từ chối: chỉ 1 thiết bị được nhận (điều kiện trang_thai = 'do_chuong' trong cùng 1 lệnh UPDATE)
create or replace function public.ht_tra_loi_goi(p_token text, p_goi bigint, p_nghe boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); g public.ht_cuoc_goi;
begin
  update public.ht_cuoc_goi
     set trang_thai = case when p_nghe then 'dang_goi' else 'tu_choi' end,
         bat_dau_luc = case when p_nghe then now() end,
         ket_thuc_luc = case when p_nghe then null else now() end
   where id = p_goi and nguoi_nghe = v_me and trang_thai = 'do_chuong' and tao_luc > now() - interval '70 seconds'
  returning * into g;
  if g.id is null then raise exception 'CUOC_GOI_DA_KET_THUC'; end if;
  perform public._ht_bao(public._ht_kenh(g.nguoi_goi), 'goi_tl', public._ht_goi_json(g));
  perform public._ht_bao(public._ht_kenh(g.nguoi_nghe), 'goi_tl', public._ht_goi_json(g)); -- thiết bị khác của người nghe ngừng chuông
  if not p_nghe then
    perform public._ht_he_thong(g.hoi_thoai_id, '📞 ' || public._ht_ten(g.nguoi_nghe) || ' đã từ chối cuộc gọi ' || case when g.loai = 'video' then 'video' else 'thoại' end);
  end if;
  return public._ht_goi_json(g);
end $$;

create or replace function public.ht_ket_thuc_goi(p_token text, p_goi bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); g public.ht_cuoc_goi;
begin
  update public.ht_cuoc_goi
     set trang_thai = case when trang_thai = 'dang_goi' then 'ket_thuc' else 'nho' end, ket_thuc_luc = now()
   where id = p_goi and v_me in (nguoi_goi, nguoi_nghe) and trang_thai in ('do_chuong', 'dang_goi')
  returning * into g;
  if g.id is null then -- đã kết thúc trước đó (bấm 2 lần / cả 2 bên cùng tắt) → không ghi lịch sử lần nữa
    select * into g from public.ht_cuoc_goi where id = p_goi and v_me in (nguoi_goi, nguoi_nghe);
    return public._ht_goi_json(g);
  end if;
  perform public._ht_ghi_ket_thuc_goi(g);
  return public._ht_goi_json(g);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('_ht_ghi_ket_thuc_goi', '_ht_don_goi_treo', 'ht_goi', 'ht_xem_goi', 'ht_tra_loi_goi', 'ht_ket_thuc_goi')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    if f.proname like 'ht\_%' then execute format('grant execute on function %s to anon, authenticated', f.sig); end if;
  end loop;
end $$;

-- dọn ngay các cuộc gọi đang treo từ trước
select public._ht_don_goi_treo();

commit;
