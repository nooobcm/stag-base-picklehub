
begin;

-- =====================================================
-- 1. UPDATE BOOKINGS TABLE
-- =====================================================

alter table public.bookings
  alter column user_id drop not null;

alter table public.bookings
  add column if not exists customer_name text,
  add column if not exists customer_email text,
  add column if not exists customer_phone text,
  add column if not exists guest_access_token_hash text,
  add column if not exists customer_cancelled_at timestamptz,
  add column if not exists confirmation_email_sent_at timestamptz;

create index if not exists bookings_customer_email_idx
on public.bookings(lower(customer_email));

grant execute on function public.get_unavailable_hours(integer,date)
to anon;


-- =====================================================
-- 2. APP SETTINGS POLICY
-- =====================================================

drop policy if exists
"Public payment instructions are readable for guest checkout"
on public.app_settings;

create policy "Public payment instructions are readable for guest checkout"
on public.app_settings
for select
to anon
using (key = 'payment_instructions');


-- =====================================================
-- 3. VERIFY GUEST ACCESS TOKEN
-- =====================================================

create or replace function public.guest_token_matches(
  p_booking_id uuid,
  p_token text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_token is not null and exists(
    select 1
    from public.bookings b
    where b.id = p_booking_id
      and b.user_id is null
      and b.guest_access_token_hash =
        encode(extensions.digest(p_token,'sha256'),'hex')
  );
$$;

revoke all on function public.guest_token_matches(uuid,text)
from public, anon, authenticated;

grant execute on function public.guest_token_matches(uuid,text)
to anon, authenticated;


-- =====================================================
-- 4. CREATE GUEST BOOKING
-- =====================================================

create or replace function public.create_guest_booking(
  p_court_id integer,
  p_booking_date date,
  p_start_hour integer,
  p_duration_hours integer,
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
  v_booking public.bookings;
  v_token text := encode(extensions.gen_random_bytes(32),'hex');
  v_start timestamptz;
  v_end timestamptz;
  v_hold_minutes integer;
  v_name text := nullif(trim(p_customer_name),'');
  v_email text := lower(nullif(trim(p_customer_email),''));
  v_phone text := nullif(trim(p_customer_phone),'');
begin

  if v_name is null or length(v_name)>120 then
    raise exception 'Enter your name';
  end if;

  if v_email is null or length(v_email)>254
    or v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then
    raise exception 'Enter a valid email address';
  end if;

  if v_phone is null or length(v_phone)>32
    or v_phone !~ '^[+0-9() .-]{7,32}$' then
    raise exception 'Enter a valid phone number';
  end if;

  if p_court_id not in (1,2)
    or p_start_hour<6
    or p_duration_hours<1
    or p_duration_hours>16
    or p_start_hour+p_duration_hours>22 then
    raise exception 'Choose a valid court and time between 6 AM and 10 PM';
  end if;

  if p_booking_date<(now() at time zone 'Asia/Manila')::date then
    raise exception 'Choose a future date';
  end if;

  perform public.expire_booking_holds();

  perform pg_advisory_xact_lock(6001,p_court_id);

  select coalesce((value->>'hold_minutes')::integer,10)
  into v_hold_minutes
  from public.app_settings
  where key='booking_policy';

  v_start :=
    (p_booking_date::timestamp +
    make_interval(hours=>p_start_hour))
    at time zone 'Asia/Manila';

  v_end :=
    (p_booking_date::timestamp +
    make_interval(hours=>p_start_hour+p_duration_hours))
    at time zone 'Asia/Manila';

  if v_start<=now() then
    raise exception 'Choose a future start time';
  end if;

  if exists(
    select 1
    from public.court_closures c
    where c.court_id=p_court_id
      and tstzrange(c.starts_at,c.ends_at,'[)')
      && tstzrange(v_start,v_end,'[)')
  ) then
    raise exception 'This court is closed during the selected time';
  end if;

  insert into public.bookings(
    user_id,
    court_id,
    booking_date,
    start_hour,
    duration_hours,
    total_price,
    status,
    payment_status,
    hold_expires_at,
    customer_name,
    customer_email,
    customer_phone,
    guest_access_token_hash
  )
  values(
    null,
    p_court_id,
    p_booking_date,
    p_start_hour,
    p_duration_hours,
    p_duration_hours*250,
    'held',
    'unpaid',
    now()+make_interval(mins=>coalesce(v_hold_minutes,10)),
    v_name,
    v_email,
    v_phone,
    encode(extensions.digest(v_token,'sha256'),'hex')
  )
  returning * into v_booking;

  return jsonb_build_object(
    'id',v_booking.id,
    'reference',v_booking.reference,
    'total_price',v_booking.total_price,
    'hold_expires_at',v_booking.hold_expires_at,
    'access_token',v_token
  );

exception
  when exclusion_violation then
    raise exception 'That time overlaps another booking';
end;
$$;

revoke all on function public.create_guest_booking(
  integer,date,integer,integer,text,text,text
) from public, authenticated;

grant execute on function public.create_guest_booking(
  integer,date,integer,integer,text,text,text
) to anon;


-- =====================================================
-- 5. GET GUEST BOOKING DETAILS
-- =====================================================

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

  update public.bookings
  set status='cancelled',updated_at=now()
  where id=p_booking_id
    and status='held'
    and hold_expires_at<=now();

  select *
  into v_booking
  from public.bookings
  where id=p_booking_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',p.id,
        'status',p.status,
        'rejection_reason',p.rejection_reason,
        'submitted_at',p.submitted_at
      )
      order by p.submitted_at desc
    ),
    '[]'::jsonb
  )
  into v_payments
  from public.payments p
  where p.booking_id=p_booking_id;

  return (to_jsonb(v_booking)-'guest_access_token_hash')
    || jsonb_build_object(
      'payments',v_payments,
      'cancelled_by_customer',
      exists(
        select 1
        from public.audit_logs a
        where a.entity_id=p_booking_id
          and a.entity_type='booking'
          and a.action in (
            'customer_booking_cancelled',
            'guest_booking_cancelled'
          )
      )
    );

