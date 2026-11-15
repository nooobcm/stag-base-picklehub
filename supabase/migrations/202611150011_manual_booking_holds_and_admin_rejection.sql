begin;

-- A reservation hold remains active indefinitely until the customer submits
-- it with Book now or cancels it explicitly.
update public.app_settings
set value = value || '{"hold_minutes":0}'::jsonb,
    updated_at = now()
where key = 'booking_policy';

update public.bookings
set hold_expires_at = 'infinity'::timestamptz,
    updated_at = now()
where status = 'held';

create or replace function public.create_guest_booking(
  p_court_id integer,
  p_booking_date date,
  p_selected_hours integer[],
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_booking public.bookings;
  v_token text := encode(extensions.gen_random_bytes(32),'hex');
  v_hours smallint[];
  v_name text := nullif(trim(p_customer_name),'');
  v_email text := lower(nullif(trim(p_customer_email),''));
  v_phone text := nullif(trim(p_customer_phone),'');
begin
  if v_name is null or length(v_name)>120 then raise exception 'Enter your name'; end if;
  if v_email is null or length(v_email)>254 or v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then raise exception 'Enter a valid email address'; end if;
  if v_phone is null or length(v_phone)>32 or v_phone !~ '^[+0-9() .-]{7,32}$' then raise exception 'Enter a valid phone number'; end if;
  if p_court_id not in (1,2) or p_selected_hours is null or cardinality(p_selected_hours)<1 or cardinality(p_selected_hours)>16 then raise exception 'Select one or more available hours'; end if;

  select array_agg(h order by h) into v_hours
  from (select distinct x::smallint as h from unnest(p_selected_hours) x) selected;

  if v_hours[1] is null or v_hours[cardinality(v_hours)] is null or array_position(v_hours,null) is not null
    or v_hours[1]<6 or v_hours[cardinality(v_hours)]>21 then raise exception 'Choose hours between 6 AM and 10 PM'; end if;
  if p_booking_date<(now() at time zone 'Asia/Manila')::date then raise exception 'Choose a future date'; end if;
  if exists(select 1 from unnest(v_hours) h where (p_booking_date::timestamp+make_interval(hours=>h)) at time zone 'Asia/Manila'<=now()) then raise exception 'One or more selected hours have already passed'; end if;

  perform public.expire_booking_holds();
  perform pg_advisory_xact_lock(6001,p_court_id);

  if exists(
    select 1 from public.court_closures c
    cross join lateral unnest(v_hours) h
    where c.court_id=p_court_id
      and tstzrange(c.starts_at,c.ends_at,'[)') && tstzrange(
        (p_booking_date::timestamp+make_interval(hours=>h)) at time zone 'Asia/Manila',
        (p_booking_date::timestamp+make_interval(hours=>h+1)) at time zone 'Asia/Manila','[)')
  ) then raise exception 'This court is closed during one or more selected hours'; end if;

  insert into public.bookings(
    user_id,court_id,booking_date,start_hour,duration_hours,selected_hours,
    total_price,status,payment_status,hold_expires_at,customer_name,customer_email,
    customer_phone,guest_access_token_hash
  ) values(
    null,p_court_id,p_booking_date,v_hours[1],cardinality(v_hours),v_hours,
    cardinality(v_hours)*(select c.hourly_rate from public.courts c where c.id=p_court_id and c.active),
    'held','unpaid','infinity'::timestamptz,
    v_name,v_email,v_phone,encode(extensions.digest(v_token,'sha256'),'hex')
  ) returning * into v_booking;

  return jsonb_build_object(
    'id',v_booking.id,'reference',v_booking.reference,'total_price',v_booking.total_price,
    'access_token',v_token
  );
exception when unique_violation then
  raise exception 'One or more selected hours were just taken. Choose another time.';
end;
$$;

revoke all on function public.create_guest_booking(integer,date,integer[],text,text,text) from public,authenticated;
grant execute on function public.create_guest_booking(integer,date,integer[],text,text,text) to anon;

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

  select * into b from public.bookings where id=p_booking_id for update;
  if b.status<>'held' then
    raise exception 'This reservation is no longer on hold';
  end if;

  select coalesce((value->>'proof_review_hours')::integer,24)
  into v_review_hours from public.app_settings where key='booking_policy';

  update public.bookings
  set status='pending',
      hold_expires_at=case when payment_status='proof_submitted'
        then now()+make_interval(hours=>coalesce(v_review_hours,24))
        else now()+interval '100 years' end,
      updated_at=now()
  where id=b.id returning * into b;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(null,'guest_booking_submitted','booking',b.id,jsonb_build_object(
    'reference',b.reference,'amount',b.total_price,'payment_status',b.payment_status));
  return b;
end;
$$;

revoke all on function public.confirm_guest_booking_request(uuid,text) from public,authenticated;
grant execute on function public.confirm_guest_booking_request(uuid,text) to anon;

create or replace function public.admin_reject_unpaid_booking(
  p_booking_id uuid,
  p_reason text
)
returns public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings;
  v_reason text := nullif(trim(p_reason),'');
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if v_reason is null then raise exception 'Enter a reason for rejecting this booking'; end if;

  update public.bookings
  set status='rejected',updated_at=now()
  where id=p_booking_id and status='pending' and payment_status='unpaid'
  returning * into b;
  if b.id is null then raise exception 'This booking is no longer awaiting confirmation'; end if;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'unpaid_booking_rejected','booking',b.id,
    jsonb_build_object('reference',b.reference,'reason',v_reason));
  return b;
end;
$$;

revoke all on function public.admin_reject_unpaid_booking(uuid,text) from public,anon;
grant execute on function public.admin_reject_unpaid_booking(uuid,text) to authenticated;

commit;
