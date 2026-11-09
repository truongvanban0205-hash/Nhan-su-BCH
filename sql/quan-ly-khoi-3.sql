-- =====================================================================
-- QUẢN LÝ CHUNG: xoá khối, xoá đơn vị, lưu biểu tượng (icon) chung toàn app
--  • Xoá khối: chỉ xoá được khi khối KHÔNG còn đơn vị (chuyển / xoá đơn vị trước).
--  • Xoá đơn vị: xoá đơn vị khỏi danh sách (không ai vào được nữa). Số liệu báo cáo cũ, cấu hình
--    của đơn vị đó vẫn nằm trong máy chủ (không xoá) — tạo lại không lấy lại được tự động, nên cân nhắc.
--  • Biểu tượng: lưu ở tên & màu mức '__chung' (khoá '__icon').
-- Chạy SAU quan-ly-khoi-2.sql.
-- =====================================================================
begin;

create or replace function public.admin_xoa_khoi(p_pass text, p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  if exists (select 1 from don_vi where coalesce(khoi_id, 'khoi_03') = p_id) then raise exception 'KHOI_CON_DON_VI: chuyển hoặc xoá hết đơn vị trong khối trước'; end if;
  delete from bc_ten_mau where pham_vi = '__k:' || p_id;
  delete from khoi where id = p_id;
end $$;

create or replace function public.admin_xoa_don_vi(p_pass text, p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  if (select count(*) from don_vi) <= 1 then raise exception 'PHAI_CON_IT_NHAT_1_DON_VI'; end if;
  delete from employee_don_vi where don_vi_id = p_id; -- bỏ quyền vào đơn vị đã xoá
  delete from don_vi where id = p_id;
end $$;

-- cho phép lưu mức '__chung' (biểu tượng toàn app)
create or replace function public.admin_luu_ten_mau(p_pass text, p_pham_vi text, p_cau_hinh jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not admin_dang_nhap(p_pass) then raise exception 'SAI_MAT_KHAU'; end if;
  if jsonb_typeof(p_cau_hinh) <> 'object' then raise exception 'CAU_HINH_KHONG_HOP_LE'; end if;
  if not (p_pham_vi = '__chung' or exists (select 1 from don_vi where id = p_pham_vi)
          or (p_pham_vi like '__k:%' and exists (select 1 from khoi where '__k:' || id = p_pham_vi))) then
    raise exception 'PHAM_VI_KHONG_HOP_LE';
  end if;
  insert into bc_ten_mau (pham_vi, cau_hinh) values (p_pham_vi, p_cau_hinh)
  on conflict (pham_vi) do update set cau_hinh = excluded.cau_hinh, cap_nhat = now();
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('admin_xoa_khoi', 'admin_xoa_don_vi', 'admin_luu_ten_mau')
  loop
    execute format('revoke execute on function %s from public', f.sig);
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;

commit;

select 'OK: thêm xoá khối / đơn vị + biểu tượng' as ket_qua;
