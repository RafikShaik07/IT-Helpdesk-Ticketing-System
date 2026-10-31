-- Nightdesk: clean database setup (safe to run more than once)
-- Supabase > SQL Editor > New query > paste ALL of this > Run.
-- WARNING: this deletes any existing Nightdesk tickets, comments and profiles, then rebuilds them.
-- Your signed-up accounts are kept.

-- 0. Clean slate
drop trigger  if exists on_auth_user_created on auth.users;
drop table    if exists public.comments cascade;
drop table    if exists public.tickets  cascade;
drop table    if exists public.profiles cascade;
drop function if exists public.handle_new_user() cascade;
drop function if exists public.is_agent() cascade;

-- 1. Profiles (one row per user)
create table public.profiles (
  id   uuid primary key references auth.users(id) on delete cascade,
  name text,
  role text not null default 'requester' check (role in ('agent','requester'))
);

create function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Create profiles for accounts that were signed up before this script ran
insert into public.profiles (id, name)
select id, coalesce(raw_user_meta_data->>'name', split_part(email, '@', 1))
from auth.users
on conflict (id) do nothing;

create function public.is_agent()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'agent');
$$;

-- 2. Tickets
create table public.tickets (
  id             bigint generated always as identity primary key,
  title          text not null check (char_length(title) between 1 and 90),
  description    text not null check (char_length(description) <= 600),
  category       text not null,
  priority       text not null check (priority in ('Critical','High','Medium','Low')),
  status         text not null default 'Open' check (status in ('Open','In Progress','Resolved')),
  assignee       text not null default 'Unassigned',
  requester_id   uuid not null default auth.uid() references auth.users(id),
  requester_name text not null,
  log            jsonb not null default '[]',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  resolved_at    timestamptz
);

-- 3. Comments
create table public.comments (
  id          bigint generated always as identity primary key,
  ticket_id   bigint not null references public.tickets(id) on delete cascade,
  author_id   uuid not null default auth.uid() references auth.users(id),
  author_name text not null,
  body        text not null check (char_length(body) between 1 and 500),
  created_at  timestamptz not null default now()
);

-- 4. Row Level Security
alter table public.profiles enable row level security;
alter table public.tickets  enable row level security;
alter table public.comments enable row level security;

create policy "profiles read own or agent" on public.profiles
  for select using (id = auth.uid() or public.is_agent());

create policy "profiles create own" on public.profiles
  for insert with check (id = auth.uid() and role = 'requester');

create policy "tickets read own or agent" on public.tickets
  for select using (requester_id = auth.uid() or public.is_agent());
create policy "tickets create own open" on public.tickets
  for insert with check (requester_id = auth.uid() and status = 'Open' and assignee = 'Unassigned');
create policy "tickets agents update" on public.tickets
  for update using (public.is_agent()) with check (public.is_agent());

create policy "comments read" on public.comments
  for select using (
    public.is_agent() or exists (select 1 from public.tickets t where t.id = ticket_id and t.requester_id = auth.uid())
  );
create policy "comments add" on public.comments
  for insert with check (
    author_id = auth.uid() and (
      public.is_agent() or exists (select 1 from public.tickets t where t.id = ticket_id and t.requester_id = auth.uid())
    )
  );

-- 5. Live updates
alter publication supabase_realtime add table public.tickets, public.comments;
