-- Add Bank to the existing Journal Entry accounts for every cafe.
-- Existing account availability choices and all accounting records are preserved.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Keep cafe creation and its account seeding consistent during this migration.
lock table public.cafes in share row exclusive mode;

insert into public.journal_account_options (cafe_id, account_name, enabled)
select c.id, 'Bank', true from public.cafes c
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
revoke all on function public.seed_journal_accounts_for_cafe() from public, anon, authenticated;

commit;

-- Expected: one Bank option per cafe. Existing disabled Bank options stay disabled.
select (select count(*) from public.cafes) as cafes,
       (select count(*) from public.journal_account_options where account_name = 'Bank') as bank_options,
       (select count(*) from public.journal_account_options where account_name = 'Bank' and not enabled) as disabled_bank_options;
