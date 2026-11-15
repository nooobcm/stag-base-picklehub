begin;

-- Holds are released only by customer cancellation or booking submission.
update public.app_settings
set value = value || '{"hold_minutes":0}'::jsonb,
    updated_at = now()
where key = 'booking_policy';

update public.bookings
set hold_expires_at = 'infinity'::timestamptz,
    updated_at = now()
where status = 'held';

-- Expiry processing must not cancel held or submitted bookings.
create or replace function public.expire_booking_holds()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  return;
end;
$$;

-- Keep an uploaded proof from introducing a new deadline on a held booking.
create or replace function public.mark_payment_submitted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.bookings
  set payment_status = 'proof_submitted',
      hold_expires_at = case when status = 'held'
        then 'infinity'::timestamptz else hold_expires_at end,
      updated_at = now()
  where id = new.booking_id;
  return new;
end;
$$;

create or replace function public.confirm_guest_booking_request(
  p_booking_id uuid,
  p_token text
)
returns public.bookings
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
  where id = p_booking_id
  for update;
  if b.status <> 'held' then
    raise exception 'This reservation is no longer on hold';
  end if;

  update public.bookings
  set status = 'pending',
      hold_expires_at = 'infinity'::timestamptz,
      updated_at = now()
  where id = b.id
  returning * into b;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(null,'guest_booking_submitted','booking',b.id,jsonb_build_object(
    'reference',b.reference,'amount',b.total_price,'payment_status',b.payment_status));
  return b;
end;
$$;

create or replace function public.get_guest_booking(
  p_booking_id uuid,
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.bookings;
  v_payments jsonb;
begin
  if not public.guest_token_matches(p_booking_id,p_token) then
    raise exception 'Booking link is invalid';
  end if;

  select * into v_booking
  from public.bookings
  where id = p_booking_id;

  if v_booking.id is null then
    raise exception 'Booking not found';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,
    'status',p.status,
    'rejection_reason',p.rejection_reason,
    'submitted_at',p.submitted_at
  ) order by p.submitted_at desc),'[]'::jsonb)
  into v_payments
  from public.payments p
  where p.booking_id = p_booking_id;

  return (to_jsonb(v_booking)-'guest_access_token_hash')
    || jsonb_build_object(
      'payments',v_payments,
      'cancelled_by_customer',exists(
        select 1 from public.audit_logs a
        where a.entity_id = p_booking_id
          and a.entity_type = 'booking'
          and a.action in ('customer_booking_cancelled','guest_booking_cancelled')
      )
    );
end;
$$;

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
  where id = p_booking_id
  for update;

  if b.status <> 'held' then
    raise exception 'This reservation is no longer on hold';
  end if;
  if split_part(p_proof_path,'/',1) <> p_booking_id::text
    or split_part(p_proof_path,'/',2) <> p_token
    or split_part(p_proof_path,'/',3) = '' then
    raise exception 'Invalid proof path';
  end if;
  if not exists(
    select 1 from storage.objects o
    where o.bucket_id = 'payment-proofs' and o.name = p_proof_path
  ) then
    raise exception 'Upload the payment screenshot first';
  end if;

  insert into public.payments(booking_id,amount,proof_path,status)
  values(b.id,b.total_price,p_proof_path,'proof_submitted');
end;
$$;

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
  where id = p_booking_id
  for update;
  if b.status <> 'held' then
    raise exception 'This reservation is no longer on hold';
  end if;

  select p.proof_path into v_proof_path
  from public.payments p
  where p.id = p_payment_id
    and p.booking_id = b.id
    and p.status = 'proof_submitted'
    and split_part(p.proof_path,'/',1) = b.id::text
    and split_part(p.proof_path,'/',2) = p_token;
  if v_proof_path is null then
    raise exception 'Payment screenshot not found';
  end if;

  delete from public.payments where id = p_payment_id;
  update public.bookings
  set payment_status = 'unpaid', updated_at = now()
  where id = b.id;
  return v_proof_path;
end;
$$;

create or replace function public.cancel_guest_booking(
  p_booking_id uuid,
  p_token text
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
  where id = p_booking_id
  for update;
  if b.status <> 'held' then
    raise exception 'This reservation is no longer on hold';
  end if;

  update public.bookings
  set status = 'cancelled', customer_cancelled_at = now(), updated_at = now()
  where id = b.id;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(null,'guest_booking_cancelled','booking',b.id,'{}'::jsonb);
end;
$$;

create or replace function public.can_upload_guest_proof(p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1 from public.bookings b
    where b.id::text = split_part(p_path,'/',1)
      and b.user_id is null
      and b.status = 'held'
      and b.guest_access_token_hash = encode(
        extensions.digest(split_part(p_path,'/',2),'sha256'),'hex'
      )
      and split_part(p_path,'/',3) <> ''
  );
$$;

commit;