end;
$$;

revoke all on function public.get_guest_booking(uuid,text)
from public, authenticated;

grant execute on function public.get_guest_booking(uuid,text)
to anon;


-- =====================================================
-- 6. SUBMIT GUEST PAYMENT PROOF
-- =====================================================

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
  v_token_segment text;
begin

  if not public.guest_token_matches(p_booking_id,p_token) then
    raise exception 'Booking link is invalid';
  end if;

  select *
  into b
  from public.bookings
  where id=p_booking_id
  for update;

  if b.status<>'held' or b.hold_expires_at<=now() then
    raise exception 'The 10-minute booking hold expired';
  end if;

  if split_part(p_proof_path,'/',1)<>p_booking_id::text then
    raise exception 'Invalid proof path';
  end if;

  v_token_segment:=split_part(p_proof_path,'/',2);

  if v_token_segment<>p_token
    or split_part(p_proof_path,'/',3)='' then
    raise exception 'Invalid proof path';
  end if;

  if not exists(
    select 1
    from storage.objects o
    where o.bucket_id='payment-proofs'
      and o.name=p_proof_path
  ) then
    raise exception 'Upload the payment screenshot first';
  end if;

  insert into public.payments(
    booking_id,
    amount,
    proof_path,
    status
  )
  values(
    b.id,
    b.total_price,
    p_proof_path,
    'proof_submitted'
  );

end;
$$;

revoke all on function public.submit_guest_payment_proof(
  uuid,text,text
) from public, authenticated;

grant execute on function public.submit_guest_payment_proof(
  uuid,text,text
) to anon;


-- =====================================================
-- 7. CONFIRM GUEST BOOKING REQUEST
-- =====================================================

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
  v_review_hours integer;
begin

  if not public.guest_token_matches(p_booking_id,p_token) then
    raise exception 'Booking link is invalid';
  end if;

  select *
  into b
  from public.bookings
  where id=p_booking_id
  for update;

  if b.status<>'held' or b.hold_expires_at<=now() then
    raise exception 'The 10-minute hold expired. Please reserve again.';
  end if;

  if b.payment_status<>'proof_submitted'
    or not exists(
      select 1
      from public.payments p
      where p.booking_id=b.id
        and p.status='proof_submitted'
        and p.amount=b.total_price
    ) then
    raise exception 'Upload payment proof before booking';
  end if;

  select coalesce((value->>'proof_review_hours')::integer,24)
  into v_review_hours
  from public.app_settings
  where key='booking_policy';

  update public.bookings
  set
    status='pending',
    hold_expires_at=now()+make_interval(
      hours=>coalesce(v_review_hours,24)
    ),
    updated_at=now()
  where id=b.id
  returning * into b;

  insert into public.audit_logs(
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  values(
    null,
    'guest_booking_submitted',
    'booking',
    b.id,
    jsonb_build_object(
      'reference',b.reference,
      'amount',b.total_price
    )
  );

  return b;

end;
$$;

revoke all on function public.confirm_guest_booking_request(
  uuid,text
) from public, authenticated;

grant execute on function public.confirm_guest_booking_request(
  uuid,text
) to anon;


-- =====================================================
-- 8. CANCEL GUEST BOOKING
-- =====================================================

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

  perform public.expire_booking_holds();

  select *
  into b
  from public.bookings
  where id=p_booking_id
  for update;

  if b.status<>'held' or b.hold_expires_at<=now() then
    raise exception 'This payment hold has expired';
  end if;

  update public.bookings
  set
    status='cancelled',
    customer_cancelled_at=now(),
    updated_at=now()
  where id=b.id;

  insert into public.audit_logs(
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  values(
    null,
    'guest_booking_cancelled',
    'booking',
    b.id,
    '{}'::jsonb
  );

end;
$$;

revoke all on function public.cancel_guest_booking(uuid,text)
from public, authenticated;

grant execute on function public.cancel_guest_booking(uuid,text)
to anon;


-- =====================================================
-- 9. CHECK GUEST PAYMENT PROOF UPLOAD PERMISSION
-- =====================================================

create or replace function public.can_upload_guest_proof(
  p_path text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1
    from public.bookings b
    where b.id::text=split_part(p_path,'/',1)
      and b.user_id is null
      and b.status='held'
      and b.hold_expires_at>now()
      and b.guest_access_token_hash=
        encode(
          extensions.digest(split_part(p_path,'/',2),'sha256'),
          'hex'
        )
      and split_part(p_path,'/',3)<>''
  );
$$;

revoke all on function public.can_upload_guest_proof(text)
from public, authenticated;

grant execute on function public.can_upload_guest_proof(text)
to anon;


-- =====================================================
-- 10. STORAGE POLICY FOR GUEST PAYMENT PROOF
-- =====================================================

drop policy if exists
"Guests upload proof for their active hold"
on storage.objects;

create policy "Guests upload proof for their active hold"
on storage.objects
for insert
to anon
with check (
  bucket_id='payment-proofs'
  and public.can_upload_guest_proof(name)
);


-- =====================================================
-- COMPLETE MIGRATION
-- =====================================================

commit;
