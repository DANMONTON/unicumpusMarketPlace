-- Campus Market v5. Run ONCE in Supabase > SQL Editor, after schema_v2/v3/v4.
-- Adds: (1) tamper-proof evidence log for every order, (2) in-app order chat
-- (buyer / seller / admin), (3) seller contact hidden until the buyer's money is secured.

-- ---------- 1) Evidence log: append-only ----------
create table if not exists public.order_events (
  id         bigint generated always as identity primary key,
  order_id   uuid not null,                       -- no foreign key: evidence must outlive the order
  actor      uuid default auth.uid(),             -- who did it (null = system)
  event      text not null,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists order_events_order_idx on public.order_events (order_id, created_at);
alter table public.order_events enable row level security;

drop policy if exists "parties and admin read events" on public.order_events;
create policy "parties and admin read events" on public.order_events for select to authenticated
  using (public.is_admin() or exists (
    select 1 from public.orders o where o.id = order_id and auth.uid() in (o.buyer_id, o.seller_id)));
-- No insert/update/delete policies: browsers can never write here. Only the trigger below can.

create or replace function public.block_evidence_change() returns trigger
language plpgsql as $$
begin
  raise exception 'Evidence records cannot be changed or deleted';
end $$;
drop trigger if exists order_events_immutable on public.order_events;
create trigger order_events_immutable before update or delete on public.order_events
  for each row execute function public.block_evidence_change();

create or replace function public.log_order_event() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.order_events (order_id, actor, event, detail)
    values (new.id, auth.uid(), 'order_created', jsonb_build_object(
      'status', new.status, 'amount', new.amount, 'fee_percent', new.fee_percent,
      'fee_amount', new.fee_amount, 'seller_payout', new.seller_payout, 'method', new.method,
      'listing_title', new.listing_title, 'buyer_id', new.buyer_id, 'seller_id', new.seller_id));
  elsif new.status is distinct from old.status
     or new.payment_ref is distinct from old.payment_ref
     or new.payout_ref is distinct from old.payout_ref
     or new.admin_note is distinct from old.admin_note
     or new.buyer_confirmed_at is distinct from old.buyer_confirmed_at
     or new.seller_confirmed_at is distinct from old.seller_confirmed_at then
    insert into public.order_events (order_id, actor, event, detail)
    values (new.id, auth.uid(), 'status_changed', jsonb_build_object(
      'from', old.status, 'to', new.status, 'payer_phone', new.payer_phone,
      'payment_ref', new.payment_ref, 'payout_ref', new.payout_ref, 'admin_note', new.admin_note,
      'buyer_confirmed_at', new.buyer_confirmed_at, 'seller_confirmed_at', new.seller_confirmed_at,
      'release_after', new.release_after));
  end if;
  return new;
end $$;
drop trigger if exists orders_audit on public.orders;
create trigger orders_audit after insert or update on public.orders
  for each row execute function public.log_order_event();

-- Snapshot of orders that existed before this file was run
insert into public.order_events (order_id, actor, event, detail)
select o.id, null, 'snapshot_at_v5', to_jsonb(o) from public.orders o
where not exists (select 1 from public.order_events e where e.order_id = o.id);

-- ---------- 2) Order chat (buyer, seller, admin). Messages cannot be edited or deleted ----------
create table if not exists public.order_messages (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references public.orders(id),
  sender_id  uuid not null default auth.uid(),
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists order_messages_order_idx on public.order_messages (order_id, created_at);
alter table public.order_messages enable row level security;

drop policy if exists "parties and admin read messages" on public.order_messages;
create policy "parties and admin read messages" on public.order_messages for select to authenticated
  using (public.is_admin() or exists (
    select 1 from public.orders o where o.id = order_id and auth.uid() in (o.buyer_id, o.seller_id)));

drop policy if exists "parties and admin send messages" on public.order_messages;
create policy "parties and admin send messages" on public.order_messages for insert to authenticated
  with check (sender_id = auth.uid() and (public.is_admin() or exists (
    select 1 from public.orders o where o.id = order_id and auth.uid() in (o.buyer_id, o.seller_id))));

drop trigger if exists order_messages_immutable on public.order_messages;
create trigger order_messages_immutable before update or delete on public.order_messages
  for each row execute function public.block_evidence_change();

-- ---------- 3) Seller contact protection ----------
-- Visible to: the seller, admins, anyone for "I want" requests, and a buyer ONLY once their payment is secured.
do $$
declare r record;
begin
  for r in select policyname from pg_policies
           where schemaname = 'public' and tablename = 'contacts' and cmd in ('SELECT', 'ALL')
  loop
    execute format('drop policy %I on public.contacts', r.policyname);
  end loop;
end $$;

drop policy if exists "contacts protected read" on public.contacts;
create policy "contacts protected read" on public.contacts for select to authenticated using (
  public.is_admin()
  or exists (select 1 from public.listings l
             where l.id = contacts.listing_id and (l.seller_id = auth.uid() or l.kind = 'want'))
  or exists (select 1 from public.orders o
             where o.listing_id = contacts.listing_id and o.buyer_id = auth.uid()
               and o.status in ('held','confirmed','released','disputed'))
);

drop policy if exists "seller adds contact" on public.contacts;
create policy "seller adds contact" on public.contacts for insert to authenticated
  with check (exists (select 1 from public.listings l where l.id = listing_id and l.seller_id = auth.uid()));
drop policy if exists "seller updates contact" on public.contacts;
create policy "seller updates contact" on public.contacts for update to authenticated
  using (exists (select 1 from public.listings l where l.id = listing_id and l.seller_id = auth.uid()));
