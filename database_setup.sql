-- SANGGAH KELUARGA BESAR: skema awal Supabase
-- Jalankan di SQL Editor pada proyek yang memang khusus untuk aplikasi ini.
-- Jangan jalankan di proyek FEBRY LAUNDRY.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null,
 role text not null default 'anggota' check (role in ('ketua','wakil','sekretaris','bendahara','koordinator','anggota')),
 member_id uuid,
 created_at timestamptz default now()
);
create table if not exists public.members (
 id uuid primary key default gen_random_uuid(),
 full_name text not null,
 family_name text,
 phone text,
 address text,
 relation text,
 created_by uuid references auth.users(id),
 created_at timestamptz default now()
);
create table if not exists public.transactions (
 id uuid primary key default gen_random_uuid(),
 type text not null check(type in ('pemasukan','pengeluaran')),
 description text not null,
 amount numeric(14,2) not null check(amount >= 0),
 transaction_date date default current_date,
 created_by uuid references auth.users(id),
 created_at timestamptz default now()
);
create table if not exists public.dues (
 id uuid primary key default gen_random_uuid(),
 description text not null,
 amount numeric(14,2) not null default 0,
 member_id uuid references public.members(id) on delete set null,
 type text not null default 'pemasukan' check(type in ('pemasukan','pengeluaran')),
 created_at timestamptz default now()
);
create table if not exists public.events (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 event_date date,
 location text,
 notes text,
 created_at timestamptz default now()
);
create table if not exists public.ngayah (
 id uuid primary key default gen_random_uuid(),
 task text not null,
 event_date date,
 notes text,
 created_at timestamptz default now()
);
create table if not exists public.inventory (
 id uuid primary key default gen_random_uuid(),
 item_name text not null,
 quantity integer not null default 1,
 condition text,
 notes text,
 created_at timestamptz default now()
);
create table if not exists public.announcements (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 body text,
 created_by uuid references auth.users(id),
 created_at timestamptz default now()
);
create table if not exists public.documents (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 file_url text,
 notes text,
 created_at timestamptz default now()
);

-- Helper: role user yang sedang login
create or replace function public.current_app_role()
returns text language sql stable security definer set search_path=public
as $$ select role from public.profiles where id=auth.uid() $$;

-- Aktifkan RLS untuk semua tabel.
alter table public.profiles enable row level security;
alter table public.members enable row level security;
alter table public.transactions enable row level security;
alter table public.dues enable row level security;
alter table public.events enable row level security;
alter table public.ngayah enable row level security;
alter table public.inventory enable row level security;
alter table public.announcements enable row level security;
alter table public.documents enable row level security;

-- Profil: pengguna melihat profil sendiri; ketua dapat melihat semua.
create policy "profiles read self or ketua" on public.profiles for select to authenticated
using (id=auth.uid() or public.current_app_role()='ketua');
-- Profil tidak boleh diedit sendiri oleh pengguna karena kolom role menentukan hak akses.
create policy "profiles update ketua only" on public.profiles for update to authenticated
using (public.current_app_role()='ketua')
with check (public.current_app_role()='ketua');

-- Anggota: seluruh pengguna terdaftar dapat melihat; pengurus mengelola.
create policy "members read authenticated" on public.members for select to authenticated using (true);
create policy "members insert admins" on public.members for insert to authenticated
with check (public.current_app_role() in ('ketua','wakil','sekretaris','koordinator'));
create policy "members update admins" on public.members for update to authenticated
using (public.current_app_role() in ('ketua','wakil','sekretaris','koordinator'))
with check (public.current_app_role() in ('ketua','wakil','sekretaris','koordinator'));

-- Keuangan hanya dapat dilihat/diubah ketua, wakil, bendahara.
create policy "transactions finance read" on public.transactions for select to authenticated
using (public.current_app_role() in ('ketua','wakil','bendahara'));
create policy "transactions finance write" on public.transactions for all to authenticated
using (public.current_app_role() in ('ketua','wakil','bendahara'))
with check (public.current_app_role() in ('ketua','wakil','bendahara'));
create policy "dues finance read" on public.dues for select to authenticated
using (public.current_app_role() in ('ketua','wakil','bendahara'));
create policy "dues finance write" on public.dues for all to authenticated
using (public.current_app_role() in ('ketua','wakil','bendahara'))
with check (public.current_app_role() in ('ketua','wakil','bendahara'));

-- Kegiatan, inventaris, pengumuman, arsip dapat dilihat anggota.
create policy "events read" on public.events for select to authenticated using (true);
create policy "events manage" on public.events for all to authenticated
using (public.current_app_role() in ('ketua','wakil','sekretaris','koordinator'))
with check (public.current_app_role() in ('ketua','wakil','sekretaris','koordinator'));
create policy "ngayah read" on public.ngayah for select to authenticated using (true);
create policy "ngayah manage" on public.ngayah for all to authenticated
using (public.current_app_role() in ('ketua','wakil','sekretaris','koordinator'))
with check (public.current_app_role() in ('ketua','wakil','sekretaris','koordinator'));
create policy "inventory read" on public.inventory for select to authenticated using (true);
create policy "inventory manage" on public.inventory for all to authenticated
using (public.current_app_role() in ('ketua','wakil','koordinator'))
with check (public.current_app_role() in ('ketua','wakil','koordinator'));
create policy "announcements read" on public.announcements for select to authenticated using (true);
create policy "announcements manage" on public.announcements for all to authenticated
using (public.current_app_role() in ('ketua','wakil','sekretaris','koordinator'))
with check (public.current_app_role() in ('ketua','wakil','sekretaris','koordinator'));
create policy "documents read" on public.documents for select to authenticated using (true);
create policy "documents manage" on public.documents for all to authenticated
using (public.current_app_role() in ('ketua','wakil','sekretaris'))
with check (public.current_app_role() in ('ketua','wakil','sekretaris'));
