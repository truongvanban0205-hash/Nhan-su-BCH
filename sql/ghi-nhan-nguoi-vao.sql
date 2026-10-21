-- =====================================================================
-- Ghi nhận "Hôm nay: ai đã vào / ai đã sửa" — ghi thẳng 1 tên vào data.editors
-- trên server, KHÔNG ghi đè cả bản báo cáo → nhiều người vào cùng lúc không mất tên nhau.
-- Chạy 1 lần trong Supabase → SQL Editor (cần đã chạy giai-doan-1.sql trước).
-- =====================================================================
create or replace function public.ghi_nhan_nguoi_vao(
  p_ten text, p_pin text, p_bang text, p_ngay text, p_don_vi_id text, p_loai text default 'login')
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare d jsonb; v_ten text; v_loai text; v_so int;
begin
  if p_bang not in ('nhansu', 'mmtb') then raise exception 'BANG_KHONG_HOP_LE'; end if;
  d := public._nv_xac_thuc(p_ten, p_pin, p_don_vi_id);
  -- Tên hiển thị lấy từ server, cùng dạng app đang dùng: "Họ tên - Chức vụ"
  v_ten := (d ->> 'ten') || case when coalesce(d ->> 'chuc_vu', '') <> '' then ' - ' || (d ->> 'chuc_vu') else '' end;
  v_loai := case when p_loai = 'edit' then 'edit' else 'login' end;
  execute format(
    'update public.%I
        set data = jsonb_set(coalesce(data, ''{}''::jsonb), ''{editors}'',
              coalesce(data -> ''editors'', ''{}''::jsonb)
              || jsonb_build_object($1, case when data -> ''editors'' ->> $1 = ''edit'' then ''edit'' else $2 end))
      where ngay = $3 and don_vi_id = $4', p_bang)
    using v_ten, v_loai, p_ngay, p_don_vi_id;
  get diagnostics v_so = row_count;
  return v_so > 0; -- false = ngày này chưa có bản báo cáo, app sẽ thử lại sau
end $$;

revoke execute on function public.ghi_nhan_nguoi_vao(text, text, text, text, text, text) from public;
grant execute on function public.ghi_nhan_nguoi_vao(text, text, text, text, text, text) to anon, authenticated;
