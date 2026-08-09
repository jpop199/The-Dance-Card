-- ============================================================
-- Migration: contributor role + location ownership + star ratings
-- Run this once in your existing project's SQL Editor.
-- ============================================================

-- 1a. Drop the OLD policies that reference is_developer first —
--     Postgres won't let us drop that column while they still exist.
drop policy if exists "Developers can insert locations" on locations;
drop policy if exists "Developers can update locations" on locations;
drop policy if exists "Owners and developers can update locations" on locations;
drop policy if exists "Developers can delete locations" on locations;
drop policy if exists "Developers can read suggestions" on suggestions;
drop policy if exists "Developers can delete suggestions" on suggestions;


-- 1b. Replace the boolean is_developer flag with a proper role
alter table profiles add column if not exists role text not null default 'member';
update profiles set role = 'developer' where is_developer = true;
alter table profiles drop column if exists is_developer;

alter table profiles drop constraint if exists profiles_role_valid;
alter table profiles add constraint profiles_role_valid
  check (role in ('member', 'contributor', 'developer'));


-- 2. Locations get an owner — the contributor who runs that floor.
--    A developer sets this manually in Table Editor (copy the user's
--    id from the profiles table into a location's owner_id column).
alter table locations add column if not exists owner_id uuid references auth.users(id);


-- 3. Recreate location policies: developers keep full control,
--    contributors can update ONLY the location(s) they own.
create policy "Developers can insert locations"
  on locations for insert
  with check (
    exists (select 1 from profiles where id = auth.uid() and role = 'developer')
  );

create policy "Owners and developers can update locations"
  on locations for update
  using (
    owner_id = auth.uid()
    or exists (select 1 from profiles where id = auth.uid() and role = 'developer')
  );

create policy "Developers can delete locations"
  on locations for delete
  using (
    exists (select 1 from profiles where id = auth.uid() and role = 'developer')
  );


-- 4. Recreate suggestions policies, now checking role instead of is_developer
create policy "Developers can read suggestions"
  on suggestions for select
  using (
    exists (select 1 from profiles where id = auth.uid() and role = 'developer')
  );

create policy "Developers can delete suggestions"
  on suggestions for delete
  using (
    exists (select 1 from profiles where id = auth.uid() and role = 'developer')
  );


-- 5. Ratings: any signed-in account (member, contributor, or developer)
--    can rate a location. One rating per person per location.
create table if not exists ratings (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references locations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  stars integer not null check (stars between 1 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (location_id, user_id)
);

alter table ratings enable row level security;

drop policy if exists "Anyone can read ratings" on ratings;
create policy "Anyone can read ratings"
  on ratings for select
  using (true);

drop policy if exists "Signed-in users can rate" on ratings;
create policy "Signed-in users can rate"
  on ratings for insert
  with check (auth.uid() = user_id);

drop policy if exists "Users can update own rating" on ratings;
create policy "Users can update own rating"
  on ratings for update
  using (auth.uid() = user_id);

drop policy if exists "Users can delete own rating" on ratings;
create policy "Users can delete own rating"
  on ratings for delete
  using (auth.uid() = user_id);

grant select on table ratings to anon, authenticated;
grant insert, update, delete on table ratings to authenticated;


-- 6. A simple view for the average rating + count per location
drop view if exists location_rating_stats;
create view location_rating_stats as
select location_id,
       round(avg(stars)::numeric, 2) as avg_stars,
       count(*) as rating_count
from ratings
group by location_id;

grant select on location_rating_stats to anon, authenticated;

-- ============================================================
-- To make someone a contributor for their venue:
-- 1. They sign up for an account in the app (creates a profiles row).
-- 2. In Table Editor -> profiles, find their row (matched by email),
--    set role to 'contributor'.
-- 3. In Table Editor -> locations, find their venue's row, set
--    owner_id to that same user's id (copied from the profiles row).
-- They can now edit only that location, nothing else.
-- ============================================================
