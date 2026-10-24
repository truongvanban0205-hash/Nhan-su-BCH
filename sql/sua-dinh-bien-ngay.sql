-- =====================================================================
-- SỬA: So sánh định biên Nhân sự lấy SAI mốc (lấy 01/12 trong khi đang tháng 10)
-- Nguyên nhân: hàm cũ so sánh chữ "dd/mm" theo từng ký tự → "01/12" < "24/10" (vì '0' < '2')
--   nên mốc tháng 12 bị coi là "đã tới" và được chọn vì là mốc lớn nhất.
-- Sửa: đổi mốc thành số (tháng*100 + ngày) rồi mới so sánh → hôm nay 24/10 = 1024
--   → chọn mốc lớn nhất ≤ 1024, tức 01/10 (=1001). 01/11 (=1101) và 01/12 (=1201) chưa tới.
-- Chỉ thay hàm dinhbien_lay_gia_tri_ngay (cùng tham số, cùng kết quả trả về). Không đụng dữ liệu.
-- (Báo cáo MMTB tính mốc ở trình duyệt, đã đúng cách này từ trước — không cần sửa.)
-- =====================================================================

-- "dd/mm" → tháng*100 + ngày (nhãn không đúng dạng → null, bị bỏ qua)
create or replace function public._moc_so(p_nhan text)
returns int language sql immutable as $$
  select case when trim(coalesce(p_nhan, '')) ~ '^\d{1,2}/\d{1,2}$'
              then split_part(trim(p_nhan), '/', 2)::int * 100 + split_part(trim(p_nhan), '/', 1)::int end;
$$;

create or replace function public.dinhbien_lay_gia_tri_ngay(p_ngay date, p_don_vi_id text default 'khanh_hoa'::text)
returns table(chuc_danh_id bigint, ten text, ten_tat text, so_luong numeric, thu_tu integer, an boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_nam int := extract(year from p_ngay)::int;
  v_md  int := extract(month from p_ngay)::int * 100 + extract(day from p_ngay)::int;
  v_cot_id bigint;
begin
  -- mốc gần nhất đã tới (≤ ngày đang xem)
  select c.id into v_cot_id
  from public.dinh_bien_cot c
  where c.don_vi_id = p_don_vi_id and c.nam = v_nam and public._moc_so(c.nhan) <= v_md
  order by public._moc_so(c.nhan) desc, c.thu_tu desc, c.id desc
  limit 1;

  -- chưa tới mốc nào trong năm → dùng mốc sớm nhất của năm (như trước)
  if v_cot_id is null then
    select c.id into v_cot_id
    from public.dinh_bien_cot c
    where c.don_vi_id = p_don_vi_id and c.nam = v_nam
    order by coalesce(public._moc_so(c.nhan), 9999), c.thu_tu, c.id
    limit 1;
  end if;
  if v_cot_id is null then return; end if;

  return query
  select cd.id, cd.ten, cd.ten_tat, coalesce(gt.so_luong, 0)::numeric, cd.thu_tu, coalesce(cd.an, false)
  from public.dinh_bien_chuc_danh cd
  left join public.dinh_bien_gia_tri gt on gt.chuc_danh_id = cd.id and gt.cot_id = v_cot_id
  where cd.don_vi_id = p_don_vi_id
  order by cd.thu_tu, cd.id;
end $$;

-- Kiểm tra: mỗi đơn vị hôm nay đang dùng mốc nào (phải là 01/10 nếu có các mốc 01/10, 01/11, 01/12)
select distinct on (c.don_vi_id) c.don_vi_id, c.nhan as moc_dang_dung
from public.dinh_bien_cot c
where c.nam = extract(year from now())::int
  and public._moc_so(c.nhan) <= extract(month from now())::int * 100 + extract(day from now())::int
order by c.don_vi_id, public._moc_so(c.nhan) desc;
