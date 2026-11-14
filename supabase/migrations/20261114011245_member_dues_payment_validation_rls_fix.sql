-- Validasi pembayaran menggunakan SECURITY DEFINER agar pengecekan saldo kewajiban
-- tetap berjalan konsisten sebelum RLS menolak penulisan oleh anggota biasa.
create or replace function public.validate_member_dues_payment()
returns trigger
language plpgsql
security definer
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

revoke execute on function public.validate_member_dues_payment() from public, anon, authenticated;
