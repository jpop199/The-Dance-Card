-- ============================================================
-- Dance Card app — Supabase schema + Row Level Security
-- Run this whole file once in the Supabase SQL Editor (fresh project).
-- If you already ran an earlier version of this file, use
-- supabase-migration-contributors-ratings.sql instead.
-- ============================================================

-- 1. Profiles: one row per signed-up user, tracks their role.
--    'member'      - default, can suggest locations and rate them
--    'contributor' - runs a venue, can edit only their own location
--    'developer'   - full control: add/edit/delete any location,
--                    review suggestions
create table if not exists profiles (
  id uuid references auth.users(id) on delete cascade primary key,
  email text,
  role text not null default 'member' check (role in ('member','contributor','developer')),
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

drop policy if exists "Users can read own profile" on profiles;
create policy "Users can read own profile"
  on profiles for select
  using (auth.uid() = id);

create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email);
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- 2. Locations: the live, approved list shown on the card.
--    owner_id links a location to the contributor who runs it.
create table if not exists locations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text not null,
  city text,
  lat double precision,
  lng double precision,
  lessons jsonb,               -- string OR array of {label, time} objects
  open_floor text,
  price text,
  swing_ratio integer not null default 1,
  line_ratio integer not null default 1,
  days text[] not null default '{}',
  owner_id uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table locations enable row level security;

drop policy if exists "Anyone can read locations" on locations;
create policy "Anyone can read locations"
  on locations for select
  using (true);

-- Only developers can create new locations
drop policy if exists "Developers can insert locations" on locations;
create policy "Developers can insert locations"
  on locations for insert
  with check (
    exists (select 1 from profiles where id = auth.uid() and role = 'developer')
  );

-- Developers can edit any location; contributors can edit only their own
drop policy if exists "Owners and developers can update locations" on locations;
create policy "Owners and developers can update locations"
  on locations for update
  using (
    owner_id = auth.uid()
    or exists (select 1 from profiles where id = auth.uid() and role = 'developer')
  );

-- Only developers can remove locations
drop policy if exists "Developers can delete locations" on locations;
create policy "Developers can delete locations"
  on locations for delete
  using (
    exists (select 1 from profiles where id = auth.uid() and role = 'developer')
  );


-- 3. Suggestions: pending submissions from anyone, reviewed by developers
create table if not exists suggestions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text not null,
  city text,
  lat double precision,
  lng double precision,
  lessons jsonb,
  open_floor text,
  price text,
  swing_ratio integer not null default 1,
  line_ratio integer not null default 1,
  days text[] not null default '{}',
  submitted_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table suggestions enable row level security;

drop policy if exists "Anyone can submit a suggestion" on suggestions;
create policy "Anyone can submit a suggestion"
  on suggestions for insert
  with check (true);

drop policy if exists "Developers can read suggestions" on suggestions;
create policy "Developers can read suggestions"
  on suggestions for select
  using (
    exists (select 1 from profiles where id = auth.uid() and role = 'developer')
  );

drop policy if exists "Developers can delete suggestions" on suggestions;
create policy "Developers can delete suggestions"
  on suggestions for delete
  using (
    exists (select 1 from profiles where id = auth.uid() and role = 'developer')
  );


-- 4. Ratings: any signed-in account can rate a location, once each.
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

-- Average rating + count per location, used by the app
drop view if exists location_rating_stats;
create view location_rating_stats as
select location_id,
       round(avg(stars)::numeric, 2) as avg_stars,
       count(*) as rating_count
from ratings
group by location_id;


-- 5. Table-level grants — RLS policies above only take effect once
--    these basic grants exist. Without them Postgres blocks the
--    query before RLS is even evaluated.
grant usage on schema public to anon, authenticated;

grant select on table locations to anon, authenticated;
grant insert, update, delete on table locations to authenticated;

grant select on table profiles to anon, authenticated;

grant insert on table suggestions to anon, authenticated;
grant select, delete on table suggestions to authenticated;

grant select on table ratings to anon, authenticated;
grant insert, update, delete on table ratings to authenticated;

grant select on location_rating_stats to anon, authenticated;

-- ============================================================
-- After running this:
-- 1. Sign up for an account in the app itself (creates your profile row).
-- 2. In Supabase, go to Table Editor -> profiles, find your row,
--    and set role to 'developer'. That's what makes you a developer.
-- 3. To make someone a contributor for their venue: set their
--    profiles.role to 'contributor', then set that location's
--    owner_id (in the locations table) to their user id.
-- ============================================================
