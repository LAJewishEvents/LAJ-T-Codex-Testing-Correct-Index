-- Durable organization subscriptions and notifications for LA Jewish Tonight.
--
-- Security caveat for the current static frontend prototype:
-- Some existing profiles are browser-generated UUIDs and may not equal auth.uid().
-- The SECURITY DEFINER follow/unfollow RPCs therefore allow anon callers to pass a
-- profile_id for compatibility. When Supabase Auth is present, the RPCs enforce
-- auth.uid() = p_profile_id. Move to authenticated-only execution once all
-- profiles are auth-owned.

create extension if not exists pgcrypto;

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  normalized_name text unique not null,
  description text,
  region text,
  category_tags text[] default '{}'::text[],
  logo_url text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists public.organization_follows (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (profile_id, organization_id)
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  organization_id uuid references public.organizations(id) on delete cascade,
  event_id text,
  title text not null,
  body text,
  data jsonb default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz default now()
);

alter table public.organizations
  add constraint organizations_slug_not_blank check (btrim(slug) <> ''),
  add constraint organizations_name_not_blank check (btrim(name) <> ''),
  add constraint organizations_normalized_name_not_blank check (btrim(normalized_name) <> '');

alter table public.notifications
  add constraint notifications_type_allowed check (type in ('org_new_event', 'friend_request', 'friend_accepted'));

create index if not exists organization_follows_profile_id_idx
  on public.organization_follows (profile_id);
create index if not exists organization_follows_organization_id_idx
  on public.organization_follows (organization_id);
create index if not exists notifications_profile_id_idx
  on public.notifications (profile_id);
create index if not exists notifications_read_at_idx
  on public.notifications (read_at);
create index if not exists notifications_created_at_desc_idx
  on public.notifications (created_at desc);
create index if not exists notifications_type_idx
  on public.notifications (type);
create index if not exists notifications_organization_id_idx
  on public.notifications (organization_id);
create index if not exists organizations_normalized_name_idx
  on public.organizations (normalized_name);
create index if not exists organizations_slug_idx
  on public.organizations (slug);

create unique index if not exists notifications_org_event_unique_idx
  on public.notifications (profile_id, type, organization_id, event_id)
  where type = 'org_new_event' and organization_id is not null and event_id is not null;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists organizations_touch_updated_at on public.organizations;
create trigger organizations_touch_updated_at
before update on public.organizations
for each row execute function public.touch_updated_at();

create or replace function public.normalize_organization_name(p_org_name text)
returns text
language sql
immutable
as $$
  select nullif(regexp_replace(lower(btrim(coalesce(p_org_name, ''))), '[^a-z0-9]+', ' ', 'g'), '')
$$;

create or replace function public.organization_slug_from_name(p_org_name text)
returns text
language sql
immutable
as $$
  select coalesce(
    nullif(regexp_replace(lower(btrim(coalesce(p_org_name, ''))), '[^a-z0-9]+', '-', 'g'), ''),
    'organization'
  )
$$;

create or replace function public.upsert_organization_from_event(
  p_org_name text,
  p_region text default null,
  p_category_tags text[] default '{}'::text[]
)
returns public.organizations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := nullif(btrim(coalesce(p_org_name, '')), '');
  v_normalized text;
  v_slug text;
  v_org public.organizations;
begin
  if v_name is null then
    raise exception 'Organization name is required' using errcode = '22023';
  end if;

  v_normalized := public.normalize_organization_name(v_name);
  if v_normalized is null then
    raise exception 'Organization name is invalid' using errcode = '22023';
  end if;
  v_slug := public.organization_slug_from_name(v_name);

  insert into public.organizations (slug, name, normalized_name, region, category_tags)
  values (v_slug, v_name, v_normalized, nullif(btrim(p_region), ''), coalesce(p_category_tags, '{}'::text[]))
  on conflict (normalized_name) do update
    set
      name = excluded.name,
      region = coalesce(public.organizations.region, excluded.region),
      category_tags = (
        select coalesce(array_agg(distinct tag order by tag), '{}'::text[])
        from unnest(coalesce(public.organizations.category_tags, '{}'::text[]) || coalesce(excluded.category_tags, '{}'::text[])) as tag
        where nullif(btrim(tag), '') is not null
      )
  returning * into v_org;

  return v_org;
end;
$$;

