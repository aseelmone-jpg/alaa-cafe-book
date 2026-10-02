-- Focused migration for the existing Alaa Cafe database.
-- Run with the Supabase SQL Editor's database-owner role after reviewing preflight.
-- No cafe, membership, day-book, feature-setting, or voucher records are updated/deleted.
-- Existing cafe/day-book/journal access policies are deliberately not replaced here.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $prerequisites$
declare
  v_table_name text;
begin
  foreach v_table_name in array array['cafes', 'cafe_members', 'cafe_user_features', 'journal_vouchers'] loop
    if to_regclass('public.' || v_table_name) is null then
      raise exception 'Required table public.% is missing; migration stopped', v_table_name;
    end if;
  end loop;
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise exception 'supabase_realtime publication is missing; migration stopped';
  end if;
end;
$prerequisites$;

-- Prevent a concurrent cafe/voucher insert from escaping the preflight and account seed.
-- Reads can continue; a busy write workload causes a timeout and rolls back this migration.
lock table public.cafes, public.journal_vouchers in share row exclusive mode;

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
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    return false;
  end if;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_count := v_count + 1;
    v_side := v_line ->> 'side';
    v_account := btrim(coalesce(v_line ->> 'particulars', ''));
    v_amount_text := v_line ->> 'amount';
    if v_side is null or v_side not in ('debit', 'credit') or v_account = '' then
      return false;
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
  return v_count >= 2 and v_debit > 0 and v_debit = v_credit;
exception when others then
  return false;
end;
$function$;
revoke all on function public.journal_lines_are_balanced(jsonb) from public, anon;
grant execute on function public.journal_lines_are_balanced(jsonb) to authenticated;

-- Any data conflict aborts the entire transaction instead of repairing real records.
do $data_preflight$
declare
  v_conflicts bigint;
begin
  select count(*) into v_conflicts
  from public.journal_vouchers j
  where public.journal_lines_are_balanced(j.lines) is not true;
  if v_conflicts > 0 then
    raise exception '% existing journal voucher(s) have invalid or unbalanced lines; no changes applied', v_conflicts;
  end if;

  select count(*) into v_conflicts
  from public.journal_vouchers j
  cross join lateral jsonb_array_elements(j.lines) as line(value)
  where length(btrim(coalesce(line.value ->> 'particulars', ''))) > 120;
  if v_conflicts > 0 then
    raise exception '% existing journal account name(s) exceed 120 characters; no names changed and no migration applied', v_conflicts;
  end if;
end;
$data_preflight$;

do $journal_constraint$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.journal_vouchers'::regclass
      and conname = 'journal_vouchers_lines_balanced'
  ) then
    alter table public.journal_vouchers
      add constraint journal_vouchers_lines_balanced
      check (public.journal_lines_are_balanced(lines)) not valid;
  end if;
end;
$journal_constraint$;
alter table public.journal_vouchers validate constraint journal_vouchers_lines_balanced;

-- Existing staff memberships remain private. This helper checks only the requested
-- member of a cafe owned by the signed-in admin, without recursive RLS evaluation.
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

-- Replace only the broken admin settings policy; keep the user's read policy.
drop policy if exists "Admins manage cafe feature settings" on public.cafe_user_features;
create policy "Admins manage cafe feature settings" on public.cafe_user_features
  for all to authenticated using (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin' and exists (
      select 1 from public.cafes c where c.id = cafe_user_features.cafe_id and c.owner_id = (select auth.uid())
    )
  ) with check (
    public.admin_can_manage_cafe_user(cafe_id, user_id)
  );

-- Availability flags are separate from vouchers and their historical account names.
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

-- Preserve every existing enabled/disabled flag when this migration is rerun.
insert into public.journal_account_options (cafe_id, account_name, enabled)
select c.id, a.account_name, true
from public.cafes c
cross join (values ('Cash'), ('UPI Account'), ('Sales'), ('Purchases'), ('Other Expenses')) as a(account_name)
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

-- The other three subscriptions are already enabled; add only the missing table.
do $realtime$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'journal_account_options'
  ) then
    alter publication supabase_realtime add table public.journal_account_options;
  end if;
end;
$realtime$;

commit;
