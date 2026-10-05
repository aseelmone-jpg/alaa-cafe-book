-- Delegate only the actions explicitly enabled by the cafe owner/admin.
-- Existing feature rows are unchanged; absent permission keys mean false.
begin;

create or replace function public.can_use_cafe_management_feature(p_cafe_id uuid, p_feature text)
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $$
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
$$;
revoke all on function public.can_use_cafe_management_feature(uuid,text) from public, anon;
grant execute on function public.can_use_cafe_management_feature(uuid,text) to authenticated;

-- Keep direct cafe inserts admin-only. Delegated users create through this RPC.
-- Ownership stays with the source cafe owner; the creator becomes a member.
create or replace function public.create_cafe_with_access(p_source_cafe_id uuid, p_name text, p_location text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public
as $$
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
$$;
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
commit;
