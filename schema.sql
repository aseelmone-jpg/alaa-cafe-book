begin;
-- Alaa Cafe Day Book: owner-isolated Supabase schema

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
  features jsonb not null default '{"dayBook":true,"sales":true,"purchases":true,"expenses":true,"upiAccount":true,"reportsPnl":false,"journalEntry":true,"cash":true,"ledgers":true}'::jsonb,
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

-- The member table intentionally exposes only the signed-in user's memberships.
-- Check the target staff membership without expanding that table's read access.
create or replace function public.admin_can_manage_cafe_user(p_cafe_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin'
    and exists (
      select 1 from public.cafes c
      where c.id = p_cafe_id and c.owner_id = (select auth.uid())
    ) and exists (
      select 1 from public.cafe_members m
      where m.cafe_id = p_cafe_id and m.user_id = p_user_id
    );
$function$;
revoke all on function public.admin_can_manage_cafe_user(uuid, uuid) from public, anon;
grant execute on function public.admin_can_manage_cafe_user(uuid, uuid) to authenticated;

create policy "Admins manage cafe feature settings" on public.cafe_user_features
  for all to authenticated using (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin' and exists (
      select 1 from public.cafes c where c.id = cafe_user_features.cafe_id and c.owner_id = (select auth.uid())
    )
  ) with check (
    public.admin_can_manage_cafe_user(cafe_id, user_id)
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
      coalesce(f.features, '{"dayBook":true,"sales":true,"purchases":true,"expenses":true,"upiAccount":true,"reportsPnl":false,"journalEntry":true,"cash":true,"ledgers":true}'::jsonb)
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

-- Voucher lines must be valid and balanced even when saved outside the browser UI.
create or replace function public.journal_lines_are_balanced(p_lines jsonb)
returns boolean
language plpgsql
immutable
strict
set search_path = ''
as $function$
declare
  v_line jsonb;
  v_side text;
  v_account text;
  v_amount_text text;
  v_amount numeric;
  v_debit numeric := 0;
  v_credit numeric := 0;
  v_count integer := 0;
  v_role text;
  v_has_role boolean := false;
  v_has_no_role boolean := false;
  v_first_account text;
  v_multiple_accounts boolean := false;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    return false;
  end if;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_count := v_count + 1;
    v_side := v_line ->> 'side';
    v_account := btrim(coalesce(v_line ->> 'particulars', ''));
    v_amount_text := v_line ->> 'amount';
    v_role := v_line ->> 'transferRole';
    if v_side is null or v_side not in ('debit', 'credit') or v_account = '' then
      return false;
    end if;
    if v_first_account is null then v_first_account := v_account;
    elsif v_first_account <> v_account then v_multiple_accounts := true;
    end if;
    if v_role is null then
      v_has_no_role := true;
    else
      v_has_role := true;
      if v_account not in ('Cash', 'UPI Account', 'Bank')
         or v_role <> (case when v_side = 'credit' then 'source' else 'destination' end) then
        return false;
      end if;
    end if;
    if v_amount_text is null or v_amount_text !~ '^(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?$' then
      return false;
    end if;
    v_amount := v_amount_text::numeric;
    if v_amount <= 0 then
      return false;
    end if;
    if v_side = 'debit' then v_debit := v_debit + v_amount;
    else v_credit := v_credit + v_amount;
    end if;
  end loop;
  return v_count >= 2 and v_debit > 0 and v_debit = v_credit
    and not (v_has_role and (v_has_no_role or not v_multiple_accounts));
exception when others then
  return false;
end;
$function$;
revoke all on function public.journal_lines_are_balanced(jsonb) from public, anon;
grant execute on function public.journal_lines_are_balanced(jsonb) to authenticated;

do $journal_check$
begin
  if exists (
    select 1 from public.journal_vouchers
    where public.journal_lines_are_balanced(lines) is not true
  ) then
    raise exception 'Existing journal vouchers have invalid or unbalanced lines; schema changes rolled back';
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.journal_vouchers'::regclass
      and conname = 'journal_vouchers_lines_balanced'
  ) then
    alter table public.journal_vouchers
      add constraint journal_vouchers_lines_balanced
      check (public.journal_lines_are_balanced(lines)) not valid;
  end if;
end
$journal_check$;
alter table public.journal_vouchers validate constraint journal_vouchers_lines_balanced;

-- This table only controls which existing account names can be picked in new vouchers.
-- Disabling an option never deletes the account name or any historical voucher lines.
create table if not exists public.journal_account_options (
  cafe_id uuid not null references public.cafes(id) on delete cascade,
  account_name text not null check (length(btrim(account_name)) between 1 and 120),
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (cafe_id, account_name)
);
alter table public.journal_account_options enable row level security;
drop policy if exists "Cafe users read journal account options" on public.journal_account_options;
drop policy if exists "Admins manage journal account options" on public.journal_account_options;
create policy "Cafe users read journal account options" on public.journal_account_options
  for select to authenticated using (exists (
    select 1 from public.cafes c where c.id = journal_account_options.cafe_id
      and (c.owner_id = (select auth.uid()) or exists (
        select 1 from public.cafe_members m where m.cafe_id = c.id and m.user_id = (select auth.uid())
      ))
  ));
create policy "Admins manage journal account options" on public.journal_account_options
  for all to authenticated using (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin' and exists (
      select 1 from public.cafes c where c.id = journal_account_options.cafe_id and c.owner_id = (select auth.uid())
    )
  ) with check (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin' and exists (
      select 1 from public.cafes c where c.id = journal_account_options.cafe_id and c.owner_id = (select auth.uid())
    )
  );
revoke all on public.journal_account_options from public, anon, authenticated;
grant select, insert, update on public.journal_account_options to authenticated;

-- Seed the current journal accounts, including Bank for transfers, plus any names
-- already present in saved vouchers. Preserve prior enabled/disabled choices.
insert into public.journal_account_options (cafe_id, account_name, enabled)
select c.id, a.account_name, true
from public.cafes c
cross join (values ('Cash'), ('UPI Account'), ('Bank'), ('Sales'), ('Purchases'), ('Other Expenses')) as a(account_name)
on conflict (cafe_id, account_name) do nothing;
insert into public.journal_account_options (cafe_id, account_name, enabled)
select distinct j.cafe_id, btrim(line.value ->> 'particulars'), true
from public.journal_vouchers j
cross join lateral jsonb_array_elements(j.lines) as line(value)
where nullif(btrim(line.value ->> 'particulars'), '') is not null
  and length(btrim(line.value ->> 'particulars')) <= 120
on conflict (cafe_id, account_name) do nothing;

create or replace function public.seed_journal_accounts_for_cafe()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  insert into public.journal_account_options (cafe_id, account_name, enabled)
  values
    (new.id, 'Cash', true),
    (new.id, 'UPI Account', true),
    (new.id, 'Bank', true),
    (new.id, 'Sales', true),
    (new.id, 'Purchases', true),
    (new.id, 'Other Expenses', true)
  on conflict (cafe_id, account_name) do nothing;
  return new;
end;
$function$;
drop trigger if exists seed_journal_accounts_after_cafe_insert on public.cafes;
create trigger seed_journal_accounts_after_cafe_insert
  after insert on public.cafes
  for each row execute function public.seed_journal_accounts_for_cafe();

create or replace function public.enforce_journal_account_options()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_line jsonb;
  v_account text;
begin
  for v_line in select value from jsonb_array_elements(new.lines) loop
    v_account := btrim(coalesce(v_line ->> 'particulars', ''));
    if exists (
      select 1 from public.journal_account_options o
      where o.cafe_id = new.cafe_id and o.account_name = v_account and o.enabled
    ) then
      continue;
    end if;
    if tg_op = 'UPDATE' then
      if exists (
        select 1 from jsonb_array_elements(old.lines) as old_lines(value)
        where btrim(coalesce(old_lines.value ->> 'particulars', '')) = v_account
      ) then
        continue;
      end if;
    end if;
    raise exception 'Journal account "%" is not enabled for this cafe', v_account using errcode = 'check_violation';
  end loop;
  return new;
end;
$function$;
revoke all on function public.seed_journal_accounts_for_cafe() from public, anon, authenticated;
revoke all on function public.enforce_journal_account_options() from public, anon, authenticated;
drop trigger if exists enforce_journal_account_options on public.journal_vouchers;
create trigger enforce_journal_account_options
  before insert or update on public.journal_vouchers
  for each row execute function public.enforce_journal_account_options();

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

