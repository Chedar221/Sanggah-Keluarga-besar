-- Deskripsi transaksi kas iuran tidak menampilkan nama anggota karena laporan kas publik.
create or replace function public.sync_member_dues_payment_to_transactions()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_description text;
begin
  select
    'Penerimaan iuran: ' || d.description ||
    case when nullif(btrim(d.period_label), '') is not null
      then ' (' || d.period_label || ')' else '' end
  into v_description
  from public.member_dues d
  where d.id = new.obligation_id;

  if v_description is null then
    raise exception 'Kewajiban iuran tidak ditemukan.';
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

revoke execute on function public.sync_member_dues_payment_to_transactions() from public, anon, authenticated;
