begin;

create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;

-- Push is a server-side fan-out. Only an admin can manage their own devices;
-- clients cannot read the delivery queue or mark events as sent.
create table if not exists public.admin_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  subscription jsonb not null,
  device_label text not null default 'This device',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_used_at timestamptz
);

alter table public.admin_push_subscriptions enable row level security;
drop policy if exists "Admins manage their push devices" on public.admin_push_subscriptions;
create policy "Admins manage their push devices"
on public.admin_push_subscriptions for all to authenticated
using (admin_user_id = (select auth.uid()) and public.is_admin())
with check (admin_user_id = (select auth.uid()) and public.is_admin());

create table if not exists public.admin_push_outbox (
  id uuid primary key default gen_random_uuid(),
  event_key text not null unique,
  event_type text not null check (event_type in ('booking_submitted','payment_proof_submitted','booking_cancelled')),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  payment_id uuid references public.payments(id) on delete set null,
  payload jsonb not null,
  status text not null default 'queued' check (status in ('queued','sending','sent')),
  attempts integer not null default 0,
  created_at timestamptz not null default now(),
  last_attempt_at timestamptz,
  sent_at timestamptz,
  last_error text
);

create index if not exists admin_push_outbox_due_idx
on public.admin_push_outbox(status,last_attempt_at,created_at);
alter table public.admin_push_outbox enable row level security;
revoke all on public.admin_push_outbox from anon, authenticated;
revoke all on public.admin_push_subscriptions from anon;
grant select,insert,update,delete on public.admin_push_subscriptions to authenticated;

create table if not exists public.admin_push_deliveries (
  event_id uuid not null references public.admin_push_outbox(id) on delete cascade,
  subscription_id uuid not null references public.admin_push_subscriptions(id) on delete cascade,
  status text not null default 'queued' check (status in ('queued','sending','sent')),
  attempts integer not null default 0,
  sent_at timestamptz,
  last_error text,
  primary key(event_id,subscription_id)
);
alter table public.admin_push_deliveries enable row level security;
revoke all on public.admin_push_deliveries from anon, authenticated;
grant all on public.admin_push_subscriptions, public.admin_push_outbox, public.admin_push_deliveries to service_role;

