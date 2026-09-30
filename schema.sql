-- Alaa Cafe Day Book: owner-isolated Supabase schema
begin;

create table if not exists public.cafes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  location text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.cafe_members (
  cafe_id uuid not null references public.cafes(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (cafe_id, user_id)
);

create table if not exists public.cafe_user_features (
  cafe_id uuid not null references public.cafes(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  features jsonb not null default '{"dayBook":true,"sales":true,"purchases":true,"expenses":true,"upiAccount":true,"journalEntry":true,"cash":true,"ledgers":true}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (cafe_id, user_id),
  check (jsonb_typeof(features) = 'object')
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
alter table public.cafe_members enable row level security;
alter table public.cafe_user_features enable row level security;
alter table public.day_entries enable row level security;

drop policy if exists "Owners manage their cafes" on public.cafes;
drop policy if exists "Owners read their cafes" on public.cafes;
drop policy if exists "Admins add cafes" on public.cafes;
drop policy if exists "Admins edit cafes" on public.cafes;
drop policy if exists "Admins delete cafes" on public.cafes;
create policy "Owners read their cafes" on public.cafes
  for select to authenticated using (
    owner_id = (select auth.uid()) or exists (
      select 1 from public.cafe_members m
      where m.cafe_id = cafes.id and m.user_id = (select auth.uid())
    )
  );
create policy "Admins add cafes" on public.cafes
  for insert to authenticated with check (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');
create policy "Admins edit cafes" on public.cafes
  for update to authenticated using (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin')
  with check (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');
create policy "Admins delete cafes" on public.cafes
  for delete to authenticated using (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

drop policy if exists "Users read their cafe memberships" on public.cafe_members;
create policy "Users read their cafe memberships" on public.cafe_members
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "Users read their cafe feature settings" on public.cafe_user_features;
drop policy if exists "Admins manage cafe feature settings" on public.cafe_user_features;
create policy "Users read their cafe feature settings" on public.cafe_user_features
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Admins manage cafe feature settings" on public.cafe_user_features
  for all to authenticated using (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin' and exists (
      select 1 from public.cafes c where c.id = cafe_user_features.cafe_id and c.owner_id = (select auth.uid())
    )
  ) with check (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin' and exists (
      select 1 from public.cafes c where c.id = cafe_user_features.cafe_id and c.owner_id = (select auth.uid())
    ) and exists (
      select 1 from public.cafe_members m where m.cafe_id = cafe_user_features.cafe_id and m.user_id = cafe_user_features.user_id
    )
  );

create or replace function public.admin_list_cafe_users(p_cafe_id uuid)
returns table(user_id uuid, email text, features jsonb)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') <> 'admin' or not exists (
    select 1 from public.cafes c where c.id = p_cafe_id and c.owner_id = auth.uid()
  ) then
    raise exception 'Only the cafe admin can manage its users';
  end if;
  return query
    select m.user_id, u.email::text,
      coalesce(f.features, '{"dayBook":true,"sales":true,"purchases":true,"expenses":true,"upiAccount":true,"journalEntry":true,"cash":true,"ledgers":true}'::jsonb)
    from public.cafe_members m
    join auth.users u on u.id = m.user_id
    left join public.cafe_user_features f on f.cafe_id = m.cafe_id and f.user_id = m.user_id
    where m.cafe_id = p_cafe_id
    order by lower(u.email);
end;
$function$;
revoke all on function public.admin_list_cafe_users(uuid) from public;
grant execute on function public.admin_list_cafe_users(uuid) to authenticated;

drop policy if exists "Owners manage their day entries" on public.day_entries;
drop policy if exists "Owners read their day entries" on public.day_entries;
drop policy if exists "Owners add their day entries" on public.day_entries;
drop policy if exists "Owners edit their day entries" on public.day_entries;
drop policy if exists "Admins delete day entries" on public.day_entries;
create policy "Owners read their day entries" on public.day_entries
  for select to authenticated using (exists (
    select 1 from public.cafes c where c.id = day_entries.cafe_id
      and (c.owner_id = (select auth.uid()) or exists (
        select 1 from public.cafe_members m where m.cafe_id = c.id and m.user_id = (select auth.uid())
      ))
  ));
create policy "Owners add their day entries" on public.day_entries
  for insert to authenticated with check (exists (
    select 1 from public.cafes c where c.id = day_entries.cafe_id and c.owner_id = day_entries.owner_id
      and (c.owner_id = (select auth.uid()) or exists (
        select 1 from public.cafe_members m where m.cafe_id = c.id and m.user_id = (select auth.uid())
      ))
  ));
create policy "Owners edit their day entries" on public.day_entries
  for update to authenticated using (exists (
    select 1 from public.cafes c where c.id = day_entries.cafe_id
      and (c.owner_id = (select auth.uid()) or exists (
        select 1 from public.cafe_members m where m.cafe_id = c.id and m.user_id = (select auth.uid())
      ))
  ))
  with check (exists (
    select 1 from public.cafes c where c.id = day_entries.cafe_id and c.owner_id = day_entries.owner_id
      and (c.owner_id = (select auth.uid()) or exists (
        select 1 from public.cafe_members m where m.cafe_id = c.id and m.user_id = (select auth.uid())
      ))
  ));
create policy "Admins delete day entries" on public.day_entries
  for delete to authenticated using (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

grant select, insert, update, delete on public.cafes to authenticated;
grant select on public.cafe_members to authenticated;
grant select, insert, update, delete on public.cafe_user_features to authenticated;
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
  for select to authenticated using (exists (
    select 1 from public.cafes c where c.id = journal_vouchers.cafe_id
      and (c.owner_id = (select auth.uid()) or exists (
        select 1 from public.cafe_members m where m.cafe_id = c.id and m.user_id = (select auth.uid())
      ))
  ));
create policy "Owners add their journal vouchers" on public.journal_vouchers
  for insert to authenticated with check (exists (
    select 1 from public.cafes c where c.id = journal_vouchers.cafe_id and c.owner_id = journal_vouchers.owner_id
      and (c.owner_id = (select auth.uid()) or exists (
        select 1 from public.cafe_members m where m.cafe_id = c.id and m.user_id = (select auth.uid())
      ))
  ));
create policy "Owners edit their journal vouchers" on public.journal_vouchers
  for update to authenticated using (exists (
    select 1 from public.cafes c where c.id = journal_vouchers.cafe_id
      and (c.owner_id = (select auth.uid()) or exists (
        select 1 from public.cafe_members m where m.cafe_id = c.id and m.user_id = (select auth.uid())
      ))
  ))
  with check (exists (
    select 1 from public.cafes c where c.id = journal_vouchers.cafe_id and c.owner_id = journal_vouchers.owner_id
      and (c.owner_id = (select auth.uid()) or exists (
        select 1 from public.cafe_members m where m.cafe_id = c.id and m.user_id = (select auth.uid())
      ))
  ));
create policy "Admins delete journal vouchers" on public.journal_vouchers
  for delete to authenticated using (owner_id = (select auth.uid()) and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');
grant select, insert, update, delete on public.journal_vouchers to authenticated;

commit;
