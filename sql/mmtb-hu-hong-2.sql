-- =====================================================================
-- MMTB — MỤC II (bổ sung): DANH SÁCH MÁY ĐÃ XOÁ → PHỤC HỒI / XOÁ VĨNH VIỄN
-- Chạy SAU file mmtb-hu-hong.sql. Chỉ thay 1 hàm trigger + thêm 2 hàm. Không đổi bảng, không đụng dữ liệu.
--   Phục hồi       : dòng đã xoá quay lại bảng chi tiết + biểu đồ (cần mật khẩu vận hành).
--   Xoá vĩnh viễn  : xoá hẳn dòng ĐÃ Ở TRONG DANH SÁCH ĐÃ XOÁ (VD nhập thử nghiệm) → không còn tính vào biểu đồ.
-- Chạy 1 lần trong Supabase → SQL Editor.
-- =====================================================================
begin;

-- Trigger cũ không cho "hồi sinh" dòng đã xoá. Nay cho phép, nhưng CHỈ khi đi qua hàm phục hồi có mật khẩu.
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
    if old.da_xoa and coalesce(current_setting('app.hh_phuc_hoi', true), '') = '1' then
      new.da_xoa := false; new.xoa_luc := null; new.xoa_nham := false;   -- phục hồi
    elsif old.da_xoa then -- đã xoá thì giữ nguyên
      new.da_xoa := true; new.xoa_luc := old.xoa_luc; new.xoa_nham := old.xoa_nham;
    elsif new.da_xoa then
      new.xoa_luc := now(); new.xoa_nham := not old.xong;
    end if;
  end if;
  return new;
end $$;

create or replace function public.mmtb_hh_phuc_hoi(p_pass text, p_don_vi_id text, p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.dbmmtb_kiem_mat_khau(p_pass, p_don_vi_id);
  perform set_config('app.hh_phuc_hoi', '1', true);
  update public.mmtb_hu_hong set da_xoa = false where id = p_id and don_vi_id = p_don_vi_id and da_xoa;
  perform set_config('app.hh_phuc_hoi', '', true);
end $$;

create or replace function public.mmtb_hh_xoa_vinh_vien(p_pass text, p_don_vi_id text, p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.dbmmtb_kiem_mat_khau(p_pass, p_don_vi_id);
  delete from public.mmtb_hu_hong where id = p_id and don_vi_id = p_don_vi_id and da_xoa; -- chỉ xoá dòng đã ở danh sách đã xoá
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('mmtb_hh_phuc_hoi', 'mmtb_hh_xoa_vinh_vien')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;

commit;

select 'OK: đã thêm phục hồi / xoá vĩnh viễn' as ket_qua;
