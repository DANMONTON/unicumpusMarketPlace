-- BIU Fees Portal: Supabase schema with Row Level Security
-- Run this in the Supabase SQL editor.

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  role text not null default 'student' check (role in ('student','admin')),
  full_name text not null,
  reg_no text unique,
  programme text
);

create table fees (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references profiles(id) on delete cascade,
  description text not null,
  amount integer not null check (amount > 0),
  due_date date not null,
  created_at timestamptz default now()
);

create table payments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references profiles(id) on delete cascade,
  amount integer not null check (amount > 0),
  method text not null,
  reference text not null unique,
  paid_on date not null default current_date,
  status text not null default 'pending' check (status in ('pending','verified','rejected')),
  verified_by uuid references profiles(id),
  created_at timestamptz default now()
);

create table audit_log (
  id bigserial primary key,
  actor uuid references profiles(id),
  action text not null,
  created_at timestamptz default now()
);

-- Helper: is the current user an admin?
create or replace function is_admin() returns boolean
language sql security definer stable as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

alter table profiles  enable row level security;
alter table fees      enable row level security;
alter table payments  enable row level security;
alter table audit_log enable row level security;

-- Profiles: read your own row; admins read all. Only admins change profiles.
create policy "profiles read" on profiles for select using (id = auth.uid() or is_admin());
create policy "profiles admin write" on profiles for all using (is_admin()) with check (is_admin());

-- Fees: students read their own; only admins create/change.
create policy "fees read" on fees for select using (student_id = auth.uid() or is_admin());
create policy "fees admin write" on fees for all using (is_admin()) with check (is_admin());

-- Payments: students read their own and may only insert PENDING rows for themselves.
create policy "payments read" on payments for select using (student_id = auth.uid() or is_admin());
create policy "payments student insert" on payments for insert
  with check (student_id = auth.uid() and status = 'pending');
create policy "payments admin update" on payments for update using (is_admin()) with check (is_admin());

-- Audit log: admins read; writes happen through the policies below.
create policy "audit admin read" on audit_log for select using (is_admin());
create policy "audit insert own" on audit_log for insert with check (actor = auth.uid());
