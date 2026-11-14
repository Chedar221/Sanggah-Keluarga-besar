-- Riwayat iuran per anggota. Tabel lama public.dues dan transaksi kas tidak diubah.
create table public.member_dues (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.members(id) on delete restrict,
  description text not null check (char_length(btrim(description)) between 2 and 160),
  period_label text not null check (char_length(btrim(period_label)) between 1 and 120),
  due_date date,
  amount numeric(14,2) not null check (amount > 0),
  notes text check (notes is null or char_length(notes) <= 2000),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index member_dues_member_idx on public.member_dues(member_id, created_at desc);
create index member_dues_due_date_idx on public.member_dues(due_date);

create table public.member_dues_payments (
  id uuid primary key default gen_random_uuid(),
  obligation_id uuid not null references public.member_dues(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  paid_at date not null default current_date,
  note text check (note is null or char_length(note) <= 500),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index member_dues_payments_obligation_idx
  on public.member_dues_payments(obligation_id, paid_at desc);

create table public.member_dues_audit (
  id bigint generated always as identity primary key,
  entity_type text not null check (entity_type in ('member_dues','member_dues_payments')),
  entity_id uuid not null,
  action text not null check (action in ('INSERT','UPDATE','DELETE')),
  actor_id uuid references auth.users(id) on delete set null,
  old_data jsonb,
  new_data jsonb,
  occurred_at timestamptz not null default now()
);

create index member_dues_audit_time_idx
  on public.member_dues_audit(occurred_at desc);

alter table public.member_dues enable row level security;
alter table public.member_dues_payments enable row level security;
alter table public.member_dues_audit enable row level security;

revoke all on public.member_dues, public.member_dues_payments, public.member_dues_audit from anon, authenticated;
grant select, insert, update on public.member_dues to authenticated;
grant select, insert, update on public.member_dues_payments to authenticated;
grant select on public.member_dues_audit to authenticated;
grant usage, select on sequence public.member_dues_audit_id_seq to authenticated;

create policy "member dues managers or own member read"
on public.member_dues for select to authenticated
using (
  public.current_app_role() in ('ketua','wakil','bendahara')
  or exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.member_id = member_dues.member_id
  )
);

create policy "member dues finance insert"
on public.member_dues for insert to authenticated
with check (public.current_app_role() in ('ketua','wakil','bendahara'));

create policy "member dues finance update"
on public.member_dues for update to authenticated
using (public.current_app_role() in ('ketua','wakil','bendahara'))
with check (public.current_app_role() in ('ketua','wakil','bendahara'));

create policy "member dues payments managers or own member read"
on public.member_dues_payments for select to authenticated
using (
  public.current_app_role() in ('ketua','wakil','bendahara')
  or exists (
    select 1
    from public.member_dues d
    join public.profiles p on p.member_id = d.member_id
    where d.id = member_dues_payments.obligation_id
      and p.id = auth.uid()
  )
);

create policy "member dues payments finance insert"
on public.member_dues_payments for insert to authenticated
with check (public.current_app_role() in ('ketua','wakil','bendahara'));

create policy "member dues payments finance update"
on public.member_dues_payments for update to authenticated
using (public.current_app_role() in ('ketua','wakil','bendahara'))
with check (public.current_app_role() in ('ketua','wakil','bendahara'));

create policy "member dues audit finance read"
on public.member_dues_audit for select to authenticated
using (public.current_app_role() in ('ketua','wakil','bendahara'));

create or replace function public.set_member_dues_metadata()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(auth.uid(), new.created_by);
    new.updated_by := auth.uid();
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    new.updated_by := auth.uid();
    new.updated_at := now();
  end if;
  return new;
end;
$$;

create trigger member_dues_set_metadata
before insert or update on public.member_dues
for each row execute function public.set_member_dues_metadata();

create trigger member_dues_payments_set_metadata
before insert or update on public.member_dues_payments
for each row execute function public.set_member_dues_metadata();

create or replace function public.validate_member_dues_payment()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_due numeric(14,2);
  v_paid numeric(14,2);
begin
  select d.amount into v_due
  from public.member_dues d
  where d.id = new.obligation_id
  for update;

  if not found then
    raise exception 'Kewajiban iuran tidak ditemukan.';
  end if;

  select coalesce(sum(p.amount), 0) into v_paid
  from public.member_dues_payments p
  where p.obligation_id = new.obligation_id
    and (tg_op <> 'UPDATE' or p.id <> new.id);

  if v_paid + new.amount > v_due then
    raise exception 'Pembayaran melebihi sisa kewajiban. Sisa saat ini: %', (v_due - v_paid);
  end if;

  return new;
end;
$$;

create trigger member_dues_payments_validate
before insert or update of obligation_id, amount on public.member_dues_payments
for each row execute function public.validate_member_dues_payment();

create or replace function public.validate_member_dues_amount()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_paid numeric(14,2);
begin
  select coalesce(sum(p.amount), 0) into v_paid
  from public.member_dues_payments p
  where p.obligation_id = old.id;

  if new.amount < v_paid then
    raise exception 'Nilai kewajiban tidak boleh lebih kecil dari total pembayaran yang sudah tercatat (%).', v_paid;
  end if;

  return new;
end;
$$;

create trigger member_dues_amount_validate
before update of amount on public.member_dues
for each row execute function public.validate_member_dues_amount();

create or replace function public.prevent_member_dues_history_delete()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'Riwayat iuran tidak dapat dihapus. Lakukan koreksi melalui edit agar jejak audit tetap tersimpan.';
end;
$$;

create trigger member_dues_no_delete
before delete on public.member_dues
for each row execute function public.prevent_member_dues_history_delete();

create trigger member_dues_payments_no_delete
before delete on public.member_dues_payments
for each row execute function public.prevent_member_dues_history_delete();

create or replace function public.record_member_dues_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.member_dues_audit(entity_type, entity_id, action, actor_id, new_data)
    values (tg_table_name, new.id, 'INSERT', auth.uid(), to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    insert into public.member_dues_audit(entity_type, entity_id, action, actor_id, old_data, new_data)
    values (tg_table_name, new.id, 'UPDATE', auth.uid(), to_jsonb(old), to_jsonb(new));
    return new;
  else
    insert into public.member_dues_audit(entity_type, entity_id, action, actor_id, old_data)
    values (tg_table_name, old.id, 'DELETE', auth.uid(), to_jsonb(old));
    return old;
  end if;
end;
$$;

create trigger member_dues_audit_log
after insert or update or delete on public.member_dues
for each row execute function public.record_member_dues_audit();

create trigger member_dues_payments_audit_log
after insert or update or delete on public.member_dues_payments
for each row execute function public.record_member_dues_audit();

create or replace function public.sync_member_dues_payment_to_transactions()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_description text;
begin
  select
    'Iuran: ' || m.full_name || ' - ' || d.description ||
    case when nullif(btrim(d.period_label), '') is not null
      then ' (' || d.period_label || ')' else '' end
  into v_description
  from public.member_dues d
  join public.members m on m.id = d.member_id
  where d.id = new.obligation_id;

  if v_description is null then
    raise exception 'Data anggota atau kewajiban iuran tidak ditemukan.';
  end if;

  perform set_config('app.member_dues_sync', 'on', true);

  insert into public.transactions
    (type, description, amount, transaction_date, created_by, source_table, source_id)
  values
    ('pemasukan', v_description, new.amount, new.paid_at,
     coalesce(new.created_by, auth.uid()), 'member_dues_payments', new.id)
  on conflict (source_table, source_id) where source_id is not null
  do update set
    type = excluded.type,
    description = excluded.description,
    amount = excluded.amount,
    transaction_date = excluded.transaction_date;

  perform set_config('app.member_dues_sync', 'off', true);
  return new;
end;
$$;

create trigger member_dues_payments_sync_cash
after insert or update on public.member_dues_payments
for each row execute function public.sync_member_dues_payment_to_transactions();

create or replace function public.guard_member_dues_cash_transaction()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.member_dues_sync', true), '') <> 'on' then
    if tg_op = 'INSERT' and new.source_table = 'member_dues_payments' then
      raise exception 'Transaksi iuran dibuat otomatis dari catatan pembayaran.';
    elsif tg_op = 'UPDATE' and
      (old.source_table = 'member_dues_payments' or new.source_table = 'member_dues_payments') then
      raise exception 'Transaksi iuran dikelola melalui Riwayat Iuran, bukan diedit langsung di kas.';
    elsif tg_op = 'DELETE' and old.source_table = 'member_dues_payments' then
      raise exception 'Transaksi iuran tidak dapat dihapus langsung dari kas.';
    end if;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger transactions_guard_member_dues_cash
before insert or update or delete on public.transactions
for each row execute function public.guard_member_dues_cash_transaction();

create or replace view public.member_dues_summary
with (security_invoker = true)
as
select
  d.id,
  d.member_id,
  m.full_name as member_name,
  d.description,
  d.period_label,
  d.due_date,
  d.amount,
  coalesce(sum(p.amount), 0)::numeric(14,2) as paid_total,
  greatest(d.amount - coalesce(sum(p.amount), 0), 0)::numeric(14,2) as remaining_amount,
  case when coalesce(sum(p.amount), 0) >= d.amount then 'lunas' else 'belum_lunas' end as status,
  d.notes,
  d.created_at,
  d.updated_at
from public.member_dues d
join public.members m on m.id = d.member_id
left join public.member_dues_payments p on p.obligation_id = d.id
group by d.id, m.full_name;

revoke all on public.member_dues_summary from anon, authenticated;
grant select on public.member_dues_summary to authenticated;

revoke execute on function public.set_member_dues_metadata() from public, anon, authenticated;
revoke execute on function public.validate_member_dues_payment() from public, anon, authenticated;
revoke execute on function public.validate_member_dues_amount() from public, anon, authenticated;
revoke execute on function public.prevent_member_dues_history_delete() from public, anon, authenticated;
revoke execute on function public.record_member_dues_audit() from public, anon, authenticated;
revoke execute on function public.sync_member_dues_payment_to_transactions() from public, anon, authenticated;
revoke execute on function public.guard_member_dues_cash_transaction() from public, anon, authenticated;
