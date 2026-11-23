begin;

-- The current client creates a booking and submits it in one operation. Keep
-- the existing multi-court creation and validation logic, but wrap it in one
-- transaction so the temporary row is never exposed as a customer hold.
create or replace function public.create_guest_booking_multi(
  p_booking_date date,
  p_court_selections jsonb,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking jsonb;
  v_booking_id uuid;
  v_token text;
begin
  v_booking := public.create_guest_booking_multi(
    p_booking_date,
    p_court_selections,
    p_customer_name,
    p_customer_email,
    p_customer_phone,
    'online'
  );
  v_booking_id := (v_booking->>'id')::uuid;
  v_token := v_booking->>'access_token';

  perform public.confirm_guest_booking_request(v_booking_id, v_token);
  return v_booking;
end;
$$;

revoke all on function public.create_guest_booking_multi(date,jsonb,text,text,text) from public, authenticated;
grant execute on function public.create_guest_booking_multi(date,jsonb,text,text,text) to anon;

-- A submitted pending booking can receive its payment proof from the booking
-- details page. Recording a proof changes its method to online for review.
create or replace function public.submit_guest_payment_proof(
  p_booking_id uuid,
  p_token text,
  p_proof_path text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings;
begin
  if not public.guest_token_matches(p_booking_id,p_token) then
    raise exception 'Booking link is invalid';
  end if;

  select * into b
  from public.bookings
  where id=p_booking_id
  for update;

  if b.id is null or b.status <> 'pending' then
    raise exception 'This booking is not awaiting payment';
  end if;
  if split_part(p_proof_path,'/',1) <> p_booking_id::text
     or split_part(p_proof_path,'/',2) <> p_token
     or split_part(p_proof_path,'/',3) = '' then
    raise exception 'Invalid proof path';
  end if;
  if not exists (
    select 1 from storage.objects o
    where o.bucket_id='payment-proofs' and o.name=p_proof_path
  ) then
    raise exception 'Upload the payment screenshot first';
  end if;

  update public.bookings
  set payment_method='online', updated_at=now()
  where id=b.id;

  insert into public.payments(booking_id,amount,proof_path,status)
  values(b.id,b.total_price,p_proof_path,'proof_submitted');
end;
$$;

revoke all on function public.submit_guest_payment_proof(uuid,text,text) from public, authenticated;
grant execute on function public.submit_guest_payment_proof(uuid,text,text) to anon;

-- Permit token-authenticated guests to upload proof only for their own
-- submitted booking, rather than requiring the old temporary-hold status.
create or replace function public.can_upload_guest_proof(p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1 from public.bookings b
    where b.id::text=split_part(p_path,'/',1)
      and b.user_id is null
      and b.status='pending'
      and b.guest_access_token_hash=encode(
        extensions.digest(split_part(p_path,'/',2),'sha256'),'hex'
      )
      and split_part(p_path,'/',3)<>''
  );
$$;

-- Let guests remove an unreviewed proof from their pending booking if they
-- selected the wrong receipt.
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

  select * into b from public.bookings where id=p_booking_id for update;
  if b.id is null or b.status<>'pending' then
    raise exception 'This booking is not awaiting payment';
  end if;

  select p.proof_path into v_proof_path
  from public.payments p
  where p.id=p_payment_id and p.booking_id=b.id
    and p.status='proof_submitted'
    and split_part(p.proof_path,'/',1)=b.id::text
    and split_part(p.proof_path,'/',2)=p_token;
  if v_proof_path is null then
    raise exception 'Payment screenshot not found';
  end if;

  delete from public.payments where id=p_payment_id;
  update public.bookings
  set payment_status='unpaid',payment_method='cash',updated_at=now()
  where id=b.id;
  return v_proof_path;
end;
$$;

revoke all on function public.remove_guest_payment_proof(uuid,text,uuid) from public, authenticated;
grant execute on function public.remove_guest_payment_proof(uuid,text,uuid) to anon;

commit;
