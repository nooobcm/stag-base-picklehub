begin;

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
  v_cancellation_hours integer;
  v_start_hour integer;
  v_play_starts_at timestamptz;
begin
  if not public.guest_token_matches(p_booking_id, p_token) then
    raise exception 'Booking link is invalid';
  end if;

  perform public.expire_booking_holds();

  select * into b
  from public.bookings
  where id = p_booking_id
  for update;

  if b.id is null then
    raise exception 'Booking not found';
  end if;

  if b.status = 'held' then
    if b.hold_expires_at <= now() then
      raise exception 'This payment hold has expired';
    end if;
  elsif b.status in ('pending', 'confirmed') then
    select coalesce((value->>'cancellation_hours')::integer, 12)
      into v_cancellation_hours
    from public.app_settings
    where key = 'booking_policy';

    select coalesce(min(hour)::integer, b.start_hour::integer)
      into v_start_hour
    from public.booking_hour_slots
    where booking_id = b.id;

    v_play_starts_at := (b.booking_date::timestamp
      + make_interval(hours => v_start_hour)) at time zone 'Asia/Manila';

    if v_play_starts_at < now() + make_interval(hours => coalesce(v_cancellation_hours, 12)) then
      raise exception 'Bookings must be cancelled at least % hours before start', coalesce(v_cancellation_hours, 12);
    end if;
  else
    raise exception 'This booking cannot be cancelled';
  end if;

  update public.bookings
  set status = 'cancelled', customer_cancelled_at = now(), updated_at = now()
  where id = b.id;

  insert into public.audit_logs(actor_id, action, entity_type, entity_id, details)
  values(null, 'guest_booking_cancelled', 'booking', b.id, '{}'::jsonb);
end;
$$;

revoke all on function public.cancel_guest_booking(uuid, text) from public, authenticated;
grant execute on function public.cancel_guest_booking(uuid, text) to anon;

commit;
