-- Chat keluarga SANGGAH GPR. Aman terpisah dari tabel administrasi keluarga.
create table if not exists public.chat_rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  room_type text not null default 'group' check (room_type in ('group','direct')),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.chat_room_members (
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key(room_id,user_id)
);
create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (length(trim(body)) between 1 and 3000),
  created_at timestamptz not null default now()
);

create index if not exists chat_room_members_user_idx on public.chat_room_members(user_id);
create index if not exists chat_messages_room_created_idx on public.chat_messages(room_id,created_at);

alter table public.chat_rooms enable row level security;
alter table public.chat_room_members enable row level security;
alter table public.chat_messages enable row level security;

grant select, insert on public.chat_rooms to authenticated;
grant select, insert on public.chat_room_members to authenticated;
grant select, insert on public.chat_messages to authenticated;

-- Direktori chat disediakan melalui RPC terbatas yang hanya mengembalikan ID dan nama.
drop policy if exists "chat rooms member read" on public.chat_rooms;
create policy "chat rooms member read" on public.chat_rooms
for select to authenticated using (
  created_by = (select auth.uid())
  or exists (select 1 from public.chat_room_members m
             where m.room_id = chat_rooms.id and m.user_id = (select auth.uid()))
);
drop policy if exists "chat rooms creator insert" on public.chat_rooms;
create policy "chat rooms creator insert" on public.chat_rooms
for insert to authenticated with check (
  created_by = (select auth.uid())
  and exists (select 1 from public.profiles p where p.id = (select auth.uid()))
);

drop policy if exists "chat memberships read own" on public.chat_room_members;
create policy "chat memberships read own" on public.chat_room_members
for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "chat memberships add participants" on public.chat_room_members;
create policy "chat memberships add participants" on public.chat_room_members
for insert to authenticated with check (
  exists (select 1 from public.profiles p where p.id = chat_room_members.user_id)
  and (
    user_id = (select auth.uid())
    or exists (select 1 from public.chat_rooms r
               where r.id = room_id and r.created_by = (select auth.uid()))
  )
);

drop policy if exists "chat messages read members" on public.chat_messages;
create policy "chat messages read members" on public.chat_messages
for select to authenticated using (
  exists (select 1 from public.chat_room_members m
          where m.room_id = chat_messages.room_id and m.user_id = (select auth.uid()))
);
drop policy if exists "chat messages send as self" on public.chat_messages;
create policy "chat messages send as self" on public.chat_messages
for insert to authenticated with check (
  sender_id = (select auth.uid())
  and exists (select 1 from public.chat_room_members m
              where m.room_id = chat_messages.room_id and m.user_id = (select auth.uid()))
);

-- Buat grup keluarga utama secara otomatis, lalu masukkan profil yang sudah ada.
insert into public.chat_rooms(name,room_type,created_by)
select 'Grup Keluarga Besar','group',p.id
from public.profiles p
where not exists (select 1 from public.chat_rooms r where r.name='Grup Keluarga Besar' and r.room_type='group')
order by p.created_at
limit 1;

insert into public.chat_room_members(room_id,user_id)
select r.id,p.id
from public.chat_rooms r cross join public.profiles p
where r.name='Grup Keluarga Besar' and r.room_type='group'
on conflict do nothing;

create or replace function public.add_new_profile_to_family_chat()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  insert into public.chat_room_members(room_id,user_id)
  select id,new.id from public.chat_rooms
  where name='Grup Keluarga Besar' and room_type='group'
  order by created_at limit 1
  on conflict do nothing;
  return new;
end;
$$;
revoke all on function public.add_new_profile_to_family_chat() from public, anon, authenticated;
drop trigger if exists add_profile_to_family_chat on public.profiles;
create trigger add_profile_to_family_chat after insert on public.profiles
for each row execute function public.add_new_profile_to_family_chat();

-- Postgres Changes dipakai agar pesan baru muncul otomatis pada percakapan yang sedang dibuka.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='chat_messages'
  ) then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
exception when undefined_object then
  raise notice 'Publication supabase_realtime belum tersedia; aktifkan Realtime untuk chat_messages di Dashboard.';
end $$;