-- Realtime subscriptions used by the browser app. Keep this idempotent so the
-- schema script is safe to rerun after tables have already been added manually.
do $realtime$
declare
  v_table_name text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach v_table_name in array array['day_entries', 'journal_vouchers', 'cafe_user_features', 'journal_account_options'] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = v_table_name
      ) then
        execute format('alter publication supabase_realtime add table public.%I', v_table_name);
      end if;
    end loop;
  end if;
end;
$realtime$;


-- Preserve cafe and accounting history and record auditable row snapshots.
-- Apply once from Supabase SQL Editor as the database owner. This transaction
-- aborts on any pre-existing data conflict and does not delete or rewrite rows.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

lock table public.cafes, public.cafe_user_features, public.day_entries, public.journal_vouchers in share row exclusive mode;

do $preflight$
declare n bigint;
begin
  if to_regclass('public.cafes') is null or to_regclass('public.cafe_members') is null
     or to_regclass('public.cafe_user_features') is null or to_regclass('public.day_entries') is null
     or to_regclass('public.journal_vouchers') is null then
    raise exception 'Expected Supabase tables are missing; migration stopped';
  end if;
  select count(*) into n from public.day_entries d join public.cafes c on c.id=d.cafe_id where d.owner_id<>c.owner_id;
  if n>0 then raise exception '% day entry owner/cafe mismatches; no changes applied', n; end if;
  select count(*) into n from public.journal_vouchers v join public.cafes c on c.id=v.cafe_id where v.owner_id<>c.owner_id;
  if n>0 then raise exception '% voucher owner/cafe mismatches; no changes applied', n; end if;
  select count(*) into n from public.cafe_user_features f left join public.cafe_members m on m.cafe_id=f.cafe_id and m.user_id=f.user_id where m.user_id is null;
  if n>0 then raise exception '% feature rows lack a cafe membership; no changes applied', n; end if;
  select count(*) into n from public.journal_vouchers v where public.journal_lines_are_balanced(v.lines) is not true;
  if n>0 then raise exception '% journal voucher(s) are invalid/unbalanced; no changes applied', n; end if;
  select count(*) into n from public.journal_vouchers v cross join lateral jsonb_array_elements(v.lines) l(value)
    where length(btrim(coalesce(l.value->>'particulars',''))) > 120;
  if n>0 then raise exception '% journal account names exceed 120 characters; no changes applied', n; end if;
end;
$preflight$;

alter table public.cafes add column if not exists archived_at timestamptz;
alter table public.cafes add column if not exists archived_by uuid references auth.users(id) on delete set null;
alter table public.cafes add column if not exists updated_at timestamptz not null default now();
alter table public.day_entries add column if not exists voided_at timestamptz;
alter table public.day_entries add column if not exists voided_by uuid references auth.users(id) on delete set null;
alter table public.day_entries add column if not exists updated_at timestamptz not null default now();
alter table public.journal_vouchers add column if not exists voided_at timestamptz;
alter table public.journal_vouchers add column if not exists voided_by uuid references auth.users(id) on delete set null;
alter table public.journal_vouchers add column if not exists updated_at timestamptz not null default now();

do $constraints$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.cafes'::regclass and conname='cafes_id_owner_id_unique') then
    alter table public.cafes add constraint cafes_id_owner_id_unique unique(id,owner_id);
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.cafe_user_features'::regclass and conname='cafe_user_features_membership_fk') then
    alter table public.cafe_user_features add constraint cafe_user_features_membership_fk
      foreign key(cafe_id,user_id) references public.cafe_members(cafe_id,user_id) on update cascade on delete cascade not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.cafes'::regclass and conname='cafes_archive_actor_consistent') then
    alter table public.cafes add constraint cafes_archive_actor_consistent check ((archived_at is null)=(archived_by is null)) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.day_entries'::regclass and conname='day_entries_void_actor_consistent') then
    alter table public.day_entries add constraint day_entries_void_actor_consistent check ((voided_at is null)=(voided_by is null)) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.journal_vouchers'::regclass and conname='journal_vouchers_void_actor_consistent') then
    alter table public.journal_vouchers add constraint journal_vouchers_void_actor_consistent check ((voided_at is null)=(voided_by is null)) not valid;
  end if;
  alter table public.cafe_user_features validate constraint cafe_user_features_membership_fk;
  alter table public.cafes validate constraint cafes_archive_actor_consistent;
  alter table public.day_entries validate constraint day_entries_void_actor_consistent;
  alter table public.journal_vouchers validate constraint journal_vouchers_void_actor_consistent;
end;
$constraints$;

create table if not exists public.accounting_change_events (
  id uuid primary key default gen_random_uuid(),
  cafe_id uuid not null references public.cafes(id) on update cascade on delete restrict,
  entity_type text not null check(entity_type in ('cafe','day_entry','journal_voucher')),
  entity_id uuid not null,
  event_type text not null check(event_type in ('baseline','create','update','void','restore','archive')),
  actor_id uuid references auth.users(id) on update cascade on delete set null,
  transaction_id bigint not null default txid_current(),
  old_record jsonb,
  new_record jsonb,
  occurred_at timestamptz not null default now(),
  check ((event_type in ('baseline','create'))=(old_record is null)),
  check (new_record is not null)
);
create index if not exists accounting_change_events_cafe_time_idx on public.accounting_change_events(cafe_id,occurred_at desc);
create index if not exists accounting_change_events_entity_time_idx on public.accounting_change_events(entity_type,entity_id,occurred_at desc);
create index if not exists accounting_change_events_actor_time_idx on public.accounting_change_events(actor_id,occurred_at desc) where actor_id is not null;
alter table public.accounting_change_events enable row level security;
revoke all on public.accounting_change_events from public, anon, authenticated;
grant select on public.accounting_change_events to authenticated;
drop policy if exists "Cafe users read accounting change events" on public.accounting_change_events;
create policy "Cafe users read accounting change events" on public.accounting_change_events for select to authenticated using (
  exists(select 1 from public.cafes c where c.id=accounting_change_events.cafe_id
    and (c.owner_id=(select auth.uid()) or exists(select 1 from public.cafe_members m where m.cafe_id=c.id and m.user_id=(select auth.uid()))))
);

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path='' as $function$
begin new.updated_at=now(); return new; end;
$function$;
revoke all on function public.touch_updated_at() from public, anon, authenticated;
do $updated_triggers$
declare t text;
begin
  foreach t in array array['cafes','cafe_user_features','day_entries','journal_vouchers','journal_account_options'] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop trigger if exists %I on public.%I',t||'_touch_updated_at',t);
      execute format('create trigger %I before update on public.%I for each row execute function public.touch_updated_at()',t||'_touch_updated_at',t);
    end if;
  end loop;
end;
$updated_triggers$;

create or replace function public.guard_accounting_history_changes()
returns trigger language plpgsql set search_path='' as $function$
declare is_admin boolean := coalesce(auth.jwt()->'app_metadata'->>'role','')='admin';
begin
  if tg_op='DELETE' then raise exception 'Accounting history cannot be hard-deleted; archive or void it instead' using errcode='restrict_violation'; end if;
  -- Dispatch by table before referring to fields absent from other row types.
  if tg_table_name='cafes' then
    if new.archived_at is distinct from old.archived_at then
      if not is_admin or old.owner_id is distinct from (select auth.uid()) or new.archived_by is distinct from (select auth.uid()) then
        raise exception 'Only the cafe owner admin can archive a cafe' using errcode='insufficient_privilege';
      end if;
      if old.archived_at is not null and new.archived_at is not null then raise exception 'An archived cafe cannot be re-archived'; end if;
    end if;
  elsif tg_table_name in ('day_entries','journal_vouchers') then
    if new.voided_at is distinct from old.voided_at then
      if not is_admin or (new.voided_at is not null and new.voided_by is distinct from (select auth.uid())) then
        raise exception 'Only an admin can void or restore accounting records' using errcode='insufficient_privilege';
      end if;
      if old.voided_at is not null and new.voided_at is not null then raise exception 'A voided record cannot be re-voided'; end if;
    end if;
  end if;
  return new;
