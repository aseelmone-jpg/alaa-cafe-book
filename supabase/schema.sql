-- Alaa Cafe Day Book: owner-isolated Supabase schema
begin;

create table if not exists public.cafes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  location text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.day_entries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  cafe_id uuid not null references public.cafes(id) on delete cascade,
  entry_date date not null,
  sale numeric(12,2) not null default 0 check (sale >= 0),
  upi numeric(12,2) not null default 0 check (upi >= 0 and upi <= sale),
  purchase numeric(12,2) not null default 0 check (purchase >= 0),
  other_expense numeric(12,2) not null default 0 check (other_expense >= 0),
  remarks text not null default '',
  created_at timestamptz not null default now(),
  unique (cafe_id, entry_date)
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.day_entries'::regclass
      and conname = 'day_entries_upi_not_above_sales'
  ) then
    alter table public.day_entries
      add constraint day_entries_upi_not_above_sales
      check (upi <= sale) not valid;
  end if;
end
$$;

alter table public.cafes enable row level security;
alter table public.day_entries enable row level security;

drop policy if exists "Owners manage their cafes" on public.cafes;
drop policy if exists "Owners read their cafes" on public.cafes;
drop policy if exists "Admins add cafes" on public.cafes;
drop policy if exists "Admins edit cafes" on public.cafes;
drop policy if exists "Admins delete cafes" on public.cafes;
create policy "Owners read their cafes" on public.cafes
  for select to authenticated using (owner_id = (select auth.uid()));
create policy "Admins add cafes" on public.cafes
  for insert to authenticated with check (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');
create policy "Admins edit cafes" on public.cafes
  for update to authenticated using (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin')
  with check (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');
create policy "Admins delete cafes" on public.cafes
  for delete to authenticated using (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

drop policy if exists "Owners manage their day entries" on public.day_entries;
drop policy if exists "Owners read their day entries" on public.day_entries;
drop policy if exists "Owners add their day entries" on public.day_entries;
drop policy if exists "Owners edit their day entries" on public.day_entries;
drop policy if exists "Admins delete day entries" on public.day_entries;
create policy "Owners read their day entries" on public.day_entries
  for select to authenticated using (owner_id = (select auth.uid()));
create policy "Owners add their day entries" on public.day_entries
  for insert to authenticated with check (owner_id = (select auth.uid()) and exists (
    select 1 from public.cafes where cafes.id = day_entries.cafe_id and cafes.owner_id = (select auth.uid())
  ));
create policy "Owners edit their day entries" on public.day_entries
  for update to authenticated using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()) and exists (
    select 1 from public.cafes where cafes.id = day_entries.cafe_id and cafes.owner_id = (select auth.uid())
  ));
create policy "Admins delete day entries" on public.day_entries
  for delete to authenticated using (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

grant select, insert, update, delete on public.cafes to authenticated;
grant select, insert, update, delete on public.day_entries to authenticated;


create table if not exists public.journal_vouchers (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  cafe_id uuid not null references public.cafes(id) on delete cascade,
  voucher_no integer not null check (voucher_no > 0),
  voucher_date date not null,
  remark text not null default '',
  lines jsonb not null check (jsonb_typeof(lines) = 'array' and jsonb_array_length(lines) >= 2),
  created_at timestamptz not null default now(),
  unique (cafe_id, voucher_no)
);

alter table public.journal_vouchers enable row level security;
drop policy if exists "Owners manage their journal vouchers" on public.journal_vouchers;
drop policy if exists "Owners read their journal vouchers" on public.journal_vouchers;
drop policy if exists "Owners add their journal vouchers" on public.journal_vouchers;
drop policy if exists "Owners edit their journal vouchers" on public.journal_vouchers;
drop policy if exists "Admins delete journal vouchers" on public.journal_vouchers;
create policy "Owners read their journal vouchers" on public.journal_vouchers
  for select to authenticated using (owner_id = (select auth.uid()));
create policy "Owners add their journal vouchers" on public.journal_vouchers
  for insert to authenticated with check (owner_id = (select auth.uid()) and exists (
    select 1 from public.cafes
    where cafes.id = journal_vouchers.cafe_id and cafes.owner_id = (select auth.uid())
  ));
create policy "Owners edit their journal vouchers" on public.journal_vouchers
  for update to authenticated using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()) and exists (
    select 1 from public.cafes
    where cafes.id = journal_vouchers.cafe_id and cafes.owner_id = (select auth.uid())
  ));
create policy "Admins delete journal vouchers" on public.journal_vouchers
  for delete to authenticated using (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');
grant select, insert, update, delete on public.journal_vouchers to authenticated;

commit;
