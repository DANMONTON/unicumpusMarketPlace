-- Campus Market v3: schools. Run this whole file ONCE in Supabase -> SQL Editor, after schema_v2.sql.
-- Each student picks a school at sign-up; every listing is stamped with its seller's school.

alter table public.profiles add column if not exists school text check (char_length(school) <= 100);
alter table public.listings add column if not exists school text check (char_length(school) <= 100);
create index if not exists listings_school_idx on public.listings (school);

-- Save the school chosen at sign-up into the profile.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, user_name, school)
  values (new.id,
          coalesce(nullif(left(new.raw_user_meta_data->>'full_name', 60), ''), 'Student'),
          nullif(left(new.raw_user_meta_data->>'school', 100), ''))
  on conflict (id) do nothing;
  return new;
end $$;

-- Stamp every new listing with the seller's school (the browser cannot fake it).
create or replace function public.set_listing_school() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.school := (select school from public.profiles where id = new.seller_id);
  return new;
end $$;
drop trigger if exists listing_school on public.listings;
create trigger listing_school before insert on public.listings
  for each row execute function public.set_listing_school();

-- Backfill: existing users with no school get the first school; change the name below if needed.
update public.profiles set school = 'Blantyre International University (BIU)' where school is null;
update public.listings l set school = p.school from public.profiles p where p.id = l.seller_id and l.school is null;