end;
$function$;
revoke all on function public.guard_accounting_history_changes() from public, anon, authenticated;
drop trigger if exists cafes_guard_accounting_history on public.cafes;
create trigger cafes_guard_accounting_history before update or delete on public.cafes for each row execute function public.guard_accounting_history_changes();
drop trigger if exists day_entries_guard_accounting_history on public.day_entries;
create trigger day_entries_guard_accounting_history before update or delete on public.day_entries for each row execute function public.guard_accounting_history_changes();
drop trigger if exists journal_vouchers_guard_accounting_history on public.journal_vouchers;
create trigger journal_vouchers_guard_accounting_history before update or delete on public.journal_vouchers for each row execute function public.guard_accounting_history_changes();

create or replace function public.write_accounting_change_event()
returns trigger language plpgsql security definer set search_path='' as $function$
declare v_kind text; v_cafe uuid; v_id uuid; v_old jsonb; v_new jsonb; v_event text;
begin
  if tg_op='INSERT' then v_new=to_jsonb(new);
    v_kind=case tg_table_name when 'day_entries' then 'day_entry' when 'journal_vouchers' then 'journal_voucher' else 'cafe' end;
    v_id=(v_new->>'id')::uuid; v_cafe=case when v_kind='cafe' then v_id else (v_new->>'cafe_id')::uuid end; v_event='create';
  else v_old=to_jsonb(old); v_new=to_jsonb(new); v_kind=case tg_table_name when 'day_entries' then 'day_entry' when 'journal_vouchers' then 'journal_voucher' else 'cafe' end;
    v_id=(v_new->>'id')::uuid; v_cafe=case when v_kind='cafe' then v_id else (v_new->>'cafe_id')::uuid end;
    if tg_table_name='cafes' and (v_new->>'archived_at') is distinct from (v_old->>'archived_at') then v_event='archive';
    elsif tg_table_name in ('day_entries','journal_vouchers') and (v_old->>'voided_at') is distinct from (v_new->>'voided_at') then
      v_event=case when v_new->>'voided_at' is null then 'restore' else 'void' end;
    else v_event='update'; end if;
  end if;
  insert into public.accounting_change_events(cafe_id,entity_type,entity_id,event_type,actor_id,old_record,new_record)
  values(v_cafe,v_kind,v_id,v_event,(select auth.uid()),v_old,v_new);
  return new;
end;
$function$;
revoke all on function public.write_accounting_change_event() from public, anon, authenticated;
drop trigger if exists cafes_write_accounting_change_event on public.cafes;
create trigger cafes_write_accounting_change_event after insert or update on public.cafes for each row execute function public.write_accounting_change_event();
drop trigger if exists day_entries_write_accounting_change_event on public.day_entries;
create trigger day_entries_write_accounting_change_event after insert or update on public.day_entries for each row execute function public.write_accounting_change_event();
drop trigger if exists journal_vouchers_write_accounting_change_event on public.journal_vouchers;
create trigger journal_vouchers_write_accounting_change_event after insert or update on public.journal_vouchers for each row execute function public.write_accounting_change_event();

-- Baseline snapshots preserve legacy rows without mislabeling them as recent creates.
insert into public.accounting_change_events(cafe_id,entity_type,entity_id,event_type,new_record)
select id,'cafe',id,'baseline',to_jsonb(c) from public.cafes c
where not exists(select 1 from public.accounting_change_events e where e.entity_type='cafe' and e.entity_id=c.id);
insert into public.accounting_change_events(cafe_id,entity_type,entity_id,event_type,new_record)
select cafe_id,'day_entry',id,'baseline',to_jsonb(d) from public.day_entries d
where not exists(select 1 from public.accounting_change_events e where e.entity_type='day_entry' and e.entity_id=d.id);
insert into public.accounting_change_events(cafe_id,entity_type,entity_id,event_type,new_record)
select cafe_id,'journal_voucher',id,'baseline',to_jsonb(v) from public.journal_vouchers v
where not exists(select 1 from public.accounting_change_events e where e.entity_type='journal_voucher' and e.entity_id=v.id);

-- Remove delete access only; existing read/insert/update policies remain unchanged.
drop policy if exists "Admins delete cafes" on public.cafes;
drop policy if exists "Admins delete day entries" on public.day_entries;
drop policy if exists "Admins delete journal vouchers" on public.journal_vouchers;
revoke delete on public.cafes, public.day_entries, public.journal_vouchers from public, anon, authenticated;

-- This SECURITY DEFINER RPC reads auth.users email addresses; never expose it to anon/PUBLIC.
revoke all on function public.admin_list_cafe_users(uuid) from public, anon;
grant execute on function public.admin_list_cafe_users(uuid) to authenticated;

do $realtime$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(
    select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='accounting_change_events') then
    alter publication supabase_realtime add table public.accounting_change_events;
  end if;
end;
$realtime$;



-- Delegate only the actions explicitly enabled by the cafe owner/admin.
-- Existing feature rows are unchanged; absent permission keys mean false.

