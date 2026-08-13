-- Durable, first-party organization logo cache.
alter table public.organizations
  add column if not exists website_url text,
  add column if not exists logo_source text,
  add column if not exists logo_storage_path text,
  add column if not exists logo_updated_at timestamptz;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'organization-logos',
  'organization-logos',
  true,
  5242880,
  array['image/png','image/jpeg','image/webp','image/gif','image/svg+xml']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public read organization logos" on storage.objects;
create policy "Public read organization logos"
on storage.objects for select
using (bucket_id = 'organization-logos');

comment on column public.organizations.logo_url is
  'Permanent public URL of the LAJT-owned Supabase Storage copy.';
comment on column public.organizations.logo_source is
  'Original official-site image URL used to produce the cached copy.';
comment on column public.organizations.logo_storage_path is
  'Object path inside the organization-logos Storage bucket.';
