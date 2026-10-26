-- Incremental production fix. No business rows are rewritten or deleted.
-- Apply after the existing accounting-history migration.
begin;
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
commit;
