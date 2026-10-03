-- Correct audit cafe references and table-specific history guards.
-- Existing function ownership, privileges, tables and records remain intact.
begin;

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

commit;
