begin;

-- Only submitted bookings reserve paddle stock. A submitted booking is
-- pending until an admin confirms it, and it still consumes stock meanwhile.
create or replace function public.get_paddle_availability(p_booking_date date)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(slot.hour::text,
    greatest(0, 4 - coalesce(used.paddle_count, 0))), '{}'::jsonb)
  from generate_series(6, 22) as slot(hour)
  left join lateral (
    select sum(b.paddle_count)::integer as paddle_count
    from public.booking_hour_slots s
    join public.bookings b on b.id = s.booking_id
    where s.booking_date = p_booking_date
      and s.hour = slot.hour
      and (
        b.status = 'confirmed'
        or (b.status = 'pending'
          and coalesce(b.hold_expires_at, now() + interval '1 day') > now())
      )
  ) used on true;
$$;

-- Protect submitted bookings against concurrent paddle rentals and admin time
-- adjustments. Draft forms remain uncounted until their submit operation.
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
  if new.paddle_count <= 0 or not (
    new.status = 'confirmed'
    or (new.status = 'pending'
      and coalesce(new.hold_expires_at, now() + interval '1 day') > now())
  ) then
    return new;
  end if;

  perform pg_advisory_xact_lock(6001, 3);
  for v_slot in
    select booking_date, hour
    from public.booking_hour_slots
    where booking_id = new.id
  loop
    select coalesce(sum(b.paddle_count), 0)::integer
    into v_used_paddles
    from public.booking_hour_slots s
    join public.bookings b on b.id = s.booking_id
    where s.booking_date = v_slot.booking_date
      and s.hour = v_slot.hour
      and b.id <> new.id
      and (
        b.status = 'confirmed'
        or (b.status = 'pending'
          and coalesce(b.hold_expires_at, now() + interval '1 day') > now())
      );
    if v_used_paddles + new.paddle_count > 4 then
      raise exception 'Not enough paddles are available for one or more selected hours';
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists bookings_enforce_paddle_inventory on public.bookings;
create trigger bookings_enforce_paddle_inventory
before update of status, paddle_count on public.bookings
for each row execute function public.enforce_paddle_inventory_on_booking_change();

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
  select * into v_booking
  from public.bookings
  where id = new.booking_id;
  if v_booking.id is null or v_booking.paddle_count <= 0 or not (
    v_booking.status = 'confirmed'
    or (v_booking.status = 'pending'
      and coalesce(v_booking.hold_expires_at, now() + interval '1 day') > now())
  ) then
    return new;
  end if;

  perform pg_advisory_xact_lock(6001, 3);
  select coalesce(sum(b.paddle_count), 0)::integer
  into v_used_paddles
  from public.booking_hour_slots s
  join public.bookings b on b.id = s.booking_id
  where s.booking_date = new.booking_date
    and s.hour = new.hour
    and b.id <> new.booking_id
    and (
      b.status = 'confirmed'
      or (b.status = 'pending'
        and coalesce(b.hold_expires_at, now() + interval '1 day') > now())
    );
  if v_used_paddles + v_booking.paddle_count > 4 then
    raise exception 'Not enough paddles are available for one or more selected hours';
  end if;
  return new;
end;
$$;

drop trigger if exists booking_slots_enforce_paddle_inventory on public.booking_hour_slots;
create trigger booking_slots_enforce_paddle_inventory
before insert or update on public.booking_hour_slots
for each row execute function public.enforce_paddle_inventory_on_slot_change();

revoke all on function public.get_paddle_availability(date) from public;
grant execute on function public.get_paddle_availability(date) to anon, authenticated;
revoke all on function public.enforce_paddle_inventory_on_booking_change() from public, anon, authenticated;
revoke all on function public.enforce_paddle_inventory_on_slot_change() from public, anon, authenticated;

commit;
