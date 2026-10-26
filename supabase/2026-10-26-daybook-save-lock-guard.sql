begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- Fail quickly when the same cafe/date already has a save in progress.
-- This avoids building a queue of requests that can outlive the API gateway timeout.
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
 if not pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtextextended(p_cafe_id::text||':day:'||p_entry_date::text,0)) then
  raise exception 'A save for this date is already processing. Check the date before trying again.' using errcode='55P03';
 end if;
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

commit;
