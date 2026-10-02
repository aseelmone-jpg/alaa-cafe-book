-- Read-only queries; run before the focused migration. No helper function is required.
begin read only;

-- All four must exist before this focused migration. journal_account_options may be missing.
select table_name, to_regclass('public.' || table_name) is not null as exists
from unnest(array['cafes', 'cafe_members', 'cafe_user_features', 'journal_vouchers', 'journal_account_options']) as names(table_name);

-- Expected result: zero rows. Invalid sides, accounts, amounts, fewer than two lines,
-- and unbalanced totals are reported without changing any voucher.
with vouchers as (
  select id, cafe_id, voucher_no, lines,
    case when jsonb_typeof(lines) = 'array' then jsonb_array_length(lines) else 0 end as line_count
  from public.journal_vouchers
), line_details as (
  select v.id, line.value ->> 'side' as side,
    btrim(coalesce(line.value ->> 'particulars', '')) as account_name,
    case when (line.value ->> 'amount') ~ '^(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?$'
      then (line.value ->> 'amount')::numeric else null end as amount
  from vouchers v
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(v.lines) = 'array' then v.lines else '[]'::jsonb end
  ) as line(value)
), totals as (
  select id,
    bool_and(coalesce(side in ('debit', 'credit') and account_name <> '' and amount > 0, false)) as valid_lines,
    sum(case when side = 'debit' then amount else 0 end) as debit_total,
    sum(case when side = 'credit' then amount else 0 end) as credit_total
  from line_details group by id
)
select v.id, v.cafe_id, v.voucher_no, v.line_count,
  coalesce(t.valid_lines, false) as valid_lines, t.debit_total, t.credit_total
from vouchers v left join totals t on t.id = v.id
where v.line_count < 2 or not coalesce(t.valid_lines, false)
  or coalesce(t.debit_total, 0) <= 0 or t.debit_total is distinct from t.credit_total;

-- Expected result: zero rows. The migration stops rather than truncating historical names.
select j.id, j.cafe_id, j.voucher_no, btrim(line.value ->> 'particulars') as account_name,
  length(btrim(line.value ->> 'particulars')) as characters
from public.journal_vouchers j
cross join lateral jsonb_array_elements(
  case when jsonb_typeof(j.lines) = 'array' then j.lines else '[]'::jsonb end
) as line(value)
where length(btrim(line.value ->> 'particulars')) > 120;

-- Record these counts before/after migration: business data must not change.
select 'cafes' as table_name, count(*) as rows from public.cafes
union all select 'cafe_members', count(*) from public.cafe_members
union all select 'cafe_user_features', count(*) from public.cafe_user_features
union all select 'journal_vouchers', count(*) from public.journal_vouchers;

-- Review current permissions, including any unexpected permissive policy before applying.
select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public' and tablename in ('cafe_members', 'cafe_user_features', 'journal_vouchers', 'journal_account_options')
order by tablename, policyname;

select conname, convalidated, pg_get_constraintdef(oid) as definition
from pg_constraint where conrelid = 'public.journal_vouchers'::regclass
order by conname;

select pubname, schemaname, tablename from pg_publication_tables
where pubname = 'supabase_realtime' order by schemaname, tablename;

rollback;
