begin;

create or replace function public.remove_guest_payment_proof(
  p_booking_id uuid,
  p_token text,
  p_payment_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings;
  v_proof_path text;
begin
  if not public.guest_token_matches(p_booking_id,p_token) then
    raise exception 'Booking link is invalid';
  end if;

  select * into b
  from public.bookings
  where id=p_booking_id
  for update;

  if b.status<>'held' or b.hold_expires_at<=now() then
    raise exception 'The 10-minute booking hold expired';
  end if;

  select p.proof_path into v_proof_path
  from public.payments p
  where p.id=p_payment_id
    and p.booking_id=b.id
    and p.status='proof_submitted'
    and split_part(p.proof_path,'/',1)=b.id::text
    and split_part(p.proof_path,'/',2)=p_token;

  if v_proof_path is null then
    raise exception 'Payment screenshot not found';
  end if;

  delete from public.payments where id=p_payment_id;
  update public.bookings
  set payment_status='unpaid',updated_at=now()
  where id=b.id;

  return v_proof_path;
end;
$$;

revoke all on function public.remove_guest_payment_proof(uuid,text,uuid)
from public, authenticated;
grant execute on function public.remove_guest_payment_proof(uuid,text,uuid)
to anon;

drop policy if exists "Guests remove proof for their active hold" on storage.objects;
create policy "Guests remove proof for their active hold"
on storage.objects
for delete
to anon
using (
  bucket_id='payment-proofs'
  and public.can_upload_guest_proof(name)
);

commit;
