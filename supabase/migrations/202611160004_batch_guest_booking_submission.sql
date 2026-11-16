create or replace function public.confirm_guest_booking_batch(p_bookings jsonb)
returns setof public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  booking_id uuid;
  token text;
  b public.bookings;
  booking_count integer;
begin
  if jsonb_typeof(p_bookings) <> 'array' then
    raise exception 'Invalid booking list';
  end if;

  select count(*) into booking_count from jsonb_array_elements(p_bookings);
  if booking_count < 2 or booking_count > 2 then
    raise exception 'A grouped reservation must include both courts';
  end if;
  if (select count(distinct value->>'booking_id') from jsonb_array_elements(p_bookings)) <> 2
     or (select count(distinct b.court_id)
         from public.bookings b
         where b.id in (select (value->>'booking_id')::uuid from jsonb_array_elements(p_bookings))) <> 2 then
    raise exception 'A grouped reservation must contain one booking for each court';
  end if;

  perform public.expire_booking_holds();

  -- Lock all requested rows in a consistent order before validating or changing
  -- either one, so the group is submitted as one database transaction.
  for b in
    select * from public.bookings
    where id in (
      select (value->>'booking_id')::uuid from jsonb_array_elements(p_bookings)
    )
    order by id
    for update
  loop
    null;
  end loop;

  for item in select value from jsonb_array_elements(p_bookings) loop
    booking_id := (item->>'booking_id')::uuid;
    token := item->>'token';
    if token is null or not public.guest_token_matches(booking_id, token) then
      raise exception 'A booking link is invalid';
    end if;

    select * into b from public.bookings where id = booking_id;
    if not found or b.status <> 'held' or b.hold_expires_at <= now() then
      raise exception 'A 10-minute hold expired. Please reserve the times again.';
    end if;
  end loop;

  for item in select value from jsonb_array_elements(p_bookings) loop
    booking_id := (item->>'booking_id')::uuid;
    update public.bookings
    set status = 'pending',
        hold_expires_at = 'infinity'::timestamptz,
        updated_at = now()
    where id = booking_id
    returning * into b;

    insert into public.audit_logs(actor_id, action, entity_type, entity_id, details)
    values (null, 'guest_booking_submitted', 'booking', b.id, jsonb_build_object(
      'reference', b.reference,
      'amount', b.total_price,
      'payment_status', b.payment_status,
      'grouped_reservation', true
    ));
    return next b;
  end loop;
end;
$$;

revoke all on function public.confirm_guest_booking_batch(jsonb) from public, authenticated;
grant execute on function public.confirm_guest_booking_batch(jsonb) to anon;
