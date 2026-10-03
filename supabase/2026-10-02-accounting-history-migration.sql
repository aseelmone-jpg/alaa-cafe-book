-- Preserve cafe and accounting history and record auditable row snapshots.
-- Apply once from Supabase SQL Editor as the database owner. This transaction
-- aborts on any pre-existing data conflict and does not delete or rewrite rows.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

lock table public.cafes, public.cafe_user_features, public.day_entries, public.journal_vouchers in share row exclusive mode;

do $preflight$
declare n bigint;
begin
  if to_regclass('public.cafes') is null or to_regclass('public.cafe_members') is null
     or to_regclass('public.cafe_user_features') is null or to_regclass('public.day_entries') is null
     or to_regclass('public.journal_vouchers') is null then
    raise exception 'Expected Supabase tables are missing; migration stopped';
  end if;
  select count(*) into n from public.day_entries d join public.cafes c on c.id=d.cafe_id where d.owner_id<>c.owner_id;
  if n>0 then raise exception '% day entry owner/cafe mismatches; no changes applied', n; end if;
  select count(*) into n from public.journal_vouchers v join public.cafes c on c.id=v.cafe_id where v.owner_id<>c.owner_id;
  if n>0 then raise exception '% voucher owner/cafe mismatches; no changes applied', n; end if;
  select count(*) into n from public.cafe_user_features f left join public.cafe_members m on m.cafe_id=f.cafe_id and m.user_id=f.user_id where m.user_id is null;
  if n>0 then raise exception '% feature rows lack a cafe membership; no changes applied', n; end if;
  select count(*) into n from public.journal_vouchers v where public.journal_lines_are_balanced(v.lines) is not true;
  if n>0 then raise exception '% journal voucher(s) are invalid/unbalanced; no changes applied', n; end if;
  select count(*) into n from public.journal_vouchers v cross join lateral jsonb_array_elements(v.lines) l(value)
    where length(btrim(coalesce(l.value->>'particulars',''))) > 120;
  if n>0 then raise exception '% journal account names exceed 120 characters; no changes applied', n; end if;
end;
$preflight$;

alter table public.cafes add column if not exists archived_at timestamptz;
alter table public.cafes add column if not exists archived_by uuid references auth.users(id) on delete set null;
alter table public.cafes add column if not exists updated_at timestamptz not null default now();
alter table public.day_entries add column if not exists voided_at timestamptz;
alter table public.day_entries add column if not exists voided_by uuid references auth.users(id) on delete set null;
alter table public.day_entries add column if not exists updated_at timestamptz not null default now();
alter table public.journal_vouchers add column if not exists voided_at timestamptz;
alter table public.journal_vouchers add column if not exists voided_by uuid references auth.users(id) on delete set null;
alter table public.journal_vouchers add column if not exists updated_at timestamptz not null default now();

do $constraints$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.cafes'::regclass and conname='cafes_id_owner_id_unique') then
    alter table public.cafes add constraint cafes_id_owner_id_unique unique(id,owner_id);
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.cafe_user_features'::regclass and conname='cafe_user_features_membership_fk') then
    alter table public.cafe_user_features add constraint cafe_user_features_membership_fk
      foreign key(cafe_id,user_id) references public.cafe_members(cafe_id,user_id) on update cascade on delete cascade not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.cafes'::regclass and conname='cafes_archive_actor_consistent') then
    alter table public.cafes add constraint cafes_archive_actor_consistent check ((archived_at is null)=(archived_by is null)) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.day_entries'::regclass and conname='day_entries_void_actor_consistent') then
    alter table public.day_entries add constraint day_entries_void_actor_consistent check ((voided_at is null)=(voided_by is null)) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.journal_vouchers'::regclass and conname='journal_vouchers_void_actor_consistent') then
    alter table public.journal_vouchers add constraint journal_vouchers_void_actor_consistent check ((voided_at is null)=(voided_by is null)) not valid;
  end if;
  alter table public.cafe_user_features validate constraint cafe_user_features_membership_fk;
  alter table public.cafes validate constraint cafes_archive_actor_consistent;
  alter table public.day_entries validate constraint day_entries_void_actor_consistent;
  alter table public.journal_vouchers validate constraint journal_vouchers_void_actor_consistent;
end;
$constraints$;