create or replace function public.can_use_cafe_management_feature(p_cafe_id uuid, p_feature text)
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $$
  select p_feature in ('addCafe','manageAccounts') and auth.uid() is not null and exists (
    select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null and (
      (c.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin')
      or exists (
        select 1 from public.cafe_members m join public.cafe_user_features f
          on f.cafe_id=m.cafe_id and f.user_id=m.user_id
        where m.cafe_id=c.id and m.user_id=auth.uid() and f.features->p_feature='true'::jsonb
      )
    )
  );
$$;
revoke all on function public.can_use_cafe_management_feature(uuid,text) from public, anon;
grant execute on function public.can_use_cafe_management_feature(uuid,text) to authenticated;

-- Keep direct cafe inserts admin-only. Delegated users create through this RPC.
-- Ownership stays with the source cafe owner; the creator becomes a member.
create or replace function public.create_cafe_with_access(p_source_cafe_id uuid, p_name text, p_location text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public
as $$
declare source_owner uuid; new_cafe public.cafes; actor uuid:=auth.uid();
begin
  if actor is null or not public.can_use_cafe_management_feature(p_source_cafe_id,'addCafe') then
    raise exception 'Add cafe is not enabled for this account' using errcode='42501';
  end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 80
     or p_location is null or length(btrim(p_location)) not between 1 and 100 then
    raise exception 'Enter a cafe name (1–80 characters) and location (1–100 characters)' using errcode='22023';
  end if;
  select owner_id into source_owner from public.cafes where id=p_source_cafe_id and archived_at is null for share;
  if source_owner is null then raise exception 'Source cafe is unavailable' using errcode='42501'; end if;
  -- Serialize delegated creation for this owner to avoid concurrent duplicate names/locations.
  perform pg_advisory_xact_lock(hashtextextended(source_owner::text,0));
  if exists(select 1 from public.cafes where owner_id=source_owner and archived_at is null
    and lower(btrim(name))=lower(btrim(p_name)) and lower(btrim(location))=lower(btrim(p_location))) then
    raise exception 'A cafe with that name and location already exists' using errcode='23505';
  end if;
  insert into public.cafes(owner_id,name,location) values(source_owner,btrim(p_name),btrim(p_location)) returning * into new_cafe;
  if actor<>source_owner then
    insert into public.cafe_members(cafe_id,user_id) values(new_cafe.id,actor);
    -- No management permission is carried over to the newly created cafe.
    insert into public.cafe_user_features(cafe_id,user_id) values(new_cafe.id,actor);
  end if;
  return jsonb_build_object('id',new_cafe.id,'owner_id',new_cafe.owner_id,'name',new_cafe.name,'location',new_cafe.location);
end;
$$;
revoke all on function public.create_cafe_with_access(uuid,text,text) from public, anon;
grant execute on function public.create_cafe_with_access(uuid,text,text) to authenticated;

drop policy if exists "Enabled users add journal account options" on public.journal_account_options;
create policy "Enabled users add journal account options" on public.journal_account_options
for insert to authenticated with check(public.can_use_cafe_management_feature(cafe_id,'manageAccounts'));
drop policy if exists "Enabled users update journal account options" on public.journal_account_options;
create policy "Enabled users update journal account options" on public.journal_account_options
for update to authenticated using(public.can_use_cafe_management_feature(cafe_id,'manageAccounts'))
with check(public.can_use_cafe_management_feature(cafe_id,'manageAccounts'));
-- No DELETE grant, no archive grant, no feature-settings write grant is added.


-- Requires 2026-10-05-user-management-features.sql first.
-- Delete is a soft removal; financial history and records are retained.

create or replace function public.can_use_cafe_management_feature(p_cafe_id uuid, p_feature text)
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $$
  select p_feature in ('addCafe','manageAccounts','deleteCafe') and auth.uid() is not null and exists (
    select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null and (
      (c.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin')
      or exists (
        select 1 from public.cafe_members m join public.cafe_user_features f
          on f.cafe_id=m.cafe_id and f.user_id=m.user_id
        where m.cafe_id=c.id and m.user_id=auth.uid() and f.features->p_feature='true'::jsonb
      )
    )
  );
$$;
revoke all on function public.can_use_cafe_management_feature(uuid,text) from public, anon;
grant execute on function public.can_use_cafe_management_feature(uuid,text) to authenticated;

create or replace function public.guard_accounting_history_changes()
returns trigger language plpgsql set search_path='' as $function$
declare is_admin boolean := coalesce(auth.jwt()->'app_metadata'->>'role','')='admin';
begin
  if tg_op='DELETE' then raise exception 'Accounting history cannot be hard-deleted; archive or void it instead' using errcode='restrict_violation'; end if;
  -- Dispatch by table before referring to fields absent from other row types.
  if tg_table_name='cafes' then
    if new.archived_at is distinct from old.archived_at then
      if new.archived_by is distinct from (select auth.uid()) or not (
        (is_admin and old.owner_id = (select auth.uid())) or
        (old.archived_at is null and new.archived_at is not null and public.can_use_cafe_management_feature(old.id,'deleteCafe'))
      ) then
        raise exception 'Delete cafe is not enabled for this account' using errcode='insufficient_privilege';
      end if;
      if old.archived_at is not null and new.archived_at is not null then raise exception 'An archived cafe cannot be re-archived'; end if;
    end if;
  elsif tg_table_name in ('day_entries','journal_vouchers') then
    if new.voided_at is distinct from old.voided_at then
      if not is_admin or (new.voided_at is not null and new.voided_by is distinct from (select auth.uid())) then
        raise exception 'Only an admin can void or restore accounting records' using errcode='insufficient_privilege';
      end if;
      if old.voided_at is not null and new.voided_at is not null then raise exception 'A voided record cannot be re-voided'; end if;
    end if;
  end if;
  return new;
end;
$function$;

create or replace function public.delete_cafe_with_access(p_cafe_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare cafe_owner uuid; actor uuid:=auth.uid();
begin
  if actor is null or not public.can_use_cafe_management_feature(p_cafe_id,'deleteCafe') then
    raise exception 'Delete cafe is not enabled for this account' using errcode='42501';
  end if;
  select owner_id into cafe_owner from public.cafes where id=p_cafe_id and archived_at is null;
  if cafe_owner is null then raise exception 'Cafe is unavailable' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(cafe_owner::text,0));
  if (select count(*) from public.cafes where owner_id=cafe_owner and archived_at is null)<2 then
    raise exception 'Keep at least one active cafe in this account' using errcode='23514';
  end if;
  update public.cafes set archived_at=now(),archived_by=actor where id=p_cafe_id and archived_at is null;
  if not found then raise exception 'Cafe is already deleted' using errcode='22023'; end if;
  return jsonb_build_object('id',p_cafe_id);
end;
$$;
revoke all on function public.delete_cafe_with_access(uuid) from public,anon;
grant execute on function public.delete_cafe_with_access(uuid) to authenticated;
-- Direct cafe UPDATE stays admin-only; no hard DELETE grant is added.

-- Incremental production fix. No business rows are rewritten or deleted.
-- Apply after the existing accounting-history migration.
-- Delegate only the actions explicitly enabled by the cafe owner/admin.
-- Existing feature rows are unchanged; absent permission keys mean false.

create or replace function public.can_use_cafe_management_feature(p_cafe_id uuid, p_feature text)
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $function$
  select p_feature in ('addCafe','manageAccounts') and auth.uid() is not null and exists (
    select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null and (
      (c.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin')
      or exists (
        select 1 from public.cafe_members m join public.cafe_user_features f
          on f.cafe_id=m.cafe_id and f.user_id=m.user_id
        where m.cafe_id=c.id and m.user_id=auth.uid() and f.features->p_feature='true'::jsonb
      )
    )
  );
$function$;
revoke all on function public.can_use_cafe_management_feature(uuid,text) from public, anon;
grant execute on function public.can_use_cafe_management_feature(uuid,text) to authenticated;

-- Keep direct cafe inserts admin-only. Delegated users create through this RPC.
-- Ownership stays with the source cafe owner; the creator becomes a member.
create or replace function public.create_cafe_with_access(p_source_cafe_id uuid, p_name text, p_location text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public
as $function$
declare source_owner uuid; new_cafe public.cafes; actor uuid:=auth.uid();
begin
  if actor is null or not public.can_use_cafe_management_feature(p_source_cafe_id,'addCafe') then
    raise exception 'Add cafe is not enabled for this account' using errcode='42501';
  end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 80
     or p_location is null or length(btrim(p_location)) not between 1 and 100 then
    raise exception 'Enter a cafe name (1–80 characters) and location (1–100 characters)' using errcode='22023';
  end if;
  select owner_id into source_owner from public.cafes where id=p_source_cafe_id and archived_at is null for share;
  if source_owner is null then raise exception 'Source cafe is unavailable' using errcode='42501'; end if;
  -- Serialize delegated creation for this owner to avoid concurrent duplicate names/locations.
  perform pg_advisory_xact_lock(hashtextextended(source_owner::text,0));
  if exists(select 1 from public.cafes where owner_id=source_owner and archived_at is null
    and lower(btrim(name))=lower(btrim(p_name)) and lower(btrim(location))=lower(btrim(p_location))) then
    raise exception 'A cafe with that name and location already exists' using errcode='23505';
  end if;
  insert into public.cafes(owner_id,name,location) values(source_owner,btrim(p_name),btrim(p_location)) returning * into new_cafe;
  if actor<>source_owner then
    insert into public.cafe_members(cafe_id,user_id) values(new_cafe.id,actor);
    -- No management permission is carried over to the newly created cafe.
    insert into public.cafe_user_features(cafe_id,user_id) values(new_cafe.id,actor);
  end if;
  return jsonb_build_object('id',new_cafe.id,'owner_id',new_cafe.owner_id,'name',new_cafe.name,'location',new_cafe.location);
end;
$function$;
revoke all on function public.create_cafe_with_access(uuid,text,text) from public, anon;
grant execute on function public.create_cafe_with_access(uuid,text,text) to authenticated;

drop policy if exists "Enabled users add journal account options" on public.journal_account_options;
create policy "Enabled users add journal account options" on public.journal_account_options
for insert to authenticated with check(public.can_use_cafe_management_feature(cafe_id,'manageAccounts'));
drop policy if exists "Enabled users update journal account options" on public.journal_account_options;
create policy "Enabled users update journal account options" on public.journal_account_options
for update to authenticated using(public.can_use_cafe_management_feature(cafe_id,'manageAccounts'))
with check(public.can_use_cafe_management_feature(cafe_id,'manageAccounts'));
-- No DELETE grant, no archive grant, no feature-settings write grant is added.

-- Requires 2026-10-05-user-management-features.sql first.
-- Delete is a soft removal; financial history and records are retained.

create or replace function public.can_use_cafe_management_feature(p_cafe_id uuid, p_feature text)
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $function$
  select p_feature in ('addCafe','manageAccounts','deleteCafe') and auth.uid() is not null and exists (
    select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null and (
      (c.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin')
      or exists (
        select 1 from public.cafe_members m join public.cafe_user_features f
          on f.cafe_id=m.cafe_id and f.user_id=m.user_id
        where m.cafe_id=c.id and m.user_id=auth.uid() and f.features->p_feature='true'::jsonb
      )
    )
  );
$function$;
revoke all on function public.can_use_cafe_management_feature(uuid,text) from public, anon;
grant execute on function public.can_use_cafe_management_feature(uuid,text) to authenticated;

create or replace function public.guard_accounting_history_changes()
returns trigger language plpgsql set search_path='' as $function$
declare is_admin boolean := coalesce(auth.jwt()->'app_metadata'->>'role','')='admin';
begin
  if tg_op='DELETE' then raise exception 'Accounting history cannot be hard-deleted; archive or void it instead' using errcode='restrict_violation'; end if;
  -- Dispatch by table before referring to fields absent from other row types.
  if tg_table_name='cafes' then
    if new.archived_at is distinct from old.archived_at then
      if new.archived_by is distinct from (select auth.uid()) or not (
        (is_admin and old.owner_id = (select auth.uid())) or
        (old.archived_at is null and new.archived_at is not null and public.can_use_cafe_management_feature(old.id,'deleteCafe'))
      ) then
        raise exception 'Delete cafe is not enabled for this account' using errcode='insufficient_privilege';
      end if;
      if old.archived_at is not null and new.archived_at is not null then raise exception 'An archived cafe cannot be re-archived'; end if;
    end if;
  elsif tg_table_name in ('day_entries','journal_vouchers') then
    if new.voided_at is distinct from old.voided_at then
      if not is_admin or old.owner_id is distinct from (select auth.uid()) or (new.voided_at is not null and new.voided_by is distinct from (select auth.uid())) then
        raise exception 'Only an admin can void or restore accounting records' using errcode='insufficient_privilege';
      end if;
      if old.voided_at is not null and new.voided_at is not null then raise exception 'A voided record cannot be re-voided'; end if;
    end if;
  end if;
  return new;
end;
$function$;

create or replace function public.delete_cafe_with_access(p_cafe_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $function$
declare cafe_owner uuid; actor uuid:=auth.uid();
begin
  if actor is null or not public.can_use_cafe_management_feature(p_cafe_id,'deleteCafe') then
    raise exception 'Delete cafe is not enabled for this account' using errcode='42501';
  end if;
  select owner_id into cafe_owner from public.cafes where id=p_cafe_id and archived_at is null;
  if cafe_owner is null then raise exception 'Cafe is unavailable' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(cafe_owner::text,0));
  if (select count(*) from public.cafes where owner_id=cafe_owner and archived_at is null)<2 then
    raise exception 'Keep at least one active cafe in this account' using errcode='23514';
  end if;
  update public.cafes set archived_at=now(),archived_by=actor where id=p_cafe_id and archived_at is null;
  if not found then raise exception 'Cafe is already deleted' using errcode='22023'; end if;
  return jsonb_build_object('id',p_cafe_id);
end;
$function$;
revoke all on function public.delete_cafe_with_access(uuid) from public,anon;
grant execute on function public.delete_cafe_with_access(uuid) to authenticated;
-- Direct cafe UPDATE stays admin-only; no hard DELETE grant is added.


create or replace function public.cafe_feature_allowed(p_cafe_id uuid,p_feature text)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(
  select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null and (
   (c.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin') or
   (exists(select 1 from public.cafe_members m where m.cafe_id=c.id and m.user_id=auth.uid()) and
    coalesce((select f.features->p_feature from public.cafe_user_features f where f.cafe_id=c.id and f.user_id=auth.uid()),
     case when p_feature in ('dayBook','sales','purchases','expenses','upiAccount','journalEntry','cash','ledgers') then 'true'::jsonb else 'false'::jsonb end)='true'::jsonb)
  )
 );
$$;
revoke all on function public.cafe_feature_allowed(uuid,text) from public,anon;
grant execute on function public.cafe_feature_allowed(uuid,text) to authenticated;

create or replace function public.cafe_raw_accounting_allowed(p_cafe_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select public.cafe_feature_allowed(p_cafe_id,'dayBook') or public.cafe_feature_allowed(p_cafe_id,'cash')
 or public.cafe_feature_allowed(p_cafe_id,'ledgers') or public.cafe_feature_allowed(p_cafe_id,'journalEntry')
 or public.cafe_feature_allowed(p_cafe_id,'reportsPnl');
$$;
revoke all on function public.cafe_raw_accounting_allowed(uuid) from public,anon;
grant execute on function public.cafe_raw_accounting_allowed(uuid) to authenticated;

-- A narrow Sales/Purchases/Expenses/UPI permission no longer grants whole-row access.
drop policy if exists "Owners read their day entries" on public.day_entries;
create policy "Owners read their day entries" on public.day_entries for select to authenticated
 using(public.cafe_raw_accounting_allowed(cafe_id));
drop policy if exists "Owners read their journal vouchers" on public.journal_vouchers;
create policy "Owners read their journal vouchers" on public.journal_vouchers for select to authenticated
 using(public.cafe_raw_accounting_allowed(cafe_id));
drop policy if exists "Owners add their day entries" on public.day_entries;
drop policy if exists "Owners add their journal vouchers" on public.journal_vouchers;
drop policy if exists "Owners edit their day entries" on public.day_entries;
create policy "Owners edit their day entries" on public.day_entries for update to authenticated
 using(public.cafe_feature_allowed(cafe_id,'dayBook')) with check(public.cafe_feature_allowed(cafe_id,'dayBook'));
drop policy if exists "Owners edit their journal vouchers" on public.journal_vouchers;
create policy "Owners edit their journal vouchers" on public.journal_vouchers for update to authenticated
 using(public.cafe_feature_allowed(cafe_id,'journalEntry')) with check(public.cafe_feature_allowed(cafe_id,'journalEntry'));
-- All financial writes use checked RPCs; existing admin void controls retain their two columns.
revoke insert,update,delete on public.day_entries,public.journal_vouchers from public,anon,authenticated;
grant update(voided_at,voided_by) on public.day_entries,public.journal_vouchers to authenticated;
drop policy if exists "Cafe users read accounting change events" on public.accounting_change_events;
create policy "Cafe users read accounting change events" on public.accounting_change_events for select to authenticated
 using(exists(select 1 from public.cafes c where c.id=accounting_change_events.cafe_id and c.owner_id=auth.uid()
 and auth.jwt()->'app_metadata'->>'role'='admin'));

create or replace function public.cafe_accounting_snapshot(p_cafe_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare raw_ok boolean; sales_ok boolean; purchases_ok boolean; expenses_ok boolean; upi_ok boolean;
 days jsonb; vouchers jsonb; options jsonb;
begin
 if not exists(select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null
  and ((c.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin') or
   exists(select 1 from public.cafe_members m where m.cafe_id=c.id and m.user_id=auth.uid()))) then
  raise exception 'Cafe access is unavailable' using errcode='42501';
 end if;
 raw_ok:=public.cafe_raw_accounting_allowed(p_cafe_id);
 sales_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'sales');
 purchases_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'purchases');
 expenses_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'expenses');
 upi_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'upiAccount');
 select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'updated_at',d.updated_at,'entry_date',d.entry_date,
  'sale',case when sales_ok then d.sale else 0 end,'upi',case when upi_ok then d.upi else 0 end,
  'purchase',case when purchases_ok then d.purchase else 0 end,'other_expense',case when expenses_ok then d.other_expense else 0 end,
  'remarks',case when raw_ok then d.remarks else '' end) order by d.entry_date),'[]'::jsonb) into days
 from public.day_entries d where d.cafe_id=p_cafe_id and d.voided_at is null and (raw_ok or sales_ok or purchases_ok or expenses_ok or upi_ok);
 select coalesce(jsonb_agg(to_jsonb(v)||jsonb_build_object('lines',q.lines,'remark',case when raw_ok then v.remark else '' end) order by v.voucher_no),'[]'::jsonb) into vouchers
 from public.journal_vouchers v cross join lateral (
  select jsonb_agg(case when not raw_ok
   and not exists(select 1 from jsonb_array_elements(v.lines) original where original ? 'transferRole'
    or original->>'particulars' not in ('Cash','UPI Account','Bank'))
   and (select count(distinct original->>'particulars') from jsonb_array_elements(v.lines) original)>=2
   then l.value||jsonb_build_object('side',case when l.value->>'side'='debit' then 'credit' else 'debit' end,
    'transferRole',case when l.value->>'side'='debit' then 'source' else 'destination' end)
   else l.value end order by l.ordinality) as lines from jsonb_array_elements(v.lines) with ordinality l(value,ordinality)
  where raw_ok or (sales_ok and l.value->>'particulars' in ('Sales','Cash Sale'))
   or (purchases_ok and l.value->>'particulars'='Purchases') or (expenses_ok and l.value->>'particulars' in ('Expenses','Other Expenses'))
   or (upi_ok and l.value->>'particulars'='UPI Account')
 ) q where v.cafe_id=p_cafe_id and q.lines is not null;
 select coalesce(jsonb_agg(jsonb_build_object('account_name',a.account_name,'enabled',a.enabled)),'[]'::jsonb) into options
 from public.journal_account_options a where a.cafe_id=p_cafe_id and
 (public.cafe_feature_allowed(p_cafe_id,'journalEntry') or public.cafe_feature_allowed(p_cafe_id,'manageAccounts'));
 return jsonb_build_object('day_entries',days,'journal_vouchers',vouchers,'journal_account_options',options);
end;
$$;
revoke all on function public.cafe_accounting_snapshot(uuid) from public,anon;
grant execute on function public.cafe_accounting_snapshot(uuid) to authenticated;

create or replace function public.save_day_entry_checked(p_cafe_id uuid,p_entry_date date,p_expected_updated_at timestamptz,
 p_sale numeric,p_upi numeric,p_purchase numeric,p_other_expense numeric,p_remarks text)
returns public.day_entries language plpgsql security definer set search_path='' as $$
declare saved public.day_entries; cafe_owner uuid; value numeric;
begin
 if not public.cafe_feature_allowed(p_cafe_id,'dayBook') then raise exception 'Day Book is not enabled' using errcode='42501'; end if;
 foreach value in array array[p_sale,p_upi,p_purchase,p_other_expense] loop
  if value is null or value<0 or value>9999999999.99 or value<>round(value,2) then raise exception 'Amounts must be non-negative with up to two decimal places' using errcode='22023'; end if;
 end loop;
 if p_upi>p_sale then raise exception 'UPI cannot exceed sales' using errcode='22023'; end if;
 select owner_id into cafe_owner from public.cafes where id=p_cafe_id and archived_at is null for share;
 if cafe_owner is null then raise exception 'Cafe is unavailable' using errcode='42501'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_cafe_id::text||':day:'||p_entry_date::text,0));
 select * into saved from public.day_entries where cafe_id=p_cafe_id and entry_date=p_entry_date for update;
 if found then
  if p_expected_updated_at is null and saved.voided_at is null and saved.sale=p_sale and saved.upi=p_upi and saved.purchase=p_purchase and saved.other_expense=p_other_expense and saved.remarks=p_remarks then return saved; end if;
   if saved.updated_at is distinct from p_expected_updated_at then raise exception 'This day entry changed elsewhere. Reload the date before saving; your draft has been kept.' using errcode='40001'; end if;
  if saved.voided_at is not null then raise exception 'This entry was voided. Restore it explicitly before editing.' using errcode='40001'; end if;
  update public.day_entries set sale=p_sale,upi=p_upi,purchase=p_purchase,other_expense=p_other_expense,remarks=p_remarks where id=saved.id returning * into saved;
 else
  if p_expected_updated_at is not null then raise exception 'This day entry is no longer available' using errcode='40001'; end if;
  insert into public.day_entries(owner_id,cafe_id,entry_date,sale,upi,purchase,other_expense,remarks)
   values(cafe_owner,p_cafe_id,p_entry_date,p_sale,p_upi,p_purchase,p_other_expense,p_remarks) returning * into saved;
 end if;
 return saved;
end;
$$;
revoke all on function public.save_day_entry_checked(uuid,date,timestamptz,numeric,numeric,numeric,numeric,text) from public,anon;
grant execute on function public.save_day_entry_checked(uuid,date,timestamptz,numeric,numeric,numeric,numeric,text) to authenticated;

create or replace function public.save_journal_voucher_checked(p_cafe_id uuid,p_id uuid,p_expected_updated_at timestamptz,
 p_voucher_date date,p_remark text,p_lines jsonb)
returns public.journal_vouchers language plpgsql security definer set search_path='' as $$
declare saved public.journal_vouchers; cafe_owner uuid; number_next bigint;
begin
 if not public.cafe_feature_allowed(p_cafe_id,'journalEntry') then raise exception 'Journal Entry is not enabled' using errcode='42501'; end if;
 if public.journal_lines_are_balanced(p_lines) is not true then raise exception 'Voucher lines must be valid and balanced' using errcode='22023'; end if;
 select owner_id into cafe_owner from public.cafes where id=p_cafe_id and archived_at is null for share;
 if cafe_owner is null then raise exception 'Cafe is unavailable' using errcode='42501'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_cafe_id::text||':journal',0));
 if p_id is not null then
  select * into saved from public.journal_vouchers where id=p_id and cafe_id=p_cafe_id for update;
 end if;
 if saved.id is not null then
  if saved.voided_at is not null then raise exception 'This voucher was voided. Reload before saving.' using errcode='40001'; end if;
  -- Return the same create result after a lost response, without a second posting or audit event.
  if p_expected_updated_at is null then
   if saved.voucher_date=p_voucher_date and saved.remark=p_remark and saved.lines=p_lines then return saved; end if;
   raise exception 'This request ID already belongs to a different voucher. Reload before saving.' using errcode='40001';
  end if;
  if saved.updated_at is distinct from p_expected_updated_at then
   raise exception 'This voucher changed elsewhere. Reload before saving; your draft has been kept.' using errcode='40001';
  end if;
  if p_lines is distinct from saved.lines and not exists(select 1 from jsonb_array_elements(p_lines) l where l ? 'transferRole' or l ? 'postingRule') then
   raise exception 'Refresh the application before changing voucher lines' using errcode='22023';
  end if;
  update public.journal_vouchers set voucher_date=p_voucher_date,remark=p_remark,lines=p_lines where id=p_id returning * into saved;
 else
  if p_expected_updated_at is not null then raise exception 'This voucher is no longer available' using errcode='40001'; end if;
  if not exists(select 1 from jsonb_array_elements(p_lines) l where l ? 'transferRole' or l ? 'postingRule') then
   raise exception 'Refresh the application before creating a voucher' using errcode='22023';
  end if;
  select coalesce(max(voucher_no),0)+1 into number_next from public.journal_vouchers where cafe_id=p_cafe_id;
  insert into public.journal_vouchers(id,owner_id,cafe_id,voucher_no,voucher_date,remark,lines)
   values(coalesce(p_id,gen_random_uuid()),cafe_owner,p_cafe_id,number_next,p_voucher_date,p_remark,p_lines) returning * into saved;
 end if;
 return saved;
