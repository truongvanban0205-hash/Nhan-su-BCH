-- =====================================================================
-- HOÀN TÁC BẢO MẬT ĐỢT 2 — chỉ chạy khi báo cáo bị lỗi không lưu / không tải được sau đợt 2.
-- Trả policy về như cũ (mở cho mọi người) + bật lại realtime cũ. Dữ liệu báo cáo không bị đụng tới.
-- Chạy xong báo mình để tìm nguyên nhân rồi bật lại.
-- =====================================================================
begin;
do $$
declare b text; p record;
begin
  foreach b in array array['nhansu', 'mmtb', 'ldt'] loop
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = b loop
      execute format('drop policy %I on public.%I', p.policyname, b);
    end loop;
    execute format('create policy %I on public.%I for select to public using (true)', b || '_select_public', b);
    execute format('create policy %I on public.%I for insert to public with check (true)', b || '_insert_public', b);
    execute format('create policy %I on public.%I for update to public using (true) with check (true)', b || '_update_public', b);
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = b) then
      execute format('alter publication supabase_realtime add table public.%I', b);
    end if;
  end loop;
end $$;
commit;
