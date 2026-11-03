-- KIỂM TRA HÀNG ĐỢI GỬI THÔNG BÁO (pg_net) — chỉ đọc, chạy trong Supabase → SQL Editor
-- con_cho_gui > 0 mà không giảm sau 1 phút = bộ gửi của máy chủ đang bị treo → chạy file sua-push-hang-doi.sql
select (select count(*) from net.http_request_queue) as con_cho_gui,
       (select to_char(max(created) at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI:SS DD/MM') from net._http_response) as lan_gui_cuoi,
       to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI:SS DD/MM') as bay_gio;
