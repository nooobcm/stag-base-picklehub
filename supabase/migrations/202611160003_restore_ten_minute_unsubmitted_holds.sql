begin;

-- A hold expires after ten minutes until the customer submits it with Book now.
-- Submitted reservations (status = pending) remain held for admin review.
update public.app_settings
set value = value || '{"hold_minutes":10}'::jsonb,
    updated_at = now()
where key = 'booking_policy';

update public.bookings
set hold_expires_at = created_at + interval '10 minutes',
    updated_at = now()
where status = 'held';

create or replace function public.expire_booking_holds()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.payments p
  set status = 'rejected',
      rejection_reason = 'The 10-minute booking hold expired',
      reviewed_at = now()
  from public.bookings b
  where p.booking_id = b.id
    and b.status = 'held'
    and b.hold_expires_at <= now()
    and p.status = 'proof_submitted';

  with expired as (
    update public.bookings b
    set status = 'cancelled',
        payment_status = case when b.payment_status = 'proof_submitted' then 'rejected' else b.payment_status end,
        updated_at = now()
    where b.status = 'held'
      and b.hold_expires_at <= now()
    returning b.id, b.reference, b.court_id, b.booking_date
  )
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  select null,'booking_hold_expired','booking',id,
    jsonb_build_object('reference',reference,'court_id',court_id,'booking_date',booking_date)
  from expired;
end;
$$;

-- Set a ten-minute deadline on newly created, unsubmitted holds while preserving
-- the current validation logic, including the 11 PM closing time.
do $$
declare
  v_definition text;
  v_updated text;
begin
  v_definition := pg_get_functiondef(
    'public.create_guest_booking(integer,date,integer[],text,text,text)'::regprocedure
  );
  v_updated := replace(
    v_definition,
    '''held'',''unpaid'',''infinity''::timestamptz',
    '''held'',''unpaid'',now()+interval ''10 minutes'''
  );

  if v_updated = v_definition then
    raise exception 'Could not find the indefinite hold value in create_guest_booking';
  end if;

  execute v_updated;
end;
$$;

-- Uploading an optional receipt must not extend or remove the original deadline.
create or replace function public.mark_payment_submitted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.bookings
  set payment_status = 'proof_submitted',
      updated_at = now()
  where id = new.booking_id;
  return new;
end;
$$;

-- Enforce the hold deadline at submission time as well as in availability reads.
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

  perform public.expire_booking_holds();

  select * into b
  from public.bookings
  where id = p_booking_id
  for update;
  if b.status <> 'held' or b.hold_expires_at <= now() then
    raise exception 'The 10-minute hold expired. Please reserve again.';
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

revoke all on function public.confirm_guest_booking_request(uuid,text) from public,authenticated;
grant execute on function public.confirm_guest_booking_request(uuid,text) to anon;

-- Availability reads trigger expiry, allowing stale holds to release their
-- unique hour slots and become available again without a scheduled job.
create or replace function public.get_slot_availability(
  p_court_id integer,
  p_booking_date date
)
returns table(hour integer, slot_status text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.expire_booking_holds();

  return query
  with occupied as (
    select s.hour::integer as hour,
      case when b.status in ('held','pending') then 'pending' else 'booked' end as slot_status
    from public.booking_hour_slots s
    join public.bookings b on b.id = s.booking_id
    where s.court_id = p_court_id
      and s.booking_date = p_booking_date
      and b.status in ('held','pending','confirmed','completed')
  ), maintenance as (
    select distinct h::integer as hour, 'maintenance'::text as slot_status
    from public.court_closures c
    cross join lateral generate_series(6,22) h
    where c.court_id = p_court_id
      and (p_booking_date::timestamp + make_interval(hours => h + 1)) at time zone 'Asia/Manila' > c.starts_at
      and (p_booking_date::timestamp + make_interval(hours => h)) at time zone 'Asia/Manila' < c.ends_at
  )
  select * from occupied
  union
  select * from maintenance;
end;
$$;

revoke all on function public.get_slot_availability(integer,date) from public;
grant execute on function public.get_slot_availability(integer,date) to anon,authenticated;

-- Expire any already-abandoned holds as soon as this change is applied.
select public.expire_booking_holds();

commit;
