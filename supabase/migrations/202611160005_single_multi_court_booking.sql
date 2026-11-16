begin;

-- One booking can reserve hours on both courts. The slot table remains the
-- authoritative court/hour map, while bookings.court_id remains the lead court
-- for compatibility with existing reports and records.
alter table public.bookings
  add column if not exists court_selections jsonb not null default '[]'::jsonb;

update public.bookings
set court_selections = jsonb_build_array(jsonb_build_object(
  'court_id', court_id,
  'hours', to_jsonb(selected_hours)
))
where court_selections = '[]'::jsonb;

alter table public.booking_hour_slots drop constraint if exists booking_hour_slots_pkey;
alter table public.booking_hour_slots
  add constraint booking_hour_slots_pkey primary key (booking_id, court_id, hour);

alter table public.bookings drop constraint if exists bookings_duration_hours_check;
alter table public.bookings add constraint bookings_duration_hours_check check (duration_hours between 1 and 34);
alter table public.bookings drop constraint if exists bookings_check;
alter table public.bookings add constraint bookings_check check (start_hour + duration_hours <= 56);

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
  v_booking public.bookings;
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
  v_selections jsonb;
  v_primary_court integer;
  v_primary_hours smallint[];
  v_all_hours integer;
  v_total integer := 0;
  v_name text := nullif(trim(p_customer_name), '');
  v_email text := lower(nullif(trim(p_customer_email), ''));
  v_phone text := nullif(trim(p_customer_phone), '');
  v_court record;
  v_hour integer;
  v_rate integer;
begin
  if v_name is null or length(v_name) > 120 then raise exception 'Enter your name'; end if;
  if v_email is null or length(v_email) > 254 or v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then raise exception 'Enter a valid email address'; end if;
  if v_phone is null or length(regexp_replace(v_phone,'[^0-9]','','g')) <> 11 then raise exception 'Enter a valid phone number with exactly 11 digits'; end if;
  if p_booking_date < (now() at time zone 'Asia/Manila')::date then raise exception 'Choose a future date'; end if;
  if jsonb_typeof(p_court_selections) <> 'array' or jsonb_array_length(p_court_selections) not between 1 and 2 then
    raise exception 'Select one or more available court times';
  end if;
  if (select count(distinct (selection.value->>'court_id')::integer) from jsonb_array_elements(p_court_selections) as selection(value)) <> jsonb_array_length(p_court_selections) then
    raise exception 'Each court can only be selected once';
  end if;

  perform public.expire_booking_holds();
  -- Lock both courts in a stable order so overlapping submissions cannot race.
  perform pg_advisory_xact_lock(6001, 1);
  perform pg_advisory_xact_lock(6001, 2);

  v_selections := '[]'::jsonb;
  for v_court in
    select (selection.value->>'court_id')::integer as court_id,
           array(select distinct hour_value.value::smallint from jsonb_array_elements_text(selection.value->'hours') as hour_value(value) order by 1) as hours
    from jsonb_array_elements(p_court_selections) as selection(value)
    order by (selection.value->>'court_id')::integer
  loop
    if v_court.court_id not in (1,2) or cardinality(v_court.hours) not between 1 and 17
       or v_court.hours[1] < 6 or v_court.hours[cardinality(v_court.hours)] > 22 then
      raise exception 'Choose valid court hours between 6 AM and 11 PM';
    end if;
    if exists(select 1 from unnest(v_court.hours) h where h is null or (p_booking_date::timestamp + make_interval(hours=>h)) at time zone 'Asia/Manila' <= now()) then
      raise exception 'One or more selected hours have already passed';
    end if;
    if exists (
      select 1 from unnest(v_court.hours) h
      join public.booking_hour_slots s on s.court_id=v_court.court_id and s.booking_date=p_booking_date and s.hour=h
    ) then raise exception 'One or more selected hours were just taken. Choose another time.'; end if;
    if exists (
      select 1 from unnest(v_court.hours) h
      join public.court_closures c on c.court_id=v_court.court_id
      where tstzrange(c.starts_at,c.ends_at,'[)') && tstzrange(
        (p_booking_date::timestamp+make_interval(hours=>h)) at time zone 'Asia/Manila',
        (p_booking_date::timestamp+make_interval(hours=>h+1)) at time zone 'Asia/Manila','[)')
    ) then raise exception 'This court is closed during one or more selected hours'; end if;

    select c.hourly_rate into v_rate from public.courts c where c.id=v_court.court_id and c.active;
    if v_rate is null then raise exception 'This court is unavailable'; end if;
    v_total := v_total + cardinality(v_court.hours) * v_rate;
    v_selections := v_selections || jsonb_build_array(jsonb_build_object(
      'court_id',v_court.court_id,'hours',to_jsonb(v_court.hours),
      'hourly_rate',v_rate,'subtotal',cardinality(v_court.hours)*v_rate
    ));
    if v_primary_court is null then
      v_primary_court := v_court.court_id;
      v_primary_hours := v_court.hours;
    end if;
  end loop;

  v_all_hours := cardinality(v_primary_hours);
  insert into public.bookings(
    user_id,court_id,booking_date,start_hour,duration_hours,selected_hours,court_selections,
    total_price,status,payment_status,hold_expires_at,customer_name,customer_email,
    customer_phone,guest_access_token_hash
  ) values (
    null,v_primary_court,p_booking_date,v_primary_hours[1],v_all_hours,v_primary_hours,v_selections,
    v_total,'held','unpaid',now()+interval '10 minutes',v_name,v_email,v_phone,
    encode(extensions.digest(v_token,'sha256'),'hex')
  ) returning * into v_booking;

  -- The existing insert trigger reserves the lead court; replace those rows
  -- with the complete multi-court selection for this single booking id.
  delete from public.booking_hour_slots where booking_id=v_booking.id;
  insert into public.booking_hour_slots(booking_id,court_id,booking_date,hour)
  select v_booking.id,(item->>'court_id')::integer,p_booking_date,(hour_value)::smallint
  from jsonb_array_elements(v_selections) as selection(item)
  cross join lateral jsonb_array_elements_text(selection.item->'hours') as selected_hour(hour_value);

  return jsonb_build_object(
    'id',v_booking.id,'reference',v_booking.reference,'total_price',v_booking.total_price,
    'hold_expires_at',v_booking.hold_expires_at,'access_token',v_token
  );
