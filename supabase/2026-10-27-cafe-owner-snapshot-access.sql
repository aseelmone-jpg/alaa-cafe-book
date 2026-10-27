-- Let approved cafe owners use accounting features for cafes they own, even
-- when their auth token lacks the global admin claim or a redundant membership.
-- Staff approval and cafe/user management permissions remain admin/feature gated.
create or replace function public.cafe_feature_allowed(p_cafe_id uuid,p_feature text)
returns boolean language sql stable security definer set search_path='' as $$
 select public.account_is_approved() and exists(
  select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null and (
   (c.owner_id=auth.uid() and (
    auth.jwt()->'app_metadata'->>'role'='admin' or
    p_feature in ('dayBook','sales','purchases','expenses','upiAccount','reportsPnl','journalEntry','cash','ledgers')
   )) or
   (exists(select 1 from public.cafe_members m where m.cafe_id=c.id and m.user_id=auth.uid()) and
    coalesce((select f.features->p_feature from public.cafe_user_features f where f.cafe_id=c.id and f.user_id=auth.uid()),
     case when p_feature in ('dayBook','sales','purchases','expenses','upiAccount','journalEntry','cash','ledgers') then 'true'::jsonb else 'false'::jsonb end)='true'::jsonb)
  )
 );
$$;
revoke all on function public.cafe_feature_allowed(uuid,text) from public,anon;
grant execute on function public.cafe_feature_allowed(uuid,text) to authenticated;

-- The snapshot entry check follows cafe ownership, while this function still
-- requires account approval and uses the feature checks above for data filtering.
create or replace function public.cafe_accounting_snapshot(p_cafe_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare raw_ok boolean; sales_ok boolean; purchases_ok boolean; expenses_ok boolean; upi_ok boolean;
 days jsonb; vouchers jsonb; options jsonb;
begin
 if not public.account_is_approved() then
  raise exception 'Account approval is required' using errcode='42501';
 end if;
 if not exists(
  select 1 from public.cafes c
  where c.id=p_cafe_id and c.archived_at is null
   and (c.owner_id=auth.uid() or exists(
    select 1 from public.cafe_members m where m.cafe_id=c.id and m.user_id=auth.uid()
   ))
 ) then
  raise exception 'Cafe access is unavailable' using errcode='42501';
 end if;
 raw_ok:=public.cafe_raw_accounting_allowed(p_cafe_id);
 sales_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'sales');
 purchases_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'purchases');
 expenses_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'expenses');
 upi_ok:=raw_ok or public.cafe_feature_allowed(p_cafe_id,'upiAccount');

 select coalesce(jsonb_agg(jsonb_build_object(
  'id',d.id,'updated_at',d.updated_at,'entry_date',d.entry_date,
  'sale',case when sales_ok then d.sale else 0 end,
  'upi',case when upi_ok then d.upi else 0 end,
  'purchase',case when purchases_ok then d.purchase else 0 end,
  'other_expense',case when expenses_ok then d.other_expense else 0 end,
  'remarks',case when raw_ok then d.remarks else '' end
 ) order by d.entry_date),'[]'::jsonb) into days
 from public.day_entries d
 where d.cafe_id=p_cafe_id and d.voided_at is null
  and (raw_ok or sales_ok or purchases_ok or expenses_ok or upi_ok);

 select coalesce(jsonb_agg(to_jsonb(v)||jsonb_build_object(
  'lines',q.lines,'remark',case when raw_ok then v.remark else '' end
 ) order by v.voucher_no),'[]'::jsonb) into vouchers
 from public.journal_vouchers v
 cross join lateral (
  select jsonb_agg(case when not raw_ok
   and not exists(select 1 from jsonb_array_elements(v.lines) original
    where original ? 'transferRole' or original->>'particulars' not in ('Cash','UPI Account','Bank'))
   and (select count(distinct original->>'particulars')
    from jsonb_array_elements(v.lines) original)>=2
   then l.value||jsonb_build_object(
    'side',case when l.value->>'side'='debit' then 'credit' else 'debit' end,
    'transferRole',case when l.value->>'side'='debit' then 'source' else 'destination' end
   ) else l.value end order by l.ordinality) as lines
  from jsonb_array_elements(v.lines) with ordinality l(value,ordinality)
  where raw_ok
   or (sales_ok and l.value->>'particulars' in ('Sales','Cash Sale'))
   or (purchases_ok and l.value->>'particulars'='Purchases')
   or (expenses_ok and l.value->>'particulars' in ('Expenses','Other Expenses'))
   or (upi_ok and l.value->>'particulars'='UPI Account')
 ) q
 where v.cafe_id=p_cafe_id and q.lines is not null;

 select coalesce(jsonb_agg(jsonb_build_object(
  'account_name',a.account_name,'enabled',a.enabled
 )),'[]'::jsonb) into options
 from public.journal_account_options a
 where a.cafe_id=p_cafe_id
  and (public.cafe_feature_allowed(p_cafe_id,'journalEntry')
   or public.cafe_feature_allowed(p_cafe_id,'manageAccounts'));

 return jsonb_build_object(
  'day_entries',days,'journal_vouchers',vouchers,'journal_account_options',options
 );
end;
$$;
revoke all on function public.cafe_accounting_snapshot(uuid) from public,anon;
grant execute on function public.cafe_accounting_snapshot(uuid) to authenticated;

