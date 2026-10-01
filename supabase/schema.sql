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
grant execute on function public.journal_lines_are_balanced(jsonb) to authenticated;

do $journal_check$
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
end
$journal_check$;

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
grant select, insert, update on public.journal_account_options to authenticated;

-- Seed only account names already used by the current day-book posting logic, plus
-- any names already present in saved vouchers. Preserve prior enabled/disabled choices.
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
revoke all on function public.seed_journal_accounts_for_cafe() from public, authenticated;
revoke all on function public.enforce_journal_account_options() from public, authenticated;
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

commit;
