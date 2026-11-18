begin;

-- Keep uploaded proof submissions in public.payments. Store every actual
-- receipt separately so a proof amount is never mistaken for money received.
create table public.booking_payment_transactions (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete restrict,
  payment_proof_id uuid unique references public.payments(id) on delete restrict,
  amount numeric(12,2) not null check (amount > 0),
  payment_method text not null check (payment_method in ('cash','online')),
  payment_type text not null check (payment_type in ('deposit','balance')),
  received_by uuid references public.profiles(id),
  idempotency_key uuid not null unique default gen_random_uuid(),
  received_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index booking_payment_transactions_booking_idx
  on public.booking_payment_transactions(booking_id, received_at desc);

do $$ begin
  alter publication supabase_realtime add table public.booking_payment_transactions;
exception when duplicate_object then null;
end $$;

alter table public.booking_payment_transactions enable row level security;
create policy "Admins read booking payment transactions"
  on public.booking_payment_transactions for select to authenticated
  using (public.is_admin());
grant select on public.booking_payment_transactions to authenticated;
revoke insert, update, delete on public.booking_payment_transactions from anon, authenticated;

-- Older verified proofs represented full payment in the previous workflow.
-- Preserve those recorded amounts and proof references in the new ledger.
insert into public.booking_payment_transactions(
  booking_id, payment_proof_id, amount, payment_method, payment_type,
  received_by, received_at
)
select p.booking_id, p.id, p.amount, 'online', 'deposit', p.reviewed_by,
       coalesce(p.reviewed_at, p.submitted_at)
from public.payments p
where p.status = 'verified' and p.amount > 0
on conflict (payment_proof_id) do nothing;

alter table public.bookings drop constraint if exists bookings_payment_status_check;
update public.bookings b
set payment_status = case
  when coalesce(t.received, 0) >= b.total_price then 'fully_paid'
  when coalesce(t.received, 0) > 0 then 'partially_paid'
  else 'unpaid'
end,
updated_at = now()
from (
  select booking_id, sum(amount) as received
  from public.booking_payment_transactions group by booking_id
) t
where b.id = t.booking_id and b.payment_status = 'verified';
update public.bookings set payment_status = 'unpaid', updated_at = now()
where payment_status = 'verified';
alter table public.bookings
  add constraint bookings_payment_status_check
  check (payment_status in ('unpaid','proof_submitted','partially_paid','fully_paid','rejected','refunded'));

create or replace function public.sync_booking_payment_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking_id uuid;
  v_status text;
  v_received numeric(12,2);
  v_total integer;
begin
  if tg_op = 'DELETE' then v_booking_id := old.booking_id;
  else v_booking_id := new.booking_id;
  end if;
  select status, total_price into v_status, v_total
  from public.bookings where id = v_booking_id for update;
  if v_total is null or v_status not in ('confirmed','completed') then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  select coalesce(sum(amount), 0) into v_received
  from public.booking_payment_transactions where booking_id = v_booking_id;
  update public.bookings
  set payment_status = case
        when v_received = 0 then 'unpaid'
        when v_received >= v_total then 'fully_paid'
        else 'partially_paid'
      end,
      updated_at = now()
  where id = v_booking_id;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

revoke all on function public.sync_booking_payment_status() from public, anon, authenticated;
create trigger sync_booking_payment_status_after_change
after insert or update or delete on public.booking_payment_transactions
for each row execute function public.sync_booking_payment_status();

-- Replaces the old proof review RPC. Approval requires the admin to enter the
-- actual amount received; recording and confirming happen in one transaction.
create or replace function public.admin_review_booking_payment_proof(
  p_payment_id uuid,
  p_decision text,
  p_amount_received numeric default null,
  p_request_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.payments;
  b public.bookings;
  v_received numeric(12,2);
  v_request_id uuid := coalesce(p_request_id, gen_random_uuid());
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_decision not in ('verify','reject') then raise exception 'Invalid review decision'; end if;

  if p_request_id is not null and exists (
    select 1 from public.booking_payment_transactions
    where idempotency_key=p_request_id and payment_proof_id=p_payment_id
  ) then return; end if;

  select * into p from public.payments where id = p_payment_id for update;
  if p.id is null or p.status <> 'proof_submitted' then
    if p_request_id is not null and exists (
      select 1 from public.booking_payment_transactions
      where idempotency_key=p_request_id and payment_proof_id=p_payment_id
    ) then return; end if;
    raise exception 'Payment proof is no longer awaiting review';
  end if;
  select * into b from public.bookings where id = p.booking_id for update;
  if b.id is null or b.status <> 'pending' then
    raise exception 'Customer has not submitted this booking for confirmation';
  end if;

  if p.submitted_at < now() - make_interval(hours => coalesce(
    (select (value->>'proof_review_hours')::integer from public.app_settings where key = 'booking_policy'), 24)) then
    update public.payments set status='rejected', rejection_reason='Payment proof review window expired',
      reviewed_at=now(), reviewed_by=auth.uid() where id=p.id;
    update public.bookings set status='cancelled', payment_status='rejected', updated_at=now() where id=b.id;
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'payment_expired','payment',p.id,jsonb_build_object('booking_id',b.id));
    return;
  end if;

  if p_decision = 'reject' then
    update public.payments set status='rejected', rejection_reason='Payment proof rejected',
      reviewed_at=now(), reviewed_by=auth.uid() where id=p.id;
    update public.bookings set status='rejected', payment_status='rejected', updated_at=now() where id=b.id;
  else
    if b.payment_method <> 'online' then raise exception 'Payment proof is only valid for online bookings'; end if;
    if p_amount_received is null or p_amount_received <= 0 or p_amount_received > b.total_price then
      raise exception 'Enter an amount greater than zero and no more than the booking total';
    end if;
    if round(p_amount_received, 2) <> p_amount_received then raise exception 'Amount can have at most two decimal places'; end if;

    update public.payments set status='verified', reviewed_at=now(), reviewed_by=auth.uid(), rejection_reason=null where id=p.id;
    insert into public.booking_payment_transactions(
      booking_id,payment_proof_id,amount,payment_method,payment_type,received_by,idempotency_key
    ) values (b.id,p.id,p_amount_received,'online','deposit',auth.uid(),v_request_id);

    select coalesce(sum(amount),0) into v_received
      from public.booking_payment_transactions where booking_id=b.id;
    update public.bookings set status='confirmed',
      payment_status=case when v_received >= total_price then 'fully_paid' else 'partially_paid' end,
      hold_expires_at=now(), updated_at=now() where id=b.id;
  end if;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'payment_'||p_decision,'payment',p.id,
    jsonb_build_object('booking_id',b.id,'amount_received',case when p_decision='verify' then p_amount_received else null end));
