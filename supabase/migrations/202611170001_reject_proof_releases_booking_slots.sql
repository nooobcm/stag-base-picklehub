begin;

-- Rejecting a submitted payment proof also rejects its booking. The booking
-- status transition fires bookings_release_hour_slots, freeing every court
-- hour in a multi-court reservation.
create or replace function public.review_payment(
  p_payment_id uuid,
  p_decision text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.payments;
  b public.bookings;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_decision not in ('verify','reject') then raise exception 'Invalid review decision'; end if;

  select * into p from public.payments where id = p_payment_id for update;
  if p.id is null or p.status <> 'proof_submitted' then
    raise exception 'Payment proof is no longer awaiting review';
  end if;

  select * into b from public.bookings where id = p.booking_id for update;
  if b.id is null or b.status <> 'pending' then
    raise exception 'Customer has not submitted this booking for confirmation';
  end if;

  if p.submitted_at < now() - make_interval(hours => coalesce(
    (select (value->>'proof_review_hours')::integer
     from public.app_settings where key = 'booking_policy'), 24)) then
    update public.payments
    set status = 'rejected', rejection_reason = 'Payment proof review window expired',
        reviewed_at = now(), reviewed_by = auth.uid()
    where id = p.id;
    update public.bookings
    set status = 'cancelled', payment_status = 'rejected', updated_at = now()
    where id = b.id;
    insert into public.audit_logs(actor_id, action, entity_type, entity_id, details)
    values(auth.uid(), 'payment_expired', 'payment', p.id,
      jsonb_build_object('booking_id', b.id));
    return;
  end if;

  if p_decision = 'verify' then
    update public.payments
    set status = 'verified', reviewed_at = now(), reviewed_by = auth.uid(), rejection_reason = null
    where id = p.id;
    update public.bookings
    set payment_status = 'verified', status = 'confirmed', hold_expires_at = now(), updated_at = now()
    where id = b.id;
  else
    update public.payments
    set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid(),
        rejection_reason = coalesce(nullif(trim(p_reason), ''), 'Payment proof rejected')
    where id = p.id;
    update public.bookings
    set status = 'rejected', payment_status = 'rejected', updated_at = now()
    where id = b.id;
  end if;

  insert into public.audit_logs(actor_id, action, entity_type, entity_id, details)
  values(auth.uid(), 'payment_' || p_decision, 'payment', p.id,
    jsonb_build_object('booking_id', b.id, 'amount', p.amount, 'reason', p_reason));
end;
$$;

revoke all on function public.review_payment(uuid, text, text) from public, anon;
grant execute on function public.review_payment(uuid, text, text) to authenticated;

commit;
