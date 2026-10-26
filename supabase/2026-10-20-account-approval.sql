-- LOCAL DRAFT ONLY. Apply only after production preflight and separate approval.
-- Requires the accounting-history and checked-accounting migrations first.
-- This application currently has one approving cafe owner. Refuse ambiguous routing.
begin;

create table if not exists public.user_account_access (
 user_id uuid primary key references auth.users(id) on delete restrict,
 owner_id uuid not null references auth.users(id) on delete restrict,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 reason text not null default '' check(length(reason)<=500),
 reviewed_by uuid references auth.users(id) on delete restrict,
 reviewed_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check((status='pending' and reviewed_by is null and reviewed_at is null)
    or (status<>'pending' and reviewed_by is not null and reviewed_by=owner_id and reviewed_at is not null)),
 check(status<>'rejected' or length(btrim(reason))>0)
);
create index if not exists user_account_access_review_idx
 on public.user_account_access(owner_id,status,created_at,user_id);

create table if not exists public.user_notifications (
 id uuid primary key default gen_random_uuid(),
 recipient_id uuid not null references auth.users(id) on delete restrict,
 subject_user_id uuid not null references auth.users(id) on delete restrict,
 kind text not null check(kind in ('registration_pending','registration_approved','registration_rejected')),
 message text not null check(length(message) between 1 and 1000),
 created_at timestamptz not null default now(),
 read_at timestamptz,
 unique(recipient_id,subject_user_id,kind)
);
create index if not exists user_notifications_recipient_time_idx
 on public.user_notifications(recipient_id,created_at desc,id);
create index if not exists user_notifications_unread_idx
 on public.user_notifications(recipient_id) where read_at is null;

alter table public.user_account_access enable row level security;
alter table public.user_notifications enable row level security;
revoke all on public.user_account_access,public.user_notifications from public,anon,authenticated;
grant select on public.user_account_access,public.user_notifications to authenticated;

create or replace function public.account_is_approved()
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(
  select 1 from public.user_account_access a where a.user_id=auth.uid() and a.status='approved'
 );
$$;
revoke all on function public.account_is_approved() from public,anon;
grant execute on function public.account_is_approved() to authenticated;

drop policy if exists "Users read own approval" on public.user_account_access;
create policy "Users read own approval" on public.user_account_access for select to authenticated
 using(user_id=auth.uid() or (owner_id=auth.uid() and public.account_is_approved()
 and auth.jwt()->'app_metadata'->>'role'='admin'));
drop policy if exists "Users read own notifications" on public.user_notifications;
create policy "Users read own notifications" on public.user_notifications for select to authenticated
 using(recipient_id=auth.uid());

-- Preserve existing assigned users. Never approve an unassigned legacy account.
-- No accounting amounts, vouchers, cafe ownership or existing feature rows are rewritten.
do $$
declare approving_owner uuid; owner_count integer;
begin
 select count(*),min(owner_id::text)::uuid into owner_count,approving_owner from (
  select distinct c.owner_id from public.cafes c join auth.users u on u.id=c.owner_id
  where coalesce(u.raw_app_meta_data->>'role','')='admin'
 ) owners;
 if owner_count<>1 then
  raise exception 'Approval setup requires exactly one existing cafe owner-admin. Review registration routing before applying this migration.';
 end if;
 insert into public.user_account_access(user_id,owner_id,status,reviewed_by,reviewed_at)
 select u.id,approving_owner,
  case when u.id=approving_owner or exists(select 1 from public.cafe_members m join public.cafes c on c.id=m.cafe_id
    where m.user_id=u.id and c.owner_id=approving_owner) then 'approved' else 'pending' end,
  case when u.id=approving_owner or exists(select 1 from public.cafe_members m join public.cafes c on c.id=m.cafe_id
    where m.user_id=u.id and c.owner_id=approving_owner) then approving_owner end,
  case when u.id=approving_owner or exists(select 1 from public.cafe_members m join public.cafes c on c.id=m.cafe_id
    where m.user_id=u.id and c.owner_id=approving_owner) then now() end
 from auth.users u on conflict(user_id) do nothing;
 insert into public.user_notifications(recipient_id,subject_user_id,kind,message)
 select a.owner_id,a.user_id,'registration_pending','Account approval requested: '||coalesce(u.email,'User')
 from public.user_account_access a join auth.users u on u.id=a.user_id where a.status='pending'
 on conflict(recipient_id,subject_user_id,kind) do nothing;
end;
$$;

create or replace function public.register_pending_account()
returns trigger language plpgsql security definer set search_path='' as $$
declare approving_owner uuid; owner_count integer;
begin
 select count(*),min(owner_id::text)::uuid into owner_count,approving_owner from (
  select distinct c.owner_id from public.cafes c join auth.users u on u.id=c.owner_id
  where coalesce(u.raw_app_meta_data->>'role','')='admin'
 ) owners;
 if owner_count<>1 then raise exception 'Account registration is unavailable until the owner configures approval routing'; end if;
 insert into public.user_account_access(user_id,owner_id) values(new.id,approving_owner);
 insert into public.user_notifications(recipient_id,subject_user_id,kind,message)
 values(approving_owner,new.id,'registration_pending','Account approval requested: '||coalesce(new.email,'User'));
 return new;
