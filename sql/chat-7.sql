-- =====================================================================
-- CHAT — chống gửi trùng khi mất mạng / gửi lại
-- Mỗi tin app tạo sẵn 1 "mã tạm". Gửi lại (vì mạng chập chờn không biết đã tới chưa)
-- với cùng mã → server trả về tin đã có, KHÔNG tạo tin thứ 2.
-- Chạy 1 lần trong Supabase → SQL Editor (cần đã chạy chat-3.sql).
-- =====================================================================
begin;

alter table public.ht_tin_nhan add column if not exists ma_tam text;
create unique index if not exists ht_tin_nhan_ma_tam_uq on public.ht_tin_nhan (nguoi_gui, ma_tam) where ma_tam is not null;

-- Thêm tham số p_ma_tam → phải bỏ hàm cũ trước (2 bản cùng tên sẽ làm app gọi nhầm)
drop function if exists public.ht_gui(text, bigint, text, text, jsonb, bigint, bigint[]);

create or replace function public.ht_gui(p_token text, p_ht bigint, p_noi_dung text,
  p_loai text default 'chu', p_tep jsonb default null, p_tra_loi bigint default null, p_nhac bigint[] default '{}',
  p_ma_tam text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me bigint := public._ht_nv(p_token); v_id bigint; v_path text;
begin
  if not public._ht_la_tv(p_ht, v_me) then raise exception 'KHONG_PHAI_THANH_VIEN'; end if;
  if p_ma_tam is not null then
    select id into v_id from public.ht_tin_nhan where nguoi_gui = v_me and ma_tam = left(p_ma_tam, 60);
    if v_id is not null then return jsonb_build_object('id', v_id, 'da_co', true); end if; -- đã gửi trước đó
  end if;
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
  insert into public.ht_tin_nhan (hoi_thoai_id, nguoi_gui, loai, noi_dung, tep, tra_loi_id, nhac, ma_tam)
  values (p_ht, v_me, p_loai, nullif(p_noi_dung, ''), p_tep, p_tra_loi,
          coalesce((select array_agg(x) from unnest(coalesce(p_nhac, '{}')) x where public._ht_la_tv(p_ht, x)), '{}'),
          left(p_ma_tam, 60))
  returning id into v_id;
  update public.ht_hoi_thoai set tin_cuoi_id = v_id, tin_cuoi_luc = now() where id = p_ht;
  update public.ht_thanh_vien set doc_den = v_id where hoi_thoai_id = p_ht and employee_id = v_me;
  update public.ht_thanh_vien set an = false where hoi_thoai_id = p_ht and an;
  update public.ht_nguoi set online_luc = now() where employee_id = v_me;
  perform public._ht_bao_tv(p_ht, 'tin', jsonb_build_object('ht', p_ht, 'tin', v_id, 'tu', v_me));
  return jsonb_build_object('id', v_id);
end $$;

revoke execute on function public.ht_gui(text, bigint, text, text, jsonb, bigint, bigint[], text) from public;
grant execute on function public.ht_gui(text, bigint, text, text, jsonb, bigint, bigint[], text) to anon, authenticated;

commit;
