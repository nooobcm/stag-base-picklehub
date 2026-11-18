begin;

alter table public.booking_payment_transactions
  add column if not exists received_by_name text;

drop function if exists public.admin_record_booking_payment(uuid,numeric,text,uuid);

create function public.admin_record_booking_payment(
  p_booking_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_request_id uuid,
  p_received_by_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings;
  v_received numeric(12,2);
  v_remaining numeric(12,2);
  v_payment_status text;
  v_existing public.booking_payment_transactions;
  v_receiver text := btrim(coalesce(p_received_by_name, ''));
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_request_id is null then raise exception 'Payment request id is required'; end if;
  if p_payment_method not in ('cash','online') then raise exception 'Choose Cash or GCash / InstaPay'; end if;
  if v_receiver not in (
    'Admin: Andrew Santiago',
    'Admin: Arra Santiago',
    'Admin: Christian Santiago',
    'Admin: Violeta Santiago'
  ) then raise exception 'Choose who received the payment'; end if;

  select * into v_existing from public.booking_payment_transactions where idempotency_key=p_request_id;
  if v_existing.id is not null then
    if v_existing.booking_id <> p_booking_id then raise exception 'Payment request id was already used'; end if;
    select * into b from public.bookings where id=p_booking_id;
    select coalesce(sum(amount),0) into v_received from public.booking_payment_transactions where booking_id=p_booking_id;
    return jsonb_build_object('received',v_received,'outstanding',greatest(b.total_price-v_received,0),
      'payment_status',b.payment_status,'duplicate',true);
  end if;

  select * into b from public.bookings where id=p_booking_id for update;
  if b.id is null or b.status not in ('confirmed','completed') then
    raise exception 'Only confirmed bookings can receive additional payments';
  end if;
  select * into v_existing from public.booking_payment_transactions where idempotency_key=p_request_id;
  if v_existing.id is not null then
    if v_existing.booking_id <> p_booking_id then raise exception 'Payment request id was already used'; end if;
    select coalesce(sum(amount),0) into v_received from public.booking_payment_transactions where booking_id=p_booking_id;
    return jsonb_build_object('received',v_received,'outstanding',greatest(b.total_price-v_received,0),
      'payment_status',b.payment_status,'duplicate',true);
  end if;

  if p_amount is null or p_amount <= 0 then raise exception 'Enter an amount greater than zero'; end if;
  if round(p_amount,2) <> p_amount then raise exception 'Amount can have at most two decimal places'; end if;
  select coalesce(sum(amount),0) into v_received from public.booking_payment_transactions where booking_id=b.id;
  v_remaining := greatest(b.total_price-v_received,0);
  if p_amount <> v_remaining then raise exception 'Enter the exact remaining balance of %',v_remaining; end if;

  insert into public.booking_payment_transactions(
    booking_id,amount,payment_method,payment_type,received_by,received_by_name,idempotency_key
  ) values(b.id,p_amount,p_payment_method,'balance',auth.uid(),v_receiver,p_request_id);

  v_received := v_received + p_amount;
  v_payment_status := case when v_received >= b.total_price then 'fully_paid'
                           when v_received > 0 then 'partially_paid' else 'unpaid' end;
  update public.bookings set payment_status=v_payment_status,updated_at=now() where id=b.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'booking_payment_recorded','booking',b.id,
    jsonb_build_object('amount',p_amount,'payment_method',p_payment_method,'payment_type','balance',
      'received_by_name',v_receiver));
  return jsonb_build_object('received',v_received,'outstanding',greatest(b.total_price-v_received,0),
    'payment_status',v_payment_status,'duplicate',false);
end;
$$;

revoke all on function public.admin_record_booking_payment(uuid,numeric,text,uuid,text) from public,anon;
grant execute on function public.admin_record_booking_payment(uuid,numeric,text,uuid,text) to authenticated;

commit;
