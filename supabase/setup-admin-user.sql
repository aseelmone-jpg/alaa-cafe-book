-- After both accounts have been created in Supabase Auth, replace the two
-- email placeholders and run this once in Supabase SQL Editor.
-- The admin becomes the owner of any cafes already owned by that account;
-- the user becomes a member of those cafes. No passwords or keys are used.
do $$
begin
  if not exists (select 1 from auth.users where lower(email) = lower('ADMIN_EMAIL_HERE')) then
    raise exception 'Admin email not found in Authentication > Users';
  end if;
  if not exists (select 1 from auth.users where lower(email) = lower('USER_EMAIL_HERE')) then
    raise exception 'User email not found in Authentication > Users';
  end if;
  if not exists (
    select 1 from public.cafes c join auth.users a on a.id = c.owner_id
    where lower(a.email) = lower('ADMIN_EMAIL_HERE')
  ) then
    raise exception 'No cafe is owned by the admin email yet';
  end if;
end
$$;

begin;

update auth.users
set raw_app_meta_data =
  coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
where lower(email) = lower('ADMIN_EMAIL_HERE');

insert into public.cafe_members (cafe_id, user_id)
select c.id, staff.id
from public.cafes c
join auth.users admin on admin.id = c.owner_id
join auth.users staff on lower(staff.email) = lower('USER_EMAIL_HERE')
where lower(admin.email) = lower('ADMIN_EMAIL_HERE')
on conflict (cafe_id, user_id) do nothing;

commit;

-- Verify account emails, admin role, and cafe membership:
select u.email, u.raw_app_meta_data ->> 'role' as app_role,
       c.name as cafe_name, c.location, m.added_at
from public.cafe_members m
join auth.users u on u.id = m.user_id
join public.cafes c on c.id = m.cafe_id
where lower(u.email) = lower('USER_EMAIL_HERE');