end;
$$;
revoke all on function public.save_journal_voucher_checked(uuid,uuid,timestamptz,date,text,jsonb) from public,anon;
grant execute on function public.save_journal_voucher_checked(uuid,uuid,timestamptz,date,text,jsonb) to authenticated;

create or replace function public.journal_posting_rules_valid(p_lines jsonb)
returns boolean language sql immutable set search_path='' as $$
 select jsonb_typeof(p_lines)='array' and not exists(
  select 1 from jsonb_array_elements(p_lines) l where l ? 'postingRule' and
  (l->>'postingRule' is distinct from 'account-normal-v1' or l ? 'transferRole')
 ) and (not exists(select 1 from jsonb_array_elements(p_lines) l where l ? 'postingRule')
 or not exists(select 1 from jsonb_array_elements(p_lines) l where not (l ? 'postingRule')));
$$;
revoke all on function public.journal_posting_rules_valid(jsonb) from public,anon;
grant execute on function public.journal_posting_rules_valid(jsonb) to authenticated;
do $$ begin
 if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.journal_vouchers'::regclass and conname='journal_vouchers_posting_rules_valid') then
  alter table public.journal_vouchers add constraint journal_vouchers_posting_rules_valid check(public.journal_posting_rules_valid(lines)) not valid;
 end if;
 alter table public.journal_vouchers validate constraint journal_vouchers_posting_rules_valid;
