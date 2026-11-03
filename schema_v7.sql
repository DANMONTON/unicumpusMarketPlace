-- Campus Market v7. Run ONCE in Supabase > SQL Editor, after schema_v2 ... schema_v6.
-- Adds: (1) "swap" listings, (2) Verified seller badge (admin-only), (3) swap contacts readable.

-- ---------- 1) Swap listings ----------
alter table public.listings drop constraint if exists listings_kind_check;
alter table public.listings add constraint listings_kind_check check (kind in ('sell','want','swap'));
-- create_order (v4) already refuses anything that is not kind = 'sell', so swaps can't be bought with escrow.

-- ---------- 2) Swap contacts: logged-in users can see them (no money changes hands) ----------
-- Same rule as v5, plus: l.kind in ('want','swap')
drop policy if exists "contacts protected read" on public.contacts;
create policy "contacts protected read" on public.contacts for select to authenticated using (
  public.is_admin()
  or exists (select 1 from public.listings l
             where l.id = contacts.listing_id and (l.seller_id = auth.uid() or l.kind in ('want','swap')))
  or exists (select 1 from public.orders o
             where o.listing_id = contacts.listing_id and o.buyer_id = auth.uid()
               and o.status in ('held','confirmed','released','disputed'))
);

-- ---------- 3) Verified sellers ----------
alter table public.profiles add column if not exists verified boolean not null default false;

-- Users can never set or change their own badge; only admins can.
create or replace function public.profiles_protect_verified() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not coalesce(public.is_admin(), false) then new.verified := false; end if;
  elsif new.verified is distinct from old.verified and not coalesce(public.is_admin(), false) then
    new.verified := old.verified;
  end if;
  return new;
end $$;
drop trigger if exists profiles_protect_verified on public.profiles;
create trigger profiles_protect_verified before insert or update on public.profiles
  for each row execute function public.profiles_protect_verified();

-- Used by the "Seller verification" box in admin.html (Users tab)
create or replace function public.admin_set_verified(p_email text, p_value boolean) returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'No user with that email'; end if;
  update public.profiles set verified = p_value where id = uid;
  if not found then raise exception 'That user has no profile row'; end if;
  return 'ok';
end $$;
revoke all on function public.admin_set_verified(text, boolean) from public, anon;
grant execute on function public.admin_set_verified(text, boolean) to authenticated;
