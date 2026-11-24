begin;

alter table public.bookings
  add column if not exists is_draft_hold boolean not null default false;

-- A draft blocks selected hours while the customer fills in the booking form.
-- The client renews this short lease while the form remains open; it is not a
-- customer-visible countdown and is released immediately when the form closes.
create or replace function public.create_guest_booking_draft(
  p_booking_date date,
  p_court_selections jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking jsonb;
  v_booking_id uuid;
begin
  v_booking := public.create_guest_booking_multi(
    p_booking_date,
    p_court_selections,
    'Booking in progress',
    'draft-' || extensions.gen_random_uuid()::text || '@hold.invalid',
    '00000000000',
    'cash'
  );
  v_booking_id := (v_booking->>'id')::uuid;

  update public.bookings
  set is_draft_hold = true,
      hold_expires_at = now() + interval '2 minutes',
      updated_at = now()
  where id = v_booking_id and status = 'held';

  return v_booking;
end;
$$;

create or replace function public.renew_guest_booking_draft(
  p_booking_id uuid,
  p_token text
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.bookings;
begin
  if not public.guest_token_matches(p_booking_id, p_token) then
    raise exception 'Booking draft is invalid';
  end if;

  perform public.expire_booking_holds();
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.status <> 'held' or v_booking.hold_expires_at <= now() then
    raise exception 'This booking draft expired. Select the times again.';
  end if;

  update public.bookings
  set hold_expires_at = now() + interval '2 minutes', updated_at = now()
  where id = p_booking_id
  returning hold_expires_at into v_booking.hold_expires_at;

  return v_booking.hold_expires_at;
end;
$$;

create or replace function public.release_guest_booking_draft(
  p_booking_id uuid,
  p_token text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.bookings;
begin
  if not public.guest_token_matches(p_booking_id, p_token) then
    raise exception 'Booking draft is invalid';
  end if;

  perform public.expire_booking_holds();
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.status = 'held' and v_booking.hold_expires_at > now() then
    update public.bookings
    set status = 'cancelled', updated_at = now()
    where id = p_booking_id;
    insert into public.audit_logs(actor_id, action, entity_type, entity_id, details)
    values(null, 'guest_booking_draft_released', 'booking', p_booking_id,
      jsonb_build_object('reference', v_booking.reference));
  end if;
end;
$$;

create or replace function public.finalize_guest_booking_draft(
  p_booking_id uuid,
  p_token text,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text,
  p_paddle_count integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.bookings;
  v_rental_hours integer := 0;
  v_paddle_fee integer := 0;
  v_name text := nullif(trim(p_customer_name), '');
  v_email text := lower(nullif(trim(p_customer_email), ''));
  v_phone text := nullif(trim(p_customer_phone), '');
begin
  if v_name is null or length(v_name) > 120 then raise exception 'Enter your name'; end if;
  if v_email is null or length(v_email) > 254 or v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then
    raise exception 'Enter a valid email address';
  end if;
  if v_phone is null or length(regexp_replace(v_phone, '[^0-9]', '', 'g')) <> 11 then
    raise exception 'Enter a valid phone number with exactly 11 digits';
  end if;
  if p_paddle_count is null or p_paddle_count not between 0 and 4 then
    raise exception 'Choose between 0 and 4 paddles';
  end if;
  if not public.guest_token_matches(p_booking_id, p_token) then
    raise exception 'Booking draft is invalid';
  end if;

  perform public.expire_booking_holds();
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.status <> 'held' or v_booking.hold_expires_at <= now() then
    raise exception 'This booking draft expired. Select the times again.';
  end if;

  if p_paddle_count > 0 then
    perform pg_advisory_xact_lock(6001, 3);
    select count(distinct s.hour)::integer into v_rental_hours
    from public.booking_hour_slots s where s.booking_id = p_booking_id;

    if exists (
      select 1 from public.booking_hour_slots requested
      where requested.booking_id = p_booking_id
        and (select coalesce(sum(other_booking.paddle_count), 0)
          from public.booking_hour_slots occupied
          join public.bookings other_booking on other_booking.id = occupied.booking_id
          where occupied.booking_date = requested.booking_date
            and occupied.hour = requested.hour
            and occupied.booking_id <> p_booking_id
            and (other_booking.status = 'confirmed'
              or (other_booking.status = 'pending'
                and coalesce(other_booking.hold_expires_at, now() + interval '1 day') > now()))
        ) + p_paddle_count > 4
    ) then raise exception 'Not enough paddles are available for one or more selected hours'; end if;

    v_paddle_fee := p_paddle_count * (50 + greatest(v_rental_hours - 1, 0) * 25);
  end if;

  update public.bookings
  set customer_name = v_name,
      customer_email = v_email,
      customer_phone = regexp_replace(v_phone, '[^0-9]', '', 'g'),
      paddle_count = p_paddle_count,
      paddle_fee = v_paddle_fee,
      total_price = total_price - coalesce(paddle_fee, 0) + v_paddle_fee,
      payment_method = 'online',
      is_draft_hold = false,
      updated_at = now()
  where id = p_booking_id;

  perform public.confirm_guest_booking_request(p_booking_id, p_token);
  select * into v_booking from public.bookings where id = p_booking_id;

  return jsonb_build_object(
    'id', v_booking.id,
    'reference', v_booking.reference,
    'total_price', v_booking.total_price,
    'paddle_count', v_booking.paddle_count,
    'paddle_fee', v_booking.paddle_fee
  );
end;
$$;

revoke all on function public.create_guest_booking_draft(date, jsonb) from public, authenticated;
revoke all on function public.renew_guest_booking_draft(uuid, text) from public, authenticated;
revoke all on function public.release_guest_booking_draft(uuid, text) from public, authenticated;
revoke all on function public.finalize_guest_booking_draft(uuid, text, text, text, text, integer) from public, authenticated;
grant execute on function public.create_guest_booking_draft(date, jsonb) to anon;
grant execute on function public.renew_guest_booking_draft(uuid, text) to anon;
grant execute on function public.release_guest_booking_draft(uuid, text) to anon;
grant execute on function public.finalize_guest_booking_draft(uuid, text, text, text, text, integer) to anon;

-- Surface draft holds separately so other customers see "On hold" while the
-- original customer completes the form; submitted requests remain "Pending".
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
      case when b.status = 'held' then 'held'
           when b.status = 'pending' then 'pending'
           else 'booked' end as slot_status
    from public.booking_hour_slots s
    join public.bookings b on b.id = s.booking_id
    where s.court_id = p_court_id
      and s.booking_date = p_booking_date
      and b.status in ('held', 'pending', 'confirmed', 'completed')
  ), maintenance as (
    select distinct h::integer as hour, 'maintenance'::text as slot_status
    from public.court_closures c
    cross join lateral generate_series(6, 22) h
    where c.court_id = p_court_id
      and (p_booking_date::timestamp + make_interval(hours => h + 1)) at time zone 'Asia/Manila' > c.starts_at
      and (p_booking_date::timestamp + make_interval(hours => h)) at time zone 'Asia/Manila' < c.ends_at
  )
  select * from occupied
  union
  select * from maintenance;
end;
$$;

revoke all on function public.get_slot_availability(integer, date) from public;
grant execute on function public.get_slot_availability(integer, date) to anon, authenticated;

commit;