create table if not exists public.accounting_change_events (
  id uuid primary key default gen_random_uuid(),
  cafe_id uuid not null references public.cafes(id) on update cascade on delete restrict,
  entity_type text not null check(entity_type in ('cafe','day_entry','journal_voucher')),
  entity_id uuid not null,
  event_type text not null check(event_type in ('baseline','create','update','void','restore','archive')),
  actor_id uuid references auth.users(id) on update cascade on delete set null,
  transaction_id bigint not null default txid_current(),
  old_record jsonb,
  new_record jsonb,
  occurred_at timestamptz not null default now(),
  check ((event_type in ('baseline','create'))=(old_record is null)),
  check (new_record is not null)
);
create index if not exists accounting_change_events_cafe_time_idx on public.accounting_change_events(cafe_id,occurred_at desc);
create index if not exists accounting_change_events_entity_time_idx on public.accounting_change_events(entity_type,entity_id,occurred_at desc);
create index if not exists accounting_change_events_actor_time_idx on public.accounting_change_events(actor_id,occurred_at desc) where actor_id is not null;
alter table public.accounting_change_events enable row level security;
revoke all on public.accounting_change_events from public, anon, authenticated;
grant select on public.accounting_change_events to authenticated;
drop policy if exists "Cafe users read accounting change events" on public.accounting_change_events;
create policy "Cafe users read accounting change events" on public.accounting_change_events for select to authenticated using (
  exists(select 1 from public.cafes c where c.id=accounting_change_events.cafe_id
    and (c.owner_id=(select auth.uid()) or exists(select 1 from public.cafe_members m where m.cafe_id=c.id and m.user_id=(select auth.uid()))))
);

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path='' as $function$
begin new.updated_at=now(); return new; end;
$function$;
revoke all on function public.touch_updated_at() from public, anon, authenticated;
do $updated_triggers$
declare t text;
begin
  foreach t in array array['cafes','cafe_user_features','day_entries','journal_vouchers','journal_account_options'] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop trigger if exists %I on public.%I',t||'_touch_updated_at',t);
      execute format('create trigger %I before update on public.%I for each row execute function public.touch_updated_at()',t||'_touch_updated_at',t);
    end if;
  end loop;
end;
$updated_triggers$;

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
revoke all on function public.guard_accounting_history_changes() from public, anon, authenticated;
drop trigger if exists cafes_guard_accounting_history on public.cafes;
create trigger cafes_guard_accounting_history before update or delete on public.cafes for each row execute function public.guard_accounting_history_changes();
drop trigger if exists day_entries_guard_accounting_history on public.day_entries;
create trigger day_entries_guard_accounting_history before update or delete on public.day_entries for each row execute function public.guard_accounting_history_changes();
drop trigger if exists journal_vouchers_guard_accounting_history on public.journal_vouchers;
create trigger journal_vouchers_guard_accounting_history before update or delete on public.journal_vouchers for each row execute function public.guard_accounting_history_changes();

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
revoke all on function public.write_accounting_change_event() from public, anon, authenticated;
drop trigger if exists cafes_write_accounting_change_event on public.cafes;
create trigger cafes_write_accounting_change_event after insert or update on public.cafes for each row execute function public.write_accounting_change_event();
drop trigger if exists day_entries_write_accounting_change_event on public.day_entries;
create trigger day_entries_write_accounting_change_event after insert or update on public.day_entries for each row execute function public.write_accounting_change_event();
drop trigger if exists journal_vouchers_write_accounting_change_event on public.journal_vouchers;
create trigger journal_vouchers_write_accounting_change_event after insert or update on public.journal_vouchers for each row execute function public.write_accounting_change_event();

-- Baseline snapshots preserve legacy rows without mislabeling them as recent creates.
insert into public.accounting_change_events(cafe_id,entity_type,entity_id,event_type,new_record)
select id,'cafe',id,'baseline',to_jsonb(c) from public.cafes c
where not exists(select 1 from public.accounting_change_events e where e.entity_type='cafe' and e.entity_id=c.id);
insert into public.accounting_change_events(cafe_id,entity_type,entity_id,event_type,new_record)
select cafe_id,'day_entry',id,'baseline',to_jsonb(d) from public.day_entries d
where not exists(select 1 from public.accounting_change_events e where e.entity_type='day_entry' and e.entity_id=d.id);
insert into public.accounting_change_events(cafe_id,entity_type,entity_id,event_type,new_record)
select cafe_id,'journal_voucher',id,'baseline',to_jsonb(v) from public.journal_vouchers v
where not exists(select 1 from public.accounting_change_events e where e.entity_type='journal_voucher' and e.entity_id=v.id);

-- Remove delete access only; existing read/insert/update policies remain unchanged.
drop policy if exists "Admins delete cafes" on public.cafes;
drop policy if exists "Admins delete day entries" on public.day_entries;
drop policy if exists "Admins delete journal vouchers" on public.journal_vouchers;
revoke delete on public.cafes, public.day_entries, public.journal_vouchers from public, anon, authenticated;

-- This SECURITY DEFINER RPC reads auth.users email addresses; never expose it to anon/PUBLIC.
revoke all on function public.admin_list_cafe_users(uuid) from public, anon;
grant execute on function public.admin_list_cafe_users(uuid) to authenticated;

do $realtime$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(
    select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='accounting_change_events') then
    alter publication supabase_realtime add table public.accounting_change_events;
  end if;
end;
$realtime$;

commit;
