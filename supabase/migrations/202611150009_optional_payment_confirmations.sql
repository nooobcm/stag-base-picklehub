begin;

-- Preserve the previous 10-minute timeout for any legacy pending unpaid holds.
update public.bookings
set status='cancelled',updated_at=now()
where status='pending' and payment_status='unpaid' and hold_expires_at<now();

-- Submitted unpaid reservations remain pending for admin review instead of expiring.
create or replace function public.expire_booking_holds()
returns void language plpgsql security definer set search_path = '' as $$
declare v_review_hours integer;
begin
  select coalesce((value->>'proof_review_hours')::integer,24) into v_review_hours
  from public.app_settings where key='booking_policy';

  update public.payments p
  set status='rejected', rejection_reason='The 10-minute booking hold expired', reviewed_at=now()
  from public.bookings b
  where p.booking_id=b.id and b.status='held' and b.hold_expires_at<now() and p.status='proof_submitted';

  update public.payments
  set status='rejected', rejection_reason='Payment proof review window expired', reviewed_at=now()
  where status='proof_submitted'
    and submitted_at < now()-make_interval(hours=>coalesce(v_review_hours,24))
    and exists(select 1 from public.bookings b where b.id=booking_id and b.status='pending');

  update public.bookings b
  set status='cancelled', updated_at=now(),
      payment_status=case when b.payment_status='proof_submitted' then 'rejected' else b.payment_status end
  where (b.status='held' and b.hold_expires_at<now())
     or (b.status='pending' and b.payment_status='proof_submitted' and not exists(
       select 1 from public.payments p where p.booking_id=b.id and p.status='proof_submitted'));
end;
$$;

-- A customer can submit their 10-minute hold with or without proof.
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
    raise exception 'The 10-minute hold expired. Please reserve again.';
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

-- Admin approval for an unpaid reservation confirms the court time without requiring proof.
create or replace function public.admin_confirm_unpaid_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare b public.bookings;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  update public.bookings
  set status='confirmed',updated_at=now()
  where id=p_booking_id and status='pending' and payment_status='unpaid'
  returning * into b;
  if b.id is null then raise exception 'This unpaid booking is no longer awaiting approval'; end if;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'unpaid_booking_confirmed','booking',b.id,
    jsonb_build_object('reference',b.reference,'amount_due',b.total_price));
  return b;
end;
$$;

revoke all on function public.admin_confirm_unpaid_booking(uuid) from public,anon;
grant execute on function public.admin_confirm_unpaid_booking(uuid) to authenticated;

commit;
