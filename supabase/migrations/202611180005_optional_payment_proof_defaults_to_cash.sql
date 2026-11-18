begin;

-- A new reservation always opens the payment instructions during its hold.
-- At submission, a proof determines online payment; without proof it becomes cash.
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
  v_has_proof boolean;
begin
  if not public.guest_token_matches(p_booking_id,p_token) then
    raise exception 'Booking link is invalid';
  end if;

  perform public.expire_booking_holds();

  select * into b
  from public.bookings
  where id=p_booking_id
  for update;

  if b.status <> 'held' or b.hold_expires_at <= now() then
    raise exception 'The 10-minute hold expired. Please reserve again.';
  end if;

  select exists(
    select 1 from public.payments p
    where p.booking_id=b.id and p.status='proof_submitted'
  ) into v_has_proof;

  update public.bookings
  set status='pending',
      payment_method=case when v_has_proof then 'online' else 'cash' end,
      hold_expires_at='infinity'::timestamptz,
      updated_at=now()
  where id=b.id
  returning * into b;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(null,'guest_booking_submitted','booking',b.id,jsonb_build_object(
    'reference',b.reference,
    'amount',b.total_price,
    'payment_status',b.payment_status,
    'payment_method',b.payment_method
  ));

  return b;
end;
$$;

revoke all on function public.confirm_guest_booking_request(uuid,text) from public,authenticated;
grant execute on function public.confirm_guest_booking_request(uuid,text) to anon;

commit;