end;
$$;

revoke all on function public.admin_review_booking_payment_proof(uuid,text,numeric,uuid) from public, anon;
grant execute on function public.admin_review_booking_payment_proof(uuid,text,numeric,uuid) to authenticated;
revoke all on function public.review_payment(uuid,text,text) from public, anon, authenticated;

create or replace function public.admin_record_booking_payment(
  p_booking_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_request_id uuid
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
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_request_id is null then raise exception 'Payment request id is required'; end if;
  if p_payment_method not in ('cash','online') then raise exception 'Choose Cash or GCash / InstaPay'; end if;

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
  v_remaining := b.total_price - v_received;
  if p_amount > v_remaining then raise exception 'Payment exceeds the outstanding balance of %', v_remaining; end if;

  insert into public.booking_payment_transactions(booking_id,amount,payment_method,payment_type,received_by,idempotency_key)
  values(b.id,p_amount,p_payment_method,'balance',auth.uid(),p_request_id);

  v_received := v_received + p_amount;
  v_payment_status := case when v_received >= b.total_price then 'fully_paid'
                           when v_received > 0 then 'partially_paid' else 'unpaid' end;
  update public.bookings set payment_status=v_payment_status, updated_at=now() where id=b.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'booking_payment_recorded','booking',b.id,
    jsonb_build_object('amount',p_amount,'payment_method',p_payment_method,'payment_type','balance'));
  return jsonb_build_object('received',v_received,'outstanding',greatest(b.total_price-v_received,0),
    'payment_status',v_payment_status,'duplicate',false);
end;
$$;

revoke all on function public.admin_record_booking_payment(uuid,numeric,text,uuid) from public, anon;
grant execute on function public.admin_record_booking_payment(uuid,numeric,text,uuid) to authenticated;

commit;
