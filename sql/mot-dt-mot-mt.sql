-- =====================================================================
-- 1 TÀI KHOẢN = 1 ĐIỆN THOẠI + 1 MÁY TÍNH (trước đây: chỉ 1 máy bất kỳ)
-- Đăng nhập điện thoại mới → chỉ đá điện thoại cũ; máy tính vẫn giữ (và ngược lại).
-- Server tự phân loại máy theo thông tin trình duyệt gửi lúc đăng nhập (không cần sửa app).
-- Chạy 1 lần trong Supabase → SQL Editor (cần đã chạy chat-1.sql).
-- Người có quyền "Dùng nhiều máy" vẫn không giới hạn như cũ.
-- =====================================================================
begin;

-- 1. Mỗi người tối đa 2 phiên: 'dt' (điện thoại / máy tính bảng) và 'mt' (máy tính)
alter table public.phien_dang_nhap add column if not exists loai_may text not null default 'mt';
update public.phien_dang_nhap
   set loai_may = case when coalesce(thiet_bi, '') ~* '(mobi|android|iphone|ipad|ipod)' then 'dt' else 'mt' end;
alter table public.phien_dang_nhap drop constraint if exists phien_dang_nhap_pkey;
alter table public.phien_dang_nhap add primary key (employee_id, loai_may);

create or replace function public._loai_may(p_thiet_bi text)
returns text language sql immutable as $$
  select case when coalesce(p_thiet_bi, '') ~* '(mobi|android|iphone|ipad|ipod)' then 'dt' else 'mt' end;
$$;

-- 2. Đăng nhập: chỉ thay phiên CÙNG LOẠI máy
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
    insert into public.phien_dang_nhap (employee_id, loai_may, token, thiet_bi)
    values (v_id, public._loai_may(p_thiet_bi), v_tok, left(coalesce(p_thiet_bi, ''), 200))
    on conflict (employee_id, loai_may) do update
       set token = excluded.token, thiet_bi = excluded.thiet_bi, dang_nhap_luc = now(), hoat_dong_luc = now();
  end if;
  return jsonb_set(r, '{data,token}', to_jsonb(v_tok), true);
end $$;

-- 3. Kiểm tra phiên: thẻ còn khớp với 1 trong 2 phiên (điện thoại / máy tính) là được
create or replace function public.kiem_tra_phien(p_ten text, p_token text)
returns text language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  select id into v_id from public.employees
   where lower(trim(ten)) = lower(trim(coalesce(p_ten, ''))) order by id limit 1;
  if v_id is null then return 'khong_hop_le'; end if;
  if public.ps_nhieu_may(v_id) then return 'ok'; end if;
  if coalesce(p_token, '') = '' then return 'can_dang_nhap_lai'; end if;
  if exists (select 1 from public.phien_dang_nhap where employee_id = v_id and token = p_token) then
    update public.phien_dang_nhap set hoat_dong_luc = now()
     where employee_id = v_id and token = p_token and hoat_dong_luc < now() - interval '5 minutes';
    return 'ok';
  end if;
  if exists (select 1 from public.phien_dang_nhap where employee_id = v_id) then return 'bi_da'; end if;
  return 'can_dang_nhap_lai';
end $$;

commit;

-- Xem: mỗi người hiện có phiên nào (dt = điện thoại, mt = máy tính)
select e.ten, p.loai_may, p.dang_nhap_luc, left(p.thiet_bi, 60) as thiet_bi
from public.phien_dang_nhap p join public.employees e on e.id = p.employee_id
order by e.ten, p.loai_may;
