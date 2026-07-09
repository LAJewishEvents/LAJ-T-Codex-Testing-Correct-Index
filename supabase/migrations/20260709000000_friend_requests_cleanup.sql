begin;

-- Preview before applying manually:
-- select *
-- from public.friend_requests
-- order by created_at desc
-- limit 25;

-- Ensure status exists and defaults correctly.
alter table public.friend_requests
alter column status set default 'pending';

-- Track friend-request responses and edits.
alter table public.friend_requests
add column if not exists updated_at timestamptz default now();

-- Prevent duplicate pending requests from the same person to the same person.
create unique index if not exists friend_requests_unique_pending_pair
on public.friend_requests (from_profile_id, to_profile_id)
where status = 'pending';

-- Remove broken/fake request rows with missing users.
delete from public.friend_requests
where from_profile_id is null
   or to_profile_id is null;

-- Remove self-requests.
delete from public.friend_requests
where from_profile_id = to_profile_id;

-- Remove obvious WhatsApp placeholder/fake rows only when profile refs are broken.
delete from public.friend_requests fr
where not exists (
  select 1 from public.profiles p where p.id = fr.from_profile_id
)
or not exists (
  select 1 from public.profiles p where p.id = fr.to_profile_id
);

-- Verify after applying manually:
-- select
--   status,
--   count(*) as count
-- from public.friend_requests
-- group by status
-- order by status;

commit;
