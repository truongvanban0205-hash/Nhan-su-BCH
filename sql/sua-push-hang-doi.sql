-- KHỞI ĐỘNG LẠI BỘ GỬI THÔNG BÁO (pg_net) khi bị treo. Không xoá, không sửa dữ liệu nào.
-- Các thông báo đang chờ sẽ được gửi tiếp ngay sau khi chạy.
select net.worker_restart() as da_khoi_dong_lai;