create or replace function public.enqueue_admin_push_event(
  p_event_type text,
  p_booking_id uuid,
  p_payment_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings;
  v_event_id uuid;
  v_key text;
  v_title text;
  v_body text;
  v_courts text;
  v_time text;
begin
  select * into b from public.bookings where id = p_booking_id;
  if b.id is null then return null; end if;

  v_key := case p_event_type
    when 'booking_submitted' then 'booking-submitted:' || b.id::text
    when 'booking_cancelled' then 'booking-cancelled:' || b.id::text
    when 'payment_proof_submitted' then 'payment-proof:' || coalesce(p_payment_id::text, b.id::text)
    else null end;
  if v_key is null then return null; end if;

  v_courts := coalesce((
    select string_agg(case (selection.value->>'court_id')::integer
      when 1 then 'Court 1 · The Basic' else 'Court 2 · The Pro' end, ' + ' order by (selection.value->>'court_id')::integer)
    from jsonb_array_elements(coalesce(b.court_selections,'[]'::jsonb)) as selection(value)
  ), case b.court_id when 1 then 'Court 1 · The Basic' else 'Court 2 · The Pro' end);
  v_time := coalesce(to_char(b.booking_date,'Mon DD, YYYY'), '') || ' · ' ||
    to_char(make_time(b.start_hour % 24,0,0),'FMHH12 AM') || ' onward';

  v_title := case p_event_type
    when 'booking_submitted' then 'New Booking Received!'
    when 'payment_proof_submitted' then 'Payment Proof Submitted'
    else 'Booking Cancelled' end;
  v_body := case p_event_type
    when 'booking_submitted' then coalesce(b.customer_name,'A customer') || ' submitted ' || b.reference || ' for ' || v_courts || '.'
    when 'payment_proof_submitted' then coalesce(b.customer_name,'A customer') || ' uploaded payment proof for ' || b.reference || '.'
    else coalesce(b.customer_name,'A customer') || ' cancelled booking ' || b.reference || '.' end;

  insert into public.admin_push_outbox(event_key,event_type,booking_id,payment_id,payload)
  values(v_key,p_event_type,b.id,p_payment_id,jsonb_build_object(
    'title',v_title,'body',v_body,'booking_id',b.id,'reference',b.reference,
    'booking_date',b.booking_date,'courts',v_courts,'time',v_time
  ))
  on conflict (event_key) do nothing
  returning id into v_event_id;

  if v_event_id is not null then
    perform public.dispatch_admin_push_event(v_event_id);
  end if;
  return v_event_id;
end;
$$;

create or replace function public.dispatch_admin_push_event(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
  v_event public.admin_push_outbox;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name='ADMIN_PUSH_FUNCTION_URL' limit 1;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='ADMIN_PUSH_DISPATCH_SECRET' limit 1;
  if nullif(v_url,'') is null or nullif(v_secret,'') is null then return; end if;

  select * into v_event from public.admin_push_outbox where id=p_event_id for update;
  if v_event.id is null or v_event.status='sent' then return; end if;
  if v_event.status='sending' and v_event.last_attempt_at > now()-interval '5 minutes' then return; end if;

  update public.admin_push_outbox
  set status='sending',attempts=attempts+1,last_attempt_at=now(),last_error=null
  where id=p_event_id;

  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type','application/json','x-admin-push-secret',v_secret),
    body := jsonb_build_object('event_id',p_event_id)
  );
exception when others then
  update public.admin_push_outbox
  set status='queued',last_error=left(sqlerrm,1000)
  where id=p_event_id and status <> 'sent';
  raise warning 'Could not dispatch admin push event %: %',p_event_id,sqlerrm;
end;
$$;

create or replace function public.dispatch_due_admin_push_events()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_event record;
begin
  for v_event in
    select id from public.admin_push_outbox
    where status='queued' or (status='sending' and last_attempt_at < now()-interval '5 minutes')
    order by created_at limit 50
  loop
    perform public.dispatch_admin_push_event(v_event.id);
  end loop;
end;
$$;

create or replace function public.enqueue_booking_push_from_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare p record;
begin
  if new.entity_type <> 'booking' then return new; end if;
  if new.action in ('booking_submitted','guest_booking_submitted') then
    perform public.enqueue_admin_push_event('booking_submitted',new.entity_id,null);
    -- Proof is uploaded during the initial hold. Notify the admin only after
    -- the customer actually submits the reservation, not abandoned checkout.
    for p in select id from public.payments where booking_id=new.entity_id and status='proof_submitted' loop
      perform public.enqueue_admin_push_event('payment_proof_submitted',new.entity_id,p.id);
    end loop;
  elsif new.action in ('customer_booking_cancelled','guest_booking_cancelled') then
    perform public.enqueue_admin_push_event('booking_cancelled',new.entity_id,null);
  end if;
  return new;
end;
$$;

drop trigger if exists admin_push_booking_audit on public.audit_logs;
create trigger admin_push_booking_audit
after insert on public.audit_logs
for each row execute function public.enqueue_booking_push_from_audit();

create or replace function public.enqueue_payment_proof_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_status text;
begin
  if new.status <> 'proof_submitted' then return new; end if;
  select status into v_status from public.bookings where id=new.booking_id;
  if v_status='pending' then
    perform public.enqueue_admin_push_event('payment_proof_submitted',new.booking_id,new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists admin_push_payment_proof on public.payments;
create trigger admin_push_payment_proof
after insert on public.payments
for each row execute function public.enqueue_payment_proof_push();

revoke all on function public.enqueue_admin_push_event(text,uuid,uuid) from public,anon,authenticated;
revoke all on function public.dispatch_admin_push_event(uuid) from public,anon,authenticated;
revoke all on function public.dispatch_due_admin_push_events() from public,anon,authenticated;
revoke all on function public.enqueue_booking_push_from_audit() from public,anon,authenticated;
revoke all on function public.enqueue_payment_proof_push() from public,anon,authenticated;

-- pg_cron provides recovery for callbacks interrupted by deploys/timeouts.
do $$
begin
  begin
    execute 'create extension if not exists pg_cron with schema pg_catalog';
    execute 'select cron.unschedule(jobid) from cron.job where jobname = ''admin-push-outbox-retry''';
    execute 'select cron.schedule(''admin-push-outbox-retry'', ''*/5 * * * *'', ''select public.dispatch_due_admin_push_events()'')';
  exception when others then
    raise notice 'Could not configure pg_cron for push retries; database-triggered delivery remains enabled: %', sqlerrm;
  end;
end;
$$;

commit;
