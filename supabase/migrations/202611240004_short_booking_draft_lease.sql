begin;

-- Tab-close release requests are best effort because browsers can terminate
-- network work during shutdown. Keep draft reservations short so abandoned
-- slots clear promptly even when the shutdown request is interrupted.
update public.bookings
set hold_expires_at = least(hold_expires_at, now() + interval '45 seconds'),
    updated_at = now()
where is_draft_hold = true and status = 'held';

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
      hold_expires_at = now() + interval '45 seconds',
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
  set hold_expires_at = now() + interval '45 seconds', updated_at = now()
  where id = p_booking_id
  returning hold_expires_at into v_booking.hold_expires_at;

  return v_booking.hold_expires_at;
end;
$$;

commit;