end $$;

-- Narrow raw option reads to actual Journal/Accounts access.
drop policy if exists "Cafe users read journal account options" on public.journal_account_options;
create policy "Cafe users read journal account options" on public.journal_account_options for select to authenticated
 using(public.cafe_feature_allowed(cafe_id,'journalEntry') or public.cafe_feature_allowed(cafe_id,'manageAccounts'));

-- Realtime refreshes the accessible cafe list and memberships as well as entries.
do $$ declare t text; begin
 foreach t in array array['cafes','cafe_members'] loop
  if not exists(select 1 from pg_catalog.pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
   execute pg_catalog.format('alter publication supabase_realtime add table public.%I',t);
  end if;
 end loop;
end $$;

-- Account approval extension: requires one existing cafe owner-admin.
-- LOCAL DRAFT ONLY. Apply only after production preflight and separate approval.
-- Requires the accounting-history and checked-accounting migrations first.
-- This application currently has one approving cafe owner. Refuse ambiguous routing.

create table if not exists public.user_account_access (
 user_id uuid primary key references auth.users(id) on delete restrict,
 owner_id uuid not null references auth.users(id) on delete restrict,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 reason text not null default '' check(length(reason)<=500),
 reviewed_by uuid references auth.users(id) on delete restrict,
 reviewed_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check((status='pending' and reviewed_by is null and reviewed_at is null)
    or (status<>'pending' and reviewed_by is not null and reviewed_by=owner_id and reviewed_at is not null)),
 check(status<>'rejected' or length(btrim(reason))>0)
);
create index if not exists user_account_access_review_idx
 on public.user_account_access(owner_id,status,created_at,user_id);

create table if not exists public.user_notifications (
 id uuid primary key default gen_random_uuid(),
 recipient_id uuid not null references auth.users(id) on delete restrict,
 subject_user_id uuid not null references auth.users(id) on delete restrict,
 kind text not null check(kind in ('registration_pending','registration_approved','registration_rejected')),
 message text not null check(length(message) between 1 and 1000),
 created_at timestamptz not null default now(),
 read_at timestamptz,
 unique(recipient_id,subject_user_id,kind)
);
create index if not exists user_notifications_recipient_time_idx
 on public.user_notifications(recipient_id,created_at desc,id);
create index if not exists user_notifications_unread_idx
 on public.user_notifications(recipient_id) where read_at is null;

alter table public.user_account_access enable row level security;
alter table public.user_notifications enable row level security;
revoke all on public.user_account_access,public.user_notifications from public,anon,authenticated;
grant select on public.user_account_access,public.user_notifications to authenticated;

create or replace function public.account_is_approved()
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(
  select 1 from public.user_account_access a where a.user_id=auth.uid() and a.status='approved'
 );
$$;
revoke all on function public.account_is_approved() from public,anon;
grant execute on function public.account_is_approved() to authenticated;

drop policy if exists "Users read own approval" on public.user_account_access;
create policy "Users read own approval" on public.user_account_access for select to authenticated
 using(user_id=auth.uid() or (owner_id=auth.uid() and public.account_is_approved()
 and auth.jwt()->'app_metadata'->>'role'='admin'));
drop policy if exists "Users read own notifications" on public.user_notifications;
create policy "Users read own notifications" on public.user_notifications for select to authenticated
 using(recipient_id=auth.uid());

-- Preserve existing assigned users. Never approve an unassigned legacy account.
-- No accounting amounts, vouchers, cafe ownership or existing feature rows are rewritten.
do $$
declare approving_owner uuid; owner_count integer;
begin
 select count(*),min(owner_id::text)::uuid into owner_count,approving_owner from (
  select distinct c.owner_id from public.cafes c join auth.users u on u.id=c.owner_id
  where coalesce(u.raw_app_meta_data->>'role','')='admin'
 ) owners;
 if owner_count<>1 then
  raise exception 'Approval setup requires exactly one existing cafe owner-admin. Review registration routing before applying this migration.';
 end if;
 insert into public.user_account_access(user_id,owner_id,status,reviewed_by,reviewed_at)
 select u.id,approving_owner,
  case when u.id=approving_owner or exists(select 1 from public.cafe_members m join public.cafes c on c.id=m.cafe_id
    where m.user_id=u.id and c.owner_id=approving_owner) then 'approved' else 'pending' end,
  case when u.id=approving_owner or exists(select 1 from public.cafe_members m join public.cafes c on c.id=m.cafe_id
    where m.user_id=u.id and c.owner_id=approving_owner) then approving_owner end,
  case when u.id=approving_owner or exists(select 1 from public.cafe_members m join public.cafes c on c.id=m.cafe_id
    where m.user_id=u.id and c.owner_id=approving_owner) then now() end
 from auth.users u on conflict(user_id) do nothing;
 insert into public.user_notifications(recipient_id,subject_user_id,kind,message)
 select a.owner_id,a.user_id,'registration_pending','Account approval requested: '||coalesce(u.email,'User')
 from public.user_account_access a join auth.users u on u.id=a.user_id where a.status='pending'
 on conflict(recipient_id,subject_user_id,kind) do nothing;
end;
$$;

create or replace function public.register_pending_account()
returns trigger language plpgsql security definer set search_path='' as $$
declare approving_owner uuid; owner_count integer;
begin
 select count(*),min(owner_id::text)::uuid into owner_count,approving_owner from (
  select distinct c.owner_id from public.cafes c join auth.users u on u.id=c.owner_id
  where coalesce(u.raw_app_meta_data->>'role','')='admin'
 ) owners;
 if owner_count<>1 then raise exception 'Account registration is unavailable until the owner configures approval routing'; end if;
 insert into public.user_account_access(user_id,owner_id) values(new.id,approving_owner);
 insert into public.user_notifications(recipient_id,subject_user_id,kind,message)
 values(approving_owner,new.id,'registration_pending','Account approval requested: '||coalesce(new.email,'User'));
 return new;
end;
$$;
revoke all on function public.register_pending_account() from public,anon,authenticated;
drop trigger if exists register_pending_account on auth.users;
create trigger register_pending_account after insert on auth.users
 for each row execute function public.register_pending_account();

drop trigger if exists user_account_access_touch_updated_at on public.user_account_access;
create trigger user_account_access_touch_updated_at before update on public.user_account_access
 for each row execute function public.touch_updated_at();

create or replace function public.my_account_access()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.user_account_access;
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 select * into a from public.user_account_access where user_id=auth.uid();
 if not found then raise exception 'Your account approval record is unavailable. Ask the owner to review setup.' using errcode='42501'; end if;
 return jsonb_build_object('status',a.status,'reason',a.reason,'reviewed_at',a.reviewed_at,
  'can_review',a.status='approved' and a.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin');
end;
$$;
revoke all on function public.my_account_access() from public,anon;
grant execute on function public.my_account_access() to authenticated;

create or replace function public.admin_pending_accounts(p_cafe_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.account_is_approved() or coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
  or not exists(select 1 from public.cafes c where c.id=p_cafe_id and c.owner_id=auth.uid() and c.archived_at is null) then
  raise exception 'Only the owning admin can review accounts' using errcode='42501';
 end if;
 return (select coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) from (
  select a.user_id,u.email,a.created_at,a.updated_at from public.user_account_access a
  join auth.users u on u.id=a.user_id where a.owner_id=auth.uid() and a.status='pending'
  order by a.created_at,a.user_id limit 50
 ) q);
end;
$$;
revoke all on function public.admin_pending_accounts(uuid) from public,anon;
grant execute on function public.admin_pending_accounts(uuid) to authenticated;

create or replace function public.review_account(p_user_id uuid,p_cafe_id uuid,p_decision text,p_reason text,p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.user_account_access; actor uuid:=auth.uid();
begin
 if not public.account_is_approved() or coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
  or not exists(select 1 from public.cafes c where c.id=p_cafe_id and c.owner_id=actor and c.archived_at is null) then
  raise exception 'Only the owning admin can review accounts' using errcode='42501';
 end if;
 if p_decision is null or p_decision not in ('approved','rejected') or p_reason is null or length(p_reason)>500
  or (p_decision='rejected' and length(btrim(p_reason))=0) then raise exception 'Choose a valid decision; rejection needs a reason (maximum 500 characters)' using errcode='22023'; end if;
 select * into a from public.user_account_access where user_id=p_user_id and owner_id=actor for update;
 if not found or a.status<>'pending' or a.updated_at is distinct from p_expected_updated_at then
  raise exception 'This request changed or was already reviewed. Refresh the list.' using errcode='40001';
 end if;
 if p_user_id=actor then raise exception 'You cannot approve your own account' using errcode='42501'; end if;
 if p_decision='approved' then
  insert into public.cafe_members(cafe_id,user_id) values(p_cafe_id,p_user_id) on conflict do nothing;
  -- Start with no enabled features. The owner chooses permissions in existing Settings.
  insert into public.cafe_user_features(cafe_id,user_id,features) values(p_cafe_id,p_user_id,
   '{"dayBook":false,"sales":false,"purchases":false,"expenses":false,"upiAccount":false,"reportsPnl":false,"journalEntry":false,"cash":false,"ledgers":false,"rpos":false,"addCafe":false,"manageAccounts":false,"deleteCafe":false}'::jsonb)
   on conflict(cafe_id,user_id) do nothing;
 end if;
 update public.user_account_access set status=p_decision,reason=btrim(p_reason),reviewed_by=actor,reviewed_at=now()
 where user_id=p_user_id returning * into a;
 insert into public.user_notifications(recipient_id,subject_user_id,kind,message)
 values(p_user_id,p_user_id,'registration_'||p_decision,
  case when p_decision='approved' then 'Your account was approved. Your cafe owner controls which features you can use.'
  else 'Your account was rejected. Reason: '||a.reason end);
 return jsonb_build_object('status',a.status,'user_id',a.user_id);
end;
$$;
revoke all on function public.review_account(uuid,uuid,text,text,timestamptz) from public,anon;
grant execute on function public.review_account(uuid,uuid,text,text,timestamptz) to authenticated;

create or replace function public.mark_notification_read(p_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 update public.user_notifications set read_at=coalesce(read_at,now()) where id=p_id and recipient_id=auth.uid();
 return found;
end;
$$;
revoke all on function public.mark_notification_read(uuid) from public,anon;
grant execute on function public.mark_notification_read(uuid) to authenticated;

-- Restrictive policies are ANDed with every existing permissive cafe policy.
-- Pending/rejected users can read only their status/notifications, never financial tables.
do $$ declare t text; begin
 foreach t in array array['cafes','cafe_members','cafe_user_features','day_entries','journal_vouchers','journal_account_options','accounting_change_events'] loop
  execute pg_catalog.format('drop policy if exists "Approved accounts only" on public.%I',t);
  execute pg_catalog.format('create policy "Approved accounts only" on public.%I as restrictive for all to authenticated using (public.account_is_approved()) with check (public.account_is_approved())',t);
 end loop;
end;
$$;

-- SECURITY DEFINER accounting RPCs must also pass the approval gate.
-- Use the existing owner/member access functions; do not invent another financial model.
create or replace function public.cafe_feature_allowed(p_cafe_id uuid,p_feature text)
returns boolean language sql stable security definer set search_path='' as $$
 select public.account_is_approved() and exists(
  select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null and (
   (c.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin') or
   (exists(select 1 from public.cafe_members m where m.cafe_id=c.id and m.user_id=auth.uid()) and
    coalesce((select f.features->p_feature from public.cafe_user_features f where f.cafe_id=c.id and f.user_id=auth.uid()),
     case when p_feature in ('dayBook','sales','purchases','expenses','upiAccount','journalEntry','cash','ledgers') then 'true'::jsonb else 'false'::jsonb end)='true'::jsonb)
  )
 );
$$;
create or replace function public.can_use_cafe_management_feature(p_cafe_id uuid,p_feature text)
returns boolean language sql stable security definer set search_path='' as $$
 select public.account_is_approved() and p_feature in ('addCafe','manageAccounts','deleteCafe') and exists(
  select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null and (
   (c.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin') or
   exists(select 1 from public.cafe_members m join public.cafe_user_features f on f.cafe_id=m.cafe_id and f.user_id=m.user_id
    where m.cafe_id=c.id and m.user_id=auth.uid() and f.features->p_feature='true'::jsonb)
  )
 );
$$;

do $$ begin
 if exists(select 1 from pg_catalog.pg_publication where pubname='supabase_realtime') then
  if not exists(select 1 from pg_catalog.pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='user_account_access') then
   alter publication supabase_realtime add table public.user_account_access;
  end if;
  if not exists(select 1 from pg_catalog.pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='user_notifications') then
   alter publication supabase_realtime add table public.user_notifications;
  end if;
 end if;
end;
$$;

-- Definer functions bypass RLS, so each public read endpoint also checks approval.
create or replace function public.cafe_accounting_snapshot(p_cafe_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare raw_ok boolean; sales_ok boolean; purchases_ok boolean; expenses_ok boolean; upi_ok boolean;
 days jsonb; vouchers jsonb; options jsonb;
begin
 if not public.account_is_approved() then raise exception 'Account approval is required' using errcode='42501'; end if;
 if not exists(select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null
  and ((c.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin') or
   exists(select 1 from public.cafe_members m where m.cafe_id=c.id and m.user_id=auth.uid()))) then
  raise exception 'Cafe access is unavailable' using errcode='42501';
 end if;
 raw_ok:=public.cafe_raw_accounting_allowed(p_cafe_id);
 sales_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'sales');
 purchases_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'purchases');
 expenses_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'expenses');
 upi_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'upiAccount');
 select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'updated_at',d.updated_at,'entry_date',d.entry_date,
  'sale',case when sales_ok then d.sale else 0 end,'upi',case when upi_ok then d.upi else 0 end,
  'purchase',case when purchases_ok then d.purchase else 0 end,'other_expense',case when expenses_ok then d.other_expense else 0 end,
  'remarks',case when raw_ok then d.remarks else '' end) order by d.entry_date),'[]'::jsonb) into days
 from public.day_entries d where d.cafe_id=p_cafe_id and d.voided_at is null and (raw_ok or sales_ok or purchases_ok or expenses_ok or upi_ok);
 select coalesce(jsonb_agg(to_jsonb(v)||jsonb_build_object('lines',q.lines,'remark',case when raw_ok then v.remark else '' end) order by v.voucher_no),'[]'::jsonb) into vouchers
 from public.journal_vouchers v cross join lateral (
  select jsonb_agg(case when not raw_ok
   and not exists(select 1 from jsonb_array_elements(v.lines) original where original ? 'transferRole'
    or original->>'particulars' not in ('Cash','UPI Account','Bank'))
   and (select count(distinct original->>'particulars') from jsonb_array_elements(v.lines) original)>=2
   then l.value||jsonb_build_object('side',case when l.value->>'side'='debit' then 'credit' else 'debit' end,
    'transferRole',case when l.value->>'side'='debit' then 'source' else 'destination' end)
   else l.value end order by l.ordinality) as lines from jsonb_array_elements(v.lines) with ordinality l(value,ordinality)
  where raw_ok or (sales_ok and l.value->>'particulars' in ('Sales','Cash Sale'))
   or (purchases_ok and l.value->>'particulars'='Purchases') or (expenses_ok and l.value->>'particulars' in ('Expenses','Other Expenses'))
   or (upi_ok and l.value->>'particulars'='UPI Account')
 ) q where v.cafe_id=p_cafe_id and q.lines is not null;
 select coalesce(jsonb_agg(jsonb_build_object('account_name',a.account_name,'enabled',a.enabled)),'[]'::jsonb) into options
 from public.journal_account_options a where a.cafe_id=p_cafe_id and
 (public.cafe_feature_allowed(p_cafe_id,'journalEntry') or public.cafe_feature_allowed(p_cafe_id,'manageAccounts'));
 return jsonb_build_object('day_entries',days,'journal_vouchers',vouchers,'journal_account_options',options);
end;
$$;
create or replace function public.admin_list_cafe_users(p_cafe_id uuid)
returns table(user_id uuid, email text, features jsonb)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if not public.account_is_approved() or coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') <> 'admin' or not exists (
    select 1 from public.cafes c where c.id = p_cafe_id and c.owner_id = auth.uid()
  ) then
    raise exception 'Only the cafe admin can manage its users';
  end if;
  return query
    select m.user_id, u.email::text,
      coalesce(f.features, '{"dayBook":true,"sales":true,"purchases":true,"expenses":true,"upiAccount":true,"reportsPnl":false,"journalEntry":true,"cash":true,"ledgers":true}'::jsonb)
    from public.cafe_members m
    join auth.users u on u.id = m.user_id
    left join public.cafe_user_features f on f.cafe_id = m.cafe_id and f.user_id = m.user_id
    where m.cafe_id = p_cafe_id
    order by lower(u.email);
end;
$function$;
create or replace function public.admin_can_manage_cafe_user(p_cafe_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select public.account_is_approved() and coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin'
    and exists (
      select 1 from public.cafes c
      where c.id = p_cafe_id and c.owner_id = (select auth.uid())
    ) and exists (
      select 1 from public.cafe_members m
      where m.cafe_id = p_cafe_id and m.user_id = p_user_id
    );
$function$;
revoke all on function public.cafe_accounting_snapshot(uuid),public.admin_list_cafe_users(uuid),public.admin_can_manage_cafe_user(uuid,uuid),public.cafe_feature_allowed(uuid,text),public.can_use_cafe_management_feature(uuid,text) from public,anon;
grant execute on function public.cafe_accounting_snapshot(uuid),public.admin_list_cafe_users(uuid),public.admin_can_manage_cafe_user(uuid,uuid),public.cafe_feature_allowed(uuid,text),public.can_use_cafe_management_feature(uuid,text) to authenticated;

commit;
