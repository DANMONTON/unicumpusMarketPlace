-- Campus Market v6. Run ONCE in Supabase > SQL Editor, after schema_v5.sql.
-- Adds: visit tracking (anonymous) + admin-only functions for the "Users & traffic" tab.
-- Visits are counted only from the day you run this and deploy the new app.js.

-- ---------- Visit tracking (no IP addresses, just a random id per browser) ----------
create table if not exists public.site_visits (
  id         bigint generated always as identity primary key,
  visitor    text not null check (char_length(visitor) between 8 and 64),
  path       text not null default '/' check (char_length(path) <= 200),
  user_id    uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists site_visits_created_idx on public.site_visits (created_at);
alter table public.site_visits enable row level security;

drop policy if exists "anyone records a visit" on public.site_visits;
create policy "anyone records a visit" on public.site_visits for insert to anon, authenticated
  with check (user_id is null or user_id = auth.uid());
drop policy if exists "admin reads visits" on public.site_visits;
create policy "admin reads visits" on public.site_visits for select to authenticated
  using (public.is_admin());

-- ---------- All registered users (admin only) ----------
create or replace function public.admin_user_list()
returns table (uid uuid, email text, name text, school_name text, joined timestamptz, last_seen timestamptz, listing_count bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select u.id, u.email::text,
           coalesce(p.user_name, u.raw_user_meta_data->>'full_name', 'Student'),
           p.school, u.created_at, u.last_sign_in_at,
           (select count(*) from public.listings l where l.seller_id = u.id)
    from auth.users u left join public.profiles p on p.id = u.id
    order by u.created_at desc;
end $$;

-- ---------- New accounts per day ----------
create or replace function public.admin_signups_by_day(p_days int default 30)
returns table (day date, signups bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select d::date, count(u.id)
    from generate_series(current_date - (p_days - 1), current_date, interval '1 day') d
    left join auth.users u on (u.created_at at time zone 'UTC')::date = d::date
    group by d order by d;
end $$;

-- ---------- Visits per day ----------
create or replace function public.admin_visits_by_day(p_days int default 30)
returns table (day date, visits bigint, unique_visitors bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select d::date, count(v.id), count(distinct v.visitor)
    from generate_series(current_date - (p_days - 1), current_date, interval '1 day') d
    left join public.site_visits v on (v.created_at at time zone 'UTC')::date = d::date
    group by d order by d;
end $$;

-- ---------- Totals for the chosen range ----------
create or replace function public.admin_traffic_totals(p_days int default 30)
returns table (visits bigint, unique_visitors bigint, logged_in_visitors bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select count(*), count(distinct v.visitor), count(distinct v.user_id)
    from public.site_visits v
    where (v.created_at at time zone 'UTC')::date > current_date - p_days;
end $$;