end;
$$;
revoke all on function public.register_pending_account() from public,anon,authenticated;
drop trigger if exists register_pending_account on auth.users;
create trigger register_pending_account after insert on auth.users
 for each row execute function public.register_pending_account();

drop trigger if exists user_account_access_touch_updated_at on public.user_account_access;
create trigger user_account_access_touch_updated_at before update on public.user_account_access
 for each row execute function public.touch_updated_at();

create or replace function public.my_account_access()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.user_account_access;
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 select * into a from public.user_account_access where user_id=auth.uid();
 if not found then raise exception 'Your account approval record is unavailable. Ask the owner to review setup.' using errcode='42501'; end if;
 return jsonb_build_object('status',a.status,'reason',a.reason,'reviewed_at',a.reviewed_at,
  'can_review',a.status='approved' and a.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin');
end;
$$;
revoke all on function public.my_account_access() from public,anon;
grant execute on function public.my_account_access() to authenticated;

create or replace function public.admin_pending_accounts(p_cafe_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not public.account_is_approved() or coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
  or not exists(select 1 from public.cafes c where c.id=p_cafe_id and c.owner_id=auth.uid() and c.archived_at is null) then
  raise exception 'Only the owning admin can review accounts' using errcode='42501';
 end if;
 return (select coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) from (
  select a.user_id,u.email,a.created_at,a.updated_at from public.user_account_access a
  join auth.users u on u.id=a.user_id where a.owner_id=auth.uid() and a.status='pending'
  order by a.created_at,a.user_id limit 50
 ) q);
end;
$$;
revoke all on function public.admin_pending_accounts(uuid) from public,anon;
grant execute on function public.admin_pending_accounts(uuid) to authenticated;

create or replace function public.review_account(p_user_id uuid,p_cafe_id uuid,p_decision text,p_reason text,p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.user_account_access; actor uuid:=auth.uid();
begin
 if not public.account_is_approved() or coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
  or not exists(select 1 from public.cafes c where c.id=p_cafe_id and c.owner_id=actor and c.archived_at is null) then
  raise exception 'Only the owning admin can review accounts' using errcode='42501';
 end if;
 if p_decision is null or p_decision not in ('approved','rejected') or p_reason is null or length(p_reason)>500
  or (p_decision='rejected' and length(btrim(p_reason))=0) then raise exception 'Choose a valid decision; rejection needs a reason (maximum 500 characters)' using errcode='22023'; end if;
 select * into a from public.user_account_access where user_id=p_user_id and owner_id=actor for update;
 if not found or a.status<>'pending' or a.updated_at is distinct from p_expected_updated_at then
  raise exception 'This request changed or was already reviewed. Refresh the list.' using errcode='40001';
 end if;
 if p_user_id=actor then raise exception 'You cannot approve your own account' using errcode='42501'; end if;
 if p_decision='approved' then
  insert into public.cafe_members(cafe_id,user_id) values(p_cafe_id,p_user_id) on conflict do nothing;
  -- Start with no enabled features. The owner chooses permissions in existing Settings.
  insert into public.cafe_user_features(cafe_id,user_id,features) values(p_cafe_id,p_user_id,
   '{"dayBook":false,"sales":false,"purchases":false,"expenses":false,"upiAccount":false,"reportsPnl":false,"journalEntry":false,"cash":false,"ledgers":false,"rpos":false,"addCafe":false,"manageAccounts":false,"deleteCafe":false}'::jsonb)
   on conflict(cafe_id,user_id) do nothing;
 end if;
 update public.user_account_access set status=p_decision,reason=btrim(p_reason),reviewed_by=actor,reviewed_at=now()
 where user_id=p_user_id returning * into a;
 insert into public.user_notifications(recipient_id,subject_user_id,kind,message)
 values(p_user_id,p_user_id,'registration_'||p_decision,
  case when p_decision='approved' then 'Your account was approved. Your cafe owner controls which features you can use.'
  else 'Your account was rejected. Reason: '||a.reason end);
 return jsonb_build_object('status',a.status,'user_id',a.user_id);
end;
$$;
revoke all on function public.review_account(uuid,uuid,text,text,timestamptz) from public,anon;
grant execute on function public.review_account(uuid,uuid,text,text,timestamptz) to authenticated;

create or replace function public.mark_notification_read(p_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 update public.user_notifications set read_at=coalesce(read_at,now()) where id=p_id and recipient_id=auth.uid();
 return found;
end;
$$;
revoke all on function public.mark_notification_read(uuid) from public,anon;
grant execute on function public.mark_notification_read(uuid) to authenticated;

-- Restrictive policies are ANDed with every existing permissive cafe policy.
-- Pending/rejected users can read only their status/notifications, never financial tables.
do $$ declare t text; begin
 foreach t in array array['cafes','cafe_members','cafe_user_features','day_entries','journal_vouchers','journal_account_options','accounting_change_events'] loop
  execute pg_catalog.format('drop policy if exists "Approved accounts only" on public.%I',t);
  execute pg_catalog.format('create policy "Approved accounts only" on public.%I as restrictive for all to authenticated using (public.account_is_approved()) with check (public.account_is_approved())',t);
 end loop;
end;
$$;

-- SECURITY DEFINER accounting RPCs must also pass the approval gate.
-- Use the existing owner/member access functions; do not invent another financial model.
create or replace function public.cafe_feature_allowed(p_cafe_id uuid,p_feature text)
returns boolean language sql stable security definer set search_path='' as $$
 select public.account_is_approved() and exists(
  select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null and (
   (c.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin') or
   (exists(select 1 from public.cafe_members m where m.cafe_id=c.id and m.user_id=auth.uid()) and
    coalesce((select f.features->p_feature from public.cafe_user_features f where f.cafe_id=c.id and f.user_id=auth.uid()),
     case when p_feature in ('dayBook','sales','purchases','expenses','upiAccount','journalEntry','cash','ledgers') then 'true'::jsonb else 'false'::jsonb end)='true'::jsonb)
  )
 );
$$;
create or replace function public.can_use_cafe_management_feature(p_cafe_id uuid,p_feature text)
returns boolean language sql stable security definer set search_path='' as $$
 select public.account_is_approved() and p_feature in ('addCafe','manageAccounts','deleteCafe') and exists(
  select 1 from public.cafes c where c.id=p_cafe_id and c.archived_at is null and (
   (c.owner_id=auth.uid() and auth.jwt()->'app_metadata'->>'role'='admin') or
   exists(select 1 from public.cafe_members m join public.cafe_user_features f on f.cafe_id=m.cafe_id and f.user_id=m.user_id
    where m.cafe_id=c.id and m.user_id=auth.uid() and f.features->p_feature='true'::jsonb)
  )
 );
$$;

do $$ begin
 if exists(select 1 from pg_catalog.pg_publication where pubname='supabase_realtime') then
  if not exists(select 1 from pg_catalog.pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='user_account_access') then
   alter publication supabase_realtime add table public.user_account_access;
  end if;
  if not exists(select 1 from pg_catalog.pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='user_notifications') then
   alter publication supabase_realtime add table public.user_notifications;
  end if;
 end if;
end;
$$;

-- Definer functions bypass RLS, so each public read endpoint also checks approval.
create or replace function public.cafe_accounting_snapshot(p_cafe_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare raw_ok boolean; sales_ok boolean; purchases_ok boolean; expenses_ok boolean; upi_ok boolean;
 days jsonb; vouchers jsonb; options jsonb;
begin
 if not public.account_is_approved() then raise exception 'Account approval is required' using errcode='42501'; end if;
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
create or replace function public.admin_list_cafe_users(p_cafe_id uuid)
returns table(user_id uuid, email text, features jsonb)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if not public.account_is_approved() or coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') <> 'admin' or not exists (
    select 1 from public.cafes c where c.id = p_cafe_id and c.owner_id = auth.uid()
  ) then
    raise exception 'Only the cafe admin can manage its users';
  end if;
  return query
    select m.user_id, u.email::text,
      coalesce(f.features, '{"dayBook":true,"sales":true,"purchases":true,"expenses":true,"upiAccount":true,"reportsPnl":false,"journalEntry":true,"cash":true,"ledgers":true}'::jsonb)
    from public.cafe_members m
    join auth.users u on u.id = m.user_id
    left join public.cafe_user_features f on f.cafe_id = m.cafe_id and f.user_id = m.user_id
    where m.cafe_id = p_cafe_id
    order by lower(u.email);
end;
$function$;
create or replace function public.admin_can_manage_cafe_user(p_cafe_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select public.account_is_approved() and coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin'
    and exists (
      select 1 from public.cafes c
      where c.id = p_cafe_id and c.owner_id = (select auth.uid())
    ) and exists (
      select 1 from public.cafe_members m
      where m.cafe_id = p_cafe_id and m.user_id = p_user_id
    );
$function$;
revoke all on function public.cafe_accounting_snapshot(uuid),public.admin_list_cafe_users(uuid),public.admin_can_manage_cafe_user(uuid,uuid),public.cafe_feature_allowed(uuid,text),public.can_use_cafe_management_feature(uuid,text) from public,anon;
grant execute on function public.cafe_accounting_snapshot(uuid),public.admin_list_cafe_users(uuid),public.admin_can_manage_cafe_user(uuid,uuid),public.cafe_feature_allowed(uuid,text),public.can_use_cafe_management_feature(uuid,text) to authenticated;
commit;
