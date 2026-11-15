begin;

create or replace function public.admin_reject_unpaid_booking(
  p_booking_id uuid,
  p_reason text default null
)
returns public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings;
  v_reason text := nullif(trim(p_reason),'');
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;

  update public.bookings
  set status='rejected',updated_at=now()
  where id=p_booking_id and status='pending' and payment_status='unpaid'
  returning * into b;
  if b.id is null then raise exception 'This booking is no longer awaiting confirmation'; end if;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'unpaid_booking_rejected','booking',b.id,
    jsonb_build_object('reference',b.reference,'reason',v_reason));
  return b;
end;
$$;

commit;