exception when unique_violation then
  raise exception 'One or more selected hours were just taken. Choose another time.';
end;
$$;

revoke all on function public.create_guest_booking_multi(date,jsonb,text,text,text) from public,authenticated;
grant execute on function public.create_guest_booking_multi(date,jsonb,text,text,text) to anon;

create or replace function public.get_guest_booking(p_booking_id uuid,p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.bookings;
  v_payments jsonb;
  v_selections jsonb;
begin
  if not public.guest_token_matches(p_booking_id,p_token) then raise exception 'Booking link is invalid'; end if;
  select * into v_booking from public.bookings where id=p_booking_id;
  if v_booking.id is null then raise exception 'Booking not found'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'status',p.status,'rejection_reason',p.rejection_reason,'submitted_at',p.submitted_at
  ) order by p.submitted_at desc),'[]'::jsonb) into v_payments
  from public.payments p where p.booking_id=p_booking_id;

  select coalesce(jsonb_agg(selection order by (selection->>'court_id')::integer),v_booking.court_selections)
  into v_selections
  from (
    select jsonb_build_object(
      'court_id',s.court_id,'hours',to_jsonb(array_agg(s.hour order by s.hour)),
      'hourly_rate',c.hourly_rate,'subtotal',count(*)*c.hourly_rate
    ) as selection
    from public.booking_hour_slots s join public.courts c on c.id=s.court_id
    where s.booking_id=p_booking_id group by s.court_id,c.hourly_rate
  ) court_selection;

  return (to_jsonb(v_booking)-'guest_access_token_hash') || jsonb_build_object(
    'court_selections',coalesce(v_selections,v_booking.court_selections),
    'payments',v_payments,
    'cancelled_by_customer',exists(select 1 from public.audit_logs a where a.entity_id=p_booking_id and a.entity_type='booking' and a.action in ('customer_booking_cancelled','guest_booking_cancelled'))
  );
end;
$$;

revoke all on function public.get_guest_booking(uuid,text) from public,authenticated;
grant execute on function public.get_guest_booking(uuid,text) to anon;

-- Repair the legacy combined-submit RPC too, so users on a cached older app
-- build do not hit PL/pgSQL's name conflict between row variable b and alias b.
do $$
declare
  v_definition text;
  v_original text := E'select count(distinct b.court_id)\n         from public.bookings b\n         where b.id in';
  v_fixed text := E'select count(distinct bk.court_id)\n         from public.bookings bk\n         where bk.id in';
begin
  v_definition := pg_get_functiondef('public.confirm_guest_booking_batch(jsonb)'::regprocedure);
  if position(v_original in v_definition) > 0 then
    execute replace(v_definition,v_original,v_fixed);
  end if;
end;
$$;

commit;
