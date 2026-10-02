-- Read-only metadata checks after the focused migration is approved and applied.
begin read only;

select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname in ('cafes', 'cafe_members', 'cafe_user_features', 'day_entries', 'journal_vouchers', 'journal_account_options')
order by c.relname;

select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'journal_account_options'
order by ordinal_position;

select c.relname as table_name, con.conname, con.convalidated, pg_get_constraintdef(con.oid) as definition
from pg_constraint con join pg_class c on c.oid = con.conrelid
where con.conrelid in ('public.journal_vouchers'::regclass, 'public.journal_account_options'::regclass)
order by c.relname, con.conname;

select policyname, tablename, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public' and tablename in ('cafe_user_features', 'journal_account_options')
order by tablename, policyname;

select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'journal_account_options'
  and grantee in ('authenticated', 'anon')
order by grantee, privilege_type;

select p.proname, pg_get_function_identity_arguments(p.oid) as arguments,
  p.prosecdef as security_definer, p.proconfig as function_settings,
  pg_get_functiondef(p.oid) as definition
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in (
  'admin_can_manage_cafe_user', 'journal_lines_are_balanced',
  'seed_journal_accounts_for_cafe', 'enforce_journal_account_options'
)
order by p.proname;

select c.relname as table_name, t.tgname, t.tgenabled, pg_get_triggerdef(t.oid) as definition
from pg_trigger t join pg_class c on c.oid = t.tgrelid
where not t.tgisinternal and t.tgname in ('seed_journal_accounts_after_cafe_insert', 'enforce_journal_account_options')
order by t.tgname;

select pubname, schemaname, tablename
from pg_publication_tables
where pubname = 'supabase_realtime' and schemaname = 'public'
  and tablename in ('day_entries', 'journal_vouchers', 'cafe_user_features', 'journal_account_options')
order by tablename;

-- Expected result: zero rows. All five existing day-book account names must be seeded.
select c.id as cafe_id, a.account_name as missing_account
from public.cafes c
cross join (values ('Cash'), ('UPI Account'), ('Sales'), ('Purchases'), ('Other Expenses')) as a(account_name)
where not exists (
  select 1 from public.journal_account_options o
  where o.cafe_id = c.id and o.account_name = a.account_name
);

-- Expected result: zero rows. Read-only confirmation of valid balanced vouchers.
select id, cafe_id, voucher_no from public.journal_vouchers
where public.journal_lines_are_balanced(lines) is not true;

rollback;
