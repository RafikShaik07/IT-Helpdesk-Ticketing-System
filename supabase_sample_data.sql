-- Nightdesk: make the first account an agent + add sample tickets
-- Run AFTER supabase_setup.sql AND after you have created your account in the app.
-- Supabase > SQL Editor > New query > paste ALL of this > Run.
-- It only adds sample tickets if the tickets table is empty, so running it twice is safe.

do $$
declare
  uid uuid;
  ag  text;
begin
  select id into uid from auth.users order by created_at limit 1;
  if uid is null then
    raise exception 'No account found. Create an account in the app first, then run this script.';
  end if;

  insert into public.profiles (id, name)
  select id, coalesce(raw_user_meta_data->>'name', split_part(email, '@', 1))
  from auth.users where id = uid
  on conflict (id) do nothing;

  update public.profiles set role = 'agent' where id = uid;
  ag := coalesce((select name from public.profiles where id = uid), 'Unassigned');

  if not exists (select 1 from public.tickets) then
    insert into public.tickets
      (title, description, category, priority, status, assignee, requester_id, requester_name, log, created_at, updated_at, resolved_at)
    select
      v.title, v.descr, v.cat, v.pri, v.st,
      case when v.assigned then ag else 'Unassigned' end,
      uid, v.req,
      jsonb_build_array(jsonb_build_object('t', 'Ticket created',
        'at', (extract(epoch from now() - make_interval(hours => v.h)) * 1000)::bigint)),
      now() - make_interval(hours => v.h),
      now() - make_interval(hours => v.h),
      case when v.st = 'Resolved' then now() - make_interval(hours => v.h) + make_interval(hours => v.res) end
    from (values
      ('VPN keeps disconnecting for remote staff',  'Users on the Hyderabad VPN drop every 10 to 15 minutes since this morning.',       'Network',        'Critical', 'In Progress', true,  'Priya N.',   3,  0),
      ('Laptop will not boot after Windows update', 'Black screen after the update restarted overnight. Fan runs, nothing on display.', 'Hardware',       'High',     'Open',        false, 'Rahul M.',   6,  0),
      ('Need access to the shared finance drive',   'Joined the finance team this week and cannot open the shared drive.',              'Access & Login', 'Medium',   'Open',        true,  'Sneha P.',   10, 0),
      ('Outlook not syncing on mobile',             'New mail does not arrive on the phone app, desktop works fine.',                    'Email',          'Medium',   'In Progress', true,  'Karthik R.', 20, 0),
      ('Install Adobe Acrobat Pro',                 'Need Acrobat Pro to edit contract PDFs.',                                           'Software',       'Low',      'Resolved',    true,  'Anil K.',    30, 6),
      ('Printer on floor 3 is offline',             'Shows offline for everyone on the floor, restart did not help.',                    'Hardware',       'Medium',   'Open',        false, 'Divya S.',   30, 0),
      ('Password reset for HR portal',              'Locked out after three wrong attempts.',                                            'Access & Login', 'High',     'Resolved',    true,  'Nisha V.',   12, 2),
      ('Wi-Fi drops in conference room B',          'Video calls freeze every few minutes in room B.',                                   'Network',        'High',     'Open',        true,  'Vikram J.',  9,  0)
    ) as v(title, descr, cat, pri, st, assigned, req, h, res);
  end if;
end $$;
