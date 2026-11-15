begin;

-- Give customers three hours to finish the pre-submission reservation hold.
update public.app_settings
set value = value || '{"hold_minutes":180}'::jsonb,
    updated_at = now()
where key = 'booking_policy';

-- Extend holds that are still active when this migration is applied.
update public.bookings
set hold_expires_at = created_at + interval '3 hours',
    updated_at = now()
where status = 'held'
  and hold_expires_at > now();

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
  if b.status<>'held' or b.hold_expires_at<=now() then
    raise exception 'The 3-hour hold expired. Please reserve again.';
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

commit;
