-- =====================================================================
-- BẢO MẬT ĐỢT 2 — KHOÁ BẢNG BÁO CÁO (nhansu, mmtb, ldt)
-- Trước: AI CÓ ĐƯỜNG LINK WEB cũng đọc / sửa được báo cáo của mọi đơn vị (policy = true).
-- Sau : chỉ người ĐANG ĐĂNG NHẬP (có thẻ phiên hợp lệ) và ĐÃ ĐƯỢC DUYỆT vào đúng đơn vị đó
--       mới đọc / ghi được báo cáo của đơn vị đó.
-- App gửi thẻ phiên kèm mọi yêu cầu (header "x-the"); database tự kiểm tra từng dòng.
-- Đồng bộ tức thời giữa các máy chuyển sang kênh riêng có mã bí mật của từng đơn vị
-- (chỉ báo "có thay đổi", máy nhận tự tải lại qua cổng đã kiểm tra quyền).
--
-- THỨ TỰ: up code index.html mới lên GitHub TRƯỚC → đợi 3 phút → rồi mới chạy file này.
-- Gặp sự cố: chạy sql/bao-mat-dot-2-hoan-tac.sql để trở lại như cũ ngay.
-- =====================================================================
begin;

-- 1. Thẻ phiên gửi kèm yêu cầu → mã nhân viên (null nếu không có / sai / hết hạn)
create or replace function public._the_nv()
returns bigint language plpgsql stable security definer set search_path = public as $$
declare v_tok text; v_id bigint;
begin
  begin
    v_tok := (current_setting('request.headers', true)::json) ->> 'x-the';
  exception when others then return null;
  end;
  if coalesce(v_tok, '') = '' or length(v_tok) < 32 then return null; end if;
  select employee_id into v_id from public.phien_dang_nhap where token = v_tok;
  if v_id is null then select employee_id into v_id from public.phien_nhieu_may where token = v_tok; end if;
  return v_id;
end $$;

-- 2. Người đang đăng nhập có thuộc đơn vị này (đã duyệt) không
create or replace function public._duoc_vao_dv(p_dv text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.employee_don_vi m
                 where m.employee_id = public._the_nv() and m.don_vi_id = p_dv and m.trang_thai = 'da_duyet');
$$;
revoke execute on function public._the_nv() from public;
revoke execute on function public._duoc_vao_dv(text) from public;
grant execute on function public._the_nv() to anon, authenticated;        -- policy cần gọi được
grant execute on function public._duoc_vao_dv(text) to anon, authenticated;

-- 3. Thay policy "ai cũng được" bằng policy kiểm tra thẻ phiên + đơn vị
do $$
declare b text; p record;
begin
  foreach b in array array['nhansu', 'mmtb', 'ldt'] loop
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = b loop
      execute format('drop policy %I on public.%I', p.policyname, b);
    end loop;
    execute format('alter table public.%I enable row level security', b);
    execute format('create policy %I on public.%I for select to anon, authenticated using (public._duoc_vao_dv(don_vi_id))', b || '_doc_theo_dv', b);
    execute format('create policy %I on public.%I for insert to anon, authenticated with check (public._duoc_vao_dv(don_vi_id))', b || '_them_theo_dv', b);
    execute format('create policy %I on public.%I for update to anon, authenticated using (public._duoc_vao_dv(don_vi_id)) with check (public._duoc_vao_dv(don_vi_id))', b || '_sua_theo_dv', b);
    execute format('revoke delete, truncate on public.%I from anon, authenticated', b); -- xoá chỉ qua hàm có mật khẩu vận hành
  end loop;
end $$;

-- 4. Ngừng phát nguyên dữ liệu báo cáo qua realtime công khai
do $$
declare b text;
begin
  foreach b in array array['nhansu', 'mmtb', 'ldt'] loop
    if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = b) then
      execute format('alter publication supabase_realtime drop table public.%I', b);
    end if;
  end loop;
end $$;

-- 5. Kênh đồng bộ riêng của từng đơn vị (mã bí mật, chỉ thành viên lấy được)
create table if not exists public.bc_kenh (
  don_vi_id text primary key,
  kenh      text not null unique default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
);
alter table public.bc_kenh enable row level security;
revoke all on public.bc_kenh from anon, authenticated;

create or replace function public.bc_lay_kenh(p_don_vi_id text)
returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public._duoc_vao_dv(p_don_vi_id) then return null; end if;
  insert into public.bc_kenh (don_vi_id) values (p_don_vi_id) on conflict do nothing;
  select kenh into v from public.bc_kenh where don_vi_id = p_don_vi_id;
  return v;
end $$;
revoke execute on function public.bc_lay_kenh(text) from public;
grant execute on function public.bc_lay_kenh(text) to anon, authenticated;

-- Có người lưu báo cáo → báo "bảng X, ngày Y vừa đổi" vào kênh của đơn vị (KHÔNG kèm số liệu)
create or replace function public._bc_bao_doi()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_kenh text;
begin
  insert into public.bc_kenh (don_vi_id) values (new.don_vi_id) on conflict do nothing;
  select kenh into v_kenh from public.bc_kenh where don_vi_id = new.don_vi_id;
  perform realtime.send(jsonb_build_object('ngay', new.ngay, 'don_vi_id', new.don_vi_id), tg_table_name, 'bc:' || v_kenh, false);
  return new;
exception when others then return new; -- lỗi báo realtime không được làm hỏng việc lưu
end $$;
do $$
declare b text;
begin
  foreach b in array array['nhansu', 'mmtb', 'ldt'] loop
    execute format('drop trigger if exists %I on public.%I', b || '_bao_doi', b);
    execute format('create trigger %I after insert or update on public.%I for each row execute function public._bc_bao_doi()', b || '_bao_doi', b);
  end loop;
end $$;

commit;

-- Kiểm tra: mỗi bảng phải có đúng 3 policy *_theo_dv
select tablename, string_agg(policyname, ', ' order by policyname) as policy
from pg_policies where schemaname = 'public' and tablename in ('nhansu', 'mmtb', 'ldt') group by tablename;
