-- KIỂM TRA: lúc gọi điện, máy chủ có gửi thông báo đẩy tới điện thoại người nghe không?
-- Chỉ ĐỌC, không sửa gì. Chạy trong Supabase → SQL Editor NGAY SAU khi thử gọi 1 cuộc (gộp 1 câu để editor hiện đủ).
--   Dòng "CUOC GOI": cot_3 = trạng thái, cot_5 = mã người nghe, cot_6 = số thiết bị người nghe đã bật thông báo
--   Dòng "GUI PUSH": cot_3 = mã HTTP (200 là được), cot_5 = kết quả ({"da_gui":1} = đã gửi tới điện thoại)
(select 'CUOC GOI' as loai, id::text as cot_2, trang_thai as cot_3,
        to_char(tao_luc at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI:SS DD/MM') as luc,
        nguoi_nghe::text as cot_5,
        (select count(*) from public.ht_dang_ky_push d where d.employee_id = g.nguoi_nghe)::text as cot_6
   from public.ht_cuoc_goi g order by id desc limit 5)
union all
(select 'GUI PUSH', id::text, coalesce(status_code::text, 'lỗi: ' || coalesce(error_msg, '')),
        to_char(created at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI:SS DD/MM'),
        left(coalesce(content::text, ''), 120), ''
   from net._http_response order by id desc limit 10);
