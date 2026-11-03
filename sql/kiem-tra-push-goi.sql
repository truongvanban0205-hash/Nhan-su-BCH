-- KIỂM TRA: lúc gọi điện, máy chủ có gửi thông báo đẩy tới điện thoại người nghe không?
-- Chỉ ĐỌC, không sửa gì. Chạy trong Supabase → SQL Editor ngay sau khi thử gọi 1 cuộc.

-- 1. 10 cuộc gọi gần nhất (giờ Việt Nam)
select id, loai, trang_thai,
       to_char(tao_luc at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI:SS DD/MM') as luc_goi,
       nguoi_goi, nguoi_nghe
from public.ht_cuoc_goi order by id desc limit 10;

-- 2. Kết quả gọi hàm gửi thông báo (gui-push) gần nhất:
--    status_code 200 + {"da_gui":1} trở lên = đã gửi tới điện thoại; {"da_gui":0} = người nghe chưa đăng ký nhận thông báo
select id, status_code, content::text as ket_qua,
       to_char(created at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI:SS DD/MM') as luc
from net._http_response order by id desc limit 10;

-- 3. Số thiết bị đã bật nhận thông báo của từng người
select employee_id, count(*) as so_thiet_bi from public.ht_dang_ky_push group by employee_id order by employee_id;
