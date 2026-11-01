-- =====================================================================
-- MMTB — MỤC II. TÌNH TRẠNG HƯ HỎNG, SỬA CHỮA
-- Chỉ THÊM MỚI 3 bảng + vài hàm. Không đụng bảng mmtb (phần I) hay module khác, không xoá dữ liệu.
-- Cần đã chạy bao-mat-dot-2.sql (dùng _duoc_vao_dv: chỉ người đăng nhập thuộc đơn vị mới đọc/ghi).
-- Chạy 1 lần trong Supabase → SQL Editor.
-- =====================================================================
begin;

-- 1. Cấu hình mục II của từng đơn vị (ẩn/hiện, nhóm hư hỏng + khung giờ, các đầu mục bảng chi tiết)
--    null = dùng cấu hình mặc định có sẵn trong app
create table if not exists public.mmtb_hh_cau_hinh (
  don_vi_id text primary key,
  cau_hinh  jsonb not null,
  cap_nhat  timestamptz not null default now()
);

-- 2. Bảng chi tiết hư hỏng — mỗi dòng 1 máy hỏng
--    gt: giá trị các đầu mục (theo cấu hình, thêm/bớt đầu mục không cần đổi bảng)
--    Các mốc thời gian để xếp nhóm + vẽ biểu đồ 7 ngày nằm ở cột riêng.
create table if not exists public.mmtb_hu_hong (
  id          bigserial primary key,
  don_vi_id   text not null,
  gt          jsonb not null default '{}'::jsonb,
  t_hong      timestamptz,                    -- Thời điểm hỏng
  du_kien     timestamptz,                    -- Dự kiến sửa xong
  xong        boolean not null default false, -- đang ở trạng thái "Đã sửa xong"
  xong_luc    timestamptz,                    -- lúc chuyển sang "Đã sửa xong" (tự ghi)
  da_xoa      boolean not null default false, -- đã bấm Xoá (ẩn khỏi bảng, KHÔNG xoá thật)
  xoa_luc     timestamptz,
  xoa_nham    boolean not null default false, -- xoá khi CHƯA sửa xong = nhập nhầm → không tính vào lịch sử
  tao_luc     timestamptz not null default now(),
  tao_boi     bigint,
  sua_luc     timestamptz not null default now(),
  sua_boi     bigint
);
create index if not exists mmtb_hu_hong_dv_idx on public.mmtb_hu_hong (don_vi_id, da_xoa);

-- 3. Ghi chú 3 dòng của bảng tổng hợp — mỗi ngày một ghi chú riêng
create table if not exists public.mmtb_hh_ghi_chu (
  don_vi_id text not null,
  ngay      text not null,   -- 'YYYY-MM-DD' (giờ Việt Nam), giống mmtb.ngay
  nhom_ma   text not null,
  ghi_chu   text,
  sua_luc   timestamptz not null default now(),
  primary key (don_vi_id, ngay, nhom_ma)
);

-- 4. Quyền: chỉ người đăng nhập (thẻ phiên) + đã được duyệt vào đúng đơn vị
do $$
declare b text; p record;
begin
  foreach b in array array['mmtb_hu_hong', 'mmtb_hh_ghi_chu', 'mmtb_hh_cau_hinh'] loop
    execute format('alter table public.%I enable row level security', b);
    execute format('revoke all on public.%I from anon, authenticated', b);
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = b loop
      execute format('drop policy %I on public.%I', p.policyname, b);
    end loop;
  end loop;
  -- bảng chi tiết + ghi chú: đọc / thêm / sửa trực tiếp (không cho xoá thật)
  foreach b in array array['mmtb_hu_hong', 'mmtb_hh_ghi_chu'] loop
    execute format('grant select, insert, update on public.%I to anon, authenticated', b);
    execute format('create policy %I on public.%I for select to anon, authenticated using (public._duoc_vao_dv(don_vi_id))', b || '_doc', b);
    execute format('create policy %I on public.%I for insert to anon, authenticated with check (public._duoc_vao_dv(don_vi_id))', b || '_them', b);
    execute format('create policy %I on public.%I for update to anon, authenticated using (public._duoc_vao_dv(don_vi_id)) with check (public._duoc_vao_dv(don_vi_id))', b || '_sua', b);
  end loop;
  -- cấu hình: chỉ đọc trực tiếp; sửa qua hàm có mật khẩu vận hành
  grant select on public.mmtb_hh_cau_hinh to anon, authenticated;
  create policy mmtb_hh_cau_hinh_doc on public.mmtb_hh_cau_hinh for select to anon, authenticated using (public._duoc_vao_dv(don_vi_id));
