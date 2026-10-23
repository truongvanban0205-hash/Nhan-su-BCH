-- =====================================================================
-- KIỂM TRA PHẦN 1 — chạy SAU chat-1.sql. Tự thử toàn bộ luồng chat với 2 nhân viên thật
-- bằng thẻ phiên tạm, rồi HOÀN TÁC (rollback) → không để lại gì trong database.
-- Kết quả hiện ở ô báo lỗi màu đỏ (cố ý báo lỗi để HOÀN TÁC): mỗi dòng 1 bước, phải là "OK".
-- =====================================================================
do $$
declare bc text := ''; a bigint; b bigint; ht bigint; nhom bigint; t1 bigint; r jsonb; n int; v text;
begin
  select e.id into a from public.employees e where exists (select 1 from public.employee_don_vi m where m.employee_id = e.id and m.trang_thai = 'da_duyet') order by e.id limit 1;
  select e.id into b from public.employees e where e.id <> a and exists (select 1 from public.employee_don_vi m where m.employee_id = e.id and m.trang_thai = 'da_duyet') order by e.id limit 1;
  insert into public.phien_nhieu_may (token, employee_id) values ('test_a_' || a, a), ('test_b_' || b, b);

  -- thẻ sai phải bị chặn
  begin perform public.ht_toi('the_sai'); bc := bc || 'Thẻ sai bị chặn' || ': ' || 'LỖI: không bị chặn' || chr(10);
  exception when others then bc := bc || 'Thẻ sai bị chặn' || ': ' || case when sqlerrm = 'CHUA_DANG_NHAP' then 'OK' else sqlerrm end || chr(10); end;

  r := public.ht_toi('test_a_' || a);
  bc := bc || 'ht_toi trả đúng người + kênh' || ': ' || case when (r->>'id')::bigint = a and r->>'kenh' is not null then 'OK' else r::text end || chr(10);

  ht := public.ht_mo_rieng('test_a_' || a, b);
  bc := bc || 'Mở chat 1-1 (gọi 2 lần ra cùng 1 hội thoại)' || ': ' || case when public.ht_mo_rieng('test_b_' || b, a) = ht then 'OK' else 'LỖI' end || chr(10);

  t1 := (public.ht_gui('test_a_' || a, ht, 'Xin chào (tin thử)') ->> 'id')::bigint;
  bc := bc || 'Gửi tin' || ': ' || case when t1 is not null then 'OK' else 'LỖI' end || chr(10);

  r := public.ht_danh_sach('test_b_' || b);
  select (x->>'chua_doc')::int into n from jsonb_array_elements(r) x where (x->>'id')::bigint = ht;
  bc := bc || 'Người nhận thấy 1 tin chưa đọc' || ': ' || case when n = 1 then 'OK' else 'LỖI: ' || coalesce(n::text, 'không thấy') end || chr(10);

  perform public.ht_da_xem('test_b_' || b, ht, t1);
  bc := bc || 'Đã xem → hết chưa đọc' || ': ' || case when public.ht_tong_chua_doc('test_b_' || b) = 0 then 'OK' else 'LỖI' end || chr(10);

  perform public.ht_cam_xuc('test_b_' || b, t1, '❤️');
  r := public.ht_lay_tin('test_a_' || a, ht);
  bc := bc || 'Thả cảm xúc + lấy tin' || ': ' || case when r->0->'cam_xuc'->0->>'cx' = '❤️' and r->0->>'noi_dung' = 'Xin chào (tin thử)' then 'OK' else r::text end || chr(10);

  perform public.ht_thu_hoi('test_a_' || a, t1);
  r := public.ht_lay_tin('test_b_' || b, ht);
  bc := bc || 'Thu hồi tin' || ': ' || case when (r->0->>'thu_hoi')::boolean and r->0->>'noi_dung' is null then 'OK' else 'LỖI' end || chr(10);

  nhom := public.ht_tao_nhom('test_a_' || a, 'Nhóm thử', array[b]);
  bc := bc || 'Tạo nhóm (2 thành viên)' || ': ' || case when jsonb_array_length(public.ht_thong_tin('test_b_' || b, nhom)->'thanh_vien') = 2 then 'OK' else 'LỖI' end || chr(10);

  -- người KHÔNG phải thành viên không đọc được (dùng 1 hội thoại mà b không có mặt)
  perform public.ht_xoa_tv('test_b_' || b, nhom, b);
  begin perform public.ht_lay_tin('test_b_' || b, nhom); bc := bc || 'Rời nhóm → không đọc được tin nhóm' || ': ' || 'LỖI: vẫn đọc được' || chr(10);
  exception when others then bc := bc || 'Rời nhóm → không đọc được tin nhóm' || ': ' || case when sqlerrm = 'KHONG_PHAI_THANH_VIEN' then 'OK' else sqlerrm end || chr(10); end;

  -- người ngoài không đọc thẳng bảng được
  select string_agg(table_name, ', ') into v from information_schema.role_table_grants
   where grantee = 'anon' and table_schema = 'public' and table_name like 'ht\_%';
  bc := bc || 'Người ngoài không có quyền đọc bảng ht_*' || ': ' || case when v is null then 'OK' else 'LỖI: ' || v end || chr(10);

  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'realtime' and p.proname = 'send';
  bc := bc || 'Supabase có realtime.send (tin hiện ngay)' || ': ' || case when n > 0 then 'OK' else 'THIẾU — app sẽ tự làm mới 5 giây/lần' end || chr(10);
  raise exception E'KET QUA KIEM TRA (da hoan tac, khong ghi gi):\n%', bc;
end $$;
