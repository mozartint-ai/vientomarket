insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'viento-assets',
  'viento-assets',
  true,
  10485760,
  array['image/jpeg', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Viento assets public read" on storage.objects;
create policy "Viento assets public read"
on storage.objects for select
to public
using (bucket_id = 'viento-assets');

-- This policy is removed by the next migration as soon as the initial media upload finishes.
drop policy if exists "Viento assets initial upload" on storage.objects;
create policy "Viento assets initial upload"
on storage.objects for insert
to anon
with check (bucket_id = 'viento-assets');

drop policy if exists "Viento assets initial update" on storage.objects;
create policy "Viento assets initial update"
on storage.objects for update
to anon
using (bucket_id = 'viento-assets')
with check (bucket_id = 'viento-assets');