end $$;
grant usage, select on sequence public.mmtb_hu_hong_id_seq to anon, authenticated;

-- 5. Tự ghi: người sửa, lúc sửa, lúc chuyển "Đã sửa xong", lúc xoá; báo đồng bộ cho các máy khác
create or replace function public._mmtb_hh_truoc_luu()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.sua_luc := now();
  new.sua_boi := public._the_nv();
  if tg_op = 'INSERT' then
    new.tao_luc := now(); new.tao_boi := new.sua_boi;
    new.da_xoa := false; new.xoa_luc := null; new.xoa_nham := false;
    new.xong_luc := case when new.xong then now() end;
  else
    new.don_vi_id := old.don_vi_id; new.tao_luc := old.tao_luc; new.tao_boi := old.tao_boi;
    if new.xong and not old.xong then new.xong_luc := now();
    elsif not new.xong then new.xong_luc := null;
    else new.xong_luc := old.xong_luc; end if;
    if old.da_xoa then -- đã xoá thì giữ nguyên, không "hồi sinh"
      new.da_xoa := true; new.xoa_luc := old.xoa_luc; new.xoa_nham := old.xoa_nham;
    elsif new.da_xoa then
      new.xoa_luc := now(); new.xoa_nham := not old.xong;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists mmtb_hu_hong_truoc_luu on public.mmtb_hu_hong;
create trigger mmtb_hu_hong_truoc_luu before insert or update on public.mmtb_hu_hong
  for each row execute function public._mmtb_hh_truoc_luu();

create or replace function public._mmtb_hh_bao_doi()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_kenh text;
begin
  insert into public.bc_kenh (don_vi_id) values (new.don_vi_id) on conflict do nothing;
  select kenh into v_kenh from public.bc_kenh where don_vi_id = new.don_vi_id;
  perform realtime.send(jsonb_build_object('don_vi_id', new.don_vi_id), 'mmtb_hh', 'bc:' || v_kenh, false);
  return new;
exception when others then return new;
end $$;
do $$
declare b text;
begin
  foreach b in array array['mmtb_hu_hong', 'mmtb_hh_ghi_chu', 'mmtb_hh_cau_hinh'] loop
    execute format('drop trigger if exists %I on public.%I', b || '_bao_doi', b);
    execute format('create trigger %I after insert or update on public.%I for each row execute function public._mmtb_hh_bao_doi()', b || '_bao_doi', b);
  end loop;
end $$;

-- 6. Lưu cấu hình (mật khẩu vận hành của đơn vị, giống Định biên)
create or replace function public.mmtb_hh_luu_cau_hinh(p_pass text, p_don_vi_id text, p_cau_hinh jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.dbmmtb_kiem_mat_khau(p_pass, p_don_vi_id);
  if jsonb_typeof(p_cau_hinh) <> 'object' or jsonb_typeof(p_cau_hinh -> 'nhom') <> 'array' or jsonb_typeof(p_cau_hinh -> 'cot') <> 'array' then
    raise exception 'CAU_HINH_KHONG_HOP_LE';
  end if;
  insert into public.mmtb_hh_cau_hinh (don_vi_id, cau_hinh) values (p_don_vi_id, p_cau_hinh)
  on conflict (don_vi_id) do update set cau_hinh = excluded.cau_hinh, cap_nhat = now();
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('mmtb_hh_luu_cau_hinh', '_mmtb_hh_truoc_luu', '_mmtb_hh_bao_doi')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    if f.proname = 'mmtb_hh_luu_cau_hinh' then execute format('grant execute on function %s to anon, authenticated', f.sig); end if;
  end loop;
end $$;

commit;

-- Kiểm tra: 3 bảng mới, mỗi bảng đã khoá theo đơn vị
select tablename, string_agg(policyname, ', ' order by policyname) as policy
from pg_policies where schemaname = 'public' and tablename like 'mmtb_h%' group by tablename;
