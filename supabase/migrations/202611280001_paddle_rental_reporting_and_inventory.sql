begin;

-- A parent booking can occupy both courts during the same hour. Count that
-- booking's paddles once for each hour, rather than once per court slot.
create or replace function public.get_paddle_availability(p_booking_date date)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with occupied_paddles as (
    select slot.hour, sum(slot.paddle_count)::integer as rented
    from (
      select distinct b.id, s.hour, b.paddle_count
      from public.booking_hour_slots s
      join public.bookings b on b.id = s.booking_id
      where s.booking_date = p_booking_date
        and b.paddle_count > 0
        and b.status in ('pending', 'confirmed')
        and ((s.booking_date::timestamp + make_interval(hours => s.hour + 1)) at time zone 'Asia/Manila') > now()
    ) slot
    group by slot.hour
  )
  select coalesce(jsonb_object_agg(hour_row.hour::text,
    greatest(0, 4 - coalesce(occupied.rented, 0))), '{}'::jsonb)
  from generate_series(6, 22) as hour_row(hour)
  left join occupied_paddles occupied on occupied.hour = hour_row.hour;
$$;

-- Correct duplicate counts in the booking-level capacity trigger.
create or replace function public.enforce_paddle_inventory_on_booking_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot record;
  v_used_paddles integer;
begin
  if new.paddle_count <= 0 or new.status not in ('pending', 'confirmed') then
    return new;
  end if;

  perform pg_advisory_xact_lock(6001, 3);
  for v_slot in
    select distinct booking_date, hour
    from public.booking_hour_slots
    where booking_id = new.id
  loop
    select coalesce(sum(reservation.paddle_count), 0)::integer
    into v_used_paddles
    from (
      select distinct b.id, b.paddle_count
      from public.booking_hour_slots s
      join public.bookings b on b.id = s.booking_id
      where s.booking_date = v_slot.booking_date
        and s.hour = v_slot.hour
        and b.id <> new.id
        and b.status in ('pending', 'confirmed')
        and ((s.booking_date::timestamp + make_interval(hours => s.hour + 1)) at time zone 'Asia/Manila') > now()
    ) reservation;
    if v_used_paddles + new.paddle_count > 4 then
      raise exception 'Not enough paddles are available for one or more selected hours';
    end if;
  end loop;
  return new;
end;
$$;

-- Apply the same once-per-booking inventory check to slot changes.
create or replace function public.enforce_paddle_inventory_on_slot_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.bookings;
  v_used_paddles integer;
begin
  select * into v_booking from public.bookings where id = new.booking_id;
  if v_booking.id is null or v_booking.paddle_count <= 0
     or v_booking.status not in ('pending', 'confirmed')
     or ((new.booking_date::timestamp + make_interval(hours => new.hour + 1)) at time zone 'Asia/Manila') <= now() then
    return new;
  end if;

  perform pg_advisory_xact_lock(6001, 3);
  select coalesce(sum(reservation.paddle_count), 0)::integer
  into v_used_paddles
  from (
    select distinct b.id, b.paddle_count
    from public.booking_hour_slots s
    join public.bookings b on b.id = s.booking_id
    where s.booking_date = new.booking_date
      and s.hour = new.hour
      and b.id <> new.booking_id
      and b.status in ('pending', 'confirmed')
      and ((s.booking_date::timestamp + make_interval(hours => s.hour + 1)) at time zone 'Asia/Manila') > now()
  ) reservation;
  if v_used_paddles + v_booking.paddle_count > 4 then
    raise exception 'Not enough paddles are available for one or more selected hours';
  end if;
  return new;
end;
$$;

revoke all on function public.get_paddle_availability(date) from public;
grant execute on function public.get_paddle_availability(date) to anon, authenticated;
revoke all on function public.enforce_paddle_inventory_on_booking_change() from public, anon, authenticated;
revoke all on function public.enforce_paddle_inventory_on_slot_change() from public, anon, authenticated;

-- Keep rental performance separate from court income while leaving paddle_fee
-- inside bookings.total_price and all existing payment collections unchanged.
create or replace function public.admin_get_paddle_rental_report(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Choose a valid reporting date range';
  end if;

  with rental_bookings as (
    select b.id, b.paddle_count, b.paddle_fee, b.court_selections,
           b.selected_hours, b.start_hour, b.duration_hours
    from public.bookings b
    where b.booking_date between p_from and p_to
      and b.paddle_count > 0
      and b.status in ('pending', 'confirmed', 'completed')
  ), rental_hours as (
    select b.id, h.hour::integer as hour
    from rental_bookings b
    cross join lateral (
      select distinct value::integer as hour
      from (
        select jsonb_array_elements_text(selection.value->'hours') as value
        from jsonb_array_elements(coalesce(b.court_selections, '[]'::jsonb)) as selection(value)
        where jsonb_typeof(selection.value->'hours') = 'array'
        union all
        select unnest(coalesce(b.selected_hours, array[]::smallint[]))::text
        where jsonb_array_length(coalesce(b.court_selections, '[]'::jsonb)) = 0
      ) selected
    ) h
  ), durations as (
    select id, count(*)::integer as hours from rental_hours group by id
  )
  select jsonb_build_object(
    'rental_bookings', (select count(*)::integer from rental_bookings),
    'paddles_rented', (select coalesce(sum(paddle_count), 0)::integer from rental_bookings),
    'rental_revenue', (select coalesce(sum(paddle_fee), 0)::numeric(12,2) from rental_bookings),
    'durations', coalesce((
      select jsonb_agg(jsonb_build_object('hours', hours, 'rentals', rentals) order by hours)
      from (select durations.hours, count(*)::integer as rentals from durations group by durations.hours) duration_counts
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.admin_get_paddle_rental_report(date,date) from public, anon;
grant execute on function public.admin_get_paddle_rental_report(date,date) to authenticated;

commit;