create or replace function public.follow_organization(
  p_profile_id uuid,
  p_org_name text
)
returns table (organization_id uuid, followed boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
begin
  if p_profile_id is null then
    raise exception 'profile_id is required' using errcode = '22023';
  end if;

  -- Authenticated users may only mutate their own follows. Anon is allowed for
  -- compatibility with current static/local-profile prototype IDs.
  if auth.uid() is not null and auth.uid() <> p_profile_id then
    raise exception 'Cannot follow organization for another profile' using errcode = '42501';
  end if;

  v_org := public.upsert_organization_from_event(p_org_name, null, '{}'::text[]);

  insert into public.organization_follows (profile_id, organization_id)
  values (p_profile_id, v_org.id)
  on conflict (profile_id, organization_id) do nothing;

  organization_id := v_org.id;
  followed := true;
  return next;
end;
$$;

create or replace function public.unfollow_organization(
  p_profile_id uuid,
  p_org_name text
)
returns table (organization_id uuid, followed boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_normalized text := public.normalize_organization_name(p_org_name);
  v_org_id uuid;
begin
  if p_profile_id is null then
    raise exception 'profile_id is required' using errcode = '22023';
  end if;

  if auth.uid() is not null and auth.uid() <> p_profile_id then
    raise exception 'Cannot unfollow organization for another profile' using errcode = '42501';
  end if;

  select id into v_org_id
  from public.organizations
  where normalized_name = v_normalized;

  if v_org_id is not null then
    delete from public.organization_follows
    where profile_id = p_profile_id and organization_id = v_org_id;
  end if;

  organization_id := v_org_id;
  followed := false;
  return next;
end;
$$;

create or replace function public.create_org_event_notifications(
  p_org_name text,
  p_event_id text,
  p_event_title text,
  p_event_start text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
  v_inserted integer := 0;
begin
  if nullif(btrim(coalesce(p_event_id, '')), '') is null then
    raise exception 'event_id is required' using errcode = '22023';
  end if;

  v_org := public.upsert_organization_from_event(p_org_name, null, '{}'::text[]);

  insert into public.notifications (
    profile_id,
    type,
    organization_id,
    event_id,
    title,
    body,
    data
  )
  select
    f.profile_id,
    'org_new_event',
    v_org.id,
    p_event_id,
    'New event from ' || v_org.name,
    p_event_title,
    jsonb_build_object(
      'event_title', p_event_title,
      'event_start', p_event_start,
      'organization_name', v_org.name
    )
  from public.organization_follows f
  where f.organization_id = v_org.id
  on conflict (profile_id, type, organization_id, event_id) where type = 'org_new_event' and organization_id is not null and event_id is not null
  do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

alter table public.organizations enable row level security;
alter table public.organization_follows enable row level security;
alter table public.notifications enable row level security;

-- Organizations are public catalog data for the static frontend.
drop policy if exists "Organizations are readable" on public.organizations;
create policy "Organizations are readable"
  on public.organizations
  for select
  to anon, authenticated
  using (true);

-- Follows are private to the owning authenticated profile for direct reads.
-- Current anon/static compatibility should use SECURITY DEFINER RPCs, not direct table writes.
drop policy if exists "Users can read their own organization follows" on public.organization_follows;
create policy "Users can read their own organization follows"
  on public.organization_follows
  for select
  to authenticated
  using (auth.uid() = profile_id);

-- Notifications are private to the owning authenticated profile for direct reads/updates.
drop policy if exists "Users can read their own notifications" on public.notifications;
create policy "Users can read their own notifications"
  on public.notifications
  for select
  to authenticated
  using (auth.uid() = profile_id);

drop policy if exists "Users can mark their own notifications read" on public.notifications;
create policy "Users can mark their own notifications read"
  on public.notifications
  for update
  to authenticated
  using (auth.uid() = profile_id)
  with check (auth.uid() = profile_id);

revoke all on public.organizations from anon, authenticated;
revoke all on public.organization_follows from anon, authenticated;
revoke all on public.notifications from anon, authenticated;

grant select on public.organizations to anon, authenticated;
grant select on public.organization_follows to authenticated;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

grant execute on function public.upsert_organization_from_event(text, text, text[]) to anon, authenticated;
grant execute on function public.follow_organization(uuid, text) to anon, authenticated;
grant execute on function public.unfollow_organization(uuid, text) to anon, authenticated;
-- Notification fan-out should normally be called from trusted ingestion/admin code.
-- Authenticated execute is granted for controlled internal tooling; do not call this
-- directly from the public static frontend. Service role bypasses grants when used server-side.
grant execute on function public.create_org_event_notifications(text, text, text, text) to authenticated;
