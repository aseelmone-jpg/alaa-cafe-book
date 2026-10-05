-- Requires 2026-10-05-user-management-features.sql first.
-- Delete is a soft removal; financial history and records are retained.
begin;

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
commit;
