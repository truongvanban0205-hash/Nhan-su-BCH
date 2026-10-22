-- =====================================================================
-- Bảng bộ phận: trả thêm "ai của bộ phận đã vào báo cáo hôm đó" (để chạm vào ô xem tên).
-- Chỉ thay hàm nhansu_lay_bo_phan (cùng tham số), không đụng dữ liệu. Chạy 1 lần.
-- =====================================================================
create or replace function public.nhansu_lay_bo_phan(p_ten text, p_pin text, p_ngay text, p_don_vi_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d jsonb; v_emp bigint; v_bp bigint; v_ed jsonb;
begin
  d := public._nv_xac_thuc(p_ten, p_pin, p_don_vi_id);
  select id into v_emp from public.employees where lower(trim(ten)) = lower(trim(d ->> 'ten')) order by id limit 1;
  select bo_phan_id into v_bp from public.employee_don_vi where employee_id = v_emp and don_vi_id = p_don_vi_id;
  select coalesce(data -> 'editors', '{}'::jsonb) into v_ed
    from public.nhansu where ngay = p_ngay and don_vi_id = p_don_vi_id order by id limit 1;
  return jsonb_build_object(
    'cua_toi', v_bp,
    'bo_phan', public.bo_phan_lay_danh_sach(p_don_vi_id),
    'trang_thai', (select coalesce(jsonb_object_agg(t.bo_phan_id::text, jsonb_build_object(
                      'dn', t.dn, 'sua', t.sua, 'thay', t.thay, 'thay_boi', t.thay_boi)), '{}'::jsonb)
                   from public.nhansu_bo_phan t where t.don_vi_id = p_don_vi_id and t.ngay = p_ngay),
    -- {bo_phan_id: "Tên A, Tên B"} — người thuộc bộ phận có trong danh sách đã vào / đã sửa của ngày đó
    'nguoi', (select coalesce(jsonb_object_agg(x.bp::text, x.ds), '{}'::jsonb) from (
                select m.bo_phan_id as bp, string_agg(distinct e.ten, ', ') as ds
                from jsonb_object_keys(coalesce(v_ed, '{}'::jsonb)) k
                join public.employees e on lower(trim(e.ten)) = lower(trim(split_part(k, ' - ', 1)))
                join public.employee_don_vi m on m.employee_id = e.id and m.don_vi_id = p_don_vi_id
                where m.bo_phan_id is not null
                group by m.bo_phan_id) x));
end $$;
