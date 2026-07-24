-- Canonical, categorized organization subscriptions sourced from public.events.
-- This migration deliberately reads event rows as jsonb so it works with the
-- deployed event schema as well as older LAJT schemas using organizer/org/host.

create extension if not exists pgcrypto;

create table if not exists public.organization_categories (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null unique,
  description text,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.organization_categories (slug, name, description, sort_order) values
  ('synagogues', 'Synagogues & Minyans', 'Synagogues, shuls, and prayer communities', 10),
  ('young-adults', 'Young Adults', 'Young-professional and young-adult communities', 20),
  ('campus', 'Campus', 'Campus Jewish life and alumni communities', 30),
  ('culture', 'Arts & Culture', 'Jewish arts, culture, media, and learning', 40),
  ('social-action', 'Social Action', 'Service, advocacy, and mutual aid', 50),
  ('community', 'Community Organizations', 'Community-wide organizations and institutions', 90)
on conflict (slug) do update set
  name = excluded.name, description = excluded.description,
  sort_order = excluded.sort_order, updated_at = now();

alter table public.organizations
  add column if not exists category_id uuid references public.organization_categories(id),
  add column if not exists active boolean not null default true,
  add column if not exists source_field text,
  add column if not exists first_seen_at timestamptz not null default now();

create table if not exists public.organization_aliases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  alias text not null,
  normalized_alias text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.profile_organization_subscriptions (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (profile_id, organization_id)
);

create table if not exists public.organization_event_notification_log (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  event_id text not null,
  notification_id text,
  created_at timestamptz not null default now(),
  primary key (profile_id, organization_id, event_id)
);

create index if not exists idx_organizations_category on public.organizations(category_id) where active;
create index if not exists idx_org_aliases_organization on public.organization_aliases(organization_id);
create index if not exists idx_profile_org_subscriptions_org on public.profile_organization_subscriptions(organization_id);
create index if not exists idx_org_notification_log_event on public.organization_event_notification_log(event_id);

create or replace function public.organization_name_from_event(p_event jsonb)
returns table(name text, source_field text)
language sql immutable as $$
  with candidates(field_name, field_value, priority) as (values
    ('organization', p_event->>'organization', 1),
    ('organizer', p_event->>'organizer', 2),
    ('org', p_event->>'org', 3),
    ('host', p_event->>'host', 4),
    ('calendar_name', coalesce(p_event->>'calendar_name', p_event->>'calendarName'), 5),
    ('source_organization_id', p_event->>'source_organization_id', 6)
  )
  select nullif(regexp_replace(trim(field_value), '\s+', ' ', 'g'), ''), field_name
  from candidates
  where nullif(trim(coalesce(field_value, '')), '') is not null
  order by priority limit 1;
$$;

create or replace function public.infer_organization_category(p_name text, p_event jsonb default '{}'::jsonb)
returns uuid language sql stable set search_path = public as $$
  select id from public.organization_categories
  where slug = case
    when lower(coalesce(p_name,'') || ' ' || coalesce(p_event->>'category','')) ~ '(synagogue|shul|minyan|temple|chabad)' then 'synagogues'
    when lower(coalesce(p_name,'') || ' ' || coalesce(p_event->>'category','')) ~ '(hillel|campus|university|college|student)' then 'campus'
    when lower(coalesce(p_name,'') || ' ' || coalesce(p_event->>'category','')) ~ '(young adult|young professional|\byjp\b|moishe)' then 'young-adults'
    when lower(coalesce(p_name,'') || ' ' || coalesce(p_event->>'category','')) ~ '(art|culture|museum|film|music|learning|education)' then 'culture'
    when lower(coalesce(p_name,'') || ' ' || coalesce(p_event->>'category','')) ~ '(service|action|advocacy|volunteer|justice)' then 'social-action'
    else 'community' end limit 1;
$$;

create or replace function public.register_organization_event(p_event jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_name text; v_source text; v_normalized text; v_org_id uuid; v_event_id text;
  v_title text; v_start text; v_location text; v_url text; v_inserted boolean := false;
  v_sub record; v_notification_id text; v_payload jsonb;
begin
  select x.name, x.source_field into v_name, v_source from public.organization_name_from_event(p_event) x;
  if v_name is null or lower(v_name) in ('community', 'community event') then return null; end if;
  v_normalized := public.normalize_organization_name(v_name);
  v_event_id := coalesce(nullif(p_event->>'id',''), nullif(p_event->>'event_id',''));
  if v_event_id is null then return null; end if;

  select organization_id into v_org_id from public.organization_aliases where normalized_alias = v_normalized;
  if v_org_id is null then
    insert into public.organizations (slug, name, normalized_name, category_id, source_field, last_seen_at, updated_at)
    values (public.slugify_organization_name(v_name), v_name, v_normalized,
            public.infer_organization_category(v_name, p_event), v_source, now(), now())
    on conflict (normalized_name) do update set
      last_seen_at = now(), updated_at = now(), active = true,
      source_field = coalesce(public.organizations.source_field, excluded.source_field),
      category_id = coalesce(public.organizations.category_id, excluded.category_id)
    returning id into v_org_id;
  end if;
  insert into public.organization_aliases(organization_id, alias, normalized_alias)
  values(v_org_id, v_name, v_normalized) on conflict (normalized_alias) do nothing;

  v_title := coalesce(p_event->>'title', p_event->>'name', 'New event');
  v_start := coalesce(p_event->>'start_time', p_event->>'starts_at', p_event->>'date');
  v_location := coalesce(p_event->>'location', p_event->>'venue', p_event->>'address');
  v_url := coalesce(p_event->>'rsvp_link', p_event->>'public_event_url', p_event->>'event_url', p_event->>'url');
  insert into public.organization_events(organization_id,event_id,event_title,event_start,event_location,event_url,updated_at)
  values(v_org_id,v_event_id,v_title,v_start,v_location,v_url,now())
  on conflict (organization_id,event_id) do update set event_title=excluded.event_title,
    event_start=excluded.event_start,event_location=excluded.event_location,event_url=excluded.event_url,updated_at=now()
  returning (xmax = 0) into v_inserted;
  update public.organizations set event_count=(select count(*) from public.organization_events where organization_id=v_org_id), last_seen_at=now(), updated_at=now() where id=v_org_id;

  -- Updates never fan out notifications; only a genuinely new registry/event pair does.
  if v_inserted and coalesce(current_setting('lajt.organization_backfill', true), 'false') <> 'true' then
    for v_sub in select profile_id from public.profile_organization_subscriptions where organization_id=v_org_id loop
      insert into public.organization_event_notification_log(profile_id,organization_id,event_id)
      values(v_sub.profile_id,v_org_id,v_event_id) on conflict do nothing;
      if found then
        v_payload := jsonb_build_object('profile_id',v_sub.profile_id,'type','org_new_event',
          'title','New event from ' || v_name,'body',v_title,'entity_type','event','entity_id',v_event_id,
          'organization_id',v_org_id,'event_id',v_event_id,
          'metadata',jsonb_build_object('event_id',v_event_id,'organization_id',v_org_id,'organization_name',v_name),
          'data',jsonb_build_object('event_title',v_title,'event_start',v_start,'organization_name',v_name));
        begin
          execute 'insert into public.notifications select (jsonb_populate_record(null::public.notifications, $1)).* returning id::text' into v_notification_id using v_payload;
          update public.organization_event_notification_log set notification_id=v_notification_id
          where profile_id=v_sub.profile_id and organization_id=v_org_id and event_id=v_event_id;
        exception when others then
          raise warning 'Organization notification insert failed for profile %: %', v_sub.profile_id, sqlerrm;
        end;
      end if;
    end loop;
  end if;
  return v_org_id;
end;
$$;

create or replace function public.events_register_organization_trigger()
returns trigger language plpgsql security definer set search_path=public as $$
begin perform public.register_organization_event(to_jsonb(new)); return new; end;
$$;

drop trigger if exists events_register_organization on public.events;
create trigger events_register_organization after insert or update on public.events
for each row execute function public.events_register_organization_trigger();

-- Backfill every existing event; aliases and the event log make this idempotent.
do $$ declare r record; begin
  perform set_config('lajt.organization_backfill', 'true', true);
  for r in select to_jsonb(e) payload from public.events e loop
    perform public.register_organization_event(r.payload);
  end loop;
  perform set_config('lajt.organization_backfill', 'false', true);
end $$;

-- Preserve the earlier organization_follows API while making the canonical table authoritative.
insert into public.profile_organization_subscriptions(profile_id, organization_id, created_at)
select profile_id, organization_id, created_at from public.organization_follows on conflict do nothing;

create or replace function public.set_organization_subscription(p_organization_id uuid, p_subscribed boolean)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_subscribed then
    insert into public.profile_organization_subscriptions(profile_id,organization_id)
    values(auth.uid(),p_organization_id) on conflict do nothing;
  else
    delete from public.profile_organization_subscriptions where profile_id=auth.uid() and organization_id=p_organization_id;
  end if;
  return p_subscribed;
end;
$$;

alter table public.organization_categories enable row level security;
alter table public.organization_aliases enable row level security;
alter table public.profile_organization_subscriptions enable row level security;
alter table public.organization_event_notification_log enable row level security;
drop policy if exists "Public read organization categories" on public.organization_categories;
create policy "Public read organization categories" on public.organization_categories for select using (true);
drop policy if exists "Public read organization aliases" on public.organization_aliases;
create policy "Public read organization aliases" on public.organization_aliases for select using (true);
drop policy if exists "Users read own organization subscriptions" on public.profile_organization_subscriptions;
create policy "Users read own organization subscriptions" on public.profile_organization_subscriptions for select using (profile_id=auth.uid());
drop policy if exists "Users manage own organization subscriptions" on public.profile_organization_subscriptions;
create policy "Users manage own organization subscriptions" on public.profile_organization_subscriptions for all using (profile_id=auth.uid()) with check (profile_id=auth.uid());
drop policy if exists "Users read own organization notification log" on public.organization_event_notification_log;
create policy "Users read own organization notification log" on public.organization_event_notification_log for select using (profile_id=auth.uid());

grant select on public.organization_categories, public.organizations, public.organization_aliases to anon, authenticated;
grant select, insert, delete on public.profile_organization_subscriptions to authenticated;
grant execute on function public.set_organization_subscription(uuid,boolean) to authenticated;
revoke execute on function public.register_organization_event(jsonb) from public, anon, authenticated;
revoke execute on function public.upsert_organization_from_event(text,text,text[],int) from public, anon, authenticated;
revoke execute on function public.upsert_organization_event(text,text,text,text,text,text,text,text[]) from public, anon, authenticated;
revoke execute on function public.follow_organization(uuid,text) from public, anon, authenticated;
revoke execute on function public.unfollow_organization(uuid,text) from public, anon, authenticated;
