-- Organizations derived from event feeds for LA Jewish Tonight.
-- Prototype caveat: follow_organization/unfollow_organization accept p_profile_id from
-- the static frontend. In production, prefer auth.uid() ownership checks when profiles are
-- backed by authenticated Supabase users.

create extension if not exists pgcrypto;

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  normalized_name text unique not null,
  description text,
  region text,
  category_tags text[] default '{}',
  logo_url text,
  event_count int default 0,
  last_seen_at timestamptz default now(),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists public.organization_events (
  organization_id uuid references public.organizations(id) on delete cascade,
  event_id text not null,
  event_title text,
  event_start text,
  event_location text,
  event_url text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  primary key (organization_id, event_id)
);

create table if not exists public.organization_follows (
  profile_id uuid references public.profiles(id) on delete cascade,
  organization_id uuid references public.organizations(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (profile_id, organization_id)
);

create index if not exists idx_organizations_normalized_name on public.organizations(normalized_name);
create index if not exists idx_organizations_slug on public.organizations(slug);
create index if not exists idx_organizations_name on public.organizations(name);
create index if not exists idx_organizations_region on public.organizations(region);
create index if not exists idx_organization_events_organization_id on public.organization_events(organization_id);
create index if not exists idx_organization_events_event_id on public.organization_events(event_id);
create index if not exists idx_organization_follows_profile_id on public.organization_follows(profile_id);
create index if not exists idx_organization_follows_organization_id on public.organization_follows(organization_id);

alter table public.organizations enable row level security;
alter table public.organization_events enable row level security;
alter table public.organization_follows enable row level security;

drop policy if exists "Public read organizations" on public.organizations;
create policy "Public read organizations" on public.organizations for select using (true);

drop policy if exists "Public read organization events" on public.organization_events;
create policy "Public read organization events" on public.organization_events for select using (true);

drop policy if exists "Public read organization follows" on public.organization_follows;
create policy "Public read organization follows" on public.organization_follows for select using (true);

create or replace function public.normalize_organization_name(p_name text)
returns text
language sql
immutable
as $$
  select lower(regexp_replace(trim(coalesce(p_name, 'Community')), '\s+', ' ', 'g'));
$$;

create or replace function public.slugify_organization_name(p_name text)
returns text
language sql
immutable
as $$
  select trim(both '-' from regexp_replace(lower(regexp_replace(coalesce(p_name, 'community'), '[^a-zA-Z0-9]+', '-', 'g')), '-+', '-', 'g'));
$$;

create or replace function public.upsert_organization_from_event(
  p_org_name text,
  p_region text default null,
  p_category_tags text[] default '{}',
  p_event_count int default 0
)
returns public.organizations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
  v_name text := nullif(trim(coalesce(p_org_name, 'Community')), '');
  v_normalized text;
  v_slug text;
begin
  v_name := coalesce(v_name, 'Community');
  v_normalized := public.normalize_organization_name(v_name);
  v_slug := public.slugify_organization_name(v_name);

  insert into public.organizations (slug, name, normalized_name, region, category_tags, event_count, last_seen_at, updated_at)
  values (v_slug, v_name, v_normalized, p_region, coalesce(p_category_tags, '{}'), coalesce(p_event_count, 0), now(), now())
  on conflict (normalized_name) do update set
    name = excluded.name,
    region = coalesce(excluded.region, public.organizations.region),
    category_tags = coalesce(excluded.category_tags, public.organizations.category_tags),
    event_count = greatest(public.organizations.event_count, excluded.event_count),
    last_seen_at = now(),
    updated_at = now()
  returning * into v_org;

  return v_org;
end;
$$;

create or replace function public.upsert_organization_event(
  p_org_name text,
  p_event_id text,
  p_event_title text default null,
  p_event_start text default null,
  p_event_location text default null,
  p_event_url text default null,
  p_region text default null,
  p_category_tags text[] default '{}'
)
returns public.organization_events
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
  v_event public.organization_events;
begin
  if nullif(trim(coalesce(p_event_id, '')), '') is null then
    raise exception 'event_id is required';
  end if;

  v_org := public.upsert_organization_from_event(p_org_name, p_region, p_category_tags, 1);

  insert into public.organization_events (organization_id, event_id, event_title, event_start, event_location, event_url, updated_at)
  values (v_org.id, p_event_id, p_event_title, p_event_start, p_event_location, p_event_url, now())
  on conflict (organization_id, event_id) do update set
    event_title = excluded.event_title,
    event_start = excluded.event_start,
    event_location = excluded.event_location,
    event_url = excluded.event_url,
    updated_at = now()
  returning * into v_event;

  return v_event;
end;
$$;

create or replace function public.search_organizations(
  p_query text,
  p_limit int default 30
)
returns setof public.organizations
language sql
stable
security definer
set search_path = public
as $$
  select *
  from public.organizations
  where nullif(trim(coalesce(p_query, '')), '') is not null
    and (
      name ilike '%' || p_query || '%'
      or normalized_name ilike '%' || public.normalize_organization_name(p_query) || '%'
      or slug ilike '%' || public.slugify_organization_name(p_query) || '%'
      or region ilike '%' || p_query || '%'
      or exists (select 1 from unnest(category_tags) tag where tag ilike '%' || p_query || '%')
    )
  order by event_count desc, last_seen_at desc, name asc
  limit greatest(1, least(coalesce(p_limit, 30), 100));
$$;

create or replace function public.follow_organization(
  p_profile_id uuid,
  p_org_name text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
begin
  v_org := public.upsert_organization_from_event(p_org_name, null, '{}', 0);
  insert into public.organization_follows (profile_id, organization_id)
  values (p_profile_id, v_org.id)
  on conflict do nothing;
  return true;
end;
$$;

create or replace function public.unfollow_organization(
  p_profile_id uuid,
  p_org_name text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  select id into v_org_id
  from public.organizations
  where normalized_name = public.normalize_organization_name(p_org_name)
     or slug = public.slugify_organization_name(p_org_name)
  limit 1;

  if v_org_id is not null then
    delete from public.organization_follows
    where profile_id = p_profile_id and organization_id = v_org_id;
  end if;
  return true;
end;
$$;

grant execute on function public.upsert_organization_from_event(text,text,text[],int) to anon, authenticated;
grant execute on function public.upsert_organization_event(text,text,text,text,text,text,text,text[]) to anon, authenticated;
grant execute on function public.search_organizations(text,int) to anon, authenticated;
grant execute on function public.follow_organization(uuid,text) to anon, authenticated;
grant execute on function public.unfollow_organization(uuid,text) to anon, authenticated;
