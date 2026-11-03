-- XEM THIẾT BỊ NÀO ĐANG NHẬN THÔNG BÁO của từng người (chỉ đọc)
-- cot "thiet_bi": Android / iPhone / Windows... → biết thông báo đang gửi về điện thoại hay máy tính
select employee_id,
       case when thiet_bi ilike '%iphone%' or thiet_bi ilike '%ipad%' then 'iPhone/iPad'
            when thiet_bi ilike '%android%' then 'Android'
            when thiet_bi ilike '%windows%' then 'Máy tính Windows'
            when thiet_bi ilike '%mac os%' then 'Máy Mac'
            else 'Khác' end as loai_may,
       thiet_bi,
       case when endpoint ilike '%fcm.googleapis%' then 'Google (Chrome/Android)'
            when endpoint ilike '%push.apple%' then 'Apple'
            when endpoint ilike '%mozilla%' then 'Firefox'
            when endpoint ilike '%windows%' or endpoint ilike '%notify.windows%' then 'Microsoft Edge'
            else left(endpoint, 40) end as dich_vu
from public.ht_dang_ky_push
order by employee_id;
