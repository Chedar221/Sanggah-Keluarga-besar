-- Pendaftaran akun chat keluarga dengan persetujuan pengurus.
create table if not exists public.chat_registration_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete restrict,
  full_name text not null,
  email text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id)
);
create unique index if not exists one_pending_chat_registration_per_member
  on public.chat_registration_requests(member_id) where status='pending';
create unique index if not exists one_chat_account_per_family_member
  on public.profiles(member_id) where member_id is not null;
alter table public.chat_registration_requests enable row level security;
revoke all on public.chat_registration_requests from anon, authenticated;
grant select on public.chat_registration_requests to authenticated;
drop policy if exists "chat registrations admins read" on public.chat_registration_requests;
create policy "chat registrations admins read" on public.chat_registration_requests
for select to authenticated using (
  exists (select 1 from public.profiles p
          where p.id=(select auth.uid())
          and p.role in ('ketua','wakil','sekretaris','koordinator'))
);

-- Catat setiap pendaftaran Auth sebagai permintaan; metadata pengguna tidak pernah
-- dipakai untuk memberi hak akses atau menentukan role.
create schema if not exists public_private;
revoke all on schema public_private from public, anon;
grant usage on schema public_private to supabase_auth_admin, authenticated;

create or replace function public_private.capture_chat_registration()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  chosen_member uuid;
  chosen_name text;
begin
  chosen_member := nullif(new.raw_user_meta_data->>'member_id','')::uuid;
  chosen_name := nullif(trim(new.raw_user_meta_data->>'full_name'),'');
  if chosen_member is null or chosen_name is null then
    raise exception 'Nama dan anggota keluarga wajib dipilih';
  end if;
  if not exists (select 1 from public.members m where m.id=chosen_member) then
    raise exception 'Anggota keluarga tidak ditemukan';
  end if;
  insert into public.chat_registration_requests(user_id,member_id,full_name,email)
  values(new.id,chosen_member,chosen_name,coalesce(new.email,''))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

grant execute on function public_private.capture_chat_registration() to supabase_auth_admin;
drop trigger if exists on_auth_user_chat_registration on auth.users;
create trigger on_auth_user_chat_registration
after insert on auth.users
for each row execute function public_private.capture_chat_registration();

-- Hanya pengurus berwenang yang dapat menyetujui/menolak. Role selalu anggota.
create or replace function public.decide_chat_registration(p_request_id uuid, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_role text;
  req public.chat_registration_requests%rowtype;
begin
  select p.role into actor_role
  from public.profiles p where p.id=(select auth.uid());
  if coalesce(actor_role,'') not in ('ketua','wakil','sekretaris','koordinator') then
    raise exception 'Tidak memiliki izin menyetujui pendaftaran';
  end if;

  select * into req from public.chat_registration_requests
  where id=p_request_id and status='pending' for update;
  if not found then raise exception 'Pendaftaran tidak ditemukan atau sudah diproses'; end if;

  if p_approve then
    if exists (select 1 from public.profiles p where p.member_id=req.member_id and p.id<>req.user_id) then
      raise exception 'Anggota keluarga ini sudah memiliki akun chat';
    end if;
    insert into public.profiles(id,full_name,role,member_id)
    values(req.user_id,req.full_name,'anggota',req.member_id)
    on conflict (id) do nothing;
    update public.chat_registration_requests
    set status='approved', reviewed_at=now(), reviewed_by=(select auth.uid())
    where id=req.id;
  else
    update public.chat_registration_requests
    set status='rejected', reviewed_at=now(), reviewed_by=(select auth.uid())
    where id=req.id;
  end if;
  return jsonb_build_object('ok',true,'status',case when p_approve then 'approved' else 'rejected' end);
end;
$$;
revoke all on function public.decide_chat_registration(uuid,boolean) from public, anon;
grant execute on function public.decide_chat_registration(uuid,boolean) to authenticated;

-- Directory chat hanya mengembalikan ID dan nama, bukan role/member_id.
create or replace function public.chat_directory()
returns table(id uuid, full_name text)
language sql
security definer
set search_path = ''
as $$
  select p.id,p.full_name
  from public.profiles p
  where (select auth.uid()) is not null
  order by p.full_name;
$$;
revoke all on function public.chat_directory() from public, anon;
grant execute on function public.chat_directory() to authenticated;
