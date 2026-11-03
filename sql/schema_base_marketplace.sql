-- Campus Market BASE schema. Run FIRST, in a NEW/clean Supabase project.
-- Order: this file -> schema_v2.sql -> schema_v3.sql -> schema_v4.sql
-- (do NOT run the BIU Fees Portal schema.sql in this project)

-- ---------- Listings ----------
create table if not exists public.listings (
  id          uuid primary key default gen_random_uuid(),
  seller_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  seller_name text not null default 'Student' check (char_length(seller_name) <= 60),
  title       text not null check (char_length(title) between 3 and 100),
  description text check (char_length(description) <= 1000),
  price       numeric(12,2) not null default 0 check (price >= 0),
  category    text not null,
  condition   text not null,
  status      text not null default 'available' check (status in ('available','sold')),
  image_url   text,
  image_path  text,
  created_at  timestamptz not null default now()
);
create index if not exists listings_created_idx on public.listings (created_at desc);
create index if not exists listings_status_idx on public.listings (status);

alter table public.listings enable row level security;
create policy "listings readable by everyone" on public.listings for select using (true);
create policy "users post listings" on public.listings for insert to authenticated
  with check (auth.uid() = seller_id);
create policy "owner updates listing" on public.listings for update to authenticated
  using (auth.uid() = seller_id) with check (auth.uid() = seller_id);
create policy "owner deletes listing" on public.listings for delete to authenticated
  using (auth.uid() = seller_id);

-- ---------- Seller contacts (logged-in users only) ----------
create table if not exists public.contacts (
  listing_id uuid primary key references public.listings(id) on delete cascade,
  contact    text not null check (char_length(contact) between 5 and 120)
);
alter table public.contacts enable row level security;
create policy "logged in read contacts" on public.contacts for select to authenticated using (true);
create policy "seller adds contact" on public.contacts for insert to authenticated
  with check (exists (select 1 from public.listings l where l.id = listing_id and l.seller_id = auth.uid()));
create policy "seller updates contact" on public.contacts for update to authenticated
  using (exists (select 1 from public.listings l where l.id = listing_id and l.seller_id = auth.uid()));

-- ---------- Reports ----------
create table if not exists public.reports (
  id         uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings(id) on delete cascade,
  reporter   uuid default auth.uid() references auth.users(id) on delete set null,
  reason     text not null check (char_length(reason) between 3 and 300),
  created_at timestamptz not null default now()
);
alter table public.reports enable row level security;
create policy "users report" on public.reports for insert to authenticated with check (true);

-- ---------- Listing image storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('listing-images', 'listing-images', true, 10485760, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy "anyone can view listing images" on storage.objects for select
  using (bucket_id = 'listing-images');
create policy "users upload own listing images" on storage.objects for insert to authenticated
  with check (bucket_id = 'listing-images' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "users delete own listing images" on storage.objects for delete to authenticated
  using (bucket_id = 'listing-images' and (storage.foldername(name))[1] = auth.uid()::text);
